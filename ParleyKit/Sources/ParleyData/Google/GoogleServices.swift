import Foundation
import ParleyDomain
import os

/// Google's services beyond Chat's own API that Google Chat's web client uses (Drive suggestions, People),
/// on hosts Parley signs requests to. A fixed list: a link in a message never gets a signed request.
enum GoogleHost: String, CaseIterable, Sendable {
    case taskAssist = "taskassist-pa.clients6.google.com"  // Drive file suggestions
    case peopleStack = "peoplestack-pa.clients6.google.com"  // a person's calendar time zone
    case people = "people-pa.clients6.google.com"  // directory people and spaces for the @ list
}

/// One call to one of Google's services: where it goes, what it sends, how to read the answer. A new capability is a
/// new type conforming to this; `GoogleServices` signs and sends any of them.
protocol GoogleRequest: Sendable {
    associatedtype Reply: Sendable
    var host: GoogleHost { get }
    var path: String { get }
    /// The body as sent, and its content type.
    var body: (data: Data, contentType: String) { get throws }
    /// Headers beyond the signing ones, as the service wants them.
    var headers: [String: String] { get }
    /// A gRPC-web service: the API key goes in an `x-goog-api-key` header rather than as `key=`, and the call names its
    /// client in `x-user-agent`, as Google Chat's web sends it.
    var grpcWeb: Bool { get }
    func reply(_ data: Data) throws -> Reply
}
extension GoogleRequest {
    var headers: [String: String] { [:] }
    var grpcWeb: Bool { false }
    /// A JSPB body: field n at index n-1, as Google's JSON+protobuf services take it.
    static func jspb(_ fields: [Any?]) throws -> (data: Data, contentType: String) {
        (try JSONSerialization.data(withJSONObject: fields.map { $0 ?? NSNull() }), "application/json+protobuf")
    }
}

enum GoogleServiceError: Error, Equatable {
    case unexpectedReply  // the service answered in a shape Parley doesn't read
}

/// Signs and sends `GoogleRequest`s as Google Chat's web does: the session's cookies, a SAPISID hash (both added by
/// `WebSessionAuthorizer` for these hosts) and the Chat page's API key, read once and again after a refusal.
actor GoogleServices {
    private let authorizer: WebSessionAuthorizer
    private var key: String?
    private let log = Logger(subsystem: "dev.cuza.Parley", category: "google")
    init(authorizer: WebSessionAuthorizer) { self.authorizer = authorizer }

    func send<Request: GoogleRequest>(_ request: Request) async throws -> Request.Reply {
        for attempt in 0...1 {
            let key = try await apiKey(fresh: attempt > 0)
            var components = URLComponents()
            components.scheme = "https"
            components.host = request.host.rawValue
            components.path = request.path
            if !request.grpcWeb { components.queryItems = [URLQueryItem(name: "key", value: key)] }
            var urlRequest = URLRequest(url: components.url!)
            if request.grpcWeb {
                urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                urlRequest.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
            }
            urlRequest.httpMethod = "POST"
            let body = try request.body
            urlRequest.httpBody = body.data
            urlRequest.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            do {
                let (data, _) = try await authorizer.data(for: urlRequest)
                log.info(
                    "\(request.host.rawValue, privacy: .public)\(request.path, privacy: .public): \(data.count, privacy: .public) bytes"
                )
                return try request.reply(data)
            } catch AuthFailure.http(let status) where attempt == 0 && (status == 401 || status == 403) {
                log.notice(
                    "\(request.host.rawValue, privacy: .public)\(request.path, privacy: .public) refused (\(status, privacy: .public)): reading the key again"
                )
                continue
            }
        }
        throw AuthFailure.http(403)
    }
    /// The web client's API key, from the Chat page's registration block (the realtime channel reads the same page).
    private func apiKey(fresh: Bool) async throws -> String {
        if !fresh, let key { return key }
        guard let block = try await authorizer.punctualRegistration(fresh: fresh),
            let registration = PunctualWire.Registration(block)
        else { throw GoogleServiceError.unexpectedReply }
        key = registration.apiKey
        return registration.apiKey
    }
}

/// Google's JSON+protobuf ("JSPB") replies: arrays where field n sits at index n-1, behind a ")]}'" guard.
enum JSPB {
    static func parse(_ data: Data) throws -> Any {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw GoogleServiceError.unexpectedReply
        }
        return value
    }
    /// Field `number` of a JSPB message, nil when absent or null.
    static func field(_ message: Any?, _ number: Int) -> Any? {
        guard let array = message as? [Any], number >= 1, number <= array.count, !(array[number - 1] is NSNull) else {
            return nil
        }
        return array[number - 1]
    }
}
