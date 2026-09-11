import Foundation
import BurnlineCore
#if canImport(Darwin)
import Darwin
#endif

/// Asks Claude Code whether it still has a usable credential, without starting a
/// session and without spending anything.
///
/// `claude auth status` runs in ~0.17s, makes no network call, and answers in
/// its exit code. That is the whole mechanism. `ClaudeAuthStatus` — pure, in
/// Core — decides what the code means; this type only obtains it.
///
/// **This runs before `UsagePoller` opens a pty.** Polling while signed out is a
/// ~27 second session that cannot refresh anything, so refusing to spawn it is
/// worth doing on those grounds alone.
///
/// ⚠️ **An earlier version of this comment justified the ordering with a harm
/// that does not exist, and said so in 🔴.** It claimed a signed-out Claude Code
/// boots to `Select login method:` and that the `/usage\r` written 18s later is
/// an Enter on that picker, opening a browser nobody asked for. That was read
/// out of the CLI binary's strings, never observed. **Measured 2026-09-10
/// against a genuinely signed-out CLI (2.1.228, existing install):** it booted
/// to an ordinary prompt with a `Not logged in · Run /login` footer badge, the
/// carriage return hit that prompt harmlessly, and no browser opened. The picker
/// strings exist but appear to belong to first-run onboarding.
///
/// So this is a precaution, not a defence against a known harm. A fresh install
/// or a managed `forceLoginMethod` may still reach the picker; nobody has seen
/// it.
///
/// ⚠️ **Nothing here may start a login flow, ever.** The probe is read-only by
/// construction: `auth status` has no side effect on credentials. Do not
/// "improve" this by having it recover anything — re-authentication happens when
/// the user clicks, or not at all.
@MainActor
final class ClaudeAuthProbe {

    /// ⚠️ **15s, not the 2s this shipped with, and the difference was measured
    /// rather than guessed.** `claude auth status` takes ~0.17s on an idle
    /// machine — which is what the original figure was sized against, and it was
    /// wrong for the one call that matters. The re-probe runs *immediately after*
    /// a ~27s pty session that is still winding down, and under that load the
    /// command overran 2s and returned `.noAnswer`. `AuthReducer` then correctly
    /// treats no answer as evidence in neither direction, so the effect was
    /// silent: **`.signInExpired` could never be detected at all**, because the
    /// only path to it is a re-probe that always runs under exactly that load.
    ///
    /// ⚠️ A timeout fails **open** on the gate — no answer means no block, so the
    /// poll proceeds. That is the right direction (a probe that cannot run must
    /// not freeze the app's only refresh path) but it means this constant is
    /// load-bearing in both directions: too short and expiry is undetectable,
    /// too long and a hung child delays a poll the user is waiting on.
    private static let timeout: TimeInterval = 15

    /// `security show-keychain-info` exits 36 when the login keychain is locked.
    /// The CLI itself uses exactly this check before offering an unlock.
    private static let keychainLockedExitCode: Int32 = 36

    /// Guards against overlap. A probe is fast, but a hung one that has not yet
    /// hit its timeout must not be joined by a second.
    private var running = false

    /// Diagnostics for a path that is silent in normal operation, sharing the
    /// poller's log for the reason the poller documents: the only symptom of a
    /// broken probe is a figure that quietly never refreshes.
    private static func log(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["BURNLINE_POLL_LOG"] else { return }
        let line = "\(Date()) [auth] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// What Claude Code says about its own credentials, or `nil` if the question
    /// could not be asked.
    ///
    /// ⚠️ `.noAnswer` is never "fine". The spawn failed, the timeout fired, or
    /// `claude` is not installed — none of which says anything about the user's
    /// credentials. `AuthReducer` treats it as evidence in neither direction.
    func probe(executable: String) async -> AuthProbeResult {
        guard !running else {
            Self.log("skipped: already running")
            return .noAnswer
        }
        running = true
        defer { running = false }

        let code = await Self.run(executable: executable, arguments: ["auth", "status"])
        Self.log("claude auth status -> \(code.map(String.init) ?? "no answer")")

        // Only consulted for the answer a locked keychain also produces. A
        // second process on every probe would be waste; on a signed-out result
        // it is the difference between offering the remedy that works and one
        // that cannot.
        var keychainLocked = false
        if code == 1 {
            let keychain = await Self.run(executable: "/usr/bin/security",
                                          arguments: ["show-keychain-info"])
            keychainLocked = keychain == Self.keychainLockedExitCode
            Self.log("security show-keychain-info -> \(keychain.map(String.init) ?? "no answer")"
                     + " (locked: \(keychainLocked))")
        }

        return ClaudeAuthStatus.result(exitCode: code, keychainLocked: keychainLocked)
    }

    // MARK: - Spawning

    /// Runs a command and returns its exit code, or `nil` if it could not be run
    /// to completion.
    ///
    /// ⚠️ **The exit code alone is taken, and the output is discarded to
    /// `/dev/null` on purpose.** `claude auth status --json` prints the user's
    /// email, organisation id and organisation name; not capturing it is the
    /// cheapest possible guarantee that none of it is ever logged.
    private static func run(executable: String, arguments: [String]) async -> Int32? {
        // `DisclaimedSpawn` dup2s this one descriptor onto the child's stdin,
        // stdout and stderr. `/dev/null` opened read-write serves all three.
        let devNull = open("/dev/null", O_RDWR)
        guard devNull >= 0 else {
            log("FAILED: could not open /dev/null")
            return nil
        }
        defer { close(devNull) }

        // Spawned DISCLAIMED, like the poller — macOS then holds the child
        // responsible for its own file access instead of billing it to Burnline.
        //
        // ⚠️ The reason is TCC, NOT the keychain. Claude Code reads credentials
        // by shelling out to `security`, and keychain ACLs are evaluated against
        // the calling executable's code identity — `/usr/bin/security`, which is
        // in the item's ACL by default. Disclaiming neither helps nor hurts
        // there. It is here for the documented reason `DisclaimedSpawn` gives:
        // the startup walk over recorded project paths, which produced five
        // permission prompts naming Burnline on a clean machine.
        var environment = ProcessInfo.processInfo.environment
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnline-auth-\(UUID().uuidString)")
        // Belt and braces: this command renders no status line, so it should
        // never write a capture — but if a future version did, it would write it
        // to a throwaway directory rather than over live data.
        environment[ApplicationSupport.overrideKey] = scratch.path
        defer { try? FileManager.default.removeItem(at: scratch) }

        let pid = DisclaimedSpawn.spawn(executable: executable,
                                        arguments: arguments,
                                        environment: environment,
                                        workingDirectory: ApplicationSupport.pollWorkingDirectory().path,
                                        replica: devNull)
        // ⚠️ `-1`, not nil. The doc comment on `spawn` says nil and is wrong.
        guard pid > 0 else {
            log("FAILED to spawn \(executable)")
            return nil
        }

        return await waitForExit(pid: pid)
    }

    /// Waits for the child, killing and reaping it if it overruns.
    ///
    /// ⚠️ **Reaping is not optional.** Nothing else in this app reaps, so an
    /// unreaped probe stays a zombie for the life of the process — and this can
    /// run once per poll. The poller spends forty lines on this same problem for
    /// the same reason.
    private static func waitForExit(pid: pid_t) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0

        while Date() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return exitCode(from: status) }
            // Negative means there is no such child to wait for; continuing
            // would spin until the deadline for nothing.
            if result < 0 { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Terminate the process GROUP. SETSID made the child a group leader, and
        // a bare kill(pid) would leave any descendant it spawned running.
        log("timed out after \(timeout)s; killing")
        kill(-pid, SIGTERM)
        try? await Task.sleep(for: .milliseconds(200))
        if kill(pid, 0) == 0 { kill(-pid, SIGKILL) }
        for _ in 0..<40 {
            if waitpid(pid, &status, WNOHANG) != 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // A killed probe answered nothing. Deliberately not an exit code: a
        // signal death must never be read as "signed out".
        return nil
    }

    /// The child's exit status, or `nil` if it died from a signal.
    ///
    /// Swift cannot see the `W*` macros, so the bit layout is open-coded: the
    /// low seven bits hold the terminating signal, and zero there means a normal
    /// exit whose code sits in the next eight bits.
    private static func exitCode(from status: Int32) -> Int32? {
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }
}
