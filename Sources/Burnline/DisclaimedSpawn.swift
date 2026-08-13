import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Spawns a child that macOS holds responsible for **itself**, rather than
/// attributing its file access back to Burnline.
///
/// ## Why this exists
///
/// TCC bills a child process's access to its *responsible process*. Claude Code
/// validates its recorded project paths at startup, and on a normal machine
/// plenty of those live under Documents, Downloads, or a cloud drive. Run from
/// Terminal that is silent, because Terminal already holds those grants. Run
/// from Burnline it produced **five permission prompts naming Burnline** on a
/// clean machine — for Documents, Desktop, Downloads, OneDrive, Google Drive
/// and Music.
///
/// Nothing Burnline needs depends on those grants: measured 2026-08-13, every
/// one can be declined and the poll still works. But a menu bar app asking for
/// your cloud drives on first use reads as malware, however well it is
/// explained, and explaining it was not good enough.
///
/// `responsibility_spawnattrs_setdisclaim` is the documented-by-usage mechanism
/// for exactly this: terminal emulators and shells use it so their children are
/// not billed to them. Claude Code itself ships a helper named `disclaimer` in
/// its own process chain doing the same job.
///
/// ⚠️ This is SPI, resolved at runtime via `dlsym` rather than linked. If a
/// future macOS drops it, `spawn` falls back to a normal spawn and the prompts
/// return — noisy, but working. Failing closed here would mean no usage
/// refresh at all, which is worse.
enum DisclaimedSpawn {

    private typealias SetDisclaim = @convention(c) (
        UnsafeMutablePointer<posix_spawnattr_t?>, Int32
    ) -> Int32

    /// Resolved once. `nil` means this macOS does not expose it.
    private static let setDisclaim: SetDisclaim? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    static var isAvailable: Bool { setDisclaim != nil }

    /// Launches `executable` with the given arguments, wiring `replica` to the
    /// child's stdin, stdout and stderr, and putting it in its own session so
    /// the pty becomes its controlling terminal.
    ///
    /// Returns the child's pid, or `nil` if the spawn failed.
    static func spawn(executable: String,
                      arguments: [String],
                      environment: [String: String],
                      workingDirectory: String,
                      replica: Int32) -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // SETSID: a new session, so the pty is the child's controlling terminal.
        // Claude Code renders its TUI only when it believes it has one. (Checked:
        // on Darwin the dup2'd replica does become the ctty, unlike Linux.)
        //
        // CLOEXEC_DEFAULT: close everything else. Without it the child inherits
        // every non-cloexec descriptor Burnline holds — including the pty
        // primary and the spare replica — and passes them to its own children.
        // A straggler holding a replica copy means the drain never sees EOF.
        // The adddup2 targets below survive this flag.
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // Must come AFTER setflags: if disclaim records anything in the flags
        // word, setting flags afterwards would clobber it.
        //
        // Best effort. A failure here costs the quiet spawn, not the spawn.
        _ = setDisclaim?(&attributes, 1)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in Int32(0)...Int32(2) {
            posix_spawn_file_actions_adddup2(&fileActions, replica, descriptor)
        }
        // The _np variant deliberately. macOS 26 deprecates it in favour of
        // posix_spawn_file_actions_addchdir, which does not exist on macOS 14 —
        // and 14 is the floor this app supports. A deprecation warning is the
        // cheaper problem.
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

        let argv: [String] = [executable] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for pointer in cArgv where pointer != nil { free(pointer) }
            for pointer in cEnv where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, &cArgv, &cEnv)
        return result == 0 ? pid : -1
    }
}
