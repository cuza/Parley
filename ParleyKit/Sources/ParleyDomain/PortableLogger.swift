#if !canImport(os)
    import Foundation

    /// `os.Logger`'s calls where `os` doesn't exist (Linux, Windows), so ParleyKit logs the same way everywhere. Values
    /// stay hidden unless marked `.public`, as `os` does outside a debugger; numbers and booleans are public by default.
    /// One line per message on stderr, which systemd's journal picks up.
    public struct Logger: Sendable {
        public enum Privacy: Sendable { case `public`, `private`, auto }

        public struct Message: ExpressibleByStringInterpolation, Sendable {
            public struct StringInterpolation: StringInterpolationProtocol {
                var text = ""
                public init(literalCapacity: Int, interpolationCount: Int) {}
                public mutating func appendLiteral(_ literal: String) { text += literal }
                public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .auto) {
                    let isScalar = value is any BinaryInteger || value is any BinaryFloatingPoint || value is Bool
                    let shown = privacy == .public || (privacy == .auto && isScalar)
                    text += shown ? String(describing: value) : "<private>"
                }
            }
            let text: String
            public init(stringLiteral value: String) { text = value }
            public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
        }

        let category: String
        public init(subsystem: String, category: String) { self.category = category }

        public func debug(_ message: Message) {}
        public func info(_ message: Message) { write(message) }
        public func notice(_ message: Message) { write(message) }
        public func warning(_ message: Message) { write(message) }
        public func error(_ message: Message) { write(message) }
        public func fault(_ message: Message) { write(message) }

        private func write(_ message: Message) {
            FileHandle.standardError.write(Data("\(category): \(message.text)\n".utf8))
        }
    }
#endif
