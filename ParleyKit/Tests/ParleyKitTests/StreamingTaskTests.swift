#if !canImport(Darwin)
    import Foundation
    import FoundationNetworking
    import Testing

    @testable import ParleyData

    /// Answers `https://stub.test/<name>` with that name's status and body chunks.
    final class StreamStub: URLProtocol {
        static let scripts: [String: (status: Int, chunks: [String])] = [
            "/two-chunks": (200, ["ab", "cd"]),
            "/one-chunk": (200, ["x"]),
            "/denied": (403, ["denied"]),
        ]
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let script = Self.scripts[url.path] else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in script.chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stream(_ name: String) async throws -> (AsyncThrowingStream<UInt8, any Error>, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamStub.self]
        return try await streamBytes(URLRequest(url: URL(string: "https://stub.test/\(name)")!), configuration: config)
    }

    private func collect(_ bytes: AsyncThrowingStream<UInt8, any Error>) async throws -> [UInt8] {
        var all: [UInt8] = []
        for try await byte in bytes { all.append(byte) }
        return all
    }

    @Test func streamReturnsHeadersThenAllBytes() async throws {
        let (bytes, response) = try await stream("two-chunks")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await collect(bytes) == Array("abcd".utf8))
    }

    @Test(.timeLimit(.minutes(1))) func streamFinishesWhenServerCloses() async throws {
        let (bytes, _) = try await stream("one-chunk")
        let start = ContinuousClock.now
        #expect(try await collect(bytes) == Array("x".utf8))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func errorBodyIsReadable() async throws {
        let (bytes, response) = try await stream("denied")
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        #expect(String(decoding: try await collect(bytes), as: UTF8.self) == "denied")
    }
#endif
