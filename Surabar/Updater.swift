import AppKit
import Observation
import Sparkle
import UserNotifications

/// In-app updates through Sparkle, from the appcast published with each GitHub release.
///
/// Surabar lives in the menu bar, so a scheduled check that finds an update while the user is in another
/// app doesn't put Sparkle's window in front of them (Sparkle's "gentle reminders"): Settings › General
/// shows the new version, and a notification is posted if Surabar may send them. Updates found right
/// after launch, and checks the user starts, show Sparkle's window as usual.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    nonisolated static let notificationIdentifier = "update.available"

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    /// The version a scheduled check found, until the user looks at it.
    private(set) var availableVersion: String?
    private(set) var automaticallyChecks = false

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Starts scheduled checks; called once at launch.
    func start() {
        controller.startUpdater()
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func setAutomaticallyChecks(_ checks: Bool) {
        controller.updater.automaticallyChecksForUpdates = checks
        automaticallyChecks = checks
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            availableVersion = version
            await Self.notify(version: version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            availableVersion = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
        }
    }

    /// Posts only if the user already allowed notifications (for the Manzil reminders); Surabar doesn't
    /// ask just for this.
    private static func notify(version: String) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Surabar \(version) is available"
        content.body = "Click to see what's new and install it."
        try? await center.add(UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil))
    }
}
