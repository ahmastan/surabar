import KeyboardShortcuts
import Observation
import ServiceManagement

extension KeyboardShortcuts.Name {
    /// Opens or closes the reader from anywhere; Control-Option-Q unless changed in Settings › General.
    static let toggleReader = Self("toggleReader", initial: .init(.q, modifiers: [.control, .option]))
}

/// Launch at login, through the system's login items.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change this: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// When macOS asks the user to allow the login item first.
    var needsApproval: Bool { status == .requiresApproval }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
