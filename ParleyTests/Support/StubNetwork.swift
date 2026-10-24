import Foundation

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// The Keychain's session entry, kept in memory.
final class MemoryVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read() -> Data? { lock.withLock { value } }
    func write(_ data: Data) { lock.withLock { value = data } }
    func delete() { lock.withLock { value = nil } }
}

/// One test's server: answers its session's requests with `replies`, in order, and records each request.
final class StubExchange: @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        var data = Data()
        var failure: URLError.Code?
        var delay: TimeInterval = 0  // before answering
        var hold: TimeInterval = 0  // open after the data, as a long poll
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func next(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            recorded.append(request)
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            return replies.removeFirst()
        }
    }
    var requests: [URLRequest] { lock.withLock { recorded } }
}

/// Each stub session's exchange, by the id its requests carry (`X-Stub-Exchange`).
final class StubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [String: StubExchange] = [:]
    func add(_ value: StubExchange) -> String {
        let id = UUID().uuidString
        lock.withLock { exchanges[id] = value }
        return id
    }
    func get(_ id: String?) -> StubExchange? { lock.withLock { id.flatMap { exchanges[$0] } } }
}

/// Answers every request of a stub session from its exchange, without touching the network.
final class AuthStubProtocol: URLProtocol, @unchecked Sendable {
    static let registry = StubRegistry()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let exchange = Self.registry.get(request.value(forHTTPHeaderField: "X-Stub-Exchange")),
                let url = request.url
            else { throw URLError(.badServerResponse) }
            let reply = try exchange.next(request)
            if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }  // a slow server: the caller awaits meanwhile
            if let failure = reply.failure { throw URLError(failure) }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
            else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            if reply.hold > 0 { Thread.sleep(forTimeInterval: reply.hold) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    /// A session whose requests `exchange` answers.
    static func session(_ exchange: StubExchange) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["X-Stub-Exchange": registry.add(exchange)]
        config.protocolClasses = [Self.self]
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoAuthRedirects(), delegateQueue: nil)
    }
}
