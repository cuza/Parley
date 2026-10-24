import ServiceManagement

/// macOS's login item for an app; `SMAppService.mainApp` in the app, a fake in tests.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
extension SMAppService: LoginItemService {}
/// Settings ▸ General's "Open Parley at login". Off until turned on: macOS registers nothing by itself.
struct LoginItem {
    var service: LoginItemService = SMAppService.mainApp
    var isOn: Bool { service.status == .enabled }
    /// Turned on, waiting for the user in System Settings ▸ General ▸ Login Items.
    var needsApproval: Bool { service.status == .requiresApproval }
    func set(_ on: Bool) throws { if on { try service.register() } else { try service.unregister() } }
}
