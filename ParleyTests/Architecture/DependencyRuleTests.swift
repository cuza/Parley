import Foundation
import Testing

/// The dependency rule (README's Architecture): inner layers never name outer ones. Domain and Data are modules of
/// ParleyKit, so the compiler holds them to it. The app target's layers share one module: this reads their sources, finds
/// which layer declares each top-level type, and fails when a file uses a type from a layer it may not depend on, or
/// imports a module where none belongs.
struct DependencyRuleTests {
    /// The app target's layers, inner first, and what each may use besides itself and Domain.
    enum Layer: String, CaseIterable {
        case store = "Store"
        case shared = "Shared"
        case features = "Features"
        case app = "App"
        case intents = "Intents"
        case fake = "Fake"
        var allowed: Set<Layer> {
            switch self {
            case .store, .shared: []
            // Views tag themselves with App Intents entities so Siri sees what's on screen.
            case .features: [.store, .shared, .intents]
            // The demo and test backend builds the whole demo workspace, so it isn't held to the rule.
            case .app, .intents, .fake: Set(Layer.allCases)
            }
        }
        /// Modules a layer may not import. Store may use AppKit for system services (wake and sleep, sounds), not
        /// SwiftUI. Only the outer layers reach Data; the rest go through Domain's protocols.
        var forbiddenImports: Set<String> {
            switch self {
            case .store: ["SwiftUI", "ParleyData"]
            case .shared, .features: ["ParleyData"]
            default: []
            }
        }
    }
    struct Source {
        let path: String
        let layer: Layer
        let text: String
        /// What this file may use besides its own layer.
        var allowed: Set<Layer> { layer.allowed }
        /// What this file may not import.
        var forbiddenImports: Set<String> {
            // Signing in is the session: the sign-in views drive it directly.
            if path.hasPrefix("Features/SignIn/") { return layer.forbiddenImports.subtracting(["ParleyData"]) }
            return layer.forbiddenImports
        }
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Parley")

    static func sources() throws -> [Source] {
        let files =
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.compactMap { url in
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard let top = relative.split(separator: "/").first, let layer = Layer(rawValue: String(top)) else {
                return nil
            }
            return Source(path: relative, layer: layer, text: try String(contentsOf: url, encoding: .utf8))
        }
    }
    /// The code without comments and string literals, so a type named in a doc comment or a message isn't a dependency.
    static func code(_ text: String) -> String {
        var code = text
        for pattern in [#"/\*[\s\S]*?\*/"#, #"//[^\n]*"#, #""""[\s\S]*?""""#, #""(?:[^"\\\n]|\\.)*""#] {
            code = code.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return code
    }
    /// Top-level types each layer declares (not nested ones, whose short names repeat across layers).
    static func declarations(_ sources: [Source]) -> [String: Layer] {
        var owners: [String: Layer] = [:]
        let pattern = try! NSRegularExpression(  // swiftlint:disable:this force_try
            // Modifiers and attributes in any order, so `@MainActor final class` counts too.
            pattern:
                #"^(?:(?:public|internal|private|fileprivate|final|indirect|nonisolated)\s+|@\w+(?:\([^)]*\))?\s+)*"#
                + #"(?:class|struct|enum|actor|protocol|typealias)\s+([A-Z]\w*)"#,
            options: .anchorsMatchLines)
        for source in sources {
            let code = code(source.text)
            for match in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                owners[String(code[range])] = source.layer
            }
        }
        return owners
    }

    @Test func innerLayersNeverNameOuterOnes() throws {
        let sources = try Self.sources()
        #expect(sources.count > 100, "found the sources under \(Self.root.path)")
        let owners = Self.declarations(sources)
        var violations: [String] = []
        for source in sources {
            let words = Set(
                Self.code(source.text).split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
            for word in words.sorted() {
                guard let owner = owners[word], owner != source.layer, !source.allowed.contains(owner) else { continue }
                violations.append("\(source.path) uses \(word) from \(owner.rawValue)")
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }
    @Test func layersImportOnlyWhatTheyMay() throws {
        var violations: [String] = []
        for source in try Self.sources() {
            for line in source.text.split(separator: "\n")
            where line.hasPrefix("import ") || line.hasPrefix("@preconcurrency import ") {
                let module = String(line.split(separator: " ").last ?? "")
                if source.forbiddenImports.contains(module) { violations.append("\(source.path) imports \(module)") }
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }
}
