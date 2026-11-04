import Foundation
import Testing

@testable import ParleyDomain

@Test func bareLinksFindsURLsAndTrimsPunctuation() {
    #expect(
        SharedContent.bareLinks(in: "see https://example.com/a, and http://b.org.")
            == [URL(string: "https://example.com/a")!, URL(string: "http://b.org")!])
}
