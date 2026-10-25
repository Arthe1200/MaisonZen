package fr.maisonzen.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Android implementation of the iOS CryptoKit wire format (P-256, HKDF-SHA256 and AES-GCM). */
class SecureVault(context: Context) {
    private val prefs = context.getSharedPreferences("maisonzen.secure", Context.MODE_PRIVATE)
    private val random = SecureRandom()
    private val params: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
    }

    private data class State(
        var token: String? = null,
        var privateKey: String? = null,
        var householdKeys: MutableMap<String, String> = mutableMapOf(),
        var adultKeys: MutableMap<String, String> = mutableMapOf(),
        var recoveryCode: String? = null
    )

    @Synchronized private fun state(): State {
        val encoded = prefs.getString("state", null) ?: return State()
        return runCatching {
            MaisonJson.gson.fromJson(String(openLocal(Base64.decode(encoded, Base64.NO_WRAP))), State::class.java)
        }.getOrElse { State() }
    }

    @Synchronized private fun save(state: State) {
        val clear = MaisonJson.gson.toJson(state).toByteArray(Charsets.UTF_8)
        prefs.edit().putString("state", Base64.encodeToString(sealLocal(clear), Base64.NO_WRAP)).apply()
    }

    fun token(): String? = state().token
    fun saveToken(token: String?) { val s = state(); s.token = token; save(s) }
    fun hasDeviceKey(): Boolean = state().privateKey != null
    fun recoveryCode(): String? = state().recoveryCode

    fun publicKeyBase64(): String {
        val s = state()
        if (s.privateKey == null) {
            val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()
            s.privateKey = b64(fixed((pair.private as ECPrivateKey).s))
            save(s)
        }
        return b64(publicRaw(derivePublic(BigInteger(1, unb64(s.privateKey!!)))))
    }

    fun createHouseholdEnvelope(householdKey: ByteArray, adultKey: ByteArray?): String =
        wrap(householdKey, adultKey, publicKeyBase64())

    fun wrap(householdKey: ByteArray, adultKey: ByteArray?, peerPublicBase64: String): String {
        val peerRaw = unb64(peerPublicBase64)
        val ephemeral = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()
        val ephemeralRaw = publicRaw((ephemeral.public as java.security.interfaces.ECPublicKey).w)
        val shared = ecdh(ephemeral.private, decodePublic(peerRaw))
        val key = hkdf(shared, "MaisonZen-key-wrap-v1".toByteArray(), ephemeralRaw + peerRaw)
        val payload = HouseholdKeyPayload(b64(householdKey), adultKey?.let(::b64))
        val sealed = aesSeal(key, MaisonJson.gson.toJson(payload).toByteArray(Charsets.UTF_8), null)
        return b64(MaisonJson.gson.toJson(WrappedKey(b64(ephemeralRaw), b64(sealed))).toByteArray(Charsets.UTF_8))
    }

    fun unwrap(envelope: String): HouseholdKeyBundle {
        val wrapped = MaisonJson.gson.fromJson(String(unb64(envelope)), WrappedKey::class.java)
        val ephemeralRaw = unb64(wrapped.ephemeralPublicKey)
        val peer = decodePublic(ephemeralRaw)
        val privateRaw = unb64(state().privateKey ?: error("Clé de cet appareil introuvable."))
        val localPublic = publicRaw(derivePublic(BigInteger(1, privateRaw)))
        val private = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, privateRaw), params))
        val shared = ecdh(private, peer)
        val key = hkdf(shared, "MaisonZen-key-wrap-v1".toByteArray(), ephemeralRaw + localPublic)
        val payload = MaisonJson.gson.fromJson(String(aesOpen(key, unb64(wrapped.sealedKey), null)), HouseholdKeyPayload::class.java)
        val householdKey = unb64(payload.householdKey)
        require(householdKey.size == 32) { "Clé de foyer incorrecte." }
        val adult = payload.adultKey?.let(::unb64)
        require(adult == null || adult.size == 32) { "Clé adulte incorrecte." }
        return HouseholdKeyBundle(householdKey, adult)
    }

    fun householdKey(id: UUID): ByteArray? = state().householdKeys[id.toString()]?.let(::unb64)
    fun adultKey(id: UUID): ByteArray? = state().adultKeys[id.toString()]?.let(::unb64)
    fun saveHouseholdKey(id: UUID, key: ByteArray) { val s = state(); s.householdKeys[id.toString()] = b64(key); save(s) }
    fun saveAdultKey(id: UUID, key: ByteArray) { val s = state(); s.adultKeys[id.toString()] = b64(key); save(s) }

    fun makeRecoveryBackup(): Pair<String, String> {
        val s = state()
        val privateKey = s.privateKey ?: run { publicKeyBase64(); state().privateKey!! }
        val code = s.recoveryCode ?: ByteArray(32).also(random::nextBytes).let(::b64)
        val refreshed = state().apply { recoveryCode = code }
        save(refreshed)
        val payload = RecoveryPayload(privateKey, refreshed.householdKeys.toMap(), refreshed.adultKeys.toMap())
        val encrypted = b64(aesSeal(unb64(code), MaisonJson.gson.toJson(payload).toByteArray(Charsets.UTF_8), "MaisonZen-recovery-v1".toByteArray()))
        return code to encrypted
    }

    fun restoreRecoveryBackup(encryptedBackup: String, code: String) {
        val key = unb64(code.trim())
        require(key.size == 32) { "Le code de récupération doit être le code complet affiché dans Maison Zen." }
        val clear = aesOpen(key, unb64(encryptedBackup), "MaisonZen-recovery-v1".toByteArray())
        val payload = MaisonJson.gson.fromJson(String(clear), RecoveryPayload::class.java)
        val privateRaw = unb64(payload.devicePrivateKey)
        require(privateRaw.size == 32) { "La clé de récupération est invalide." }
        derivePublic(BigInteger(1, privateRaw))
        val restored = state().apply {
            privateKey = payload.devicePrivateKey
            householdKeys = payload.householdKeys.mapKeys { UUID.fromString(it.key).toString() }.toMutableMap()
            adultKeys = payload.adultKeys.mapKeys { UUID.fromString(it.key).toString() }.toMutableMap()
            recoveryCode = code.trim()
        }
        save(restored)
    }

    fun personalKey(userId: UUID): ByteArray {
        val privateRaw = unb64(state().privateKey ?: error("Clé de cet appareil introuvable."))
        return hkdf(fixed(BigInteger(1, privateRaw)), "MaisonZen-personal-key-v1".toByteArray(), userId.toString().uppercase().toByteArray())
    }

    fun encrypt(document: MaisonDocument, householdId: UUID, key: ByteArray): String {
        return encryptJson(MaisonJson.gson.toJson(document), householdId, document.id, key)
    }

    fun encryptText(value: String, householdId: UUID, recordId: UUID, key: ByteArray): String =
        encryptJson(MaisonJson.gson.toJson(value), householdId, recordId, key)

    fun decryptText(ciphertext: String, householdId: UUID, recordId: UUID, key: ByteArray): String =
        MaisonJson.gson.fromJson(String(aesOpen(key, unb64(ciphertext), aad(householdId, recordId))), String::class.java)

    private fun encryptJson(json: String, householdId: UUID, recordId: UUID, key: ByteArray): String =
        b64(aesSeal(key, json.toByteArray(Charsets.UTF_8), aad(householdId, recordId)))

    private fun aad(householdId: UUID, recordId: UUID) =
        "MaisonZen|${householdId.toString().uppercase()}|${recordId.toString().uppercase()}|v1".toByteArray()

    fun decrypt(record: ServerRecord, householdId: UUID, key: ByteArray): MaisonDocument {
        return MaisonJson.gson.fromJson(String(aesOpen(key, unb64(record.ciphertext), aad(householdId, record.recordId))), MaisonDocument::class.java)
    }

    private fun decodePublic(raw: ByteArray) = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point(raw), params))
    private fun point(raw: ByteArray): ECPoint {
        require(raw.size == 65 && raw[0] == 4.toByte()) { "Clé P-256 invalide." }
        return ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65)))
    }
    private fun publicRaw(point: ECPoint): ByteArray = byteArrayOf(4) + fixed(point.affineX) + fixed(point.affineY)
    private fun ecdh(privateKey: java.security.PrivateKey, publicKey: java.security.PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run { init(privateKey); doPhase(publicKey, true); generateSecret() }

    private fun derivePublic(scalar: BigInteger): ECPoint {
        val curve = params.curve
        val p = (curve.field as java.security.spec.ECFieldFp).p
        val a = curve.a
        fun add(left: ECPoint?, right: ECPoint?): ECPoint? {
            if (left == null) return right
            if (right == null) return left
            val x1 = left.affineX; val y1 = left.affineY; val x2 = right.affineX; val y2 = right.affineY
            if (x1 == x2 && (y1 + y2).mod(p) == BigInteger.ZERO) return null
            val two = BigInteger.valueOf(2)
            val slope = if (x1 == x2) (BigInteger.valueOf(3) * x1 * x1 + a).mod(p)
                .multiply((two * y1).mod(p).modInverse(p)).mod(p)
            else (y2 - y1).mod(p).multiply((x2 - x1).mod(p).modInverse(p)).mod(p)
            val x3 = (slope * slope - x1 - x2).mod(p)
            val y3 = (slope * (x1 - x3) - y1).mod(p)
            return ECPoint(x3, y3)
        }
        var n = scalar
        var addend: ECPoint? = params.generator
        var result: ECPoint? = null
        while (n > BigInteger.ZERO) {
            if (n.testBit(0)) result = add(result, addend)
            addend = add(addend, addend)
            n = n.shiftRight(1)
        }
        return result ?: error("Clé privée P-256 invalide.")
    }

    private fun hkdf(input: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
        val extract = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(salt, "HmacSHA256")); doFinal(input) }
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(extract, "HmacSHA256")) }
        return mac.doFinal(info + byteArrayOf(1)).copyOf(32)
    }

    private fun aesSeal(key: ByteArray, clear: ByteArray, aad: ByteArray?): ByteArray {
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        aad?.let(cipher::updateAAD)
        return nonce + cipher.doFinal(clear)
    }

    private fun aesOpen(key: ByteArray, combined: ByteArray, aad: ByteArray?): ByteArray {
        require(combined.size >= 28) { "Données chiffrées incomplètes." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
        aad?.let(cipher::updateAAD)
        return cipher.doFinal(combined.copyOfRange(12, combined.size))
    }

    private fun masterKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(MASTER_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(MASTER_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
            generateKey()
        }
    }

    private fun sealLocal(clear: ByteArray): ByteArray = localCipher(clear, true)
    private fun openLocal(sealed: ByteArray): ByteArray = localCipher(sealed, false)
    private fun localCipher(data: ByteArray, encrypt: Boolean): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (encrypt) {
            val nonce = ByteArray(12).also(random::nextBytes)
            cipher.init(Cipher.ENCRYPT_MODE, masterKey(), GCMParameterSpec(128, nonce))
            return nonce + cipher.doFinal(data)
        }
        cipher.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        return cipher.doFinal(data.copyOfRange(12, data.size))
    }

    private fun fixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray().let { if (it.size > 32 && it[0] == 0.toByte()) it.copyOfRange(1, it.size) else it }
        return ByteArray(32).also { bytes.copyInto(it, 32 - bytes.size) }
    }
    private fun b64(value: ByteArray) = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun unb64(value: String) = Base64.decode(value, Base64.DEFAULT)

    private companion object { const val MASTER_ALIAS = "maisonzen.local.master" }
}
