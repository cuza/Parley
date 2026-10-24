import ParleyData
import ParleyDomain
import SwiftUI

extension ParleyApp {
    /// The launch's store, whether it runs the real account, and whether windows come back.
    ///
    /// The test host launches this app; keep it off the network and away from the real cache.
    /// UI tests launch it with -uiTestingLongHistory: a long, paged fake history for scroll tests;
    /// -uiTestingManyConversations: 320 more conversations, for sidebar tests.
    /// -uiTestingDemo: the demo workspace (README screenshots), with -uiTestingDark for dark mode, -uiTestingHome to
    /// open on Home, as a real launch does, and -uiTestingTyping for someone typing.
    static func launchStore(
        authorizer: WebSessionAuthorizer
    ) -> (store: ChatStore, live: Bool, restoresWindows: SceneRestorationBehavior) {
        let store: ChatStore
        var live = false
        // The test and demo switches exist in Debug builds only: a release build always runs the real account.
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
            let arguments: [String] = []
            let testHost = false
        #endif
        let restoresWindows: SceneRestorationBehavior =
            testHost || arguments.contains(where: { $0.hasPrefix("-uiTesting") }) ? .disabled : .automatic
        // Tests and the demo workspaces keep no pictures on disk: they'd share the Debug build's folder.
        if testHost
            || arguments.contains(where: { $0.hasPrefix("-uiTesting") })
        {
            ImageCache.directory = nil
            CardLayout.sizesFile = nil
        }
        if arguments.contains("-uiTestingLongHistory") {
            store = ChatStore(backend: FakeBackend(longHistory: 600, latency: .milliseconds(300)))
        } else if arguments.contains("-uiTestingFormattedThread") {
            store = ChatStore(backend: FakeBackend(formattedThread: true))
        } else if arguments.contains("-uiTestingManyConversations") {
            for key in ["collapsedSidebarSections", SidebarLimit.enabledKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            store = ChatStore(backend: FakeBackend(manyConversations: 320))
        } else if testHost || arguments.contains("-uiTestingDemo") {
            let fake = FakeBackend()
            store = ChatStore(backend: fake)
            // Maria keeps typing in Design studio, Maria and Alex in Launch crew, and Gemini keeps working, as their pushes repeat.
            if arguments.contains("-uiTestingTyping") {
                Task {
                    while true {
                        await fake.simulateTyping("maria", in: "design")
                        await fake.simulateTyping("maria", in: "launch")
                        await fake.simulateTyping("alex", in: "launch")
                        await fake.simulateActivity("gemini", in: "gemini", label: "Collecting info")
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
            }
            RemoteImage.preload(FakeBackend.demoIcons)
            if arguments.contains("-uiTestingDemo") {  // the README shots don't follow the Mac's appearance
                NSApplication.shared.appearance = NSAppearance(
                    named: arguments.contains("-uiTestingDark") ? .darkAqua : .aqua)
            }
            if arguments.contains("-uiTestingHome") { store.navigation.shortcut = .home }  // as a real launch opens
        } else {
            live = true
            store = ChatStore(backend: DynamiteBackend(authorizer: authorizer), cache: LaunchCache.dynamite)
            store.navigation.shortcut = LaunchLanding.current.shortcut  // the UI-testing workspaces keep opening a conversation
            _ = SystemNotifier(store: store)  // the store keeps it; registering now catches the click that launched the app
        }
        return (store, live, restoresWindows)
    }
}
