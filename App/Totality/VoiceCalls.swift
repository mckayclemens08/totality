#if os(iOS) && canImport(MatrixRustSDK) && canImport(WebRTC)
import AVFoundation
import AudioToolbox
import SwiftUI
@preconcurrency import MatrixRustSDK
@preconcurrency import WebRTC
import TotalityCore
import TotalityMessages
import TotalityUI

struct VoiceSignal: Codable, Sendable {
    static let messageType = "app.totality.voice.v1"
    enum Kind: String, Codable { case invite, answer, end, decline }
    let id: UUID
    let kind: Kind
    let sdp: String?
}

@MainActor @Observable
final class VoiceCalls {
    enum Phase: String { case dialing = "Calling…", incoming = "Incoming voice call", connecting = "Connecting…", connected = "Voice call" }
    struct Call: Identifiable {
        let id: UUID
        let chat: ChatSummary
        let offer: String?
        var phase: Phase
    }

    private(set) var call: Call?
    private(set) var muted = false
    private(set) var speaker = false
    var notice: String?
    private var service: MatrixMessagesService?
    private struct Watcher {
        let timeline: Timeline
        let subscription: TaskHandle
    }
    private var watchers: [String: Watcher] = [:]
    private var pending: [String: UUID] = [:]
    private var desiredRooms: Set<String> = []
    private var seen: [UUID: Date] = [:]
    private var peer: RTCPeerConnection?
    private var microphone: RTCAudioTrack?
    private var timeout: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    @ObservationIgnored private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    func watch(_ next: MatrixMessagesService?, chats: [ChatSummary]) async {
        if service !== next {
            reset()
            watchers.values.forEach { $0.subscription.cancel() }
            watchers.removeAll()
            pending.removeAll()
            seen.removeAll()
            notice = nil
            service = next
        }
        let direct = chats.filter { !$0.isRequest && !$0.isGroup && $0.otherPerson != nil }
        desiredRooms = Set(direct.map(\.id))
        for id in Array(watchers.keys) where !desiredRooms.contains(id) {
            watchers.removeValue(forKey: id)?.subscription.cancel()
        }
        if let call, !desiredRooms.contains(call.chat.id) { reset() }
        guard let next else { return }
        for chat in direct where watchers[chat.id] == nil && pending[chat.id] == nil {
            guard !Task.isCancelled, service === next else { return }
            let ticket = UUID()
            pending[chat.id] = ticket
            if let room = try? next.client.getRoom(roomId: chat.id),
               let timeline = try? await room.timeline() {
                let listener = VoiceTimelineListener(sender: chat.otherPerson, own: next.userID) { [weak self, weak next] events in
                    Task { @MainActor in
                        guard let self, let next, self.service === next else { return }
                        for event in events {
                            await self.receive(event, chat: chat, service: next)
                        }
                    }
                }
                let handle = await timeline.addListener(listener: listener)
                if service === next, desiredRooms.contains(chat.id), pending[chat.id] == ticket {
                    watchers[chat.id] = Watcher(timeline: timeline, subscription: handle)
                } else {
                    handle.cancel()
                }
            }
            if pending[chat.id] == ticket { pending[chat.id] = nil }
        }
    }

    func dial(_ chat: ChatSummary) async {
        guard call == nil, let service else { return }
        let id = UUID()
        call = Call(id: id, chat: chat, offer: nil, phase: .dialing)
        notice = nil
        expire(id, after: .seconds(45))
        do {
            let room = try await eligibleRoom(chat, service: service)
            try requireCurrent(id)
            let peer = try await makePeer(id, service: service)
            let offer = try await localDescription(peer, offer: true, id: id)
            try await send(.init(id: id, kind: .invite, sdp: offer), to: room)
        } catch { failed(id) }
    }

    func answer() async {
        guard let call, call.phase == .incoming, let offer = call.offer, let service else { return }
        self.call?.phase = .connecting
        expire(call.id, after: .seconds(35))
        do {
            let room = try await eligibleRoom(call.chat, service: service)
            let peer = try await makePeer(call.id, service: service)
            try await peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer))
            let answer = try await localDescription(peer, offer: false, id: call.id)
            try await send(.init(id: call.id, kind: .answer, sdp: answer), to: room)
            monitorPeer(call.id)
        } catch { failed(call.id) }
    }

    func hangUp() async {
        guard let id = call?.id else { return }
        await hangUp(id)
    }

    private func hangUp(_ id: UUID) async {
        guard let call, call.id == id else { return }
        let service = service
        reset()
        guard let service, self.service === service,
              let room = try? await eligibleRoom(call.chat, service: service),
              self.service === service else { return }
        let kind: VoiceSignal.Kind = call.phase == .incoming ? .decline : .end
        try? await send(.init(id: call.id, kind: kind, sdp: nil), to: room)
    }

    func toggleMute() {
        guard let microphone else { return }
        muted.toggle()
        microphone.isEnabled = !muted
    }

    func toggleSpeaker() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .none : .speaker)
            speaker.toggle()
        } catch { notice = "Couldn't change the audio output." }
    }

    private func receive(_ event: VoiceTimelineEvent, chat: ChatSummary, service: MatrixMessagesService) async {
        let signal = event.signal
        let timestamp = event.timestamp
        guard desiredRooms.contains(chat.id), abs(timestamp.timeIntervalSinceNow) < 60 else { return }
        if event.isOwn {
            guard signal.kind == .answer || signal.kind == .decline else { return }
            seen[signal.id] = Date()
            if call?.id == signal.id, call?.chat.id == chat.id, call?.phase == .incoming { reset() }
            return
        }
        guard (try? await eligibleRoom(chat, service: service)) != nil, self.service === service,
              desiredRooms.contains(chat.id) else { return }
        seen = seen.filter { $0.value.timeIntervalSinceNow > -120 }
        switch signal.kind {
        case .invite:
            guard timestamp.timeIntervalSinceNow > -45, seen[signal.id] == nil, let offer = signal.sdp, validAudio(offer) else { return }
            seen[signal.id] = Date()
            guard call == nil else { return }
            notice = nil
            call = Call(id: signal.id, chat: chat, offer: offer, phase: .incoming)
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
            expire(signal.id, after: .seconds(min(45, max(1, 45 + timestamp.timeIntervalSinceNow))))
        case .answer:
            guard call?.id == signal.id, call?.chat.id == chat.id, call?.phase == .dialing,
                  let peer, let answer = signal.sdp, validAudio(answer) else { return }
            call?.phase = .connecting
            expire(signal.id, after: .seconds(30))
            do {
                try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
                monitorPeer(signal.id)
            } catch { failed(signal.id) }
        case .end, .decline:
            seen[signal.id] = Date()
            guard call?.id == signal.id, call?.chat.id == chat.id else { return }
            notice = signal.kind == .decline ? "Call declined." : "Call ended."
            reset()
        }
    }

    private func eligibleRoom(_ chat: ChatSummary, service: MatrixMessagesService) async throws -> Room {
        guard self.service === service, let person = chat.otherPerson,
              let room = try service.client.getRoom(roomId: chat.id), room.membership() == .joined,
              let info = try? await room.roomInfo(), info.isDirect, await room.isEncrypted(),
              let blocked = try? await service.blocked(), !blocked.contains(person),
              let members = try? await room.members() else { throw CallFailure.unavailable }
        var joined: Set<String> = []
        while let chunk = members.nextChunk(chunkSize: 100) {
            guard !chunk.contains(where: { $0.membership == .invite }) else { throw CallFailure.unavailable }
            joined.formUnion(chunk.filter { $0.membership == .join }.map(\.userId))
        }
        guard joined == Set([person, service.userID]), self.service === service else { throw CallFailure.unavailable }
        return room
    }

    private func send(_ signal: VoiceSignal, to room: Room) async throws {
        guard await room.isEncrypted() else { throw CallFailure.unavailable }
        if signal.kind == .invite || signal.kind == .answer { try requireCurrent(signal.id) }
        let payload = String(decoding: try JSONEncoder().encode(signal), as: UTF8.self)
        let content = ["msgtype": VoiceSignal.messageType, "body": payload]
        let json = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        _ = try await room.sendRaw(eventType: "m.room.message", content: json)
    }

    private func makePeer(_ id: UUID, service: MatrixMessagesService) async throws -> RTCPeerConnection {
        guard await AVAudioApplication.requestRecordPermission() else {
            if call?.id == id { notice = "Allow microphone access in Settings to make a call." }
            throw CallFailure.unavailable
        }
        let servers = await relayServers(service)
        try requireCurrent(id)
        let audio = AVAudioSession.sharedInstance()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = servers
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw CallFailure.unavailable
        }
        self.peer = peer
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try audio.setActive(true)
        let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "voice")
        guard peer.add(track, streamIds: ["voice"]) != nil else { throw CallFailure.unavailable }
        microphone = track
        return peer
    }

    private func relayServers(_ service: MatrixMessagesService) async -> [RTCIceServer] {
        struct Relay: Decodable {
            let uris: [String]
            let username: String
            let password: String
        }
        guard let endpoint = URL(string: MatrixMessagesService.homeserver + "/_matrix/client/v3/voip/turnServer"),
              let session = try? service.client.session() else { return [] }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let relay = try? JSONDecoder().decode(Relay.self, from: data) else { return [] }
        let urls = relay.uris.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") || $0.hasPrefix("stun:") }
        guard !urls.isEmpty else { return [] }
        return [RTCIceServer(urlStrings: urls, username: relay.username, credential: relay.password)]
    }

    private func localDescription(_ peer: RTCPeerConnection, offer: Bool, id: UUID) async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let description: RTCSessionDescription
        if offer {
            description = try await peer.offer(for: constraints)
        } else {
            description = try await peer.answer(for: constraints)
        }
        try requireCurrent(id)
        try await peer.setLocalDescription(description)
        for _ in 0..<40 {
            try requireCurrent(id)
            if peer.iceGatheringState == .complete, let sdp = peer.localDescription?.sdp, validAudio(sdp) { return sdp }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CallFailure.unavailable
    }

    private func validAudio(_ sdp: String) -> Bool {
        let lines = sdp.split(whereSeparator: \.isNewline)
        let media = lines.filter { $0.hasPrefix("m=") }
        return sdp.utf8.count <= 20_000 && media.count == 1 && media[0].hasPrefix("m=audio ")
            && lines.contains { $0.hasPrefix("a=fingerprint:sha-256 ") }
    }

    private func requireCurrent(_ id: UUID) throws {
        guard !Task.isCancelled, call?.id == id else { throw CancellationError() }
    }

    private func monitorPeer(_ id: UUID) {
        guard call?.id == id else { return }
        monitor?.cancel()
        monitor = Task { [weak self] in
            var disconnectedSince: ContinuousClock.Instant?
            while !Task.isCancelled, let self, self.call?.id == id, let peer = self.peer {
                switch peer.connectionState {
                case .connected:
                    disconnectedSince = nil
                    self.call?.phase = .connected
                    self.timeout?.cancel()
                case .failed, .closed:
                    self.failed(id)
                    return
                case .disconnected:
                    let now = ContinuousClock.now
                    if let disconnectedSince, disconnectedSince.duration(to: now) > .seconds(12) {
                        self.failed(id)
                        return
                    }
                    if disconnectedSince == nil { disconnectedSince = now }
                default: break
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func expire(_ id: UUID, after duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.call?.id == id else { return }
            if self.call?.phase == .incoming {
                self.notice = "Missed call."
                self.reset()
            } else {
                self.notice = self.call?.phase == .dialing ? "No answer." : "The call didn't connect."
                Task { await self.hangUp(id) }
            }
        }
    }

    private func failed(_ id: UUID) {
        guard call?.id == id else { return }
        if notice == nil { notice = "Couldn't connect the voice call." }
        Task { await hangUp(id) }
    }

    private func reset() {
        timeout?.cancel()
        monitor?.cancel()
        call = nil
        let usedAudio = peer != nil
        peer?.close()
        peer = nil
        microphone = nil
        muted = false
        speaker = false
        if usedAudio { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private enum CallFailure: Error { case unavailable }
}

private struct VoiceTimelineEvent: Sendable {
    let signal: VoiceSignal
    let timestamp: Date
    let isOwn: Bool
}

private final class VoiceTimelineListener: TimelineListener {
    let sender: String?
    let own: String
    let update: @Sendable ([VoiceTimelineEvent]) -> Void
    init(sender: String?, own: String, _ update: @escaping @Sendable ([VoiceTimelineEvent]) -> Void) {
        self.sender = sender
        self.own = own
        self.update = update
    }

    private static func authenticated(_ shield: ShieldState) -> Bool {
        switch shield {
        // A contact's Matrix identity may be personally unverified. The device
        // still has to be signed by that identity for the call signal to count.
        case .none, .red(.unverifiedIdentity), .grey(.unverifiedIdentity):
            return true
        case .red, .grey:
            return false
        }
    }

    func onUpdate(diff: [TimelineDiff]) {
        let events: [VoiceTimelineEvent] = diff.flatMap { change -> [TimelineItem] in
            switch MatrixChat.change(change) {
            case .append(let items), .reset(let items): items
            case .pushFront(let item), .pushBack(let item), .insert(_, let item), .set(_, let item): [item]
            default: []
            }
        }.compactMap { item in
            guard let event = item.asEvent(), event.isRemote, event.sender == sender || event.sender == own,
                  event.forwarder == nil,
                  case .msgLike(let like) = event.content,
                  case .message(let message) = like.kind,
                  case .other(let type, let body) = message.msgType, type == VoiceSignal.messageType,
                  body.utf8.count < 24_000,
                  Self.authenticated(event.lazyProvider.getShields(strict: true)),
                  let signal = try? JSONDecoder().decode(VoiceSignal.self, from: Data(body.utf8)) else { return nil }
            return VoiceTimelineEvent(signal: signal, timestamp: MatrixMessagesService.date(event.timestamp), isOwn: event.sender == own)
        }
        if !events.isEmpty { update(events) }
    }
}

struct VoiceCallsHome: View {
    let calls: VoiceCalls
    let chats: [ChatSummary]
    let ready: Bool
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    HeaderButton("Back", systemImage: "chevron.left", action: close)
                    ScreenTitle("Calls")
                    Spacer()
                    AskTotalityButton(context: AIAskContext(id: "calls.home", module: .calls, title: "Calls"))
                }
                if let notice = calls.notice { Text(notice).font(Typeface.callout) }
                if !ready || chats.isEmpty {
                    Text(ready ? "Accept a one-to-one conversation in Messages to make a voice call." :
                        "Connect Messages to make a voice call.")
                        .font(Typeface.body)
                        .foregroundStyle(Theme.current.textSecondary.color)
                }
                ForEach(chats) { chat in
                    HStack {
                        Text(chat.title).font(Typeface.body).lineLimit(1)
                        Spacer()
                        HeaderPill("Call \(chat.title)", systemImage: "phone", iconOnly: true) {
                            Task { await calls.dial(chat) }
                        }
                        .disabled(!ready || calls.call != nil)
                    }
                }
            }
            .padding(Space.s4)
        }
        .foregroundStyle(Theme.current.textPrimary.color)
    }
}

struct VoiceCallPresentation: ViewModifier {
    let calls: VoiceCalls
    let showingCalls: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { calls.call != nil }, set: { _ in })) {
                VoiceCallSheet(calls: calls)
            }
            .alert("Voice call", isPresented: Binding(
                get: { !showingCalls && calls.call == nil && calls.notice != nil },
                set: { if !$0 { calls.notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(calls.notice ?? "")
            }
    }
}

private struct VoiceCallSheet: View {
    let calls: VoiceCalls

    var body: some View {
        if let call = calls.call {
            VStack(spacing: Space.s4) {
                ScreenTitle(call.chat.title, subtitle: call.phase.rawValue)
                if let notice = calls.notice { Text(notice).font(Typeface.callout) }
                if call.phase == .incoming {
                    HeaderPill("Answer", systemImage: "phone", isProminent: true) { Task { await calls.answer() } }
                }
                if call.phase == .connected {
                    HStack {
                        HeaderPill(calls.muted ? "Unmute" : "Mute", systemImage: calls.muted ? "mic.slash" : "mic") {
                            calls.toggleMute()
                        }
                        HeaderPill("Speaker", systemImage: calls.speaker ? "speaker.wave.2.fill" : "speaker.wave.2",
                                   isProminent: calls.speaker) { calls.toggleSpeaker() }
                    }
                }
                HeaderPill(call.phase == .incoming ? "Decline" : "End call", systemImage: "phone.down") {
                    Task { await calls.hangUp() }
                }
            }
            .padding(Space.s4)
            .interactiveDismissDisabled()
        }
    }
}
#endif
