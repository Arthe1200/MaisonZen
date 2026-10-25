package fr.maisonzen.android

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.time.Duration
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class AppStore(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences("maisonzen.settings", 0)
    val vault = SecureVault(application)
    var serverAddress by mutableStateOf(preferences.getString("server", "http://192.168.1.168:5080") ?: "")
        private set
    var token by mutableStateOf(vault.token())
        private set
    var userId by mutableStateOf<UUID?>(null)
        private set
    var displayName by mutableStateOf("")
        private set
    var email by mutableStateOf(preferences.getString("email", "") ?: "")
        private set
    var pendingEmail by mutableStateOf("")
        private set
    var pendingName by mutableStateOf("")
        private set
    var pendingResetEmail by mutableStateOf("")
        private set
    var developmentCode by mutableStateOf<String?>(null)
        private set
    var recoveryNeeded by mutableStateOf(false)
        private set
    var recoveryCodeForDisplay by mutableStateOf<String?>(null)
        private set
    private var pendingRecoveryBackup: String? = null
    var households by mutableStateOf<List<Household>>(emptyList())
        private set
    var householdNames by mutableStateOf<Map<UUID, String>>(emptyMap())
        private set
    var selectedHousehold by mutableStateOf<Household?>(null)
        private set
    var members by mutableStateOf<List<Member>>(emptyList())
        private set
    var documents by mutableStateOf<List<MaisonDocument>>(emptyList())
        private set
    var records by mutableStateOf<Map<UUID, ServerRecord>>(emptyMap())
        private set
    var isBusy by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    var infoMessage by mutableStateOf<String?>(null)
        private set
    var currentPage by mutableStateOf(if (preferences.getBoolean("dashboard", false)) "Tableau de bord" else "Accueil")
    var dashboardMode by mutableStateOf(preferences.getBoolean("dashboard", false))

    val isAdult: Boolean get() = selectedHousehold?.role in setOf("admin", "adult")
    val isSignedIn: Boolean get() = token != null
    val selectedName: String get() = selectedHousehold?.let { householdNames[it.householdId] } ?: "Mon foyer"

    init { if (token != null) viewModelScope.launch { restoreSession() } }

    fun setServerAddress(value: String) {
        serverAddress = value.trim().trimEnd('/')
        preferences.edit().putString("server", serverAddress).apply()
    }

    fun setDashboardMode(enabled: Boolean) {
        dashboardMode = enabled
        preferences.edit().putBoolean("dashboard", enabled).apply()
        currentPage = if (enabled) "Tableau de bord" else "Accueil"
    }

    private fun api(authenticated: Boolean = true): MaisonApi {
        val base = serverAddress.trim().trimEnd('/')
        require(base.startsWith("http://") || base.startsWith("https://")) { "Indique l’adresse du serveur, par exemple http://192.168.1.168:5080" }
        return MaisonApi(base, if (authenticated) token else null)
    }

    fun register(name: String, address: String, password: String) = execute {
        require(password.length >= 12) { "Le mot de passe doit contenir au moins 12 caractères." }
        setServerAddress(serverAddress)
        val result = io { api(false).register(address.trim(), password, name.trim()) }
        pendingEmail = address.trim(); pendingName = name.trim(); email = address.trim(); preferences.edit().putString("email", email).apply(); developmentCode = result.developmentCode
        infoMessage = if (developmentCode == null) "Un code de vérification a été envoyé par e-mail." else "Code de test : $developmentCode"
        currentPage = "Vérification"
    }

    fun verify(code: String) = execute {
        val auth = io { api(false).verify(pendingEmail, code.trim()) }
        establishSession(auth.accessToken, auth.userId, auth.displayName)
        publishDeviceKey()
        refreshHouseholds()
    }

    fun login(address: String, password: String) = execute {
        email = address.trim()
        preferences.edit().putString("email", email).apply()
        val auth = io { api(false).login(email, password) }
        establishSession(auth.accessToken, auth.userId, auth.displayName)
        prepareAccountKeys()
    }

    fun requestPasswordReset(address: String) = execute {
        pendingResetEmail = address.trim()
        val result = io { api(false).requestPasswordReset(pendingResetEmail) }
        developmentCode = result.developmentCode
        infoMessage = if (developmentCode == null) "Si ce compte existe, un code de réinitialisation a été envoyé par e-mail." else "Code de test : $developmentCode"
        currentPage = "Code réinitialisation"
    }

    fun resetPassword(code: String, newPassword: String) = execute {
        require(newPassword.length >= 12) { "Le nouveau mot de passe doit contenir au moins 12 caractères." }
        io { api(false).resetPassword(pendingResetEmail, code.trim(), newPassword) }
        currentPage = "Accueil"
        infoMessage = "Mot de passe modifié. Tu peux maintenant te connecter."
    }

    fun signOut() {
        vault.saveToken(null); token = null; userId = null; displayName = ""; households = emptyList(); householdNames = emptyMap()
        selectedHousehold = null; members = emptyList(); documents = emptyList(); records = emptyMap(); currentPage = "Accueil"; recoveryNeeded = false; pendingRecoveryBackup = null
    }

    fun restoreSession() = execute {
        val profile = io { api().profile() }
        userId = profile.userId; displayName = profile.displayName
        prepareAccountKeys()
    }

    private suspend fun establishSession(accessToken: String, id: UUID, name: String) {
        vault.saveToken(accessToken); token = accessToken; userId = id; displayName = name
    }

    private suspend fun prepareAccountKeys() {
        if (!vault.hasDeviceKey()) {
            val backup = io { api().recoveryBackup() }
            if (backup != null) {
                val localCode = vault.recoveryCode()
                if (localCode != null) vault.restoreRecoveryBackup(backup, localCode)
                else { pendingRecoveryBackup = backup; recoveryNeeded = true; infoMessage = "Entre le code de récupération Maison Zen de cet appareil."; return }
            }
        }
        publishDeviceKey()
        refreshHouseholds()
    }

    private suspend fun publishDeviceKey() {
        io { api().updatePublicKey(vault.publicKeyBase64()) }
        recoveryNeeded = false; pendingRecoveryBackup = null
    }

    fun restoreWithRecoveryCode(code: String) = execute {
        val backup = pendingRecoveryBackup ?: io { api().recoveryBackup() } ?: error("Aucune sauvegarde de récupération trouvée pour ce compte.")
        vault.restoreRecoveryBackup(backup, code)
        publishDeviceKey()
        refreshHouseholds()
        infoMessage = "Clés récupérées. Les foyers vont se synchroniser."
    }

    fun createRecoveryBackup() = execute {
        val (code, encrypted) = vault.makeRecoveryBackup()
        io { api().saveRecoveryBackup(encrypted) }
        recoveryCodeForDisplay = code
        infoMessage = "Sauvegarde chiffrée enregistrée sur le serveur. Garde ce code en lieu sûr."
    }

    private suspend fun refreshRecoveryBackupIfConfigured() {
        val code = vault.recoveryCode() ?: return
        val (_, encrypted) = vault.makeRecoveryBackup()
        io { api().saveRecoveryBackup(encrypted) }
    }

    private suspend fun refreshHouseholds() {
        try {
            val list = io { api().households() }
            households = list
            val names = householdNames.toMutableMap()
            list.forEach { household ->
                runCatching {
                    val bundle = vault.unwrap(household.keyEnvelope)
                    vault.saveHouseholdKey(household.householdId, bundle.householdKey)
                    bundle.adultKey?.let { vault.saveAdultKey(household.householdId, it) }
                    val key = vault.householdKey(household.householdId) ?: return@runCatching
                    names[household.householdId] = vault.decryptText(household.encryptedName, ZERO_UUID, ZERO_UUID, key)
                }
            }
            householdNames = names
            if (selectedHousehold == null || list.none { it.householdId == selectedHousehold?.householdId }) selectedHousehold = list.firstOrNull()
            selectedHousehold?.let { sync(it.householdId) }
        } catch (error: Throwable) {
            errorMessage = error.message ?: "Impossible de charger les foyers."
        }
    }

    fun selectHousehold(household: Household) = execute { selectedHousehold = household; sync(household.householdId) }

    fun createHousehold(name: String) = execute {
        require(name.isNotBlank()) { "Donne un nom au foyer." }
        val key = ByteArray(32).also(java.security.SecureRandom()::nextBytes)
        val adult = ByteArray(32).also(java.security.SecureRandom()::nextBytes)
        val encryptedName = vault.encryptText(name.trim(), ZERO_UUID, ZERO_UUID, key)
        val envelope = vault.createHouseholdEnvelope(key, adult)
        val household = io { api().createHousehold(name, envelope, encryptedName) }
        vault.saveHouseholdKey(household.householdId, key); vault.saveAdultKey(household.householdId, adult)
        householdNames = householdNames + (household.householdId to name.trim())
        households = households + household; selectedHousehold = household
        sync(household.householdId); infoMessage = "Le foyer « ${name.trim()} » est prêt."
        refreshRecoveryBackupIfConfigured()
    }

    fun acceptInvite(code: String) = execute {
        val accepted = io { api().acceptInvite(code.trim()) }
        val bundle = vault.unwrap(accepted.keyEnvelope)
        vault.saveHouseholdKey(accepted.householdId, bundle.householdKey)
        bundle.adultKey?.let { vault.saveAdultKey(accepted.householdId, it) }
        refreshRecoveryBackupIfConfigured()
        refreshHouseholds()
        infoMessage = "Tu as rejoint le foyer."
    }

    fun invite(emailAddress: String, role: String) = execute {
        val household = selectedHousehold ?: error("Choisis un foyer d’abord.")
        require(household.role == "admin") { "Seul l’administrateur peut inviter des membres." }
        val householdKey = vault.householdKey(household.householdId) ?: error("Clé du foyer introuvable.")
        val publicKey = io { api().publicKey(emailAddress.trim()) }
        val adultKey = if (role == "adult") vault.adultKey(household.householdId) ?: error("Clé réservée aux adultes indisponible.") else null
        val envelope = vault.wrap(householdKey, adultKey, publicKey)
        val result = io { api().invite(household.householdId, emailAddress.trim(), role, envelope) }
        infoMessage = "Code d’invitation à partager : ${result.inviteCode} (valable ${result.expiresInDays} jours)."
    }

    fun removeMember(member: Member) = execute {
        val household = selectedHousehold ?: return@execute
        require(household.role == "admin") { "Seul l’administrateur peut retirer un membre." }
        io { api().removeMember(household.householdId, member.userId) }
        sync(household.householdId)
        infoMessage = "${member.displayName} a été retiré du foyer."
    }

    private suspend fun sync(householdId: UUID) {
        val household = households.firstOrNull { it.householdId == householdId } ?: selectedHousehold ?: return
        val houseKey = vault.householdKey(householdId) ?: error("Clé du foyer absente sur cet appareil.")
        val (remote, people) = io { api().records(householdId) to api().members(householdId) }
        val decoded = remote.mapNotNull { record ->
            if (record.deleted) return@mapNotNull null
            val recordKey = when (record.audience) {
                "owner" -> if (record.ownerId == userId) userId?.let(vault::personalKey) else null
                "adults" -> vault.adultKey(householdId)
                else -> houseKey
            } ?: return@mapNotNull null
            runCatching { vault.decrypt(record, householdId, recordKey) }.getOrNull()
        }.sortedBy { it.date ?: Instant.MAX }
        if (selectedHousehold?.householdId == householdId) {
            documents = decoded; records = remote.associateBy { it.recordId }; members = people
            decoded.filter { !it.completed && (it.recipientId == null || it.recipientId == userId) && it.kind in setOf("reminder", "task", "food", "subscription") }
                .forEach(::scheduleReminder)
        }
    }

    fun refresh() = execute { selectedHousehold?.let { sync(it.householdId) } }

    fun saveDocument(document: MaisonDocument, audience: String = "household", ownerId: UUID? = null, allowed: List<UUID> = emptyList()) = execute {
        val household = selectedHousehold ?: error("Crée ou sélectionne un foyer avant d’enregistrer.")
        val key = when (audience) {
            "owner" -> {
                require(ownerId == userId) { "Une donnée personnelle ne peut être créée que pour ton compte." }
                vault.personalKey(userId ?: error("Compte introuvable."))
            }
            "adults" -> {
                require(isAdult) { "Cette information est réservée aux adultes." }
                vault.adultKey(household.householdId) ?: error("Clé réservée aux adultes indisponible.")
            }
            else -> vault.householdKey(household.householdId) ?: error("Clé du foyer introuvable.")
        }
        val input = RecordInput(document.id, audience, ownerId, allowed, vault.encrypt(document, household.householdId, key))
        val existing = records[document.id]
        io {
            if (existing == null) api().createRecord(household.householdId, input)
            else api().updateRecord(household.householdId, input, existing.revision)
        }
        sync(household.householdId)
        if (document.completed) WorkManager.getInstance(getApplication()).cancelUniqueWork("maisonzen-${document.id}")
        else if (document.kind in setOf("reminder", "task", "food", "subscription") && (document.recipientId == null || document.recipientId == userId)) scheduleReminder(document, replace = true)
        infoMessage = "Enregistré."
    }

    fun saveExisting(document: MaisonDocument) {
        val record = records[document.id] ?: return
        saveDocument(document, record.audience, record.ownerId, record.allowedMemberIds)
    }

    fun deleteDocument(document: MaisonDocument) = execute {
        val household = selectedHousehold ?: return@execute
        val record = records[document.id] ?: return@execute
        io { api().deleteRecord(household.householdId, document.id) }
        WorkManager.getInstance(getApplication()).cancelUniqueWork("maisonzen-${document.id}")
        sync(household.householdId)
    }

    suspend fun lookupProduct(barcode: String): ProductLookup = io { api().product(barcode.trim()) }

    fun setLookupError(message: String?) { errorMessage = message }

    fun canEdit(document: MaisonDocument): Boolean = when (records[document.id]?.audience) {
        "owner" -> records[document.id]?.ownerId == userId
        "adults" -> isAdult
        else -> true
    }

    private fun scheduleReminder(document: MaisonDocument, replace: Boolean = false) {
        val date = document.notifyAt ?: document.expirationDate ?: document.date ?: return
        val data = Data.Builder().putString("recordId", document.id.toString()).putString("title", document.title)
            .putString("detail", document.detail ?: "Rappel Maison Zen").putBoolean("silent", document.isSilent)
            .putString("recurrence", document.recurrence ?: "Aucune").build()
        val delay = Duration.between(Instant.now(), date).toMillis().coerceAtLeast(0)
        val request = OneTimeWorkRequestBuilder<MaisonNotificationWorker>().setInputData(data).setInitialDelay(delay, java.util.concurrent.TimeUnit.MILLISECONDS).build()
        WorkManager.getInstance(getApplication()).enqueueUniqueWork("maisonzen-${document.id}", if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP, request)
    }

    private fun execute(block: suspend () -> Unit) {
        viewModelScope.launch {
            isBusy = true; errorMessage = null; infoMessage = null
            try { block() } catch (error: Throwable) { errorMessage = error.message ?: "Une erreur est survenue." }
            finally { isBusy = false }
        }
    }

    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }
}
