import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppStore {
    var serverAddress = UserDefaults.standard.string(forKey: "maisonzen.server") ?? "http://192.168.1.10:5080" {
        didSet { UserDefaults.standard.set(serverAddress, forKey: "maisonzen.server") }
    }
    var token: String? = SecureVault.sessionToken()
    var userId: UUID?
    var displayName = ""
    var email = ""
    var pendingEmail = ""
    var pendingName = ""
    var developmentCode: String?
    var households: [HouseholdSummary] = []
    var householdNames: [UUID: String] = [:]
    var selectedHousehold: HouseholdSummary?
    var members: [HouseholdMember] = []
    var documents: [MaisonDocument] = []
    var serverRecords: [UUID: ServerRecord] = [:]
    var isBusy = false
    var errorMessage: String?
    var infoMessage: String?
    var recoveryCodeForDisplay: String?
    var isConnected = false
    var dashboardMode = UserDefaults.standard.bool(forKey: "maisonzen.dashboard")

    var currentRole: HouseholdRole { selectedHousehold?.householdRole ?? .child }
    var isAdult: Bool { currentRole.isAdult }
    var householdKey: Data? { selectedHousehold.flatMap { SecureVault.householdKey($0.householdId) } }

    private var api: MaisonAPI? {
        guard let token, let api = try? MaisonAPI(address: serverAddress, token: token) else { return nil }
        return api
    }
    private var realtimeSocket: URLSessionWebSocketTask?

    init() {
        if token != nil { Task { await restoreSession() } }
    }

    func register(name: String, email: String, password: String) async {
        await perform {
            self.email = email
            let api = try MaisonAPI(address: self.serverAddress)
            let result = try await api.register(email: email, password: password, displayName: name)
            self.pendingEmail = email; self.pendingName = name; self.developmentCode = result.developmentCode
            self.infoMessage = "Un code de vérification a été envoyé par e-mail."
        }
    }

    func verify(code: String) async {
        await perform {
            let api = try MaisonAPI(address: self.serverAddress)
            let result = try await api.verify(email: self.pendingEmail, code: code)
            self.setSession(token: result.accessToken, userId: result.userId, name: result.displayName)
            try await self.api?.updatePublicKey()
            await self.loadHouseholds()
        }
    }

    func login(email: String, password: String) async {
        await perform {
            self.email = email
            let api = try MaisonAPI(address: self.serverAddress)
            let result = try await api.login(email: email, password: password)
            self.setSession(token: result.accessToken, userId: result.userId, name: result.displayName)
            try await self.api?.updatePublicKey()
            await self.loadHouseholds()
        }
    }

    func requestPasswordReset(email: String) async {
        await perform {
            let result = try await MaisonAPI(address: self.serverAddress).requestPasswordReset(email: email)
            self.pendingEmail = email; self.developmentCode = result.developmentCode
            self.infoMessage = "Si ce compte existe, un code de réinitialisation a été envoyé par e-mail."
        }
    }

    func resetPassword(code: String, newPassword: String) async {
        await perform {
            try await MaisonAPI(address: self.serverAddress).resetPassword(email: self.pendingEmail, code: code, newPassword: newPassword)
            self.infoMessage = "Mot de passe modifié. Tu peux maintenant te connecter."
        }
    }

    func signOut() {
        realtimeSocket?.cancel(with: .normalClosure, reason: nil); realtimeSocket = nil; isConnected = false
        token = nil; userId = nil; displayName = ""; households = []; selectedHousehold = nil; documents = []; members = []; serverRecords = [:]
        SecureVault.clearSession()
    }

    func restoreSession() async {
        guard token != nil else { return }
        await perform {
            let profile: ProfileResult = try await self.requireAPI().sendMe()
            self.userId = profile.userId; self.displayName = profile.displayName
            try await self.api?.updatePublicKey()
            await self.loadHouseholds()
        }
    }

    func createHousehold(name: String) async {
        await perform {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MaisonAPIError.server("Donne un nom au foyer.") }
            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let adultKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let household = try await self.requireAPI().createHousehold(name: name, householdKey: key, adultKey: adultKey)
            try SecureVault.saveHouseholdKey(key, householdId: household.householdId)
            try SecureVault.saveAdultKey(adultKey, householdId: household.householdId)
            self.households.append(household); self.householdNames[household.householdId] = name
            self.selectedHousehold = household; self.members = []
            await self.sync()
            self.connectRealtime()
            await self.refreshRecoveryBackupIfConfigured()
        }
    }

    func loadHouseholds() async {
        guard let api else { return }
        do {
            households = try await api.households()
            for household in households {
                if let keys = try? SecureVault.unwrapHouseholdKey(household.keyEnvelope) {
                    try? SecureVault.saveHouseholdKey(keys.householdKey, householdId: household.householdId)
                    if let adultKey = keys.adultKey { try? SecureVault.saveAdultKey(adultKey, householdId: household.householdId) }
                }
                if let key = SecureVault.householdKey(household.householdId),
                   let name = try? SecureVault.decrypt(String.self, ciphertext: household.encryptedName, householdId: .zero, recordId: .zero, keyData: key) {
                    householdNames[household.householdId] = name
                }
            }
            if selectedHousehold == nil, let first = households.first { selectedHousehold = first }
            if let selectedHousehold { await sync(householdId: selectedHousehold.householdId); connectRealtime() }
        } catch { errorMessage = error.localizedDescription }
    }

    func select(_ household: HouseholdSummary) async {
        realtimeSocket?.cancel(with: .goingAway, reason: nil); realtimeSocket = nil; isConnected = false
        selectedHousehold = household
        await sync(householdId: household.householdId)
        connectRealtime()
    }

    func refreshForeground() async {
        if let socket = realtimeSocket {
            socket.cancel(with: .goingAway, reason: nil)
            realtimeSocket = nil
            isConnected = false
        }
        await sync()
        connectRealtime()
    }

    func sync(householdId: UUID? = nil) async {
        guard let api, let household = selectedHousehold, let key = SecureVault.householdKey(householdId ?? selectedHousehold!.householdId) else { return }
        let id = householdId ?? household.householdId
        do {
            async let remoteRecords = api.records(householdId: id)
            async let remoteMembers = api.members(id)
            let (records, people) = try await (remoteRecords, remoteMembers)
            var decoded: [MaisonDocument] = []; var index: [UUID: ServerRecord] = [:]
            for record in records {
                index[record.recordId] = record
                guard !record.deleted else { continue }
                guard let recordKey = contentKey(for: record, householdId: id) else { continue }
                if let document = try? SecureVault.decrypt(MaisonDocument.self, ciphertext: record.ciphertext, householdId: id, recordId: record.recordId, keyData: recordKey) { decoded.append(document) }
            }
            if selectedHousehold?.householdId == id { documents = decoded.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }; serverRecords = index; members = people }
            let scheduled = decoded.filter { document in
                if document.kind == "subscription" || document.kind == "food" { return true }
                return (document.kind == "reminder" || document.kind == "task") && !document.completed && (document.recipientId == nil || document.recipientId == userId)
            }
            for document in scheduled { await LocalReminderScheduler.schedule(document) }
            await LocalReminderScheduler.removeStale(keeping: Set(scheduled.map { $0.id.uuidString }))
        } catch { errorMessage = error.localizedDescription }
    }

    func save(_ document: MaisonDocument, audience: String, ownerId: UUID? = nil, allowed: [UUID] = []) async {
        await perform {
            guard let household = self.selectedHousehold, let key = SecureVault.householdKey(self.selectedHousehold!.householdId), let api = self.api else { throw MaisonAPIError.server("Choisis un foyer avant d’enregistrer.") }
            let recordKey: Data
            switch audience {
            case "owner":
                guard let user = self.userId, ownerId == user else { throw MaisonAPIError.server("Une dépense personnelle ne peut être enregistrée que pour son propriétaire.") }
                recordKey = try SecureVault.personalKey(userId: user)
            case "adults":
                guard self.isAdult, let adultKey = SecureVault.adultKey(household.householdId) else { throw MaisonAPIError.server("La clé adulte est indisponible pour ce compte.") }
                recordKey = adultKey
            default: recordKey = key
            }
            let ciphertext = try SecureVault.encrypt(document, householdId: household.householdId, recordId: document.id, keyData: recordKey)
            let input = RecordInput(recordId: document.id, audience: audience, ownerId: ownerId, allowedMemberIds: allowed, ciphertext: ciphertext)
            if let old = self.serverRecords[document.id] {
                _ = try await api.updateRecord(householdId: household.householdId, input: UpdateRecordInput(expectedRevision: old.revision, record: input))
            } else {
                _ = try await api.createRecord(householdId: household.householdId, input: input)
            }
            await self.sync(householdId: household.householdId)
            if document.kind == "subscription" || document.kind == "food" || ((document.kind == "reminder" || document.kind == "task") && !document.completed && (document.recipientId == nil || document.recipientId == self.userId)) { await LocalReminderScheduler.schedule(document) }
        }
    }

    func delete(_ document: MaisonDocument) async {
        await perform {
            guard let household = self.selectedHousehold, let api = self.api else { return }
            try await api.deleteRecord(householdId: household.householdId, id: document.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [document.id.uuidString])
            await self.sync()
        }
    }

    func createInvite(email: String, role: HouseholdRole) async -> String? {
        var code: String?
        await perform {
            guard let household = self.selectedHousehold, let key = SecureVault.householdKey(self.selectedHousehold!.householdId) else { throw MaisonAPIError.server("Clé du foyer introuvable sur cet appareil.") }
            let peerKey = try await self.requireAPI().publicKey(email: email)
            let adultKey = role == .adult ? SecureVault.adultKey(household.householdId) : nil
            if role == .adult && adultKey == nil { throw MaisonAPIError.server("Clé réservée aux adultes introuvable sur cet appareil.") }
            let envelope = try SecureVault.wrapHouseholdKey(key, adultKey: adultKey, for: peerKey)
            code = try await self.requireAPI().invite(householdId: household.householdId, email: email, role: role, keyEnvelope: envelope).inviteCode
            self.infoMessage = "Invitation créée. Partage ce code avec le membre du foyer."
        }
        return code
    }

    func acceptInvite(_ code: String) async {
        await perform {
            let accepted = try await self.requireAPI().acceptInvite(code: code)
            let keys = try SecureVault.unwrapHouseholdKey(accepted.keyEnvelope)
            try SecureVault.saveHouseholdKey(keys.householdKey, householdId: accepted.householdId)
            if let adultKey = keys.adultKey { try SecureVault.saveAdultKey(adultKey, householdId: accepted.householdId) }
            await self.loadHouseholds()
            await self.refreshRecoveryBackupIfConfigured()
            self.infoMessage = "Tu as rejoint le foyer."
        }
    }

    func removeMember(_ memberId: UUID) async {
        await perform {
            guard let household = self.selectedHousehold else { return }
            try await self.requireAPI().removeMember(householdId: household.householdId, memberId: memberId)
            await self.sync()
            self.infoMessage = "Le membre a été retiré du foyer."
        }
    }

    func createRecoveryBackup() async -> String? {
        await perform {
            let code = SecureVault.recoveryCode() ?? SecureVault.makeRecoveryCode()
            try SecureVault.saveRecoveryCode(code)
            let keys = Dictionary(uniqueKeysWithValues: self.households.compactMap { household in SecureVault.householdKey(household.householdId).map { (household.householdId, $0) } })
            let adultKeys = Dictionary(uniqueKeysWithValues: self.households.compactMap { household in SecureVault.adultKey(household.householdId).map { (household.householdId, $0) } })
            let encrypted = try SecureVault.makeRecoveryBackup(code: code, householdKeys: keys, adultKeys: adultKeys)
            try await self.requireAPI().saveRecoveryBackup(encrypted)
            self.recoveryCodeForDisplay = code
        }
        return recoveryCodeForDisplay
    }

    func restoreRecoveryBackup(code: String) async {
        await perform {
            let encrypted = try await self.requireAPI().recoveryBackup()
            try SecureVault.restoreRecoveryBackup(encrypted, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            try await self.requireAPI().updatePublicKey()
            await self.loadHouseholds()
            self.infoMessage = "Les clés chiffrées ont été restaurées sur cet appareil."
        }
    }

    func lookupProduct(_ barcode: String) async -> ProductLookup? {
        do { return try await requireAPI().product(barcode: barcode) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func connectRealtime() {
        guard realtimeSocket == nil, let household = selectedHousehold, let token, let api else { return }
        guard var components = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/realtime/\(household.householdId)"
        guard let url = components.url else { return }
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request); realtimeSocket = socket; socket.resume(); isConnected = true
        receiveRealtime()
    }

    private func receiveRealtime() {
        realtimeSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    if let data = text.data(using: .utf8), let event = try? JSONDecoder().decode(RealtimeRefreshEvent.self, from: data), event.type == "record_changed" || event.type == "record_deleted" { await self.sync() }
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8), let value = text.data(using: .utf8), let event = try? JSONDecoder().decode(RealtimeRefreshEvent.self, from: value), event.type == "record_changed" || event.type == "record_deleted" { await self.sync() }
                case .failure:
                    self.realtimeSocket = nil; self.isConnected = false
                @unknown default: break
                }
                if self.realtimeSocket != nil { self.receiveRealtime() }
            }
        }
    }

    func canSee(_ document: MaisonDocument, record: ServerRecord) -> Bool {
        switch record.audience {
        case "owner": return record.ownerId == userId
        case "adults": return isAdult
        case "members": return record.allowedMemberIds.contains(userId ?? UUID.zero)
        default: return true
        }
    }

    func documents(of kind: String) -> [MaisonDocument] { documents.filter { $0.kind == kind } }
    func record(for document: MaisonDocument) -> ServerRecord? { serverRecords[document.id] }

    private func contentKey(for record: ServerRecord, householdId: UUID) -> Data? {
        switch record.audience {
        case "owner":
            guard let userId, record.ownerId == userId else { return nil }
            return try? SecureVault.personalKey(userId: userId)
        case "adults": return SecureVault.adultKey(householdId)
        default: return SecureVault.householdKey(householdId)
        }
    }

    private func setSession(token: String, userId: UUID, name: String) {
        self.token = token; self.userId = userId; self.displayName = name
        try? SecureVault.saveSession(token)
    }
    private func refreshRecoveryBackupIfConfigured() async {
        guard let code = SecureVault.recoveryCode(), let api else { return }
        do {
            let keys = Dictionary(uniqueKeysWithValues: households.compactMap { household in SecureVault.householdKey(household.householdId).map { (household.householdId, $0) } })
            let adultKeys = Dictionary(uniqueKeysWithValues: households.compactMap { household in SecureVault.adultKey(household.householdId).map { (household.householdId, $0) } })
            let encrypted = try SecureVault.makeRecoveryBackup(code: code, householdKeys: keys, adultKeys: adultKeys)
            try await api.saveRecoveryBackup(encrypted)
        } catch { errorMessage = error.localizedDescription }
    }
    private func requireAPI() throws -> MaisonAPI { guard let api else { throw MaisonAPIError.unauthorized }; return api }
    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true; errorMessage = nil; infoMessage = nil
        defer { isBusy = false }
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
}

private struct ProfileResult: Decodable { var userId: UUID; var displayName: String }
private struct RealtimeRefreshEvent: Decodable { var type: String }

extension MaisonAPI {
    fileprivate func sendMe() async throws -> ProfileResult { try await send("GET", "/api/me") }
}

enum LocalReminderScheduler {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    static func schedule(_ document: MaisonDocument) async {
        guard let date = document.notifyAt ?? document.date else { return }
        let center = UNUserNotificationCenter.current()
        let granted = await requestPermission()
        guard granted else { return }
        let content = UNMutableNotificationContent(); content.title = document.kind == "food" ? "À consommer bientôt : \(document.title)" : document.kind == "subscription" ? "Paiement à venir : \(document.title)" : document.title; content.body = document.detail ?? "Rappel MaisonZen"; content.sound = (document.isSilent || UserDefaults.standard.bool(forKey: "maisonzen.notifications.silent")) ? nil : .default
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let repeats = document.recurrence != nil && document.recurrence != "Aucune"
        switch document.recurrence {
        case "Chaque jour": components = Calendar.current.dateComponents([.hour, .minute], from: date)
        case "Chaque semaine": components = Calendar.current.dateComponents([.weekday, .hour, .minute], from: date)
        case "Chaque mois": components = Calendar.current.dateComponents([.day, .hour, .minute], from: date)
        case "Chaque année": components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        default: break
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        let request = UNNotificationRequest(identifier: document.id.uuidString, content: content, trigger: trigger)
        try? await center.add(request)
    }
    static func removeStale(keeping desired: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { UUID(uuidString: $0) != nil && !desired.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
    }
}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
