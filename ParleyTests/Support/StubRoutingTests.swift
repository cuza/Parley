import Foundation
import Testing

/// The stub harness itself: a request goes to the exchange of the test that made its session, so a task an earlier
/// test left running can't take the replies meant for the next one.
struct StubRoutingTests {
    @Test func aRequestReachesTheExchangeItsSessionWasMadeFor() async throws {
        let first = StubExchange([.init(data: Data("first".utf8))])
        let second = StubExchange([.init(data: Data("second".utf8))])
        let earlier = AuthStubProtocol.session(first)
        _ = AuthStubProtocol.session(second)  // the next test's session
        let (data, _) = try await earlier.data(from: URL(string: "https://chat.google.com/late")!)
        #expect(String(decoding: data, as: UTF8.self) == "first")
        #expect(second.requests.isEmpty)
    }
}
