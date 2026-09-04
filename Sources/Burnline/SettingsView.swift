import SwiftUI
import ServiceManagement
import UserNotifications
import BurnlineCore

struct SettingsView: View {
    @Bindable var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLoginFailed = false
    @State private var confirmingPoller = false
    /// Seeded from Sparkle in `onAppear`, because `Updater.shared` starts the
    /// updater on first access and a property initialiser would do that while
    /// the view struct is being built.
    @State private var automaticUpdates = false

    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                "Thursday", "Friday", "Saturday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Two columns. The single column ran to 1,222pt — taller than the
            // 1,055pt of usable height on a 1080p display, so Updates and
            // Advanced sat permanently below the fold with no scroll view to
            // reach them. The split is by subject: what the number means on the
            // left, how Burnline runs on the right. Advanced spans both, so
            // expanding it grows the window downward rather than unbalancing
            // one column.
            HStack(alignment: .top, spacing: 20) {
                // Left reads as the pipeline: where the figure comes from, what
                // window it counts against, what it is compared to, how it is
                // shown. Status line leads because the green note in Reset —
                // "read automatically from Claude Code" — is true only when the
                // row above it says Configured.
                VStack(alignment: .leading, spacing: 14) {
                    statusLineSection
                    Divider().overlay(Theme.hairline)
                    resetSection
                    Divider().overlay(Theme.hairline)
                    compareSection
                    Divider().overlay(Theme.hairline)
                    menuBarSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().overlay(Theme.hairline)

                VStack(alignment: .leading, spacing: 14) {
                    generalSection
                    Divider().overlay(Theme.hairline)
                    notificationsSection
                    Divider().overlay(Theme.hairline)
                    updatesSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.hairline)

            advancedSection
        }
        .padding(18)
        // Without this every system control in the window — checkboxes, the
        // segmented pickers — renders system blue when the window is key. The
        // History window learned the same lesson. One of the six
        // screenshot-only defects (CLAUDE.md) was exactly this.
        .tint(Theme.accent)
        // Width fixed, height follows the content — so expanding Advanced grows
        // the window instead of leaving dead space below when it is collapsed.
        // 776 is two ~360pt columns plus the gutter and padding, and matches the
        // History window so the app's two full windows are the same size.
        .frame(width: 776, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            store.refreshClaudeExecutable()
            store.refreshWiringState()
            store.refreshNotificationAuthorization()
            automaticUpdates = Updater.shared.automaticallyChecks
        }
        .alert("Let Burnline refresh your usage?", isPresented: $confirmingPoller) {
            Button("Cancel", role: .cancel) { }
            Button("Turn on") {
                store.settings.refreshesUsageAutomatically = true
                store.refreshClaudeExecutable()
            }
        } message: {
            // Says the part the inline description doesn't: that this starts
            // real sessions, and that those sessions reach Anthropic. "Uses no
            // message quota" is measured — /usage produces no assistant turn —
            // but it is not the same as "does nothing".
            Text("Burnline will run /usage in a brief Claude Code session when the figure "
                 + "goes stale: no more than every "
                 + "\(store.settings.usageRefreshInterval.prose) normally, up to every "
                 + "10 minutes near a limit.\n\n"
                 + "This uses no message quota, but it starts real Claude Code sessions, "
                 + "which contact Anthropic.\n\n"
                 + "The first time, macOS will ask for folder access on Claude Code's "
                 + "behalf (Documents, Downloads, cloud drives). Decline them all; "
                 + "Burnline doesn't need them.\n\n"
                 + "You can turn this off at any time.")
        }
    }

    @ViewBuilder private var resetSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset").eyebrow()

            if store.snapshot.isScheduleAutomatic {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Theme.success).frame(width: 5, height: 5).padding(.top, 5)
                    Text("Read automatically from Claude Code, resetting \(automaticResetDescription). The fields below are unused while this is live.")
                        .font(.system(size: 11)).foregroundStyle(Theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Day", selection: $store.settings.resetSchedule.weekday) {
                ForEach(1...7, id: \.self) { Text(weekdayNames[$0 - 1]).tag($0) }
            }
            .frame(maxWidth: 220)
            .disabled(store.snapshot.isScheduleAutomatic)

            HStack(spacing: 10) {
                Stepper(value: $store.settings.resetSchedule.hour, in: 0...23) {
                    Text("Hour \(String(format: "%02d", store.settings.resetSchedule.hour))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                Stepper(value: $store.settings.resetSchedule.minute, in: 0...59, step: 5) {
                    Text("Minute \(String(format: "%02d", store.settings.resetSchedule.minute))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .disabled(store.snapshot.isScheduleAutomatic)

            if !store.snapshot.isScheduleAutomatic {
                // Through `ResetSchedule.description()`, like every other
                // reset string in the app: this one printed a 24-hour clock
                // and a raw tzdata identifier while the popover row beside
                // it printed `Tue 9:00 PM`.
                Text("Resets \(store.settings.resetSchedule.description()). Used only until Claude Code reports the real reset.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var compareSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare against").eyebrow()

            Picker("Compare against", selection: $store.settings.targetMode) {
                ForEach(TargetMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(targetModeExplanation)
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Today ends").font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Picker("Today ends", selection: $store.settings.dayBoundary) {
                    ForEach(DayBoundary.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.top, 2)

            Text(dayBoundaryExplanation)
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Menu bar").eyebrow()

            // Five options won't fit across a ~360pt column as a segmented
            // control.
            Picker("Menu bar shows", selection: $store.settings.menuBarMode) {
                ForEach(MenuBarMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)

            Text(store.settings.menuBarMode.explanation)
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            // The live value, so the choice is concrete rather than
            // described. Formatting comes from the same tested unit the
            // menu bar itself uses.
            HStack(spacing: 6) {
                Text("Right now").font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Text(menuBarPreview)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusRow))
            }
        }
    }

    @ViewBuilder private var statusLineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The setup window used to be reachable exactly once, on first
            // launch, and was marked seen whatever the user did with it.
            // Anyone who dismissed it kept a permanently stale figure with
            // no in-app way back — while the README told them to "open the
            // setup window", an affordance that no longer existed.
            Text("Status line").eyebrow()
            HStack(alignment: .firstTextBaseline) {
                statuslineStateLabel
                Spacer()
                Button("Open setup") { OnboardingWindow.open(using: openWindow) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // These two carried no heading in the single column, where the
            // divider above was enough. In a column they need one, or the
            // right-hand eyebrow rhythm breaks against the left's.
            Text("General").eyebrow()

            Toggle("Launch at login", isOn: Binding(
                get: { store.settings.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))

            if launchAtLoginFailed {
                Text("Couldn't register at login. Move Burnline to /Applications and try again.")
                    .font(.system(size: 11)).foregroundStyle(Theme.danger)
            }

            // Enabling asks first. Off-by-default protects someone who
            // never touches this; it says nothing to someone who flips it
            // because the label sounded useful. Spawning Claude Code
            // sessions on a machine is a different category of act from
            // reading files, and the person doing it should know before it
            // happens rather than find out from a process list.
            Toggle("Refresh usage automatically", isOn: Binding(
                get: { store.settings.refreshesUsageAutomatically },
                set: { wanted in
                    if wanted && !store.settings.refreshesUsageAutomatically {
                        confirmingPoller = true      // not enabled until confirmed
                    } else {
                        store.settings.refreshesUsageAutomatically = wanted
                    }
                }
            ))
            // Says plainly what it does, because it spawns processes. Off by
            // default for that reason.
            Text("Runs /usage in a brief Claude Code session when the figure goes "
                 + "stale. Uses no message quota. Without it, usage updates only while "
                 + "you work in a terminal session.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            claudeExecutableStatus

            if store.settings.refreshesUsageAutomatically {
                HStack {
                    Text("Refresh at least every").font(.system(size: 11.5))
                    Picker("Refresh interval", selection: Binding(
                        get: { store.settings.usageRefreshInterval },
                        set: { store.settings.usageRefreshInterval = $0 }
                    )) {
                        ForEach(RefreshInterval.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 92)
                }
                // A ceiling, not a fixed cadence — worth saying, or the
                // observed rate looks like the setting being ignored. Said
                // in what it does rather than in the word "ceiling", which
                // is the implementer's name for it.
                Text("Burnline checks more often as you approach a limit, down to every "
                     + "10 minutes, and never less often than this.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notifications").eyebrow()

            // Routes through the store, not a direct binding: enabling
            // requests notification permission the first time.
            Toggle("Send notifications", isOn: Binding(
                get: { store.settings.notifications.enabled },
                set: { store.setNotificationsEnabled($0) }
            ))

            Group {
                Stepper(value: $store.settings.notifications.behindPacePoints,
                        in: NotificationSettings.behindPaceRange) {
                    Text("Behind pace by \(DisplayValue.points(store.settings.notifications.behindPacePoints))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }

                Stepper(value: $store.settings.notifications.weeklyPercent,
                        in: NotificationSettings.percentRange) {
                    Text("Weekly usage reaches \(DisplayValue.whole(store.settings.notifications.weeklyPercent))%")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }

                Stepper(value: $store.settings.notifications.fiveHourPercent,
                        in: NotificationSettings.percentRange) {
                    Text("5-hour usage reaches \(DisplayValue.whole(store.settings.notifications.fiveHourPercent))%")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .disabled(!store.settings.notifications.enabled)
            // The system's disabled rendering is invisible on these dark
            // hardcoded surfaces — verified by screenshot: the chevrons
            // barely change. Dim explicitly so off looks off.
            .opacity(store.settings.notifications.enabled ? 1 : 0.45)

            notificationPermissionStatus
        }
    }

    @ViewBuilder private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Updates").eyebrow()

            // Sparkle's own persisted setting, not a BurnlineSettings field
            // — Sparkle reads it back on its own at launch, so duplicating
            // it here would give two answers to one question. Mirrored into
            // @State only so the checkbox redraws; Sparkle stays the record.
            Toggle("Automatically check for updates", isOn: Binding(
                get: { automaticUpdates },
                set: {
                    automaticUpdates = $0
                    Updater.shared.automaticallyChecks = $0
                }
            ))

            HStack(alignment: .firstTextBaseline) {
                Text("Version \(versionDescription)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Check for updates…") { Updater.shared.checkForUpdates() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("Advanced") {
                // Two columns again, for the same reason as the panel above and
                // for one more: `weightRow` is label · Spacer · field, so across
                // the full 740pt the fields drift most of the window away from
                // the names they belong to.
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Weights").eyebrow().padding(.top, 6)
                        Text("Only the ratios matter; calibration sets the scale.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)

                        weightRow("Input", $store.settings.weights.input)
                        weightRow("Cache write", $store.settings.weights.cacheWrite)
                        weightRow("Cache read", $store.settings.weights.cacheRead)
                        weightRow("Output", $store.settings.weights.output)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().overlay(Theme.hairline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Calibration anchors").eyebrow().padding(.top, 6)
                        if store.settings.calibrationAnchors.isEmpty {
                            Text("None yet. Use Calibrate in the popover.")
                                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        ForEach(store.settings.calibrationAnchors) { anchor in
                            HStack {
                                Text("\(DisplayValue.whole(anchor.observedPercent))% · \(anchor.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button("Remove") { store.removeAnchor(anchor) }
                                    .buttonStyle(.plain).font(.system(size: 11))
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            }
        }
    }


    /// Spells out the choice with the live numbers, so it is concrete rather
    /// than abstract. Both targets stay on the bar either way.
    private var targetModeExplanation: String {
        let now = DisplayValue.whole(store.snapshot.targetPercent)
        let today = DisplayValue.whole(store.snapshot.endOfDayPercent)
        switch store.settings.targetMode {
        case .realTime:
            return "\(TargetMode.realTime.explanation) Currently \(now)%; the bar still shades today's allowance to \(today)%."
        case .endOfDay:
            return "\(TargetMode.endOfDay.explanation) Currently \(today)%, against \(now)% this instant. Gentler during the day."
        }
    }

    /// Names the actual clock time each option resolves to, since the two only
    /// differ by however far the reset sits from midnight.
    private var dayBoundaryExplanation: String {
        let resetClock = store.settings.resetSchedule
            .description(of: store.snapshot.window.end, .clock)
        let base = store.settings.dayBoundary.explanation
        let today = DisplayValue.whole(store.snapshot.endOfDayPercent)
        switch store.settings.dayBoundary {
        case .windowDay:
            return "\(base) Your days end at \(resetClock); currently \(today)%."
        case .calendarDay:
            // The contrast only when there is one to draw. A reset at midnight
            // makes the two options identical, and "not at the 12:00 AM reset"
            // then invents a difference the user does not have.
            let contrast = resetClock == "12:00 AM" ? "" : ", not at the \(resetClock) reset"
            return "\(base)\(contrast). Currently \(today)%."
        }
    }

    /// Marketing version with the build number in parentheses — the pair that
    /// identifies a build, since the two move independently.
    private var versionDescription: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "unknown"
        }
    }

    private var menuBarPreview: String {
        MenuBarFormatter.text(for: store.snapshot,
                              target: store.settings.targetMode,
                              display: store.settings.menuBarMode)
    }

    private var automaticResetDescription: String {
        store.settings.resetSchedule.description(of: store.snapshot.window.end)
    }

    private func weightRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
        }
    }

    /// Exceptions only: shown when notifications are on but macOS has them
    /// blocked, so the toggle would otherwise promise something that never
    /// arrives. Word and icon, never colour alone.
    @ViewBuilder private var notificationPermissionStatus: some View {
        if store.settings.notifications.enabled,
           store.notificationAuthorization == .denied {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.warning)
                    Text("Notifications are blocked in System Settings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.warning)
                }
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Says whether the poller can actually run.
    ///
    /// Without this, a user enables the setting, nothing happens, and the only
    /// diagnostic is an environment variable — the same silent-failure class
    /// that the capture helper was rewritten to remove. Word and icon, never
    /// colour alone.
    @ViewBuilder private var claudeExecutableStatus: some View {
        if store.settings.refreshesUsageAutomatically {
            if let path = store.claudeExecutable {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.success)
                    Text("Using \(path)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(Theme.warning)
                        Text("Claude Code not found. Automatic refresh will do nothing.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.warning)
                    }
                    Text("Looked on your PATH and in:\n"
                         + ClaudeExecutable.searchedLocationsDescription())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Word and icon, never colour alone.
    ///
    /// The words are `StatuslineWiring.State.title`, shared with Onboarding —
    /// two views of one state should not describe it two ways. Only the icon and
    /// the tint are decided here, because those are presentation.
    @ViewBuilder private var statuslineStateLabel: some View {
        let state = store.wiringState
        Label(state.title, systemImage: statuslineStateIcon)
            .font(.system(size: 11.5))
            .foregroundStyle(statuslineStateTint)
    }

    private var statuslineStateIcon: String {
        switch store.wiringState {
        case .configured: "checkmark.circle.fill"
        case .noSettingsFile, .notConfigured: "circle.dashed"
        case .stalePath: "arrow.triangle.2.circlepath"
        case .conflict, .unreadable: "exclamationmark.triangle.fill"
        }
    }

    private var statuslineStateTint: Color {
        switch store.wiringState {
        case .configured: Theme.success
        case .noSettingsFile, .notConfigured: Theme.textMuted
        case .stalePath, .conflict, .unreadable: Theme.warning
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            store.settings.launchAtLogin = enabled
            launchAtLoginFailed = false
        } catch {
            // Registration fails for unsigned or non-/Applications builds.
            launchAtLoginFailed = true
        }
    }
}
