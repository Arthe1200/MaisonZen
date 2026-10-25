package fr.maisonzen.android

import android.app.Activity
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID
import kotlinx.coroutines.launch

@Composable
fun MessageBanner(message: String, error: Boolean) {
    Card(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 5.dp), colors = CardDefaults.cardColors(containerColor = if (error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer)) {
        Text(message, Modifier.padding(12.dp), color = if (error) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSecondaryContainer)
    }
}

@Composable
fun EmptyCard(message: String) {
    Card(Modifier.fillMaxWidth()) { Text(message, Modifier.padding(18.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

@Composable
fun DocumentCard(store: AppStore, document: MaisonDocument, canComplete: Boolean = false, onEdit: (() -> Unit)? = null) {
    val record = store.records[document.id]
    val detail = listOfNotNull(document.category, document.detail, document.date?.let(::formatInstant), document.recurrence?.takeIf { it != "Aucune" }).joinToString(" · ")
    Card(Modifier.fillMaxWidth().clickable(enabled = onEdit != null) { onEdit?.invoke() }) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            if (canComplete) {
                Checkbox(checked = document.completed, onCheckedChange = { store.saveExisting(document.copy(completed = it)) })
            }
            Column(Modifier.weight(1f)) {
                Text(document.title, fontWeight = FontWeight.SemiBold)
                if (detail.isNotBlank()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (document.amount != null) Text("%.2f €".format(document.amount), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
                if (document.kind == "food") {
                    val expiry = document.expirationDate
                    Text("${document.storagePlace ?: "Frigo"} · ${document.quantity ?: "1"} · ${expiry?.let { formatInstant(it) } ?: "Date à préciser"}", style = MaterialTheme.typography.bodySmall)
                }
                if (record?.audience == "owner") Text("Personnel · visible uniquement par toi", style = MaterialTheme.typography.labelSmall)
                if (record?.audience == "adults") Text("Visible par les adultes", style = MaterialTheme.typography.labelSmall)
            }
            if (store.canEdit(document)) {
                if (onEdit != null) TextButton(onClick = onEdit) { Text("Modifier") }
                androidx.compose.material3.IconButton(onClick = { store.deleteDocument(document) }) { androidx.compose.material3.Icon(Icons.Default.Delete, "Supprimer") }
            }
        }
    }
}

@Composable
fun ChatPage(store: AppStore, onNew: () -> Unit) {
    val messages = store.documents.filter { it.kind == "chat" }.sortedBy { it.date ?: Instant.MIN }
    LazyColumn(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Spacer(Modifier.height(8.dp)); Text("Messages", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold); Text("Messages chiffrés entre membres du foyer.", style = MaterialTheme.typography.bodySmall) }
        if (messages.isEmpty()) item { EmptyCard("La conversation du foyer est vide.") }
        items(messages, key = { it.id }) { item ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(14.dp)) { Row { Text(item.title, fontWeight = FontWeight.SemiBold); Spacer(Modifier.weight(1f)); Text(item.date?.let(::formatInstant) ?: "", style = MaterialTheme.typography.labelSmall) }; item.recipientId?.let { target -> Text("Message privé · ${store.members.firstOrNull { it.userId == target }?.displayName ?: "membre"}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary) }; Text(item.detail.orEmpty()) } }
        }
        item { OutlinedButton(onClick = onNew, modifier = Modifier.fillMaxWidth()) { Text("Écrire un message") } }
    }
}

@Composable
fun ChatComposer(store: AppStore, onClose: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var target by remember { mutableStateOf("all") }
    var targetMenu by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onClose, title = { Text("Nouveau message") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { targetMenu = true }) { Text(if (target == "all") "Tout le foyer" else store.members.firstOrNull { it.userId.toString() == target }?.displayName ?: "Choisir un membre") }
            DropdownMenu(expanded = targetMenu, onDismissRequest = { targetMenu = false }) {
                DropdownMenuItem(text = { Text("Tout le foyer") }, onClick = { target = "all"; targetMenu = false })
                store.members.filter { it.userId != store.userId }.forEach { member -> DropdownMenuItem(text = { Text(member.displayName) }, onClick = { target = member.userId.toString(); targetMenu = false }) }
            }
            OutlinedTextField(text, { text = it }, label = { Text("Message") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
        }
    }, confirmButton = {
        Button(onClick = {
            val targetId = runCatching { UUID.fromString(target) }.getOrNull()
            val private = target != "all" && targetId != null
            val doc = MaisonDocument(kind = "chat", title = store.displayName, detail = text.trim(), category = if (private) "privé" else "foyer", date = Instant.now(), recipientId = targetId, allowedMembers = if (private) listOfNotNull(store.userId, targetId) else emptyList())
            store.saveDocument(doc, if (private) "members" else "household", allowed = if (private) doc.allowedMembers else emptyList())
            onClose()
        }, enabled = text.isNotBlank()) { Text("Envoyer") }
    }, dismissButton = { TextButton(onClick = onClose) { Text("Annuler") } })
}

@Composable
fun FamilyPage(store: AppStore, onCreateHousehold: () -> Unit) {
    var inviteDialog by remember { mutableStateOf(false) }
    var selectHouse by remember { mutableStateOf(false) }
    LazyColumn(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        item { Spacer(Modifier.height(8.dp)); Text("Foyer", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold) }
        item { OutlinedButton(onClick = { selectHouse = true }, modifier = Modifier.fillMaxWidth()) { Text("Foyer actif : ${store.selectedName}  ·  ${store.selectedHousehold?.role ?: ""}") } }
        item { OutlinedButton(onClick = onCreateHousehold, modifier = Modifier.fillMaxWidth()) { Text("Créer ou rejoindre un autre foyer") } }
        item { Text("Membres", style = MaterialTheme.typography.titleLarge) }
        items(store.members, key = { it.userId }) { member ->
            Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) { Column(Modifier.weight(1f)) { Text(member.displayName, fontWeight = FontWeight.SemiBold); Text(roleLabel(member.role), style = MaterialTheme.typography.bodySmall) }; if (store.selectedHousehold?.role == "admin" && member.userId != store.userId) TextButton(onClick = { store.removeMember(member) }) { Text("Retirer") } } }
        }
        if (store.selectedHousehold?.role == "admin") item { Button(onClick = { inviteDialog = true }, modifier = Modifier.fillMaxWidth()) { Text("Inviter une personne") } }
    }
    if (selectHouse) AlertDialog(onDismissRequest = { selectHouse = false }, title = { Text("Choisir un foyer") }, text = { Column { store.households.forEach { household -> TextButton(onClick = { store.selectHousehold(household); selectHouse = false }) { Text("${store.householdNames[household.householdId] ?: "Foyer"} · ${roleLabel(household.role)}") } } } }, confirmButton = { TextButton(onClick = { selectHouse = false }) { Text("Fermer") } })
    if (inviteDialog) InviteDialog(store) { inviteDialog = false }
}

@Composable
private fun InviteDialog(store: AppStore, onClose: () -> Unit) {
    var email by remember { mutableStateOf("") }
    var role by remember { mutableStateOf("adult") }
    var roleMenu by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onClose, title = { Text("Inviter un membre") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("La personne doit d’abord créer et vérifier son compte Maison Zen.", style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(email, { email = it }, label = { Text("E-mail du compte") }, modifier = Modifier.fillMaxWidth())
            OutlinedButton(onClick = { roleMenu = true }) { Text("Rôle : ${roleLabel(role)}") }
            DropdownMenu(roleMenu, { roleMenu = false }) { listOf("adult", "child", "tenant").forEach { DropdownMenuItem(text = { Text(roleLabel(it)) }, onClick = { role = it; roleMenu = false }) } }
        }
    }, confirmButton = { Button(onClick = { store.invite(email, role); onClose() }, enabled = email.contains('@')) { Text("Créer le code") } }, dismissButton = { TextButton(onClick = onClose) { Text("Annuler") } })
}

@Composable
fun SettingsPage(store: AppStore) {
    var server by rememberSaveable { mutableStateOf(store.serverAddress) }
    var saved by rememberSaveable { mutableStateOf(false) }
    var showRecovery by remember { mutableStateOf(false) }
    Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Réglages", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) { Text("Serveur familial", style = MaterialTheme.typography.titleMedium); OutlinedTextField(server, { server = it }, label = { Text("Adresse") }, supportingText = { Text("Sur le réseau local : http://IP_DU_PC:5080") }, modifier = Modifier.fillMaxWidth()); Button(onClick = { store.setServerAddress(server); store.refresh(); saved = true }, modifier = Modifier.fillMaxWidth()) { Text(if (saved) "Adresse enregistrée" else "Enregistrer et synchroniser") } } }
        Card { Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) { Column(Modifier.weight(1f)) { Text("Mode tableau de bord", style = MaterialTheme.typography.titleMedium); Text("Affichage simplifié pour une tablette dédiée.", style = MaterialTheme.typography.bodySmall) }; Switch(checked = store.dashboardMode, onCheckedChange = store::setDashboardMode) } }
        Card { Column(Modifier.padding(16.dp)) { Text("Compte", style = MaterialTheme.typography.titleMedium); Text("${store.displayName} · ${store.email}"); Text("Les données de la maison sont chiffrées sur l’appareil avant leur envoi.", style = MaterialTheme.typography.bodySmall) } }
        Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { Text("Récupérer tes données sur un nouvel appareil", style = MaterialTheme.typography.titleMedium); Text("Crée une sauvegarde chiffrée et conserve son code de récupération. Il sera demandé lors de la première connexion sur un autre téléphone.", style = MaterialTheme.typography.bodySmall); Button(onClick = { store.createRecoveryBackup(); showRecovery = true }) { Text("Créer / mettre à jour la sauvegarde") }; store.recoveryCodeForDisplay?.let { SelectionContainer { Text("Code de récupération :\n$it", fontWeight = FontWeight.Bold) } } } }
        OutlinedButton(onClick = { store.refresh() }, modifier = Modifier.fillMaxWidth()) { Text("Synchroniser maintenant") }
        TextButton(onClick = { store.signOut() }, modifier = Modifier.fillMaxWidth()) { Text("Se déconnecter") }
    }
    if (showRecovery && store.recoveryCodeForDisplay != null) AlertDialog(onDismissRequest = { showRecovery = false }, title = { Text("Code de récupération") }, text = { SelectionContainer { Text("Note et conserve ce code hors de ton téléphone. Il déverrouille la copie chiffrée de tes clés.\n\n${store.recoveryCodeForDisplay}") } }, confirmButton = { TextButton(onClick = { showRecovery = false }) { Text("J’ai noté le code") } })
}

@Composable
fun RecoveryScreen(store: AppStore) {
    var code by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center) {
        Text("Récupération du compte", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Text("Une sauvegarde chiffrée existe pour ce compte. Saisis le code de récupération créé sur ton autre appareil pour déverrouiller tes foyers.", Modifier.padding(vertical = 12.dp))
        OutlinedTextField(code, { code = it }, label = { Text("Code de récupération") }, modifier = Modifier.fillMaxWidth())
        Button(onClick = { store.restoreWithRecoveryCode(code) }, enabled = code.isNotBlank() && !store.isBusy, modifier = Modifier.fillMaxWidth().padding(top = 10.dp)) { Text("Récupérer les clés") }
        TextButton(onClick = { store.signOut() }, modifier = Modifier.fillMaxWidth()) { Text("Retour à la connexion") }
        store.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        if (store.isBusy) androidx.compose.material3.CircularProgressIndicator(Modifier.padding(top = 12.dp))
    }
}

@Composable
fun DocumentEditor(store: AppStore, kind: String, document: MaisonDocument? = null, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var title by remember(document?.id) { mutableStateOf(document?.title.orEmpty()) }
    var detail by remember(document?.id) { mutableStateOf(document?.detail.orEmpty()) }
    var amount by remember(document?.id) { mutableStateOf(document?.amount?.toString().orEmpty()) }
    var category by remember(document?.id) { mutableStateOf(document?.category ?: when (kind) { "expense" -> "Courses"; "subscription" -> "Maison"; else -> "" }) }
    var recurrence by remember(document?.id) { mutableStateOf(document?.recurrence ?: "Aucune") }
    var recurrenceMenu by remember { mutableStateOf(false) }
    var due by remember(document?.id) { mutableStateOf((document?.expirationDate ?: document?.date)?.atZone(ZoneId.systemDefault())?.toLocalDateTime() ?: LocalDateTime.now().plusDays(1).withHour(9).withMinute(0).withSecond(0).withNano(0)) }
    var shared by remember(document?.id) { mutableStateOf(document?.let { store.records[it.id]?.audience == "adults" } ?: false) }
    var silent by remember(document?.id) { mutableStateOf(document?.isSilent ?: false) }
    var target by remember(document?.id) { mutableStateOf(document?.let { item -> item.recipientId?.toString() ?: if (store.records[item.id]?.audience == "owner") "me" else "all" } ?: "all") }
    var targetMenu by remember { mutableStateOf(false) }
    var barcode by remember(document?.id) { mutableStateOf(document?.barcode.orEmpty()) }
    var quantity by remember(document?.id) { mutableStateOf(document?.quantity ?: "1") }
    var storage by remember(document?.id) { mutableStateOf(document?.storagePlace ?: "Frigo") }
    var storageMenu by remember { mutableStateOf(false) }
    var lookingUp by remember { mutableStateOf(false) }
    val dateLabel = due.format(DateTimeFormatter.ofPattern("dd/MM/yyyy · HH:mm"))

    AlertDialog(onDismissRequest = onClose, title = { Text(if (document == null) editorTitle(kind) else "Modifier · ${document.title}") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            OutlinedTextField(title, { title = it }, label = { Text(if (kind == "food") "Nom du produit" else "Titre") }, modifier = Modifier.fillMaxWidth())
            if (kind !in setOf("calendar")) OutlinedTextField(detail, { detail = it }, label = { Text(if (kind == "food") "Marque (facultatif)" else "Détail (facultatif)") }, modifier = Modifier.fillMaxWidth())
            if (kind in setOf("expense", "subscription")) {
                OutlinedTextField(amount, { amount = it }, label = { Text("Montant (€)") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
                OutlinedTextField(category, { category = it }, label = { Text("Catégorie") }, modifier = Modifier.fillMaxWidth())
            }
            if (kind in setOf("reminder", "task", "calendar", "subscription", "food")) {
                Text(if (kind == "food") "À consommer avant" else "Date et heure", style = MaterialTheme.typography.labelLarge)
                OutlinedButton(onClick = {
                    DatePickerDialog(context, { _, year, month, day -> due = due.withDayOfMonth(1).withYear(year).withMonth(month + 1).withDayOfMonth(day) }, due.year, due.monthValue - 1, due.dayOfMonth).show()
                }, modifier = Modifier.fillMaxWidth()) { Text(dateLabel) }
                if (kind != "food") OutlinedButton(onClick = {
                    TimePickerDialog(context, { _, hour, minute -> due = due.withHour(hour).withMinute(minute) }, due.hour, due.minute, true).show()
                }, modifier = Modifier.fillMaxWidth()) { Text("Heure du rappel : %02d:%02d".format(due.hour, due.minute)) }
            }
            if (kind in setOf("reminder", "task")) {
                Text("Attribuer à", style = MaterialTheme.typography.labelLarge)
                OutlinedButton(onClick = { targetMenu = true }, enabled = document == null || store.records[document.id]?.audience != "members", modifier = Modifier.fillMaxWidth()) { Text(targetLabel(target, store)) }
                DropdownMenu(targetMenu, { targetMenu = false }) {
                    DropdownMenuItem(text = { Text("Tout le foyer") }, onClick = { target = "all"; targetMenu = false })
                    DropdownMenuItem(text = { Text("Moi uniquement") }, onClick = { target = "me"; targetMenu = false })
                    store.members.filter { it.userId != store.userId }.forEach { member -> DropdownMenuItem(text = { Text(member.displayName) }, onClick = { target = member.userId.toString(); targetMenu = false }) }
                }
            }
            if (kind in setOf("reminder", "task", "subscription")) {
                OutlinedButton(onClick = { recurrenceMenu = true }, modifier = Modifier.fillMaxWidth()) { Text("Répétition : $recurrence") }
                DropdownMenu(recurrenceMenu, { recurrenceMenu = false }) { listOf("Aucune", "Chaque jour", "Chaque semaine", "Chaque mois", "Chaque année").forEach { DropdownMenuItem(text = { Text(it) }, onClick = { recurrence = it; recurrenceMenu = false }) } }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("Notification silencieuse", Modifier.weight(1f)); Switch(silent, { silent = it }) }
            }
            if (kind in setOf("expense", "subscription") && store.isAdult) {
                Row(verticalAlignment = Alignment.CenterVertically) { Column(Modifier.weight(1f)) { Text("Élément commun aux adultes"); Text(if (document == null) "Désactivé : visible seulement par toi." else "La visibilité ne peut pas être modifiée après l’enregistrement.", style = MaterialTheme.typography.bodySmall) }; Switch(shared, { shared = it }, enabled = document == null) }
            }
            if (kind == "food") {
                OutlinedTextField(quantity, { quantity = it }, label = { Text("Quantité") }, modifier = Modifier.fillMaxWidth())
                OutlinedButton(onClick = { storageMenu = true }) { Text("Rangement : $storage") }
                DropdownMenu(storageMenu, { storageMenu = false }) { listOf("Frigo", "Congélateur", "Placard").forEach { DropdownMenuItem(text = { Text(it) }, onClick = { storage = it; storageMenu = false }) } }
                OutlinedTextField(barcode, { barcode = it.filter(Char::isDigit) }, label = { Text("Code-barres") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
                val activity = context as? Activity
                OutlinedButton(onClick = {
                    if (activity == null) return@OutlinedButton
                    GmsBarcodeScanning.getClient(activity).startScan().addOnSuccessListener { result ->
                        val value = result.rawValue ?: return@addOnSuccessListener
                        barcode = value; lookingUp = true
                        scope.launch { runCatching { store.lookupProduct(value) }.onSuccess { product -> title = product.name ?: title; detail = product.brand ?: detail; quantity = product.quantity ?: quantity }.onFailure { store.setLookupError(it.message) }; lookingUp = false }
                    }
                }, modifier = Modifier.fillMaxWidth()) { Text(if (lookingUp) "Recherche du produit…" else "Scanner le code-barres") }
                Text("Si le code n’est pas reconnu, saisis le nom du produit à la main.", style = MaterialTheme.typography.bodySmall)
            }
            if (store.errorMessage != null) Text(store.errorMessage!!, color = MaterialTheme.colorScheme.error)
        }
    }, confirmButton = {
        Button(onClick = {
            val instant = due.atZone(ZoneId.systemDefault()).toInstant()
            val recipient = when (target) { "all", "me" -> null; else -> runCatching { UUID.fromString(target) }.getOrNull() }
            val doc = when (kind) {
                "expense", "subscription" -> MaisonDocument(id = document?.id ?: UUID.randomUUID(), kind = kind, title = title.trim(), amount = amount.replace(',', '.').toDoubleOrNull(), category = category.ifBlank { null }, date = instant, recurrence = recurrence, allowedMembers = store.members.map { it.userId }, notifyAt = instant, isSilent = silent)
                "reminder", "task" -> MaisonDocument(id = document?.id ?: UUID.randomUUID(), kind = kind, title = title.trim(), detail = detail.ifBlank { null }, date = instant, recurrence = recurrence, recipientId = recipient, allowedMembers = listOfNotNull(store.userId, recipient), notifyAt = instant, isSilent = silent)
                "food" -> MaisonDocument(id = document?.id ?: UUID.randomUUID(), kind = "food", title = title.trim(), detail = detail.ifBlank { null }, date = instant, barcode = barcode.ifBlank { null }, expirationDate = instant, storagePlace = storage, quantity = quantity, notifyAt = instant.minus(3, java.time.temporal.ChronoUnit.DAYS).coerceAtLeast(Instant.now()))
                else -> MaisonDocument(id = document?.id ?: UUID.randomUUID(), kind = "calendar", title = title.trim(), detail = detail.ifBlank { null }, date = instant)
            }
            when (kind) {
                "expense", "subscription" -> {
                    val existing = document?.let { store.records[it.id] }
                    store.saveDocument(doc, existing?.audience ?: if (shared && store.isAdult) "adults" else "owner", existing?.ownerId ?: if (shared && store.isAdult) null else store.userId, existing?.allowedMemberIds ?: emptyList())
                }
                "reminder" -> {
                    val existing = document?.let { store.records[it.id] }
                    when {
                        existing != null -> store.saveDocument(doc, existing.audience, existing.ownerId, existing.allowedMemberIds)
                        target == "me" -> store.saveDocument(doc, "owner", store.userId)
                        target == "all" -> store.saveDocument(doc, "household")
                        else -> store.saveDocument(doc, "members", allowed = doc.allowedMembers)
                    }
                }
                else -> store.saveDocument(doc, "household")
            }
            onClose()
        }, enabled = title.isNotBlank() && (kind !in setOf("expense", "subscription") || amount.replace(',', '.').toDoubleOrNull() != null)) { Text("Enregistrer") }
    }, dismissButton = { TextButton(onClick = onClose) { Text("Annuler") } })
}

private fun formatInstant(value: Instant): String = value.atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm"))
private fun editorTitle(kind: String) = when (kind) { "expense" -> "Nouvelle dépense"; "subscription" -> "Nouvel abonnement"; "reminder" -> "Nouveau rappel"; "task" -> "Nouvelle tâche / devoir"; "food" -> "Ajouter un produit"; else -> "Ajouter au planning" }
private fun targetLabel(target: String, store: AppStore) = when (target) { "all" -> "Tout le foyer"; "me" -> "Moi uniquement"; else -> store.members.firstOrNull { it.userId.toString() == target }?.displayName ?: "Membre" }
private fun roleLabel(role: String) = when (role) { "admin" -> "Administrateur"; "adult" -> "Adulte / parent"; "child" -> "Enfant"; "tenant" -> "Locataire"; else -> role }

