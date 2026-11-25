import Foundation

/// "Who can message me" and message requests (issue 149 §4, step 8). The Matrix guard on Totality's
/// server enforces the setting; this side only explains it and offers a request instead of a refusal.
extension MessagesModel {
    /// Your setting, requests waiting for you, and who accepted yours. Quietly keeps what it had offline.
    public func loadPrivacy() async {
        guard let privacy, phase == .ready else { return }
        let mine = generation
        async let reach = try? privacy.myReach()
        async let incoming = try? privacy.incoming()
        async let accepted = try? privacy.accepted()
        let (r, i, a) = await (reach, incoming, accepted)
        guard mine == generation else { return }
        if let r { self.reach = r }
        if let i { messageRequests = i }
        if let a {
            acceptedBy = Set(a)
            joinAcceptedRequests()
        }
    }

    public func setReach(_ reach: MessageReach) async {
        guard let privacy else { return }
        let before = self.reach
        self.reach = reach
        do {
            notice = nil
            try await privacy.setReach(reach)
        } catch {
            self.reach = before
            notice = Self.describe(error)
        }
    }

    /// Sends the request New message offered. True once it's sent.
    @discardableResult
    public func sendRequest() async -> Bool {
        guard let privacy, let username = needsRequest else { return false }
        do {
            try await privacy.sendRequest(to: username)
            needsRequest = nil
            sentRequestTo = username
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Accepts a request and starts the chat with them, which their app joins straight away.
    public func accept(_ request: MessageRequest) async {
        guard let privacy, let service else { return }
        do {
            notice = nil
            try await privacy.answer(request.username, accept: true)
            messageRequests.removeAll { $0 == request }
            requestedChat = try await service.startChat(with: request.username)
        } catch {
            notice = Self.describe(error)
        }
    }

    /// Deletes a request. They aren't told, and can't send another.
    public func decline(_ request: MessageRequest) async {
        guard let privacy else { return }
        do {
            notice = nil
            try await privacy.answer(request.username, accept: false)
            messageRequests.removeAll { $0 == request }
        } catch {
            notice = Self.describe(error)
        }
    }

    // MARK: Inside the model

    func hasChat(with username: String) -> Bool {
        chats.contains { !$0.isGroup && $0.otherPerson.map(MessagesUsername.display) == username }
    }

    /// Nil when it can't be asked (no backend, offline): the guard still decides, so starting is tried.
    func reachAnswer(for username: String) async -> ReachAnswer? {
        guard let privacy else { return nil }
        return try? await privacy.reach(username)
    }

    /// Why a group can't start with these people yet, or nil when it can.
    func notReachable(_ names: [String]) async -> String? {
        guard privacy != nil else { return nil }
        var refused: [String] = []
        for name in names {
            if let answer = await reachAnswer(for: name), answer != .allowed { refused.append("@" + name) }
        }
        guard !refused.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: refused)
        return refused.count == 1
            ? "\(list) only takes messages from people they know. Message them on their own first to send a request."
            : "\(list) only take messages from people they know. Message each of them on their own first to send a request."
    }

    /// Joins, once, a one-to-one invite from someone who accepted your request: it's the chat you asked for.
    func joinAcceptedRequests() {
        guard let service, !acceptedBy.isEmpty else { return }
        for request in requests where !request.isGroup && !autoJoined.contains(request.id) {
            guard let from = request.from, acceptedBy.contains(MessagesUsername.display(from)) else { continue }
            autoJoined.insert(request.id)
            Task { try? await service.accept(request.id) }
        }
    }
}
