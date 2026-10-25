import Foundation

enum MaisonAPIError: LocalizedError {
    case invalidServerAddress, unauthorized, server(String), malformedResponse
    var errorDescription: String? {
        switch self {
        case .invalidServerAddress: "Adresse du serveur invalide."
        case .unauthorized: "Session expirée. Reconnecte-toi."
        case .server(let message): message
        case .malformedResponse: "Réponse du serveur invalide."
        }
    }
}

struct MaisonAPI {
    var baseURL: URL
    var token: String? = nil
    var session: URLSession = .shared

    init(address: String, token: String? = nil) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw MaisonAPIError.invalidServerAddress }
        self.baseURL = url; self.token = token
    }

    func register(email: String, password: String, displayName: String) async throws -> RegisterResult {
        try await send("POST", "/api/auth/register", body: RegistrationInput(email: email, password: password, displayName: displayName), authenticated: false)
    }
    func verify(email: String, code: String) async throws -> VerifyResult {
        try await send("POST", "/api/auth/verify-email", body: VerifyEmailInput(email: email, code: code), authenticated: false)
    }
    func login(email: String, password: String) async throws -> AuthResult {
        try await send("POST", "/api/auth/login", body: LoginInput(email: email, password: password), authenticated: false)
    }
    func requestPasswordReset(email: String) async throws -> ResetRequestResult {
        try await send("POST", "/api/auth/forgot-password", body: ForgotPasswordInput(email: email), authenticated: false)
    }
    func resetPassword(email: String, code: String, newPassword: String) async throws {
        let _: EmptyResult = try await send("POST", "/api/auth/reset-password", body: ResetPasswordInput(email: email, code: code, newPassword: newPassword), authenticated: false)
    }
    func updatePublicKey() async throws {
        let key = try SecureVault.publicKeyBase64()
        let _: EmptyResult = try await send("PUT", "/api/me/public-key", body: PublicKeyInput(publicKey: key))
    }
    func saveRecoveryBackup(_ encryptedBackup: String) async throws {
        let _: EmptyResult = try await send("PUT", "/api/me/recovery-backup", body: RecoveryBackupInput(encryptedBackup: encryptedBackup))
    }
    func recoveryBackup() async throws -> String {
        let response: RecoveryBackupResult = try await send("GET", "/api/me/recovery-backup")
        return response.encryptedBackup
    }
    func createHousehold(name: String, householdKey: Data, adultKey: Data) async throws -> HouseholdSummary {
        let keyEnvelope = try SecureVault.wrapHouseholdKey(householdKey, adultKey: adultKey, for: SecureVault.publicKeyBase64())
        let encryptedName = try SecureVault.encrypt(name, householdId: UUID.zero, recordId: UUID.zero, keyData: householdKey)
        return try await send("POST", "/api/households", body: CreateHouseholdInput(encryptedName: encryptedName, keyEnvelope: keyEnvelope))
    }
    func households() async throws -> [HouseholdSummary] { try await send("GET", "/api/households") }
    func members(_ householdId: UUID) async throws -> [HouseholdMember] { try await send("GET", "/api/households/\(householdId)/members") }
    func removeMember(householdId: UUID, memberId: UUID) async throws {
        let _: EmptyResult = try await send("DELETE", "/api/households/\(householdId)/members/\(memberId)")
    }
    func publicKey(email: String) async throws -> String {
        let escaped = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let result: PublicKeyResult = try await send("GET", "/api/users/public-key?email=\(escaped)")
        return result.publicKey
    }
    func invite(householdId: UUID, email: String, role: HouseholdRole, keyEnvelope: String) async throws -> InviteResult {
        try await send("POST", "/api/households/\(householdId)/invites", body: InviteInput(email: email, role: role.rawValue, keyEnvelope: keyEnvelope))
    }
    func acceptInvite(code: String) async throws -> AcceptedInvite {
        try await send("POST", "/api/households/accept-invite", body: AcceptInviteInput(inviteCode: code))
    }
    func records(householdId: UUID) async throws -> [ServerRecord] { try await send("GET", "/api/households/\(householdId)/records") }
    func createRecord(householdId: UUID, input: RecordInput) async throws -> ServerRecord {
        try await send("POST", "/api/households/\(householdId)/records", body: input)
    }
    func updateRecord(householdId: UUID, input: UpdateRecordInput) async throws -> ServerRecord {
        try await send("PUT", "/api/households/\(householdId)/records/\(input.record.recordId)", body: input)
    }
    func deleteRecord(householdId: UUID, id: UUID) async throws {
        let _: EmptyResult = try await send("DELETE", "/api/households/\(householdId)/records/\(id)")
    }
    func product(barcode: String) async throws -> ProductLookup {
        try await send("GET", "/api/products/\(barcode)")
    }
    func iceServers() async throws -> [IceServerCredential] {
        let response: IceServerResponse = try await send("GET", "/api/calls/ice-servers")
        return response.iceServers
    }

    func send<T: Decodable>(_ method: String, _ path: String, authenticated: Bool = true) async throws -> T {
        try await perform(method, path, body: Optional<EmptyBody>.none, authenticated: authenticated)
    }
    func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B, authenticated: Bool = true) async throws -> T {
        try await perform(method, path, body: Optional(body), authenticated: authenticated)
    }
    func perform<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B?, authenticated: Bool) async throws -> T {
        let url = URL(string: path, relativeTo: baseURL)!
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try MaisonJSON.encoder().encode(body) }
        if authenticated, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MaisonAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MaisonAPIError.unauthorized }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? String(data: data, encoding: .utf8) ?? "Erreur serveur (\(http.statusCode))."
            throw MaisonAPIError.server(message)
        }
        if T.self == EmptyResult.self { return EmptyResult() as! T }
        guard !data.isEmpty, let value = try? MaisonJSON.decoder().decode(T.self, from: data) else { throw MaisonAPIError.malformedResponse }
        return value
    }
}

private struct ServerError: Decodable { var error: String? }
private struct PublicKeyResult: Decodable { var publicKey: String }
private struct EmptyBody: Encodable {}
struct EmptyResult: Decodable {}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
