import Foundation
import Observation

@MainActor
@Observable
final class AudioCallService {
    private(set) var status = "Appels audio bientôt disponibles"
    private(set) var incomingCallerId: UUID?
    private(set) var activePeerId: UUID?
    var isMuted = false
    private(set) var callError: String? = "Le module audio nécessite une version WebRTC dédiée."
    private let store: AppStore
    init(store: AppStore) { self.store = store }
    func connect() async { status = "Appels audio indisponibles dans cette version de test" }
    func startCall(to memberId: UUID) async { callError = "Les appels audio seront activés dans une prochaine version." }
    func acceptCall() async { }
    func rejectCall() async { incomingCallerId = nil }
    func toggleMute() { isMuted.toggle() }
    func hangUp() async { activePeerId = nil; status = "Appels audio indisponibles" }
}
