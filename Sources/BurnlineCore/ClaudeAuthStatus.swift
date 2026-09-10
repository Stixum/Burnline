import Foundation

/// A reason Burnline's usage anchor has stopped moving that the user must act
/// on, and the instant that reason was observed.
///
/// **The optional is the discriminator.** There is deliberately no `healthy`
/// case: `AuthBlock?` being nil covers both "probed, fine" and "never probed",
/// and both must render identically. A distinct healthy case differs from
/// unknown in exactly one rendering decision, and would be read as proof that
/// authentication works — which no local check can establish. Same rule, and the
/// same reasoning, as the mid-window re-grant's open epoch.
public struct AuthBlock: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable, Codable {
        /// No usable credential. Claude Code boots to `Select login method:`.
        case signedOut
        /// A credential probably exists but the keychain is locked, so the CLI
        /// cannot read it and reports exactly what a sign-out reports.
        case keychainLocked
        /// A credential exists and its refresh has failed. Claude Code boots to
        /// a normal prompt.
        case signInExpired
    }

    public let kind: Kind

    /// When the evidence was **observed**.
    ///
    /// ⚠️ For `.signInExpired` this is the end of the poll that discovered it,
    /// never the start. A poll takes ~27 seconds; back-dating the block to its
    /// start lets a terminal turn that landed mid-poll clear the very block that
    /// poll just set.
    public let detectedAt: Date

    public init(kind: Kind, detectedAt: Date) {
        self.kind = kind
        self.detectedAt = detectedAt
    }
}

/// Reads `claude auth status`'s exit code.
///
/// ## Why the exit code and not the JSON
///
/// The command ends `process.exit(c ? 0 : 1)`, where `c` is the same boolean it
/// serialises as `loggedIn`. An exit code is a far more stable contract than a
/// key name, and it needs no decoder — which matters, because the JSON body
/// carries the user's email, org id and org name and must never be logged.
///
/// ## ⚠️ What a zero does NOT mean
///
/// It is a **presence** check. `hasToken` is true whenever the stored scopes
/// include `user:inference` and an `accessToken` exists; `expiresAt` and
/// `refreshTokenExpiresAt` are never compared. So an expired credential still
/// exits 0 until something has tried to refresh it and failed.
///
/// Once a refresh **has** failed with `invalid_grant`, the CLI writes back
/// `refreshToken: ""` and `accessToken: ""`, and the presence check then reads
/// false — so a *discovered*-dead credential does exit 1. Discovery is what a
/// poll performs; this type only reports what the CLI has already concluded.
/// What a single run of `claude auth status` established.
///
/// ⚠️ Three outcomes, not two. `.noAnswer` is **not** `.credentialPresent`: a
/// probe that could not run says nothing about the user's credentials, and
/// collapsing the two would let a missing binary read as proof of health.
public enum AuthProbeResult: Equatable, Sendable {
    /// Exit 0. A credential exists. Says nothing about whether it still works.
    case credentialPresent
    /// Exit 1, with the keychain disambiguated.
    case blocked(AuthBlock.Kind)
    /// The probe did not run to completion.
    case noAnswer
}

public enum ClaudeAuthStatus {

    /// The exit code Claude Code uses for "no usable credential". Nothing else
    /// is interpreted — see `kind`.
    private static let signedOutExitCode: Int32 = 1

    /// What the probe found, or `nil` if it found nothing worth acting on.
    ///
    /// - Parameters:
    ///   - exitCode: `nil` when the probe did not run to completion — the spawn
    ///     failed, the timeout fired, or `claude` is not installed.
    ///   - keychainLocked: whether `security show-keychain-info` reported the
    ///     login keychain locked (exit 36). Only consulted for a signed-out
    ///     result, which is the answer a locked keychain also produces.
    public static func kind(exitCode: Int32?, keychainLocked: Bool) -> AuthBlock.Kind? {
        // ⚠️ A probe that did not run is not evidence. Inferring a block from a
        // missing answer would gate polling on a machine whose only problem is
        // that Claude Code moved.
        guard let exitCode else { return nil }
        // ⚠️ Only exactly 1. A crash, a signal, or 127 from a missing binary are
        // all non-zero and none of them says anything about credentials.
        guard exitCode == signedOutExitCode else { return nil }
        return keychainLocked ? .keychainLocked : .signedOut
    }

    /// The probe's outcome as three cases, for `AuthReducer`.
    ///
    /// `kind` above answers "what block, if any"; this answers "what did we
    /// learn", which is the distinction the reducer needs — a probe that did not
    /// run must not be mistaken for one that found a credential.
    public static func result(exitCode: Int32?, keychainLocked: Bool) -> AuthProbeResult {
        guard let exitCode else { return .noAnswer }
        if let kind = kind(exitCode: exitCode, keychainLocked: keychainLocked) {
            return .blocked(kind)
        }
        // ⚠️ Only exit 0 is a credential. Every other code reached here is a
        // crash, a signal, or 127 — no answer, not a healthy one.
        return exitCode == 0 ? .credentialPresent : .noAnswer
    }

    /// Whether this state means `UsagePoller` must not spawn a session.
    ///
    /// 🔴 This is the gate. Signed out, Claude Code boots to `Select login
    /// method:` rather than a prompt, and the `/usage\r` the poller writes 18
    /// seconds later is an Enter keypress on that picker — which starts an OAuth
    /// flow and opens a browser the user never asked for. On a managed Mac with
    /// `forceLoginMethod` set it is worse still: the login component starts in
    /// `ready_to_start` and opens the browser at boot, before anything is typed.
    /// **The probe therefore has to precede the spawn, not the write.**
    ///
    /// ⚠️ **Every kind gates, `.signInExpired` included — and an earlier draft of
    /// this design said the opposite.** The argument for exempting it was that
    /// an expired-but-present credential boots to a prompt rather than a picker,
    /// so polling stays safe. True of a credential nothing has *discovered* yet
    /// — but that state carries no block at all (`AuthReducer` sets one only
    /// when a probe answers exit 1). By the time `.signInExpired` exists, the
    /// CLI has already written its dead-credential marker, `auth status` answers
    /// 1 from then on, and a session would boot to the picker like any other
    /// signed-out one. Exempting it would have reopened the exact harm the gate
    /// closes.
    ///
    /// The exemption was there to keep a recovery path open. It is not needed:
    /// a probe answering `.credentialPresent` refutes any block, and probes are
    /// not gated by anything.
    public static func blocksPolling(_ kind: AuthBlock.Kind?) -> Bool {
        kind != nil
    }
}
