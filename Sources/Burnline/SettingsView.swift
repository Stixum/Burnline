import SwiftUI
import ServiceManagement
import BurnlineCore

struct SettingsView: View {
    @Bindable var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLoginFailed = false
    @State private var confirmingPoller = false

    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                "Thursday", "Friday", "Saturday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                Text("Reset").eyebrow()

                if store.snapshot.isScheduleAutomatic {
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(Theme.success).frame(width: 5, height: 5).padding(.top, 5)
                        Text("Read automatically from Claude Code — resets \(automaticResetDescription). The fields below are unused while this is live.")
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
                        Text("Min \(String(format: "%02d", store.settings.resetSchedule.minute))")
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .disabled(store.snapshot.isScheduleAutomatic)

                if !store.snapshot.isScheduleAutomatic {
                    Text("Resets \(weekdayNames[store.settings.resetSchedule.weekday - 1]) at \(String(format: "%02d:%02d", store.settings.resetSchedule.hour, store.settings.resetSchedule.minute)), \(store.settings.resetSchedule.timeZone.identifier). Fallback only — used until Claude Code reports the real reset time.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.hairline)

                Text("Compare against").eyebrow()

                Picker("", selection: $store.settings.targetMode) {
                    ForEach(TargetMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(targetModeExplanation)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("\"Today\" ends").font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                    Picker("", selection: $store.settings.dayBoundary) {
                        ForEach(DayBoundary.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.top, 2)

                Text(dayBoundaryExplanation)
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.hairline)

                Text("Menu bar").eyebrow()

                // Five options won't fit across 380pt as a segmented control.
                Picker("", selection: $store.settings.menuBarMode) {
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

                Divider().overlay(Theme.hairline)

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

                Divider().overlay(Theme.hairline)

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
                     + "you are working in a terminal session.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                claudeExecutableStatus

                if store.settings.refreshesUsageAutomatically {
                    HStack {
                        Text("Check at least every").font(.system(size: 11.5))
                        Picker("", selection: Binding(
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
                    // observed rate looks like the setting being ignored.
                    Text("A ceiling. Burnline checks more often than this as you approach a "
                         + "limit — down to every 10 minutes — and never less often.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.hairline)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Weights").eyebrow().padding(.top, 6)
                        Text("Relative only — calibration divides out the absolute scale.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)

                        weightRow("Input", $store.settings.weights.input)
                        weightRow("Cache write", $store.settings.weights.cacheWrite)
                        weightRow("Cache read", $store.settings.weights.cacheRead)
                        weightRow("Output", $store.settings.weights.output)

                        Text("Calibration anchors").eyebrow().padding(.top, 10)
                        if store.settings.calibrationAnchors.isEmpty {
                            Text("None yet — use Calibrate in the popover.")
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
                    .padding(.top, 4)
                }
        }
        .padding(18)
        // Width fixed, height follows the content — so expanding Advanced grows
        // the window instead of leaving dead space below when it is collapsed.
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            store.refreshClaudeExecutable()
            store.refreshWiringState()
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
            Text("Burnline will start a brief Claude Code session running /usage when "
                 + "the figure goes stale, at most once every "
                 + "\(store.settings.usageRefreshInterval.title.lowercased()).\n\n"
                 + "This uses no message quota, but it does start real Claude Code "
                 + "sessions, which contact Anthropic.\n\n"
                 + "macOS will ask for access to folders such as Documents, Downloads "
                 + "and any cloud drives. That is Claude Code scanning your home "
                 + "directory at startup, not Burnline reading your files. "
                 + "You can decline every one of them and this still works.\n\n"
                 + "You can turn this off at any time.")
        }
    }

    /// Spells out the choice with the live numbers, so it is concrete rather
    /// than abstract. Both targets stay on the bar either way.
    private var targetModeExplanation: String {
        let now = DisplayValue.whole(store.snapshot.targetPercent)
        let today = DisplayValue.whole(store.snapshot.endOfDayPercent)
        switch store.settings.targetMode {
        case .realTime:
            return "\(TargetMode.realTime.explanation) Right now that's \(now)%. The bar still shades today's allowance out to \(today)%."
        case .endOfDay:
            return "\(TargetMode.endOfDay.explanation) Right now that's \(today)%, versus \(now)% this second. More forgiving during the day."
        }
    }

    /// Names the actual clock time each option resolves to, since the two only
    /// differ by however far the reset sits from midnight.
    private var dayBoundaryExplanation: String {
        let schedule = store.settings.resetSchedule
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = schedule.timeZone
        let resetClock = formatter.string(from: store.snapshot.window.end)

        let base = store.settings.dayBoundary.explanation
        let today = DisplayValue.whole(store.snapshot.endOfDayPercent)
        switch store.settings.dayBoundary {
        case .windowDay:
            return "\(base) Yours end at \(resetClock) — currently \(today)%."
        case .calendarDay:
            return "\(base) Yours end at 12:00 AM, \(resetClock.hasPrefix("12:00") ? "the same as the reset" : "not at the \(resetClock) reset") — currently \(today)%."
        }
    }

    private var menuBarPreview: String {
        MenuBarFormatter.text(for: store.snapshot,
                              target: store.settings.targetMode,
                              display: store.settings.menuBarMode)
    }

    private var automaticResetDescription: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        return formatter.string(from: store.snapshot.window.end)
    }

    private func weightRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
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
                        Text("Claude Code not found — automatic refresh will do nothing")
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
    @ViewBuilder private var statuslineStateLabel: some View {
        switch store.wiringState {
        case .configured:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5)).foregroundStyle(Theme.success)
        case .noSettingsFile, .notConfigured:
            Label("Not set up", systemImage: "circle.dashed")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
        case .stalePath:
            Label("Configured for a different copy", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
        case .conflict:
            Label("Another status line configured", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
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
