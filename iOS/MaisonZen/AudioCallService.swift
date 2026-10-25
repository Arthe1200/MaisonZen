import AVFoundation
import Foundation
import Observation
import WebRTC

@MainActor
@Observable
final class AudioCallService: NSObject, RTCPeerConnectionDelegate {
    private(set) var status = "Prêt à appeler"
    private(set) var incomingCallerId: UUID?
    private(set) var activePeerId: UUID?
    var isMuted = false
    private(set) var callError: String?

    private let store: AppStore
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var socket: URLSessionWebSocketTask?
    private var callId: UUID?
    private var pendingOffer: String?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var iceCredentials: [IceServerCredential] = []

    init(store: AppStore) {
        self.store = store
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }

    func connect() async {
        guard socket == nil, let household = store.selectedHousehold, let api = try? MaisonAPI(address: store.serverAddress, token: store.token), let token = store.token else { return }
        do { iceCredentials = try await api.iceServers() } catch { callError = error.localizedDescription }
        guard var components = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false) else { callError = "Adresse du serveur invalide."; return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/realtime/\(household.householdId)"
        guard let url = components.url else { callError = "Adresse temps réel invalide."; return }
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request); socket = task; task.resume(); status = "Connecté au foyer"; receiveNext()
    }

    func startCall(to memberId: UUID) async {
        guard store.userId != nil, let household = store.selectedHousehold, let key = store.householdKey else { callError = "Choisis un foyer pour appeler."; return }
        await connect()
        activePeerId = memberId; callId = UUID(); status = "Appel en cours…"
        configureAudio()
        guard let peer = makePeer() else { status = "Impossible d’ouvrir l’audio"; return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer.offer(for: constraints) { [weak self] offer, error in
            guard let self, let offer, error == nil else { Task { @MainActor in self?.callError = error?.localizedDescription ?? "Création de l’appel impossible." }; return }
            peer.setLocalDescription(offer) { [weak self] error in
                Task { @MainActor in
                    guard let self, error == nil else { self?.callError = error?.localizedDescription; return }
                    await self.sendSignal(SignalPayload(kind: "offer", callId: self.callId!, callerId: self.store.userId!, sdp: offer.sdp), to: memberId, household: household.householdId, key: key)
                }
            }
        }
    }

    func acceptCall() async {
        guard let caller = incomingCallerId, let offer = pendingOffer, let household = store.selectedHousehold, let key = store.householdKey, let user = store.userId else { return }
        activePeerId = caller; status = "Connexion audio…"; incomingCallerId = nil; configureAudio()
        guard let peer = makePeer() else { status = "Impossible d’ouvrir l’audio"; return }
        let description = RTCSessionDescription(type: .offer, sdp: offer)
        peer.setRemoteDescription(description) { [weak self] error in
            guard let self, error == nil else { Task { @MainActor in self?.callError = error?.localizedDescription }; return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            peer.answer(for: constraints) { answer, answerError in
                guard let answer, answerError == nil else { Task { @MainActor in self?.callError = answerError?.localizedDescription }; return }
                peer.setLocalDescription(answer) { [weak self] setError in
                    Task { @MainActor in
                        guard let self, setError == nil else { self?.callError = setError?.localizedDescription; return }
                        await self.sendSignal(SignalPayload(kind: "answer", callId: self.callId ?? UUID(), callerId: user, sdp: answer.sdp), to: caller, household: household.householdId, key: key)
                        self.pendingOffer = nil
                        self.flushCandidates()
                    }
                }
            }
        }
    }

    func rejectCall() async {
        if let caller = incomingCallerId, let household = store.selectedHousehold, let key = store.householdKey, let user = store.userId {
            await sendSignal(SignalPayload(kind: "reject", callId: callId ?? UUID(), callerId: user), to: caller, household: household.householdId, key: key)
        }
        incomingCallerId = nil; pendingOffer = nil; status = "Prêt à appeler"
    }

    func toggleMute() { isMuted.toggle(); audioTrack?.isEnabled = !isMuted }

    func hangUp() async {
        if let peerId = activePeerId, let household = store.selectedHousehold, let key = store.householdKey, let user = store.userId {
            await sendSignal(SignalPayload(kind: "hangup", callId: callId ?? UUID(), callerId: user), to: peerId, household: household.householdId, key: key)
        }
        peer?.close(); peer = nil; audioTrack = nil; activePeerId = nil; callId = nil; status = "Prêt à appeler"
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func configureAudio() {
        do { let session = AVAudioSession.sharedInstance(); try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker]); try session.setActive(true) }
        catch { callError = error.localizedDescription }
    }

    private func makePeer() -> RTCPeerConnection? {
        let configuration = RTCConfiguration()
        configuration.iceServers = iceCredentials.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else { return nil }
        let source = factory.audioSource(with: constraints); let track = factory.audioTrack(with: source, trackId: "maisonzen-audio-\(UUID().uuidString)")
        connection.add(track, streamIds: ["maisonzen-audio"]); peer = connection; audioTrack = track
        return connection
    }

    private func receiveNext() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)): await self.handle(text)
                case .success(.data(let data)): if let text = String(data: data, encoding: .utf8) { await self.handle(text) }
                case .failure(let error): self.status = "Connexion au serveur interrompue"; self.callError = error.localizedDescription; self.socket = nil
                @unknown default: break
                }
                if self.socket != nil { self.receiveNext() }
            }
        }
    }

    private func handle(_ json: String) async {
        guard let data = json.data(using: .utf8), let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data), event.type == "signal", event.senderId != store.userId,
              let inner = event.envelope.data(using: .utf8), let wire = try? JSONDecoder().decode(SignalWire.self, from: inner), wire.recipientId == store.userId,
              let household = store.selectedHousehold, let key = store.householdKey,
              let payload = try? SecureVault.decrypt(SignalPayload.self, ciphertext: wire.ciphertext, householdId: household.householdId, recordId: wire.callId, keyData: key) else { return }
        callId = payload.callId
        switch payload.kind {
        case "offer": pendingOffer = payload.sdp; incomingCallerId = event.senderId; status = "Appel entrant"; if let sdp = payload.sdp { pendingOffer = sdp }
        case "answer":
            guard let sdp = payload.sdp, let peer else { return }
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in Task { @MainActor in if let error { self?.callError = error.localizedDescription } else { self?.status = "En appel"; self?.flushCandidates() } } }
        case "candidate":
            guard let sdp = payload.candidate, let index = payload.sdpMLineIndex else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: payload.sdpMid)
            if let peer { peer.add(candidate, completionHandler: { _ in }) } else { pendingCandidates.append(candidate) }
        case "hangup", "reject": peer?.close(); peer = nil; audioTrack = nil; activePeerId = nil; incomingCallerId = nil; pendingOffer = nil; status = "Appel terminé"
        default: break
        }
    }

    private func sendSignal(_ signal: SignalPayload, to recipient: UUID, household householdId: UUID, key: Data) async {
        do {
            let ciphertext = try SecureVault.encrypt(signal, householdId: householdId, recordId: signal.callId, keyData: key)
            let wire = SignalWire(recipientId: recipient, callId: signal.callId, ciphertext: ciphertext)
            let data = try MaisonJSON.encoder().encode(wire)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await socket?.send(.string(text))
        } catch { callError = error.localizedDescription }
    }

    private func flushCandidates() {
        guard let peer else { return }
        for candidate in pendingCandidates { peer.add(candidate, completionHandler: { _ in }) }; pendingCandidates.removeAll()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState { case .connected, .completed: status = "En appel"; case .failed: status = "Échec réseau. Vérifie le relais TURN."; case .disconnected: status = "Connexion interrompue"; default: break }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let recipient = activePeerId, let household = store.selectedHousehold, let key = store.householdKey, let user = store.userId, let callId else { return }
        Task { await sendSignal(SignalPayload(kind: "candidate", callId: callId, callerId: user, candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex), to: recipient, household: household.householdId, key: key) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private struct RealtimeEvent: Decodable { var type: String; var senderId: UUID?; var envelope: String }
private struct SignalWire: Codable { var recipientId: UUID; var callId: UUID; var ciphertext: String }
private struct SignalPayload: Codable { var kind: String; var callId: UUID; var callerId: UUID; var sdp: String? = nil; var candidate: String? = nil; var sdpMid: String? = nil; var sdpMLineIndex: Int32? = nil }
