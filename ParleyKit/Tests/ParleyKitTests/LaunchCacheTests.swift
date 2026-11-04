import Foundation
import Testing

@testable import ParleyData

@Test func launchCacheLivesInApplicationSupport() {
    #expect(LaunchCache.dynamite.url.path(percentEncoded: false).contains("Parley/cache"))
    #if os(macOS)
        // An installed copy reads its cache from here after an update.
        #expect(LaunchCache.dynamite.url.path(percentEncoded: false).contains("Library/Application Support/Parley/"))
    #endif
}
