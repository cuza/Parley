import ServiceManagement
import Testing

@testable import Parley

/// "Open Parley at login": macOS's login item for the app, off until turned on.
@MainActor struct LoginItemTests {
    final class FakeService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        func register() throws { status = .enabled }
        func unregister() throws { status = .notRegistered }
    }
    @Test func offUntilTurnedOnAndBackOff() throws {
        let fake = FakeService()
        let item = LoginItem(service: fake)
        #expect(!item.isOn && !item.needsApproval)
        try item.set(true)
        #expect(item.isOn)
        try item.set(false)
        #expect(!item.isOn)
        fake.status = .requiresApproval  // macOS asks in System Settings ▸ General ▸ Login Items
        #expect(item.needsApproval && !item.isOn)
    }
}
