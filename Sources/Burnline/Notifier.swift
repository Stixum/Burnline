import Foundation
import UserNotifications
import BurnlineCore

/// The only unit that touches UNUserNotificationCenter. All *decisions* —
/// what fires, when, with what text — live in `NotificationDecision`, which is
/// pure and tested; this file only performs the I/O it is handed.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter.current() traps in a process without a bundle
    /// identity — swift run, the probe, the statusline helper. Under swift test
    /// Bundle.main is the xctest host (which has one), so this is no test guard.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Sets the delegate so banners present while the app is "foreground" —
    /// an LSUIElement app effectively always is, and without the delegate the
    /// system may suppress the banner entirely.
    func activate() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard isAvailable else { return nil }
        return await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Keyed on the system's own `.notDetermined`, not a persisted flag, so a
    /// user who resets permissions gets asked again on the next enable.
    func requestAuthorizationIfNeeded() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined
        else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ emissions: [NotificationDecision.Emission]) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        for emission in emissions {
            let content = UNMutableNotificationContent()
            content.title = emission.title
            content.body = emission.body
            content.sound = .default  // foreground playback is governed by willPresent below
            // Stable per-signal identifiers: a duplicate could only replace,
            // never stack. The marks make duplicates unreachable anyway.
            center.add(UNNotificationRequest(identifier: emission.identifier,
                                             content: content, trigger: nil))
        }
    }

    /// Banners alone vanish after seconds and the sound never plays unless
    /// returned here — an LSUIElement app is always "foreground", so these
    /// options, not the content, govern presentation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}
