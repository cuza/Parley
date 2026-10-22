import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

struct PunctualWireTests {
    static let block = #"["dfe.cr.rr",["reg-1"],[null,[null,"/punctual/prod-dynamite-prod-02-us/user-targeted-changes",["","user-state-changes","group-state-changes"]],[1791432459,227491000],[3600],"utid1","key1"],1]"#

    @Test func registrationComesFromThePage() throws {
        let page = #"<script>var x = {"a":"]"}; foo(["other",[1]]); bar("x]["); AF(\#(Self.block));</script>"#
        let json = try #require(PunctualWire.registrationBlock(in: page))
        let registration = try #require(PunctualWire.Registration(json))
        #expect(registration.baseURL.absoluteString == "https://chat.google.com/punctual/prod-02-us")
        #expect(registration.startMicros == 1_791_432_459_227_491)
        #expect(registration.leaseSeconds == 3600)
        #expect(registration.utid == "utid1")
        #expect(registration.apiKey == "key1")
        #expect(PunctualWire.registrationBlock(in: "<html>no block</html>") == nil)
    }
    /// A lease of nothing (0 or less) would renew the channel in a loop at network speed: at least a minute.
    @Test func aTinyLeaseIsAMinute() throws {
        for lease in ["0", "-5", "10"] {
            let json = Self.block.replacingOccurrences(of: "[3600]", with: "[\(lease)]")
            #expect(try #require(PunctualWire.Registration(json)).leaseSeconds == 60)
        }
    }
    @Test func unknownEnvironmentIsRejected() {
        #expect(PunctualWire.Registration(Self.block.replacingOccurrences(of: "prod-dynamite-prod-02-us", with: "staging-x")) == nil)
    }
    @Test func sapisidHashIsGooglesStandardForm() {
        let cookies = [SessionCookie(name: "SAPISID", value: "abc", domain: ".google.com", path: "/", secure: true, expires: -1)]
        #expect(WebSessionAuthorizer.sapisidHash(cookies, at: Date(timeIntervalSince1970: 1_700_000_000))
                == "SAPISIDHASH 1700000000_c37cbcfc4f485638947ca5e102cc6ae5eb0710df")
        #expect(WebSessionAuthorizer.sapisidHash([], at: .now) == nil)
    }
    @Test func requestsMatchGoogleChatsBytes() {
        let user = PunctualWire.Watch(id: 1, target: .user("U"), start: 5, resumed: false, reason: 1)
        #expect(PunctualWire.chooseServer(user) ==
                #"[[null,null,null,[9,5],null,[["user-targeted-changes"],[null,1],[[["userTargeted"],["U"],["events"]]]]],null,null,0,0]"#)
        let typing = PunctualWire.Watch(id: 2, target: .typing("G"), start: nil, resumed: false, reason: 1)
        #expect(PunctualWire.batch([user, typing], streamType: 1) ==
                #"[[[1,[5,null,null,[9,5],null,[["user-targeted-changes"],[null,1],[[["userTargeted"],["U"],["events"]]]],null,0,1],null,1],"#
                + #"[2,[null,null,null,[9,5],null,[["group-state-changes"],[1],[[["state"],["group"],["G"],["typing"]]]],null,0,1],null,1]]]"#)
        #expect(PunctualWire.cancel([7]) == "[[[7,null,[]]]]")
        #expect(PunctualWire.ChooseServerReply(Data(#"["G1",1,null,"10","20"]"#.utf8)) == .init(session: "G1", streamType: 1, delayMs: 0))
    }
    @Test func serverFramesDecode() throws {
        let event = Dynamite_Event.with { $0.userRevision.timestamp = 42 }
        let base64 = (try event.serializedBytes() as Data).base64EncodedString()
        #expect(PunctualWire.updates(#"[null,null,["ch1"]]"#) == [.channel("ch1")])
        #expect(PunctualWire.updates(#"[[["1",[["100"]]]]]"#) == [.started(watch: 1, at: 100)])
        #expect(PunctualWire.updates(#"[[["2",[null,null,["300"]]],["1",[null,null,["300"]]]]]"#)
                == [.watermark(watch: 2, at: 300), .watermark(watch: 1, at: 300)])
        #expect(PunctualWire.updates(#"[[["1",[null,[[[null,"\#(base64)","9",null,null,[]]]]]]]]"#)
                == [.change(watch: 1, payload: try event.serializedBytes())])
        #expect(PunctualWire.updates(#"[[["1",null,[[14,null,"busy"]]]]]"#) == [.failed(watch: 1, code: 14)])
        #expect(PunctualWire.updates(#"[null,[1]]"#) == [.close])
        // A resume point older than Google keeps (about 20 to 30 minutes): the stream ends, then completes with no error.
        #expect(PunctualWire.updates(#"[[["1",[null,null,null,null,[[1]]]]]]"#) == [.ended(watch: 1)])
        #expect(PunctualWire.updates(#"[[["1",null,[[]]]]]"#) == [])
    }
}

extension AuthTests {
    private static func frame(_ json: String) -> String { "\(json.utf16.count)\n\(json)" }
    private static let bootstrap = StubExchange.Reply(data: Data((#"{"SMqcke":"test-xsrf"} "# + PunctualWireTests.block).utf8))

    /// macOS repeats the same network state every few seconds; only the network coming back after being down reconnects
    /// at once. Reopening on every report cut a healthy channel and showed Reconnecting.
    @Test func onlyTheNetworkComingBackReconnects() async throws {
        let auth = WebSessionAuthorizer(vault: MemoryVault(), session: AuthStubProtocol.session(StubExchange([])))
        let channel = PunctualChannel(authorizer: auth, config: .init(backoff: { _ in .seconds(3600) }), onEvent: { _ in }, onState: { _ in })
        #expect(await channel.network(up: true) == false)   // the first report: up, as the channel opened
        #expect(await channel.network(up: true) == false)   // the same again, every few seconds
        #expect(await channel.network(up: false) == false)
        #expect(await channel.network(up: true) == true)    // back after being down
        #expect(await channel.network(up: true) == false)
    }
    /// Conversations subscribed or dropped while the channel opens (the open request was already built) are watched or
    /// cancelled once the stream starts, not left until the next reconnect.
    @Test(.timeLimit(.minutes(1))) func typingWatchesChangedWhileOpeningAreSentOnceStarted() async throws {
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1)], userAgent: "T")))
        let exchange = StubExchange([Self.bootstrap,
                                     .init(data: Data(#"["G1",1,null,"10","20"]"#.utf8), delay: 0.4),   // chooseServer, slow
                                     .init(data: Data(Self.frame(#"[[0,["c","SID1","",8,15,30000]]]"#).utf8)),
                                     .init(data: Data(Self.frame(#"[[1,[[[["1",[["100"]]]]]]]]"#).utf8)),
                                     .init(data: Data()), .init(data: Data()), .init(data: Data())])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let channel = PunctualChannel(authorizer: auth, config: .init(backoff: { _ in .seconds(3600) }), onEvent: { _ in }, onState: { _ in })
        await channel.subscribe(["dm/a", "space/b"])   // watches 2 and 3, in the open request
        let run = Task { await channel.run() }
        try await Task.sleep(for: .milliseconds(150))   // the open request is built; chooseServer is still on its way
        await channel.subscribe(["dm/a", "space/c"])   // c added (watch 4), b dropped
        func sent() -> String {
            exchange.requests.dropFirst(3).map { String(decoding: AuthTests.body($0), as: UTF8.self).removingPercentEncoding ?? "" }.joined()
        }
        for _ in 0..<200 where !(sent().contains(#"["group"],["c"],["typing"]"#) && sent().contains(PunctualWire.cancel([3]))) {
            try await Task.sleep(for: .milliseconds(10))
        }
        run.cancel(); await run.value
        #expect(sent().contains(#"["group"],["c"],["typing"]"#))
        #expect(sent().contains(PunctualWire.cancel([3])))
    }
    /// Woken from sleep on a connection that died: a nudge reopens at once instead of waiting on the dead socket and then
    /// the backoff.
    @Test(.timeLimit(.minutes(1))) func aNudgeReopensAConnectedChannel() async throws {
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1)], userAgent: "T")))
        let choose = StubExchange.Reply(data: Data(#"["G1",1,null,"10","20"]"#.utf8))
        let open = StubExchange.Reply(data: Data(Self.frame(#"[[0,["c","SID1","",8,15,30000]]]"#).utf8))
        let exchange = StubExchange([Self.bootstrap, choose, open,
                                     // The stream starts, then the long poll hangs, as on a connection that died in sleep.
                                     .init(data: Data(Self.frame(#"[[1,[[[["1",[["100"]]]]]]]]"#).utf8), hold: 2),
                                     Self.bootstrap, choose, open])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let (states, sink) = AsyncStream<ConnectionState>.makeStream()
        let channel = PunctualChannel(authorizer: auth, config: .init(backoff: { _ in .seconds(3600) }), onEvent: { _ in }, onState: { sink.yield($0) })
        let run = Task { await channel.run() }
        for await state in states where state == .connected { break }
        await channel.nudge()
        func chooses() -> Int { exchange.requests.filter { $0.url?.path.hasSuffix("chooseServer") == true }.count }
        for _ in 0..<500 where chooses() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel(); await run.value
        #expect(chooses() == 2, "\(exchange.requests.map { ($0.url?.path ?? "") + "?" + ($0.url?.query?.prefix(40) ?? "") })")
    }
    @Test(.timeLimit(.minutes(1))) func punctualChannelDeliversEvents() async throws {
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1),
                       SessionCookie(name: "SAPISID", value: "abc", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "TestAgent/1")))
        let event = Dynamite_Event.with { $0.userRevision.timestamp = 42 }
        let base64 = (try event.serializedBytes() as Data).base64EncodedString()
        let stream = Self.frame(#"[[1,[[null,null,["ch1"]]]],[2,[[[["1",[["100"]]]]]]]]"#)
            + Self.frame(#"[[3,[[[["1",[null,[[[null,"\#(base64)","9"]]]]]]]]]]"#)
        let exchange = StubExchange([Self.bootstrap,
                                     .init(data: Data(#"["G1",1,null,"10","20"]"#.utf8)),
                                     .init(data: Data(Self.frame(#"[[0,["c","SID1","",8,15,30000]]]"#).utf8)),
                                     .init(data: Data(stream.utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let (received, sink) = AsyncStream<Dynamite_Event>.makeStream()
        let (states, stateSink) = AsyncStream<ConnectionState>.makeStream()
        let channel = PunctualChannel(authorizer: auth, onEvent: { sink.yield($0) }, onState: { stateSink.yield($0) })
        let run = Task { await channel.run() }
        var events = received.makeAsyncIterator()
        let ready = await events.next()
        let pushed = await events.next()
        var stateIterator = states.makeAsyncIterator()
        let state = await stateIterator.next()
        run.cancel(); await run.value
        #expect(ready?.bodies.first?.eventType == .sessionReady)
        #expect(pushed?.userRevision.timestamp == 42)
        #expect(state == .connected)
        let requests = exchange.requests
        let choose = requests[1]
        #expect(choose.url?.absoluteString == "https://chat.google.com/punctual/prod-02-us/v1/chooseServer?key=key1")
        #expect(choose.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(choose.value(forHTTPHeaderField: "X-Goog-AuthUser") == "0")
        let open = requests[2]
        #expect(open.url?.path == "/punctual/prod-02-us/multi-watch/channel")
        #expect(open.url?.query?.contains("gsessionid=G1") == true)
        #expect(open.url?.query?.contains("TYPE=init") == false)
        #expect(open.value(forHTTPHeaderField: "X-WebChannel-Content-Type") == "application/json+protobuf")
        let poll = requests[3]
        #expect(poll.httpMethod == "GET")
        #expect(poll.url?.query?.contains("SID=SID1") == true)
    }

    /// Google sends each change on the user stream twice, byte for byte; Parley applies it once.
    @Test(.timeLimit(.minutes(1))) func aRepeatedChangeIsAppliedOnce() async throws {
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1),
                       SessionCookie(name: "SAPISID", value: "abc", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "TestAgent/1")))
        let first = (try Dynamite_Event.with { $0.groupRevision.timestamp = 42 }.serializedBytes() as Data).base64EncodedString()
        let second = (try Dynamite_Event.with { $0.groupRevision.timestamp = 43 }.serializedBytes() as Data).base64EncodedString()
        func change(_ aid: Int, _ base64: String, _ version: String) -> String {
            #"[\#(aid),[[[["1",[null,[[[null,"\#(base64)","\#(version)"]]]]]]]]]"#
        }
        let stream = Self.frame(#"[[1,[[[["1",[["100"]]]]]]]]"#) + Self.frame("[" + change(2, first, "9") + "]")
            + Self.frame("[" + change(3, first, "8") + "]") + Self.frame("[" + change(4, second, "10") + "]")
        let exchange = StubExchange([Self.bootstrap, .init(data: Data(#"["G1",1,null,"10","20"]"#.utf8)),
                                     .init(data: Data(Self.frame(#"[[0,["c","SID1","",8,15,30000]]]"#).utf8)),
                                     .init(data: Data(stream.utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let (received, sink) = AsyncStream<Dynamite_Event>.makeStream()
        let channel = PunctualChannel(authorizer: auth, onEvent: { sink.yield($0) }, onState: { _ in })
        let run = Task { await channel.run() }
        var events = received.makeAsyncIterator()
        _ = await events.next()   // session ready
        let a = await events.next(), b = await events.next()
        run.cancel(); await run.value
        #expect(a?.groupRevision.timestamp == 42)
        #expect(b?.groupRevision.timestamp == 43)
    }

    /// After a long sleep the saved resume point is too old: Google ends the user stream instead of starting it. Parley
    /// has to drop that point and ask for a fresh stream, or it resumes from it on every reconnect and never connects.
    @Test(.timeLimit(.minutes(1))) func anEndedUserStreamReopensFresh() async throws {
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1),
                       SessionCookie(name: "SAPISID", value: "abc", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "TestAgent/1")))
        let choose = StubExchange.Reply(data: Data(#"["G1",1,null,"10","20"]"#.utf8))
        let handshake = StubExchange.Reply(data: Data(Self.frame(#"[[0,["c","SID1","",8,15,30000]]]"#).utf8))
        let live = Self.frame(#"[[1,[[[["1",[["100"]]]]]]],[2,[[[["1",[null,null,["300"]]]]]]],[3,["stop"]]]"#)
        let ended = Self.frame(#"[[4,[[[["1",[null,null,null,null,[[1]]]]]]]],[5,[[[["1",null,[[]]]]]]]]"#)
        let fresh = Self.frame(#"[[6,[[[["1",[["500"]]]]]]]]"#)
        let exchange = StubExchange([Self.bootstrap, choose, handshake, .init(data: Data(live.utf8)),
                                     Self.bootstrap, choose, handshake, .init(data: Data(ended.utf8)),
                                     Self.bootstrap, choose, handshake, .init(data: Data(fresh.utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let (gaps, gapSink) = AsyncStream<Void>.makeStream()
        let channel = PunctualChannel(authorizer: auth, config: .init(backoff: { _ in .zero }), onEvent: { _ in }, onState: { _ in },
                                      onGap: { gapSink.yield() })
        let run = Task { await channel.run() }
        func opens() -> [String] {
            exchange.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("multi-watch/channel") == true }
                .map { String(decoding: Self.body($0), as: UTF8.self).removingPercentEncoding ?? "" }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while opens().count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        var gapIterator = gaps.makeAsyncIterator()
        _ = await gapIterator.next()   // the fresh stream started: what came during the gap is gone, so reload
        run.cancel(); await run.value
        let sent = opens()
        try #require(sent.count >= 3)
        #expect(sent[1].contains("[300,"))                  // the reconnect resumes from the watermark
        #expect(sent[2].contains("[1791432459227491,"))     // after the stream ended: the registration's start
        #expect(!sent[2].contains("[300,"))
    }
}
