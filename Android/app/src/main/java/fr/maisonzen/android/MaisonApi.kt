package fr.maisonzen.android

import android.net.Uri
import com.google.gson.JsonObject
import com.google.gson.reflect.TypeToken
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.UUID
import java.util.concurrent.TimeUnit

class MaisonApi(private val address: String, private val token: String? = null) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    private inline fun <reified T> request(method: String, path: String, body: Any? = null): T {
        val builder = Request.Builder().url(address.trim().trimEnd('/') + path).header("Accept", "application/json")
        if (token != null) builder.header("Authorization", "Bearer $token")
        val requestBody = body?.let { MaisonJson.gson.toJson(it).toRequestBody(jsonType) }
        builder.method(method, when (method) { "GET", "DELETE" -> null; else -> requestBody ?: "{}".toRequestBody(jsonType) })
        client.newCall(builder.build()).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val message = runCatching { MaisonJson.gson.fromJson(text, JsonObject::class.java).get("error")?.asString }.getOrNull()
                    ?: when (response.code) { 401 -> "Session expirée. Reconnecte-toi."; 403 -> "Tu n’as pas l’autorisation pour cette action."; else -> "Erreur du serveur (${response.code})." }
                throw MaisonApiException(response.code, message)
            }
            if (T::class == Unit::class) return Unit as T
            return MaisonJson.gson.fromJson(text, object : TypeToken<T>() {}.type)
        }
    }

    fun register(email: String, password: String, name: String) = request<RegisterResult>("POST", "/api/auth/register", RegisterInput(email, password, name))
    fun verify(email: String, code: String) = request<AuthResult>("POST", "/api/auth/verify-email", VerifyInput(email, code))
    fun login(email: String, password: String) = request<AuthResult>("POST", "/api/auth/login", LoginInput(email, password))
    fun requestPasswordReset(email: String) = request<ResetRequestResult>("POST", "/api/auth/forgot-password", ForgotPasswordInput(email))
    fun resetPassword(email: String, code: String, newPassword: String) = request<JsonObject>("POST", "/api/auth/reset-password", ResetPasswordInput(email, code, newPassword))
    fun profile() = request<Profile>("GET", "/api/me")
    fun updatePublicKey(key: String) = request<JsonObject>("PUT", "/api/me/public-key", PublicKeyInput(key))
    fun saveRecoveryBackup(encrypted: String) = request<JsonObject>("PUT", "/api/me/recovery-backup", RecoveryBackupInput(encrypted))
    fun recoveryBackup(): String? = try { request<RecoveryBackupResult>("GET", "/api/me/recovery-backup").encryptedBackup } catch (error: MaisonApiException) { if (error.statusCode == 404) null else throw error }
    fun households(): List<Household> = request("GET", "/api/households")
    fun createHousehold(name: String, envelope: String, encryptedName: String) = request<Household>("POST", "/api/households", CreateHouseholdInput(encryptedName, envelope))
    fun members(id: UUID): List<Member> = request("GET", "/api/households/$id/members")
    fun publicKey(email: String) = request<JsonObject>("GET", "/api/users/public-key?email=${Uri.encode(email)}").get("publicKey").asString
    fun invite(id: UUID, email: String, role: String, envelope: String) = request<InviteResult>("POST", "/api/households/$id/invites", InviteInput(email, role, envelope))
    fun acceptInvite(code: String) = request<AcceptedInvite>("POST", "/api/households/accept-invite", AcceptInviteInput(code))
    fun records(id: UUID): List<ServerRecord> = request("GET", "/api/households/$id/records")
    fun createRecord(id: UUID, record: RecordInput) = request<ServerRecord>("POST", "/api/households/$id/records", record)
    fun updateRecord(id: UUID, record: RecordInput, revision: Long) = request<ServerRecord>("PUT", "/api/households/$id/records/${record.recordId}", UpdateRecordInput(revision, record))
    fun deleteRecord(householdId: UUID, recordId: UUID) = request<JsonObject>("DELETE", "/api/households/$householdId/records/$recordId")
    fun removeMember(householdId: UUID, memberId: UUID) = request<JsonObject>("DELETE", "/api/households/$householdId/members/$memberId")
    fun product(barcode: String) = request<ProductLookup>("GET", "/api/products/${Uri.encode(barcode)}")
}

class MaisonApiException(val statusCode: Int, message: String) : IllegalStateException(message)
