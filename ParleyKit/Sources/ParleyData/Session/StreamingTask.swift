#if !canImport(Darwin)
    import Foundation
    import FoundationNetworking

    /// `URLSession.bytes(for:)` where Foundation doesn't have it (Linux, Windows): returns once the response headers
    /// arrive, then streams the body as it comes. Redirects are refused, as `NoAuthRedirects` does on Apple platforms.
    func streamBytes(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (
        AsyncThrowingStream<UInt8, any Error>, URLResponse
    ) {
        let (bytes, body) = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let delegate = StreamingDelegate(body: body)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        body.onTermination = { _ in task.cancel() }  // the reader stopped early or was cancelled
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { headers in
                delegate.waitForHeaders(headers)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (bytes, response)
    }

    private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var headers: CheckedContinuation<URLResponse, any Error>?  // guarded by lock
        private let body: AsyncThrowingStream<UInt8, any Error>.Continuation

        init(body: AsyncThrowingStream<UInt8, any Error>.Continuation) { self.body = body }

        func waitForHeaders(_ continuation: CheckedContinuation<URLResponse, any Error>) {
            lock.withLock { headers = continuation }
        }
        private func resumeHeaders(_ result: Result<URLResponse, any Error>) {
            lock.withLock {
                headers?.resume(with: result)
                headers = nil
            }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            resumeHeaders(.success(response))
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            for byte in data { body.yield(byte) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            resumeHeaders(.failure(error ?? URLError(.badServerResponse)))  // no-op once the headers came
            body.finish(throwing: error)
            session.finishTasksAndInvalidate()  // a session keeps its delegate until invalidated
        }
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
#endif
