import Foundation

public struct BurnlineSettings: Equatable, Sendable, Codable {
    public var resetSchedule: ResetSchedule
    public var weights: Weights
    public var calibrationAnchors: [CalibrationAnchor]
    public var launchAtLogin: Bool
    public var targetMode: TargetMode
    public var dayBoundary: DayBoundary
    public var menuBarMode: MenuBarMode
    /// Spawn a short-lived Claude Code session running `/usage` when the anchor
    /// goes stale. **Off by default**: reading files is one kind of app, and
    /// spawning processes on someone's machine is another. Costs no model
    /// tokens — `/usage` produces no assistant turn — but it does create real
    /// sessions. See `PollDecision`.
    public var refreshesUsageAutomatically: Bool
    /// Ceiling on how often the anchor is refreshed. Pressure on any limit
    /// tightens below this; nothing loosens past it.
    public var usageRefreshInterval: RefreshInterval
    /// Whether the first-run onboarding has been offered. Set once at launch
    /// whatever the user then does with the window — declining to wire the
    /// statusline is an answer, and re-asking every launch would be nagging.
    public var hasSeenOnboarding: Bool
    public var notifications: NotificationSettings

    public init(resetSchedule: ResetSchedule, weights: Weights,
                calibrationAnchors: [CalibrationAnchor], launchAtLogin: Bool,
                targetMode: TargetMode = .realTime,
                dayBoundary: DayBoundary = .windowDay,
                menuBarMode: MenuBarMode = .usedOverTarget,
                refreshesUsageAutomatically: Bool = false,
                usageRefreshInterval: RefreshInterval = .fortyFive,
                hasSeenOnboarding: Bool = false,
                notifications: NotificationSettings = .default) {
        self.resetSchedule = resetSchedule
        self.weights = weights
        self.calibrationAnchors = calibrationAnchors
        self.launchAtLogin = launchAtLogin
        self.targetMode = targetMode
        self.dayBoundary = dayBoundary
        self.menuBarMode = menuBarMode
        self.refreshesUsageAutomatically = refreshesUsageAutomatically
        self.usageRefreshInterval = usageRefreshInterval
        self.hasSeenOnboarding = hasSeenOnboarding
        self.notifications = notifications
    }

    /// Thursday 09:00 local is a placeholder — replaced by the real reset as
    /// soon as a live capture lands, and settable by hand until then.
    public static let `default` = BurnlineSettings(
        resetSchedule: ResetSchedule(weekday: 5, hour: 9),
        weights: .default,
        calibrationAnchors: [],
        launchAtLogin: false,
        targetMode: .realTime,
        dayBoundary: .windowDay
    )

    // Hand-written so that settings files predating a field still decode.
    // A missing key must fall back rather than throw and reset everything.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetSchedule = try container.decode(ResetSchedule.self, forKey: .resetSchedule)
        weights = try container.decode(Weights.self, forKey: .weights)
        calibrationAnchors = try container.decode([CalibrationAnchor].self, forKey: .calibrationAnchors)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        targetMode = try container.decodeIfPresent(TargetMode.self, forKey: .targetMode) ?? .realTime
        dayBoundary = try container.decodeIfPresent(DayBoundary.self, forKey: .dayBoundary) ?? .windowDay
        menuBarMode = try container.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .usedOverTarget
        refreshesUsageAutomatically = try container.decodeIfPresent(
            Bool.self, forKey: .refreshesUsageAutomatically) ?? false
        usageRefreshInterval = try container.decodeIfPresent(
            RefreshInterval.self, forKey: .usageRefreshInterval) ?? .fortyFive
        // Absent in every settings file written before onboarding existed, so
        // existing installs are treated as not having seen it. They get the
        // window once, and only if there is actually something to fix.
        hasSeenOnboarding = try container.decodeIfPresent(
            Bool.self, forKey: .hasSeenOnboarding) ?? false
        notifications = try container.decodeIfPresent(
            NotificationSettings.self, forKey: .notifications) ?? .default
    }
}
