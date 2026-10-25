import Foundation

enum HouseholdRole: String, Codable, CaseIterable, Identifiable {
    case admin, adult, child, tenant
    var id: String { rawValue }
    var label: String { switch self { case .admin: "Administrateur"; case .adult: "Adulte / parent"; case .child: "Enfant"; case .tenant: "Locataire" } }
    var isAdult: Bool { self == .admin || self == .adult }
}

struct HouseholdSummary: Codable, Identifiable {
    var householdId: UUID
    var role: String
    var encryptedName: String
    var keyEnvelope: String
    var id: UUID { householdId }
    var householdRole: HouseholdRole { HouseholdRole(rawValue: role) ?? .child }
}

struct HouseholdMember: Codable, Identifiable {
    var userId: UUID
    var displayName: String
    var role: String
    var keyEnvelope: String
    var id: UUID { userId }
    var householdRole: HouseholdRole { HouseholdRole(rawValue: role) ?? .child }
}

struct ServerRecord: Codable, Identifiable {
    var recordId: UUID
    var audience: String
    var ownerId: UUID?
    var allowedMemberIds: [UUID]
    var ciphertext: String
    var revision: Int64
    var updatedAt: Date
    var deleted: Bool
    var id: UUID { recordId }
}

struct RecordInput: Codable {
    var recordId: UUID
    var audience: String
    var ownerId: UUID?
    var allowedMemberIds: [UUID]
    var ciphertext: String
}

struct UpdateRecordInput: Codable {
    var expectedRevision: Int64
    var record: RecordInput
}

struct MaisonDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: String
    var title: String
    var detail: String? = nil
    var amount: Double? = nil
    var category: String? = nil
    var date: Date? = nil
    var recurrence: String? = nil
    var recipientId: UUID? = nil
    var allowedMembers: [UUID] = []
    var completed: Bool = false
    var barcode: String? = nil
    var expirationDate: Date? = nil
    var storagePlace: String? = nil
    var quantity: String? = nil
    var ingredients: [String] = []
    var steps: [String] = []
    var servings: Int? = nil
    var dietaryTags: [String] = []
    var durationMinutes: Int? = nil
    var repeatUntil: Date? = nil
    var notifyAt: Date? = nil
    var isSilent: Bool = false
}

struct RegistrationInput: Codable { var email: String; var password: String; var displayName: String }
struct VerifyEmailInput: Codable { var email: String; var code: String }
struct LoginInput: Codable { var email: String; var password: String }
struct ForgotPasswordInput: Codable { var email: String }
struct ResetPasswordInput: Codable { var email: String; var code: String; var newPassword: String }
struct ResetRequestResult: Codable { var accepted: Bool; var developmentCode: String? }
struct RecoveryBackupInput: Codable { var encryptedBackup: String }
struct RecoveryBackupResult: Codable { var encryptedBackup: String }
struct AuthResult: Codable { var accessToken: String; var userId: UUID; var displayName: String }
struct RegisterResult: Codable { var userId: UUID; var verificationRequired: Bool; var developmentCode: String? }
struct VerifyResult: Codable { var accessToken: String; var userId: UUID; var displayName: String }
struct PublicKeyInput: Codable { var publicKey: String }
struct CreateHouseholdInput: Codable { var encryptedName: String; var keyEnvelope: String }
struct InviteInput: Codable { var email: String; var role: String; var keyEnvelope: String }
struct InviteResult: Codable { var inviteCode: String; var expiresInDays: Int }
struct AcceptInviteInput: Codable { var inviteCode: String }
struct AcceptedInvite: Codable { var householdId: UUID; var role: String; var keyEnvelope: String }
struct ProductLookup: Codable { var barcode: String; var name: String?; var brand: String?; var quantity: String?; var imageUrl: String? }
struct IceServerCredential: Codable { var urls: [String]; var username: String; var credential: String }
struct IceServerResponse: Codable { var iceServers: [IceServerCredential] }

enum MaisonJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.maison.string(from: date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.maison.date(from: value) ?? ISO8601DateFormatter.maisonNoFraction.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Date ISO-8601 invalide"))
        }
        return decoder
    }
}

enum MaisonMoney {
    static func monthlyAmount(for document: MaisonDocument) -> Double {
        let value = document.amount ?? 0
        switch document.recurrence {
        case "Chaque semaine": value * 52 / 12
        case "Chaque année": value / 12
        default: value
        }
    }
}

private extension ISO8601DateFormatter {
    static let maison: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
    static let maisonNoFraction: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; return formatter }()
}
