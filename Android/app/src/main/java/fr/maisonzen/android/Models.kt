package fr.maisonzen.android

import com.google.gson.annotations.SerializedName
import java.time.Instant
import java.util.UUID

data class Household(
    val householdId: UUID,
    val role: String,
    val encryptedName: String,
    val keyEnvelope: String
)

data class Member(
    val userId: UUID,
    val displayName: String,
    val role: String,
    val keyEnvelope: String
)

data class ServerRecord(
    val recordId: UUID,
    val audience: String,
    val ownerId: UUID?,
    val allowedMemberIds: List<UUID> = emptyList(),
    val ciphertext: String,
    val revision: Long,
    val updatedAt: Instant,
    val deleted: Boolean
)

data class RecordInput(
    val recordId: UUID,
    val audience: String,
    val ownerId: UUID? = null,
    val allowedMemberIds: List<UUID> = emptyList(),
    val ciphertext: String
)

data class UpdateRecordInput(val expectedRevision: Long, val record: RecordInput)

data class MaisonDocument(
    val id: UUID = UUID.randomUUID(),
    val kind: String,
    val title: String,
    val detail: String? = null,
    val amount: Double? = null,
    val category: String? = null,
    val date: Instant? = null,
    val recurrence: String? = null,
    val recipientId: UUID? = null,
    val allowedMembers: List<UUID> = emptyList(),
    val completed: Boolean = false,
    val barcode: String? = null,
    val expirationDate: Instant? = null,
    val storagePlace: String? = null,
    val quantity: String? = null,
    val ingredients: List<String> = emptyList(),
    val steps: List<String> = emptyList(),
    val servings: Int? = null,
    val dietaryTags: List<String> = emptyList(),
    val durationMinutes: Int? = null,
    val repeatUntil: Instant? = null,
    val notifyAt: Instant? = null,
    val isSilent: Boolean = false
)

data class AuthResult(val accessToken: String, val userId: UUID, val displayName: String)
data class RegisterResult(val userId: UUID, val verificationRequired: Boolean, val developmentCode: String?)
data class VerifyInput(val email: String, val code: String)
data class RegisterInput(val email: String, val password: String, val displayName: String)
data class LoginInput(val email: String, val password: String)
data class ForgotPasswordInput(val email: String)
data class ResetPasswordInput(val email: String, val code: String, val newPassword: String)
data class ResetRequestResult(val accepted: Boolean, val developmentCode: String?)
data class CreateHouseholdInput(val encryptedName: String, val keyEnvelope: String)
data class PublicKeyInput(val publicKey: String)
data class RecoveryBackupInput(val encryptedBackup: String)
data class RecoveryBackupResult(val encryptedBackup: String)
data class RecoveryPayload(val devicePrivateKey: String, val householdKeys: Map<String, String>, val adultKeys: Map<String, String>)
data class InviteInput(val email: String, val role: String, val keyEnvelope: String)
data class InviteResult(val inviteCode: String, val expiresInDays: Int)
data class AcceptInviteInput(val inviteCode: String)
data class AcceptedInvite(val householdId: UUID, val role: String, val keyEnvelope: String)
data class ProductLookup(val barcode: String, val name: String?, val brand: String?, val quantity: String?, val imageUrl: String?)
data class Profile(val userId: UUID, val displayName: String)
data class HouseholdKeyBundle(val householdKey: ByteArray, val adultKey: ByteArray?)
data class WrappedKey(val ephemeralPublicKey: String, val sealedKey: String)
data class HouseholdKeyPayload(val householdKey: String, val adultKey: String?)

val ZERO_UUID: UUID = UUID.fromString("00000000-0000-0000-0000-000000000000")

object MaisonJson {
    val gson = com.google.gson.GsonBuilder()
        .registerTypeAdapter(Instant::class.java, InstantAdapter())
        .create()
}

private class InstantAdapter : com.google.gson.JsonSerializer<Instant>, com.google.gson.JsonDeserializer<Instant> {
    override fun serialize(src: Instant, typeOfSrc: java.lang.reflect.Type, context: com.google.gson.JsonSerializationContext) =
        com.google.gson.JsonPrimitive(src.toString())

    override fun deserialize(json: com.google.gson.JsonElement, typeOfT: java.lang.reflect.Type, context: com.google.gson.JsonDeserializationContext): Instant =
        Instant.parse(json.asString)
}

