import SwiftUI
import BurnlineCore

/// First-run window: says whether the statusline capture is wired up, offers to
/// wire it, and — when someone else's statusline is already there — refuses and
/// shows the snippet instead.
///
/// The refusal is the important case. Plenty of Claude Code users have a
/// statusline already; silently replacing one is the worst thing this app could
/// do to a stranger's setup, and it is unrecoverable without the backup.
struct OnboardingView: View {
    @Bindable var store: UsageStore
    @State private var copied = false
    @State private var showingManual = false

    var body: some View {
        // Not a ScrollView: it expands to fill whatever height the window has,
        // which left ~200pt of dead space below the content in every state
        // except the tallest. Content is short here, so the window sizes to it.
        VStack(alignment: .leading, spacing: 18) {
            header
            statusCard
            if let error = store.wiringError { errorRow(error) }
            manualSection
        }
        .padding(20)
        .frame(width: 460, alignment: .top)
        .windowBackground()
        .preferredColorScheme(.dark)
        .onAppear { store.refreshWiringState() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup").eyebrow()
            Text("Connect Claude Code")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            // Deliberately not "the app cannot work without this" — it can.
            // ~/.claude.json supplies a figure on its own; what it will not do
            // is keep itself current.
            Text("Burnline reads your usage from files Claude Code already keeps, "
                 + "so it works now. Adding a status line keeps it current: Claude Code "
                 + "reports after every response. Without one, the figure goes stale.")
            Text("Nothing here asks macOS for permission.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.wiringState {
            case .configured:
                statusRow(icon: "checkmark.circle.fill", tint: Theme.success,
                          state: store.wiringState,
                          detail: "Claude Code reports usage after each response in a terminal session.")
                captureAgeRow

            case .noSettingsFile, .notConfigured:
                statusRow(icon: "circle.dashed", tint: Theme.textMuted,
                          state: store.wiringState,
                          detail: "Adds a status line to your Claude Code settings.")
                setUpButton("Set up automatically")

            case .stalePath(let current):
                statusRow(icon: "arrow.triangle.2.circlepath", tint: Theme.warning,
                          state: store.wiringState,
                          detail: "Your settings name a copy of Burnline other than this one.")
                monospacedBox(current)
                setUpButton("Update it")

            case .conflict(let command):
                statusRow(icon: "exclamationmark.triangle.fill", tint: Theme.warning,
                          state: store.wiringState,
                          detail: "Burnline will not replace it. Merge the snippet below into "
                                + "your own, and both keep working.")
                if !command.isEmpty { monospacedBox(command) }

            // 🔴 No merge instruction and no snippet. Nothing has read this
            // file, so there is no status line to merge with — and the advice
            // that fits a conflict is advice about a claim we cannot make. The
            // error row beneath this one carries the parser's own message.
            case .unreadable:
                statusRow(icon: "exclamationmark.triangle.fill", tint: Theme.warning,
                          state: store.wiringState,
                          detail: "Burnline will not change a file it cannot parse. "
                                + "Fix the JSON and reopen this window.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.hairline))
    }

    /// Status carries an icon and words as well as colour — never colour alone.
    ///
    /// The title comes from the state itself, not from the call site: Settings
    /// reports the same five states and the two used to word them differently.
    private func statusRow(icon: String, tint: Color,
                           state: StatuslineWiring.State, detail: String) -> some View {
        statusRow(icon: icon, tint: tint, title: state.title, detail: detail)
    }

    private func statusRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Reuses the same tested age vocabulary as the popover rather than
    /// formatting a second time — no arithmetic in a view body.
    @ViewBuilder private var captureAgeRow: some View {
        if case .live = store.snapshot.source {
            let stale = CaptureAge.isStale(store.snapshot.liveAge)
            Text("Last report \(CaptureAge.description(store.snapshot.liveAge))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(stale ? Theme.warning : Theme.textMuted)
        } else {
            Text("No report yet. Send a message in a terminal Claude Code session.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func setUpButton(_ title: String) -> some View {
        Button(title) { store.configureStatusline() }
            .buttonStyle(AccentButtonStyle())
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Manual

    /// Always available, whatever the automatic route did. Someone who would
    /// rather an app didn't edit their config file is being reasonable.
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showingManual) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add to ~/.claude/settings.json:")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    monospacedBox(StatuslineWiring.snippet(helperPath: store.helperPath))
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            StatuslineWiring.snippet(helperPath: store.helperPath), forType: .string)
                        copied = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            } label: {
                Text("Set up manually")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func monospacedBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.track))
    }
}


/// Violet filled button.
///
/// `.borderedProminent` + `.tint(Theme.accent)` renders as a grey system pill
/// here rather than violet — verified by screenshot, and invisible in the
/// source.
///
/// Structured as a `ButtonStyle` rather than a `Button` with a hand-built label
/// so the title stays a plain `String` and SwiftUI derives the accessible name
/// from it. An earlier version built the label by hand; System Events then
/// reported the control with no name, but the same read also showed the
/// window's own traffic-light buttons as unnamed, so that measurement was not
/// trustworthy and no defect is claimed. This shape is correct regardless and
/// costs nothing.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

enum OnboardingWindow {
    static let id = "burnline-onboarding"

    /// Both halves required, same as `SettingsWindow`: an `LSUIElement` process
    /// is never activated, so `openWindow` alone puts the window behind
    /// everything and the app looks broken.
    @MainActor
    static func open(using openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
