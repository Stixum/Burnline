import Foundation

/// What macOS says about Burnline's login item, and what the toggle should
/// therefore show.
///
/// The stored `launchAtLogin` flag records what the user *asked for*. The
/// system's answer (`SMAppService.mainApp.status`) can differ: the item can be
/// switched off in System Settings › Login Items without the app hearing about
/// it, or sit waiting for an approval the user never gave. The toggle used to
/// mirror the flag, so it read "on" over an item that was not running — the
/// kind of disagreement that is only ever noticed as "it stopped working".
///
/// Mirrors `SMAppService.Status` case for case, as its own type so the rule is
/// testable without ServiceManagement and so the view converts exactly once.
public enum LoginItemRegistration: Equatable, Sendable {
    /// Registered and approved. The only state the toggle shows as on.
    case enabled
    /// Not registered, or registered and then switched off in System Settings.
    case notRegistered
    /// Registered, but macOS is waiting for the user to approve it.
    case requiresApproval
    /// The app is not in a place `SMAppService` can register from — a debug
    /// binary, or a bundle outside /Applications.
    case notFound

    /// Whether the toggle shows on. Only `.enabled` does: everything else is a
    /// login item that will not launch anything.
    public var isOn: Bool { self == .enabled }

    /// Exceptions-only, and only for the state the user can act on. Word and
    /// icon in the view, never colour alone.
    public var note: String? {
        switch self {
        case .requiresApproval:
            return "Waiting for approval. Turn Burnline on under System Settings › General › Login Items."
        case .enabled, .notRegistered, .notFound:
            return nil
        }
    }
}
