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
        case .realTime: return "now \(Int(snapshot.targetPercent.rounded()))%  ·  today \(Int(snapshot.endOfDayPercent.rounded()))%"
        case .endOfDay: return "today \(Int(snapshot.endOfDayPercent.rounded()))%  ·  now \(Int(snapshot.targetPercent.rounded()))%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Weekly window").eyebrow()

            hero

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
        .onAppear { store.refreshIfStale() }
    }

    @ViewBuilder private var hero: some View {
        if snapshot.isPaceOnly {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(snapshot.activeTarget(mode).rounded()))%")
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
                Text("\(Int(abs(delta).rounded()))")
                    .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(under ? "points under budget" : "points over budget")
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

    private var paceOnlyExplanation: String {
        if snapshot.isScanning { return "Scanning transcripts…" }
        return "Waiting for Claude Code — usage appears after its next response"
    }

    private var legend: some View {
        HStack {
            Text(snapshot.estimatedPercent.map { "\(Int($0.rounded()))% used" } ?? "usage unknown")
            Spacer()
            Text(legendTarget)
        }
        .font(.system(size: 10)).monospacedDigit()
        .foregroundStyle(Theme.textMuted)
        .padding(.top, 7)
    }

    private var rows: some View {
        VStack(spacing: 3) {
            row("Day", String(format: "%.1f of 7", snapshot.window.dayIndex))
            row("Resets", resetDescription)
            row("Time left", remainingDescription)
            // The one row that should change what you do next, so it is allowed
            // to shout when the week is heading past the limit.
            row("At this rate", Projection.description(snapshot.projectedPercent),
                tint: Projection.isOverLimit(snapshot.projectedPercent)
                    ? Theme.danger : Theme.textSecondary)
            // Only when a live capture carries one — it's absent on plans that
            // don't report a 5-hour limit, and dies with its own window.
            if let fiveHour = snapshot.fiveHour {
                row("5-hour", fiveHour.rowValue)
            }
        }
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
            .help(stale
                  ? "Claude Code hasn't reported in a while. This figure is carried forward from local token counts, which see only this Mac."
                  : "Exact figure from Claude Code, carried forward by local token counts.")
        case .calibrated, .paceOnly:
            Button(calibrationLabel) { isCalibrating = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(snapshot.isCalibrationStale ? Theme.danger : Theme.accent)
        }
    }

    private var calibrationLabel: String {
        guard let age = snapshot.calibrationAge else { return "Calibrate" }
        let days = Int(age / 86_400)
        return days < 1 ? "Calibrated today" : "Calibrated \(days)d ago"
    }

    private var resetDescription: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        formatter.timeZone = store.settings.resetSchedule.timeZone
        return formatter.string(from: snapshot.window.end)
    }

    private var remainingDescription: String {
        let total = Int(snapshot.window.timeRemaining)
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
