import Foundation

/// Error text made safe for the system log and bug reports: addresses, cookie and query values, and quoted names taken out.
public enum Redaction {
    public static func redact(_ text: String) -> String {
        text.replacing(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, with: "<email>")
            .replacing(/([A-Za-z0-9_\-]+)=[^;\s]+/) { "\($0.output.1)=<redacted>" }
            .replacing(/“[^”]*”/, with: "“<name>”")  // how macOS and Parley quote file, space and people names
    }
}
