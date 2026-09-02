import SwiftUI
import BurnlineCore

struct PopoverView: View {
    @Bindable var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var calibrationInput = ""
    @State private var isCalibrating = false

    private var snapshot: Snapshot { store.snapshot }
    private var mode: TargetMode { store.settings.targetMode }

    /// Names the target being compared against, so the number is never ambiguous.
    private var legendTarget: String {
        switch mode {
        case .realTime: return "now \(DisplayValue.whole(snapshot.targetPercent))% · today \(DisplayValue.whole(snapshot.endOfDayPercent))%"
        case .endOfDay: return "today \(DisplayValue.whole(snapshot.endOfDayPercent))% · now \(DisplayValue.whole(snapshot.targetPercent))%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Weekly window").eyebrow()

            hero

            // Exceptions-only. Names the cause of a frozen figure instead of
            // leaving the user to infer it from an age string — which is what
            // made "stuck at 69%" read as a broken app.
            if let explanation = CaptureAge.scarcityExplanation(snapshot.liveAge) {
                Text(explanation)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }

            UsageBar(estimatedPercent: snapshot.estimatedPercent,
                     targetPercent: snapshot.targetPercent,
                     endOfDayPercent: snapshot.endOfDayPercent,
                     mode: mode)
                .padding(.top, 12)

            legend
            Divider().overlay(Theme.hairline).padding(.vertical, 9)
            rows
            Divider().overlay(Theme.hairline).padding(.vertical, 9)
            footer
        }
        .padding(14)
        .frame(width: Theme.popoverWidth)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear {
            store.refreshIfStale()
            store.refreshClaudeExecutable()
            // wiringState starts at .noSettingsFile, so without this a correctly
            // configured user would see a spurious "Set up" until something else
            // refreshed it. One small file read per popover open, not on a timer.
            store.refreshWiringState()
        }
    }

    @ViewBuilder private var hero: some View {
        if snapshot.isPaceOnly {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(DisplayValue.whole(snapshot.activeTarget(mode)))%")
                    .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text("of the window elapsed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 8)
            Text(paceOnlyExplanation)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let delta = snapshot.delta(mode) ?? 0
            let under = snapshot.isUnder(mode) ?? true
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(DisplayValue.whole(abs(delta)))")
                    .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                // The noun agrees with the figure beside it: the hero renders
                // the number at 34pt and the words at 12pt, so it takes the
                // unit alone rather than the whole `DisplayValue.points`
                // string. "ahead of / behind pace" is the app's one vocabulary
                // for this comparison — the menu bar's spoken label, the
                // notification body and the Settings stepper all use it.
                Text("\(DisplayValue.pointsUnit(delta)) \(under ? "ahead of pace" : "behind pace")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 8)
            // Word + arrow + color. Never color alone.
            Text(under ? "↓ Running cool" : "↑ Running hot")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(under ? Theme.success : Theme.danger)
        }
    }

    /// ⚠️ Branches on the wiring state, because "usage appears after its next
    /// response" is a promise only a configured status line can keep. Without a
    /// status line no response ever produces a figure, and the panel sat there
    /// waiting for something that was never coming.
    private var paceOnlyExplanation: String {
        if snapshot.isScanning { return "Scanning transcripts…" }
        if store.wiringState != .configured {
            return "No usage figure yet. Set up the status line, or run /usage in Claude Code."
        }
        return "Waiting for Claude Code. Usage appears after its next response."
    }

    private var legend: some View {
        HStack {
            Text(snapshot.estimatedPercent.map { "\(DisplayValue.whole($0))% used" } ?? "usage unknown")
            Spacer()
            Text(legendTarget)
        }
        .font(.system(size: 10.5)).monospacedDigit()
        .foregroundStyle(Theme.textMuted)
        // The bar's caption. At 7 it sat almost on the bar's edge while the gap
        // below it was larger — the group read upside down.
        .padding(.top, 10)
    }

    private var rows: some View {
        VStack(spacing: 3) {
            row("Day", String(format: "%.1f of 7", snapshot.window.dayIndex))
            row("Resets", resetDescription)
            row("Time left", remainingDescription)
            // The one row that should change what you do next, so it is allowed
            // to shout when the week is heading past the limit.
            // ⚠️ The label is `snapshot.projectionLabel`, not a literal: this
            // row's denominator is the allowance epoch while the pace figure
            // above it is the window's, and once a re-grant opens those are
            // different spans. The rule lives on `Snapshot` because a view
            // branch is a rule no test can see.
            row(snapshot.projectionLabel, Projection.description(snapshot.projectedPercent),
                tint: Projection.isOverLimit(snapshot.projectedPercent)
                    ? Theme.danger : Theme.textSecondary)
            // Only when a live capture carries one — it's absent on plans that
            // don't report a 5-hour limit, and dies with its own window.
            if let fiveHour = snapshot.fiveHour {
                row("5-hour", fiveHour.rowValue)
            }
            // Per-model weekly limit. Only the utilization source reports this —
            // the statusline payload omits it entirely, which is why this was
            // recorded for months as impossible to obtain.
            if let scoped = snapshot.scopedWeekly {
                row(scoped.rowLabel, scoped.rowValue)
            }
            // Exceptions-only, and above the rejection row on purpose: a
            // re-grant is the CAUSE of the disagreement the rejection row
            // reports, so it reads cause then consequence.
            if let regrant = snapshot.regrant {
                regrantRow(regrant)
            }
            // Exceptions-only, per the portfolio status-chip standard: absent
            // unless the file actually disagrees with what's on screen.
            if let rejected = snapshot.rejectedReading {
                rejectionRow(rejected)
            }
        }
    }

    /// Explains a disagreement with the user's own terminal status line.
    ///
    /// Another Claude Code session republishing a lower reading is the normal
    /// case, not an error — every open session rewrites the same file on its own
    /// timer, carrying whatever its last API response said. Without this row the
    /// app just quietly shows a different number than the terminal does, which
    /// is what made the 2026-08-11 investigation start from "the app is stuck".
    ///
    /// ⚠️ The reason lives on `RejectedReading.explanation`, not here: since the
    /// allowance can be re-issued inside a window, the stale reading is
    /// sometimes the HIGHER one, and the wording has to follow the direction.
    /// Branching in a view body would put that rule outside the tests.
    ///
    /// Symbol + word + colour. Never colour alone.
    private func rejectionRow(_ rejected: RateLimitHighWater.RejectedReading) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            // ⚠️ `rejected.rowLabel`, not a literal. `Stale session` was
            // unconditional across three branches, two of which have not
            // checked a date — see `RejectedReading.rowLabel`.
            Text(rejected.rowLabel)
            Spacer()
            Text(rejected.rowValue).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.warning)
        .help(rejected.explanation)
    }

    /// The one thing that can make the figure fall without the window
    /// resetting: Anthropic re-issued the weekly allowance mid-window.
    ///
    /// Without this row the drop has no cause on screen, which is the shape of
    /// the 2026-09-01 incident in reverse — the app was believed broken because
    /// its number disagreed with the terminal and nothing said why.
    ///
    /// Accent violet, not amber: this is notable, not wrong, and the amber
    /// rejection row can sit directly beneath it. Symbol + word + colour, never
    /// colour alone.
    ///
    /// The value string is `Snapshot.Regrant.rowValue`; this target has no
    /// tests, so nothing is assembled here.
    private func regrantRow(_ regrant: Snapshot.Regrant) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 9))
            Text("Limits re-granted")
            Spacer()
            Text(regrant.rowValue).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.accent)
        .help("Anthropic re-granted the weekly limit inside this window, "
              + "without moving the reset. The rate above is measured from "
              + "there; the pace target still runs from the window's own start.")
    }

    private func row(_ label: String, _ value: String,
                     tint: Color = Theme.textSecondary) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value).foregroundStyle(tint).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder private var footer: some View {
        if isCalibrating {
            HStack(spacing: 6) {
                Text("/usage says").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                TextField("40", text: $calibrationInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                    .onSubmit(commitCalibration)
                Text("%").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Save", action: commitCalibration).font(.system(size: 11))
                Button("Cancel") { isCalibrating = false; calibrationInput = "" }
                    .font(.system(size: 11))
            }
        } else {
            HStack(spacing: 12) {
                sourceLabel
                Spacer()
                // Only when the status line is not wired. This is where a user
                // notices the figure has stopped moving, so it is where the
                // remedy belongs — but it must not add a row in the normal case,
                // which is already a dense 300pt panel.
                if store.wiringState != .configured {
                    Button("Set up") { OnboardingWindow.open(using: openWindow) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                checkNowButton
                historyButton
                Button("Settings") { SettingsWindow.open(using: openWindow) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .keyboardShortcut(",")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .keyboardShortcut("q")
            }
        }
    }

    /// Says plainly where the number came from — exact, estimated, or absent.
    ///
    /// A capture that has aged past the threshold is no longer a reading, it is
    /// an hour or more of extrapolation from local tokens alone. Word and colour
    /// both change; never colour alone.
    @ViewBuilder private var sourceLabel: some View {
        switch snapshot.source {
        case .live:
            let stale = CaptureAge.isStale(snapshot.liveAge)
            HStack(spacing: 4) {
                Circle().fill(stale ? Theme.warning : Theme.success).frame(width: 5, height: 5)
                Text("\(stale ? "Extrapolated" : "Live") · \(CaptureAge.description(snapshot.liveAge))")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(stale ? Theme.warning : Theme.success)
            // The stale branch does not repeat the amber row directly above
            // it, which already names the cause and the elapsed time.
            .help(stale
                  ? "Carried forward from local token counts, which see only this Mac."
                  : "Exact figure from Claude Code, carried forward by local token counts. They see only this Mac.")
        case .calibrated, .paceOnly:
            Button(calibrationLabel) { isCalibrating = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(snapshot.isCalibrationStale ? Theme.danger : Theme.accent)
        }
    }

    /// Manual refresh, for people who want a current number without leaving
    /// anything running in the background.
    ///
    /// Hidden rather than disabled when Claude Code is missing: a permanently
    /// dead control in a 300pt panel is worse than no control, and Settings
    /// already explains why it could not be found.
    @ViewBuilder private var checkNowButton: some View {
        if store.claudeExecutable != nil {
            // A glyph, not a label. "Check now" as text cost ~70pt in a 300pt
            // footer that already carries the source label, Settings and Quit,
            // and it pushed both itself and "Live · 5m ago" into truncation.
            // A refresh arrow beside a timestamp is the conventional form and
            // costs ~16pt.
            Button {
                Task { await store.pollNow() }
            } label: {
                if store.isPolling {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isPolling)
            .foregroundStyle(Theme.accent)
            // A glyph button has no text to derive an accessible name from, so
            // the name is stated. The History button beside it already does.
            .accessibilityLabel("Refresh now")
            .help("Refresh now: runs /usage in a brief Claude Code session. "
                  + "No message quota; about half a minute.")
        }
    }

    /// The way into the History window.
    ///
    /// A glyph rather than the word, for the reason `checkNowButton` already
    /// records: this footer is 272pt wide and already carries the source label,
    /// a refresh control, Settings and Quit. "History" as text costs ~40pt and
    /// pushes "Extrapolated · 2h ago" into truncation, which is the one string
    /// here that must stay readable. The tooltip and the accessibility label
    /// carry the word.
    private var historyButton: some View {
        Button { HistoryWindow.open(using: openWindow) } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textMuted)
        .accessibilityLabel("Usage history")
        .help("Usage history: past weeks, burn curves, and where it went.")
    }

    private var calibrationLabel: String {
        guard let age = snapshot.calibrationAge else { return "Calibrate" }
        let days = DisplayValue.seconds(age) / 86_400
        return days < 1 ? "Calibrated today" : "Calibrated \(days)d ago"
    }

    private var resetDescription: String {
        store.settings.resetSchedule.description(of: snapshot.window.end, .abbreviated)
    }

    private var remainingDescription: String {
        let total = DisplayValue.seconds(snapshot.window.timeRemaining)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }

    private func commitCalibration() {
        if let value = Double(calibrationInput.trimmingCharacters(in: .whitespaces)),
           value > 0, value <= 200 {
            store.calibrate(observedPercent: value)
        }
        calibrationInput = ""
        isCalibrating = false
    }
}
