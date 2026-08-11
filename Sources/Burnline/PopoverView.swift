import SwiftUI
import BurnlineCore

struct PopoverView: View {
    @Bindable var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var calibrationInput = ""
    @State private var isCalibrating = false

    private var snapshot: Snapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Weekly window").eyebrow()

            hero

            UsageBar(estimatedPercent: snapshot.estimatedPercent,
                     targetPercent: snapshot.targetPercent)
                .padding(.top, 10)

            legend
            Divider().overlay(Theme.hairline).padding(.vertical, 9)
            rows
            Divider().overlay(Theme.hairline).padding(.vertical, 9)
            footer
        }
        .padding(14)
        .frame(width: Theme.popoverWidth)
        .background(Theme.background)
        .onAppear { store.refreshIfStale() }
    }

    @ViewBuilder private var hero: some View {
        if snapshot.isPaceOnly {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(snapshot.targetPercent.rounded()))%")
                    .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text("of the window elapsed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 8)
            Text(snapshot.isScanning ? "Scanning transcripts…" : "Not calibrated — showing pace only")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
        } else {
            let delta = snapshot.deltaPercent ?? 0
            let under = snapshot.isUnderBudget ?? true
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

    private var legend: some View {
        HStack {
            Text(snapshot.estimatedPercent.map { "\(Int($0.rounded()))% used" } ?? "usage unknown")
            Spacer()
            Text("should be \(Int(snapshot.targetPercent.rounded()))%")
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
            row("At this rate", snapshot.projectedPercent.map { "\(Int($0.rounded()))% by reset" } ?? "—")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value).foregroundStyle(Theme.textSecondary).monospacedDigit()
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
                Button(calibrationLabel) { isCalibrating = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(snapshot.isCalibrationStale ? Theme.danger : Theme.accent)
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
