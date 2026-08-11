import SwiftUI
import ServiceManagement
import BurnlineCore

struct SettingsView: View {
    @Bindable var store: UsageStore
    @State private var launchAtLoginFailed = false

    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                "Thursday", "Friday", "Saturday"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Reset").eyebrow()

                Picker("Day", selection: $store.settings.resetSchedule.weekday) {
                    ForEach(1...7, id: \.self) { Text(weekdayNames[$0 - 1]).tag($0) }
                }
                .frame(maxWidth: 220)

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

                Text("Resets \(weekdayNames[store.settings.resetSchedule.weekday - 1]) at \(String(format: "%02d:%02d", store.settings.resetSchedule.hour, store.settings.resetSchedule.minute)), \(store.settings.resetSchedule.timeZone.identifier). Read this off Claude Code's /usage.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Launch at login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))

                if launchAtLoginFailed {
                    Text("Couldn't register at login. Move Burnline to /Applications and try again.")
                        .font(.system(size: 11)).foregroundStyle(Theme.danger)
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
                                Text("\(Int(anchor.observedPercent))% · \(anchor.timestamp.formatted(date: .abbreviated, time: .shortened))")
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
        }
        .frame(width: 380, height: 420)
        .background(Theme.background)
    }

    private func weightRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
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
