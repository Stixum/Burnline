import Foundation

// The words two surfaces share — the popover banner and the menu bar's spoken
// label — plus the one command in this app that a button is allowed to run.
//
// Words live here rather than in a view for the reason `StatuslineWiring.State.title`
// records: the same states described in two places drift into sounding like two
// features. Colour and icon stay in the views; status in this app is never
// carried by colour alone anyway.

public extension AuthBlock.Kind {

    /// The state in words.
    ///
    /// Words only — icon and colour stay in the view, following
    /// `StatuslineWiring.State.title`. Two surfaces describe these states (the
    /// popover banner and the menu bar's spoken label) and they must not drift
    /// into sounding like two features.
    var title: String {
        switch self {
        case .signedOut:      "Claude Code is signed out"
        // ⚠️ Kept short deliberately. This sits on one row beside the action
        // button, and the longer "Claude Code needs to sign in again" squeezed
        // it until "Sign in…" wrapped onto two lines — invisible to 756 tests,
        // obvious in a render.
        case .signInExpired:  "Claude Code sign-in expired"
        case .keychainLocked: "Your keychain is locked"
        }
    }

    /// The button. ⚠️ The ellipsis is the platform's promise that *this opens
    /// something and asks you more* — which is exactly what happens.
    var actionLabel: String {
        switch self {
        case .signedOut, .signInExpired: "Sign in…"
        case .keychainLocked:            "Unlock…"
        }
    }

    /// The command the button runs. Never run without a click.
    ///
    /// ⚠️ `claude auth login` and NOT `claude auth logout && claude auth login`.
    /// The CLI has no presence check — absent `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`
    /// it goes straight to the OAuth flow — so the plain command already works
    /// for an expired credential. The logout variant would revoke machine-wide
    /// from a button press, killing every other session on the Mac.
    func command(claudeExecutable: String) -> String {
        switch self {
        case .signedOut, .signInExpired: "\(claudeExecutable) auth login"
        case .keychainLocked:            "security unlock-keychain"
        }
    }
}

public extension AuthBlock {

    /// The second line of the banner.
    ///
    /// ⚠️ **"the figure stopped updating", never "usage stopped".** Desktop-app
    /// sessions write transcripts, so their tokens are still counted — units
    /// keep moving while the CLI sits signed out, and telling those users their
    /// usage stopped is simply false.
    func detail(anchorAge: TimeInterval?) -> String {
        let when = anchorAge.map { "Stopped updating \(CaptureAge.description($0))." }
            ?? "No reading yet."
        switch kind {
        case .keychainLocked: return "\(when) Opens a Terminal window to unlock it."
        case .signedOut, .signInExpired: return "\(when) Opens a Terminal window."
        }
    }
}
