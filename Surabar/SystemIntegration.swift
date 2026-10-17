import KeyboardShortcuts
import Observation
import ServiceManagement
import UserNotifications

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

/// Daily Manzil reminders: local notifications at the chosen times, repeating every day. Clicking one
/// opens Surabar on the Manzil.
@MainActor
final class ManzilReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ManzilReminders()
    nonisolated private static let identifiers = ["manzil.morning", "manzil.evening"]

    /// Opens the Manzil; set by the app.
    var onOpen: (() -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Replaces the scheduled reminders. Asks for permission when one is on; returns why it could not
    /// schedule, if it could not.
    func schedule(morning: Int?, evening: Int?) async -> String? {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.identifiers)
        let times = [(Self.identifiers[0], morning), (Self.identifiers[1], evening)].compactMap { id, minutes in minutes.map { (id, $0) } }
        guard !times.isEmpty else { return nil }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            return "Allow notifications for Surabar in System Settings › Notifications to get reminders."
        }
        for (id, minutes) in times {
            let content = UNMutableNotificationContent()
            content.title = "Manzil"
            content.body = "A reminder to read the Manzil."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: minutes / 60, minute: minutes % 60), repeats: true)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                return "Couldn't schedule the reminder: \(error.localizedDescription)"
            }
        }
        return nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isManzil = Self.identifiers.contains(response.notification.request.identifier)
        completionHandler()
        guard isManzil else { return }
        Task { @MainActor in self.onOpen?() }
    }

    /// Shows the reminder even while Surabar is in use.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
