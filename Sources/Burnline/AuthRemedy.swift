import AppKit
import BurnlineCore

/// Hands the user a terminal with the sign-in command in it.
///
/// 🔴 **Only ever called from a button.** Nothing on a timer, in a probe, or in
/// a state transition may reach this. Burnline detects that re-authentication is
/// needed; the user decides when it happens.
enum AuthRemedy {

    /// Opens Terminal running the command for this state.
    ///
    /// ⚠️ A `.command` file handed to `NSWorkspace`, **not** `NSAppleScript`
    /// telling Terminal to `do script`. Opening a document with its default
    /// handler is not Automation and raises no TCC prompt; the AppleScript route
    /// would put up an Automation dialog naming Burnline.
    ///
    /// Returns `false` if the file could not be written, so the caller can fall
    /// back to the clipboard rather than leaving a button that did nothing.
    @discardableResult
    static func open(_ kind: AuthBlock.Kind, claudeExecutable: String) -> Bool {
        let script = """
        #!/bin/sh
        # Opened by Burnline because Claude Code needs to sign in again.
        # Burnline never runs this for you — you clicked, and that is the point.
        \(kind.command(claudeExecutable: claudeExecutable))
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnline-sign-in-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            // ⚠️ Terminal refuses a `.command` file without the executable bit.
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// Puts the command on the pasteboard.
    ///
    /// The fallback for a machine whose `.command` handler is an editor rather
    /// than a terminal, and the option-click on the same button. Zero
    /// permissions, works everywhere.
    static func copy(_ kind: AuthBlock.Kind, claudeExecutable: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(kind.command(claudeExecutable: claudeExecutable), forType: .string)
    }
}
