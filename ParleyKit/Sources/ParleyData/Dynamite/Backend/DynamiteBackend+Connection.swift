import Foundation
import ParleyDomain

extension DynamiteBackend {
    public func connect() async throws -> Person {
        let status: Dynamite_GetSelfUserStatusResponse = try await rpc(
            "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        guard !status.userStatus.userID.id.isEmpty else { throw DynamiteError.malformedReply }
        selfID = status.userStatus.userID.id
        continuation.yield(.ownStatusChanged(DynamiteMapper.ownStatus(status.userStatus)))
        readyBefore = false  // a fresh load follows every connect
        await resolve([selfID])
        continuation.yield(.connectionChanged(.connecting))
        if realtime {
            let punctual = PunctualChannel(
                authorizer: authorizer,
                onEvent: { [weak self] in await self?.apply($0) },
                onState: { [weak self] in await self?.channelChanged($0) },
                onGap: { [weak self] in await self?.reload() })
            await punctual.subscribe(watched)
            // From here to the end, nothing awaits: a connect that overlaps this one can't slip in between the old channel
            // being cancelled and this one taking its place, and leave a channel no one cancels.
            channel?.cancel()
            stayAwake(true)
            self.realtimeChannel = punctual
            channel = Task { await punctual.run() }
            // Polling starts from now: what came before is in the pages this connect loads.
            userRevision = max(userRevision, Int64(Date.now.timeIntervalSince1970 * 1_000_000))
            polling(true)  // until the channel connects
        }
        return people[selfID] ?? Person(id: PersonID(selfID), name: "Me")
    }
    /// Closes the realtime channel and polling; tests end an event stream with it.
    func disconnect() {
        stayAwake(false)
        channel?.cancel()
        channel = nil
        polling(false)
        realtimeChannel = nil
        continuation.yield(.connectionChanged(.offline))
    }
    func stayAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Google Chat connection")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    public func watch(_ conversations: Set<ConversationID>) async {
        watched = conversations
        await realtimeChannel?.subscribe(conversations)
    }
    static let pollInterval: Duration = .seconds(10)
    /// The channel's state as the app sees it. Polling doesn't stand in for it: catch_up_user leaves out new messages.
    /// Events are polled while the channel is down, and not once it is signed out: polling would only fail again.
    func channelChanged(_ state: ConnectionState) {
        polling(state != .connected && state != .signedOut)
        if state == .signedOut { stayAwake(false) }
        continuation.yield(.connectionChanged(state))
    }
    /// Starts or stops the fallback poll: a round every `pollInterval`, the first one an interval after it starts.
    func polling(_ on: Bool) {
        guard on else {
            poller?.cancel()
            poller = nil
            return
        }
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }
    /// One round of polling: the events since the last one, announced as if pushed (notifications included). Events at
    /// or before the revision already seen are skipped, so a replayed one (a reaction toggle) never applies twice.
    @discardableResult
    func poll() async -> Bool {
        let from = userRevision
        do {
            let response = try await catchUpPage(from: from, size: 500)
            for event in response.events where max(event.userRevision.timestamp, event.groupRevision.timestamp) > from {
                await apply(event, live: true)
            }
            if !polled { log.notice("Polling for events: the realtime channel is down") }
            polled = true
            return true
        } catch {
            log.error("Polling failed: \(PunctualChannel.reason(error), privacy: .public)")
            return false
        }
    }

    /// The realtime stream restarted without its missed changes: reload the conversations and the open one.
    func reload() { continuation.yield(.resync) }

    /// Events missed while the channel was down (Google Chat: catch_up_user on every SESSION_READY); else a full resync.
    func catchUp() async {
        var from = userRevision
        guard from > 0 else {
            continuation.yield(.resync)
            return
        }
        do {
            for _ in 0..<10 {  // ponytail: ≤ 20k events; past that a resync is cheaper anyway
                let response = try await catchUpPage(from: from, size: 2000)
                for event in response.events { await apply(event, live: false) }
                if response.status == .completed { return }
                guard response.status == .paginated, userRevision > from else { break }
                from = userRevision
            }
        } catch {
            log.error("catch_up_user failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        continuation.yield(.resync)
    }
    /// One `catch_up_user` page: the events after a revision, at most `size` of them.
    private func catchUpPage(from revision: Int64, size: Int32) async throws -> Dynamite_CatchUpResponse {
        try await rpc(
            "catch_up_user",
            Dynamite_CatchUpUserRequest.with { request in
                request.range.fromRevisionTimestamp = revision
                request.pageSize = size
                request.cutoffSize = size
            })
    }
}
