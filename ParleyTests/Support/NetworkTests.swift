import Foundation
import SwiftProtobuf
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Every test that answers requests from a stub exchange, one suite per topic nested here
/// (`extension NetworkTests { @Suite struct <Topic>Tests: NetworkSuite {} }`). They run one at a time, as they always
/// have: `.serialized` reaches every nested suite.
@Suite(.serialized) enum NetworkTests {}

/// The helpers network-stubbed suites share, as `Self.<helper>` inside a suite or `NetworkTests.<helper>` outside one.
protocol NetworkSuite {}
extension NetworkTests: NetworkSuite {}

extension NetworkSuite {
    /// A reply carrying `message` in binary, as Google Chat's API answers.
    static func proto(_ message: some SwiftProtobuf.Message) throws -> StubExchange.Reply {
        .init(headers: ["Content-Type": "application/x-protobuf"], data: try message.serializedBytes())
    }
    /// A request's body. URLProtocol sees it as a stream; this reads it back for assertions.
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
    /// The body of the last request to `/api/<path>`.
    static func body(_ exchange: StubExchange, _ path: String) throws -> [UInt8] {
        [UInt8](body(try #require(exchange.requests.last { $0.url?.path == "/api/\(path)" })))
    }
    /// The RequestHeader every RPC sends, in bytes.
    static var header: [UInt8] { Array(Wire.encoded(DynamiteClient.header)) }
    /// A message posted by `user` in topic `topic` of space `x`, its text its id.
    static func message(_ id: String, topic: String, at time: Int64, by user: String = "u1") -> Dynamite_Message {
        .with {
            $0.id.parentID.topicID.topicID = topic
            $0.id.messageID = id
            $0.createTime = time
            $0.creator.userID.id = user
            $0.textBody = id
        }
    }

    /// A backend signed in as "me" (Dave), knowing Maria ("u1"), whose next requests `extra` answers.
    static func connected(_ extra: [StubExchange.Reply] = []) async throws -> (DynamiteBackend, StubExchange) {
        let me = try proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" })
        let people = try proto(
            Dynamite_GetMembersResponse.with {
                $0.memberProfiles = [("me", "Dave"), ("u1", "Maria")].map { id, name in
                    .with {
                        $0.member.user.userID.id = id
                        $0.member.user.name = name
                    }
                }
            })
        let (auth, exchange) = try signedIn([me, people] + extra)
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        return (backend, exchange)
    }
    /// Everything the backend emitted so far; disconnect's `.offline` marks the end.
    static func drain(_ backend: DynamiteBackend) async -> [ChatEvent] {
        await backend.disconnect()
        var events: [ChatEvent] = []
        for await event in backend.events {
            if event == .connectionChanged(.offline) { break }
            events.append(event)
        }
        return events
    }
    /// A pushed event of `type` carrying `message`, in space `space`.
    static func pushed(_ type: Dynamite_EventBody.EventType, _ message: Dynamite_Message, space: String = "x")
        -> Dynamite_StreamEventsResponse
    {
        .with {
            $0.event.groupID.spaceID.spaceID = space
            $0.event.bodies = [
                .with {
                    $0.eventType = type
                    $0.messagePosted.message = message
                }
            ]
        }
    }
    /// The messages among `events`.
    static func upserts(_ events: [ChatEvent]) -> [ParleyDomain.Message] {
        events.compactMap { if case .messageUpserted(let message) = $0 { message } else { nil } }
    }
    /// The stream's first event: the session is ready.
    static var ready: Dynamite_StreamEventsResponse {
        .with { $0.event.bodies = [.with { $0.eventType = .sessionReady }] }
    }
}
