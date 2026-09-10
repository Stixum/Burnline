import SwiftUI
import BurnlineCore

/// Why the figure stopped, when Claude Code's own credentials are the reason,
/// with the one control in this app allowed to fix it.
///
/// **Amber, not red.** Red in this app is the failure of an action just
/// attempted — "Couldn't register at login", a settings file that would not
/// write. Amber is a state with a remedy on offer, which is every other
/// environment problem here: Claude Code not found, notifications blocked in
/// System Settings, a status line pointing at a different copy. ⚠️ Red would
/// also read as *you're over*, the one thing this banner is not saying.
///
/// Symbol + word + colour, never colour alone.
///
/// ⚠️ **Takes no store, deliberately.** Everything it draws comes from the two
/// values passed in, so it can be rendered through `ImageRenderer` in a
/// throwaway target and asserted on pixel by pixel — no running app, no awake
/// display. Do not reach into `UsageStore` from here; that would put this view
/// back out of reach of the only check that can prove a drawing is right.
struct AuthBanner: View {

    let block: AuthBlock
    /// Age of the live capture, for the second line. `nil` under pace-only.
    let anchorAge: TimeInterval?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                Text(block.kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 6)
                // 🔴 The only thing in this app that may start a login flow.
                Button(block.kind.actionLabel, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    // 🔴 The control must stay whole. Without this the row
                    // resolves a long title by wrapping the BUTTON — "Sign in…"
                    // became "Sign" / "in…" — which is the one element here
                    // that has to stay legible and clickable.
                    .fixedSize()
                    .foregroundStyle(Theme.accent)
                    .help("Opens a Terminal window running "
                          + "\(block.kind.command(claudeExecutable: "claude")). "
                          + "Option-click to copy it instead.")
            }
            Text(block.detail(anchorAge: anchorAge))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.warning)
        .padding(.top, 5)
    }
}
