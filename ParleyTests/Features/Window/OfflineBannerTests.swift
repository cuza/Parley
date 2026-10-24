import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// A slim bar over the conversation when Parley has been offline a few seconds, so a window without the sidebar shows it.
@MainActor struct OfflineBannerTests {
    @Test func onlyAConnectionThatIsDownShows() {
        #expect(
            OfflineBanner.isDown(.offline) && OfflineBanner.isDown(.reconnecting) && OfflineBanner.isDown(.connecting))
        #expect(!OfflineBanner.isDown(.connected) && !OfflineBanner.isDown(.signedOut))  // signed out has its own screen
    }
    @Test func itShowsOnlyAfterTheDelay() async throws {
        func height(_ connection: ConnectionState) async -> CGFloat {
            let host = NSHostingView(
                rootView: OfflineBanner(connection: connection, delay: .milliseconds(50)).frame(width: 500))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height < 1, "nothing at first: a short drop isn't worth a bar")
            await eventually {
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height > 20
            }
            return host.fittingSize.height
        }
        #expect(await height(.offline) > 20)
    }
}
