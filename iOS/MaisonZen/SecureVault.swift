import CryptoKit
import Foundation
import Security

enum SecureVaultError: Error { case keychain(OSStatus), invalidKey, invalidEnvelope, authenticationFailed }

enum SecureVault {
    private static let privateKeyName = "maisonzen.device.p256"

    static func devicePrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        if let saved = try keychainRead(privateKeyName) { return try P256.KeyAgreement.PrivateKey(rawRepresentation: saved) }
        let key = P256.KeyAgreement.PrivateKey()
        try keychainWrite(key.rawRepresentation, name: privateKeyName)
        return key
    }

    static func publicKeyBase64() throws -> String {
        Data(try devicePrivateKey().publicKey.rawRepresentation).base64EncodedString()
    }

    static func wrapHouseholdKey(_ key: Data, adultKey: Data? = nil, for peerPublicKeyBase64: String) throws -> String {
        guard let peerData = Data(base64Encoded: peerPublicKeyBase64) else { throw SecureVaultError.invalidKey }
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: peerData)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("MaisonZen-key-wrap-v1".utf8), sharedInfo: ephemeral.publicKey.rawRepresentation + peer.rawRepresentation, outputByteCount: 32)
        let payload = HouseholdKeyPayload(householdKey: key.base64EncodedString(), adultKey: adultKey?.base64EncodedString())
        let box = try AES.GCM.seal(try MaisonJSON.encoder().encode(payload), using: wrappingKey)
        let envelope = WrappedKey(ephemeralPublicKey: Data(ephemeral.publicKey.rawRepresentation).base64EncodedString(), sealedKey: box.combined!.base64EncodedString())
        let json = try MaisonJSON.encoder().encode(envelope)
        // The API transports key envelopes as base64-encoded opaque bytes.
        return json.base64EncodedString()
    }

    static func unwrapHouseholdKey(_ envelopeString: String) throws -> HouseholdKeyBundle {
        guard let data = Data(base64Encoded: envelopeString), let envelope = try? MaisonJSON.decoder().decode(WrappedKey.self, from: data), let ephemeralData = Data(base64Encoded: envelope.ephemeralPublicKey), let sealedData = Data(base64Encoded: envelope.sealedKey) else { throw SecureVaultError.invalidEnvelope }
        let privateKey = try devicePrivateKey()
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeralData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("MaisonZen-key-wrap-v1".utf8), sharedInfo: ephemeral.rawRepresentation + privateKey.publicKey.rawRepresentation, outputByteCount: 32)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedData), using: wrappingKey)
        let payload = try MaisonJSON.decoder().decode(HouseholdKeyPayload.self, from: clear)
        guard let householdKey = Data(base64Encoded: payload.householdKey), householdKey.count == 32 else { throw SecureVaultError.invalidEnvelope }
        let adultKey: Data?
        if let encodedAdultKey = payload.adultKey {
            guard let decodedAdultKey = Data(base64Encoded: encodedAdultKey), decodedAdultKey.count == 32 else { throw SecureVaultError.invalidEnvelope }
            adultKey = decodedAdultKey
        } else { adultKey = nil }
        return HouseholdKeyBundle(householdKey: householdKey, adultKey: adultKey)
    }

    static func encrypt<T: Encodable>(_ value: T, householdId: UUID, recordId: UUID, keyData: Data) throws -> String {
        let clear = try MaisonJSON.encoder().encode(value)
        let aad = Data("MaisonZen|\(householdId.uuidString)|\(recordId.uuidString)|v1".utf8)
        return try AES.GCM.seal(clear, using: SymmetricKey(data: keyData), authenticating: aad).combined!.base64EncodedString()
    }

    static func decrypt<T: Decodable>(_ type: T.Type, ciphertext: String, householdId: UUID, recordId: UUID, keyData: Data) throws -> T {
        guard let combined = Data(base64Encoded: ciphertext) else { throw SecureVaultError.invalidEnvelope }
        let aad = Data("MaisonZen|\(householdId.uuidString)|\(recordId.uuidString)|v1".utf8)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: keyData), authenticating: aad)
        return try MaisonJSON.decoder().decode(type, from: clear)
    }

    static func saveSession(_ token: String) throws { try keychainWrite(Data(token.utf8), name: "maisonzen.session") }
    static func sessionToken() -> String? { guard let data = try? keychainRead("maisonzen.session") else { return nil }; return String(data: data, encoding: .utf8) }
    static func clearSession() { try? keychainDelete("maisonzen.session") }
    static func saveHouseholdKey(_ key: Data, householdId: UUID) throws { try keychainWrite(key, name: "maisonzen.household.\(householdId.uuidString)") }
    static func householdKey(_ householdId: UUID) -> Data? {
        guard let stored = try? keychainRead("maisonzen.household.\(householdId.uuidString)") else { return nil }
        return stored
    }
    static func saveAdultKey(_ key: Data, householdId: UUID) throws { try keychainWrite(key, name: "maisonzen.adults.\(householdId.uuidString)") }
    static func adultKey(_ householdId: UUID) -> Data? {
        guard let stored = try? keychainRead("maisonzen.adults.\(householdId.uuidString)") else { return nil }
        return stored
    }
    static func personalKey(userId: UUID) throws -> Data {
        let privateKey = try devicePrivateKey()
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: privateKey.rawRepresentation), salt: Data("MaisonZen-personal-key-v1".utf8), info: Data(userId.uuidString.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }
    static func recoveryCode() -> String? { guard let data = try? keychainRead("maisonzen.recovery.code") else { return nil }; return String(data: data, encoding: .utf8) }
    static func makeRecoveryCode() -> String { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
    static func saveRecoveryCode(_ code: String) throws { try keychainWrite(Data(code.utf8), name: "maisonzen.recovery.code") }

    static func makeRecoveryBackup(code: String, householdKeys: [UUID: Data], adultKeys: [UUID: Data]) throws -> String {
        guard let codeData = Data(base64Encoded: code), codeData.count == 32 else { throw SecureVaultError.invalidKey }
        let bundle = RecoveryBundle(devicePrivateKey: Data(try devicePrivateKey().rawRepresentation).base64EncodedString(), householdKeys: Dictionary(uniqueKeysWithValues: householdKeys.map { ($0.key.uuidString, $0.value.base64EncodedString()) }), adultKeys: Dictionary(uniqueKeysWithValues: adultKeys.map { ($0.key.uuidString, $0.value.base64EncodedString()) }))
        let clear = try MaisonJSON.encoder().encode(bundle)
        let box = try AES.GCM.seal(clear, using: SymmetricKey(data: codeData), authenticating: Data("MaisonZen-recovery-v1".utf8))
        return box.combined!.base64EncodedString()
    }

    static func restoreRecoveryBackup(_ encryptedBackup: String, code: String) throws {
        guard let codeData = Data(base64Encoded: code), codeData.count == 32, let combined = Data(base64Encoded: encryptedBackup) else { throw SecureVaultError.invalidKey }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: codeData), authenticating: Data("MaisonZen-recovery-v1".utf8))
        let bundle = try MaisonJSON.decoder().decode(RecoveryBundle.self, from: clear)
        guard let privateData = Data(base64Encoded: bundle.devicePrivateKey) else { throw SecureVaultError.invalidKey }
        _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateData)
        try keychainWrite(privateData, name: privateKeyName)
        for (id, value) in bundle.householdKeys {
            guard let householdId = UUID(uuidString: id), let key = Data(base64Encoded: value), key.count == 32 else { throw SecureVaultError.invalidEnvelope }
            try saveHouseholdKey(key, householdId: householdId)
        }
        for (id, value) in bundle.adultKeys {
            guard let householdId = UUID(uuidString: id), let key = Data(base64Encoded: value), key.count == 32 else { throw SecureVaultError.invalidEnvelope }
            try saveAdultKey(key, householdId: householdId)
        }
        try saveRecoveryCode(code)
    }

    private static func keychainRead(_ name: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MaisonZen", kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecureVaultError.keychain(status) }
        return data
    }
    private static func keychainWrite(_ data: Data, name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MaisonZen", kSecAttrAccount as String: name]
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { var newQuery = query; attrs.forEach { newQuery[$0.key] = $0.value }; let add = SecItemAdd(newQuery as CFDictionary, nil); guard add == errSecSuccess else { throw SecureVaultError.keychain(add) } }
        else if status != errSecSuccess { throw SecureVaultError.keychain(status) }
    }
    private static func keychainDelete(_ name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MaisonZen", kSecAttrAccount as String: name]
        let status = SecItemDelete(query as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw SecureVaultError.keychain(status) }
    }
}

struct HouseholdKeyBundle { var householdKey: Data; var adultKey: Data? }
private struct HouseholdKeyPayload: Codable { var householdKey: String; var adultKey: String? }
private struct WrappedKey: Codable { var ephemeralPublicKey: String; var sealedKey: String }
private struct RecoveryBundle: Codable { var devicePrivateKey: String; var householdKeys: [String: String]; var adultKeys: [String: String] }
