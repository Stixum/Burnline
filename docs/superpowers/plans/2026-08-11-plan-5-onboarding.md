# Burnline Plan 5 — First-run onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A first-run window that tells the user whether the statusline capture is wired up, offers to wire it, and refuses to damage an existing configuration.

**Architecture:** The decision — *what should we do about this `settings.json`?* — is a pure function over a parsed dictionary, living in `BurnlineCore` with full test coverage. The file I/O (read, back up, write) is a thin separate unit. The SwiftUI window only renders the resulting state and calls one method. No branching logic in a view body.

**Tech Stack:** SwiftUI `Window` scene, `JSONSerialization`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-11-burnline-distribution-design.md` §5. **Depends on:** Plan 4 (the helper binary must exist at a known path inside the bundle).

> ## Revision note — 2026-08-12
>
> Written before `UtilizationStore`, `UsagePoller` and `BURNLINE_DATA_DIR`
> existed. Three changes, none of which invalidate the design:
>
> 1. **The premise softened.** A user who configures nothing is no longer
>    necessarily stuck in `.paceOnly` — `~/.claude.json` may feed a live figure
>    on its own. The statusline is still the right recommendation (event-driven,
>    free, refreshes on every response, no subprocess), so onboarding still
>    pushes it — but the copy changes from *"do this or it cannot work"* to
>    *"do this and it works properly"*. **Do not write copy that claims the app
>    is broken without a statusline; a stranger can now disprove it in one
>    glance, and that costs you their trust in everything else the window says.**
> 2. **Two tasks added** — Task 5 (poller first-enable confirmation) and Task 6
>    (surface "Claude Code not found"). Both come from spec §5 and §1 as revised.
>    The old Task 5 (clean-account end-to-end) is now Task 7.
> 3. **`BURNLINE_DATA_DIR` exists**, so the capture path is safely testable.
>    Any warning below about being unable to avoid live data is obsolete.
>
> `StatuslineWiring` and `ClaudeSettingsFile` as specified are unaffected. The
> refuse-to-clobber rule is unchanged and remains the most important line here.

---

## Background for the implementer

**Why this exists.** Without a `statusLine` entry in `~/.claude/settings.json`, Burnline depends entirely on `~/.claude.json` — which does not self-refresh, so the figure goes stale and stays stale until something runs `/usage`. The statusline is what makes the number move on its own: event-driven, free, updating on every response, no subprocess. A new user has no idea any of that is configurable, and today the fix is undocumented outside the author's own notes.

⚠️ **Do not write copy claiming the app cannot work without it.** That was true when this plan was drafted and is not true now — a stranger can disprove it at a glance, which costs you their trust in everything else the window says.

**The single most important rule in this plan: never clobber an existing statusline.** Plenty of Claude Code users have one — a custom prompt, `ccusage`, a shell script they wrote. Silently replacing it is unrecoverable without the backup and is the worst thing this app could do to a stranger's setup. When there is a conflict, **Burnline loses** and shows the manual snippet instead.

**`SettingsLink` and the `Settings` scene silently no-op in this app.** `LSUIElement` processes are never activated, so the scene has nothing to attach to and the click looks like a dead button. Settings is an explicit `Window` scene opened via `openWindow(id:)` **plus `NSApplication.shared.activate()`** — both halves required. Onboarding follows the exact same pattern; copy `BurnlineApp.swift`'s existing Settings wiring rather than inventing a new one.

**Appearance.** Hardcoded dark surfaces are only half the job — the window also needs `.preferredColorScheme(.dark)`, and `.windowBackground()` (not `.background()`) on the root. Skip either and every *system* control renders for light mode: near-black on near-black, while the hand-styled text looks fine, so the bug hides from code review. Screenshot the window before calling this done.

**Key ordering.** `JSONSerialization` does not preserve key order, so writing the file reorders the user's keys. That is accepted here: the alternative is a surgical text edit of arbitrary JSON, which is fragile in exactly the situation where being wrong is most expensive. The backup makes it recoverable, and the file's *content* is preserved exactly.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/BurnlineCore/StatuslineWiring.swift` | **Create.** Pure: parsed settings + helper path → what state we're in |
| `Sources/BurnlineCore/ClaudeSettingsFile.swift` | **Create.** Locate, read, back up, write `~/.claude/settings.json` |
| `Sources/Burnline/OnboardingView.swift` | **Create.** The window's contents |
| `Sources/Burnline/BurnlineApp.swift` | **Modify.** Register the window scene, open on first run |
| `Sources/Burnline/UsageStore.swift` | **Modify.** Expose wiring state + the setup action |
| `Sources/BurnlineCore/BurnlineSettings.swift` | **Modify.** Add `hasSeenOnboarding` |
| `Tests/BurnlineCoreTests/StatuslineWiringTests.swift` | **Create.** The state table |
| `Tests/BurnlineCoreTests/ClaudeSettingsFileTests.swift` | **Create.** Read/backup/write against temp dirs |

---

### Task 1: `StatuslineWiring` — the decision, as a pure function

**Files:**
- Create: `Sources/BurnlineCore/StatuslineWiring.swift`
- Test: `Tests/BurnlineCoreTests/StatuslineWiringTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private let helper = "/Applications/Burnline.app/Contents/MacOS/burnline-statusline"

@Test func noFileMeansNotConfigured() {
    #expect(StatuslineWiring.state(settings: nil, helperPath: helper) == .noSettingsFile)
}

@Test func fileWithoutStatusLineMeansNotConfigured() {
    let settings: [String: Any] = ["theme": "dark"]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .notConfigured)
}

@Test func ourHelperAtTheCurrentPathIsConfigured() {
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": helper, "refreshInterval": 30]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .configured)
}

@Test func ourHelperAtAnotherPathIsStale() {
    let old = "/Users/someone/Downloads/Burnline.app/Contents/MacOS/burnline-statusline"
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": old]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .stalePath(current: old))
}

@Test func theOldBashScriptCountsAsOurs() {
    // Upgraders from the pre-1.0 hand-installed script must be migrated, not
    // treated as a foreign statusline we have to refuse.
    let script = "/Users/someone/.claude/burnline-statusline.sh"
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": script]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .stalePath(current: script))
}

@Test func someoneElsesStatusLineIsAConflict() {
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/my-prompt.sh"]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .conflict(command: "~/bin/my-prompt.sh"))
}

@Test func aConflictWithNoCommandStringStillConflicts() {
    let settings: [String: Any] = ["statusLine": ["type": "command"]]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .conflict(command: ""))
}

@Test func aNonDictionaryStatusLineIsAConflict() {
    // Don't guess at a shape we don't recognise — refuse and let the user look.
    let settings: [String: Any] = ["statusLine": "some-command"]
    #expect(StatuslineWiring.state(settings: settings, helperPath: helper) == .conflict(command: "some-command"))
}

// --- the merge itself ---

@Test func mergeAddsStatusLineAndPreservesEverythingElse() throws {
    let existing: [String: Any] = ["theme": "dark", "hooks": ["PreToolUse": ["x"]]]
    let merged = StatuslineWiring.merged(into: existing, helperPath: helper)

    let statusLine = try #require(merged["statusLine"] as? [String: Any])
    #expect(statusLine["type"] as? String == "command")
    #expect(statusLine["command"] as? String == helper)
    #expect(statusLine["refreshInterval"] as? Int == 30)

    #expect(merged["theme"] as? String == "dark")
    #expect((merged["hooks"] as? [String: Any])?["PreToolUse"] != nil)
}

@Test func mergeIntoNothingProducesOnlyStatusLine() {
    let merged = StatuslineWiring.merged(into: [:], helperPath: helper)
    #expect(merged.count == 1)
    #expect(merged["statusLine"] != nil)
}

@Test func mergeReplacesOnlyTheCommandOnAStalePath() throws {
    // A user who set their own refreshInterval keeps it.
    let existing: [String: Any] = [
        "statusLine": ["type": "command", "command": "/old/path", "refreshInterval": 10]
    ]
    let merged = StatuslineWiring.merged(into: existing, helperPath: helper)
    let statusLine = try #require(merged["statusLine"] as? [String: Any])
    #expect(statusLine["command"] as? String == helper)
    #expect(statusLine["refreshInterval"] as? Int == 10)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StatuslineWiring`
Expected: FAIL — `cannot find 'StatuslineWiring' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What `~/.claude/settings.json` currently says about the statusline, and what
/// Burnline is allowed to do about it.
///
/// Pure by design: the decision is the part that must never be wrong, so it is
/// tested against a dictionary rather than against the filesystem.
public enum StatuslineWiring {
    public enum State: Equatable, Sendable {
        /// No settings file at all. Safe to create one.
        case noSettingsFile
        /// A settings file with no `statusLine` key. Safe to add one.
        case notConfigured
        /// Ours, pointing at this bundle. Nothing to do.
        case configured
        /// Ours, pointing somewhere else — a moved bundle, or the pre-1.0
        /// hand-installed shell script. Safe to repoint.
        case stalePath(current: String)
        /// Someone else's statusline. **Burnline does not win this.** The user
        /// is shown the snippet and decides.
        case conflict(command: String)

        /// Whether "Set up automatically" should be offered.
        public var isAutomaticallyFixable: Bool {
            switch self {
            case .noSettingsFile, .notConfigured, .stalePath: true
            case .configured, .conflict: false
            }
        }
    }

    /// Default cadence. Load-bearing: between captures the app extrapolates
    /// from local token counts alone and undershoots any usage that happened
    /// off this Mac, so a slow refresh is a wrong number, not just a stale one.
    public static let refreshInterval = 30

    /// Recognises a command as Burnline's own. Matches on the trailing
    /// component so a moved bundle is still recognised, and includes the
    /// pre-1.0 shell script so early adopters are migrated rather than
    /// treated as a conflict.
    static func isOurs(_ command: String) -> Bool {
        command.hasSuffix("/burnline-statusline")
            || command.hasSuffix("/burnline-statusline.sh")
    }

    public static func state(settings: [String: Any]?, helperPath: String) -> State {
        guard let settings else { return .noSettingsFile }
        guard let raw = settings["statusLine"] else { return .notConfigured }

        guard let statusLine = raw as? [String: Any] else {
            // An unrecognised shape. Describe it and refuse rather than guess.
            return .conflict(command: (raw as? String) ?? String(describing: raw))
        }

        let command = statusLine["command"] as? String ?? ""
        guard isOurs(command) else { return .conflict(command: command) }
        return command == helperPath ? .configured : .stalePath(current: command)
    }

    /// The settings dictionary with our statusline installed.
    ///
    /// Every other key is carried across untouched, including a `refreshInterval`
    /// the user has customised — we only ever own the `command`.
    public static func merged(into settings: [String: Any], helperPath: String) -> [String: Any] {
        var result = settings
        var statusLine = (settings["statusLine"] as? [String: Any]) ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = helperPath
        if statusLine["refreshInterval"] == nil {
            statusLine["refreshInterval"] = refreshInterval
        }
        result["statusLine"] = statusLine
        return result
    }

    /// The snippet shown for hand-merging, for the conflict case and for users
    /// who would rather an app not edit their config.
    public static func snippet(helperPath: String) -> String {
        """
        "statusLine": {
          "type": "command",
          "command": "\(helperPath)",
          "refreshInterval": \(refreshInterval)
        }
        """
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter StatuslineWiring`
Expected: PASS, 11 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/StatuslineWiring.swift Tests/BurnlineCoreTests/StatuslineWiringTests.swift
git commit -m "feat: decide what to do about an existing statusLine, purely"
```

---

### Task 2: `ClaudeSettingsFile` — read, back up, write

**Files:**
- Create: `Sources/BurnlineCore/ClaudeSettingsFile.swift`
- Test: `Tests/BurnlineCoreTests/ClaudeSettingsFileTests.swift`

**Tests must never touch the real `~/.claude`.** Every test injects a temporary directory, exactly as `RateLimitStore(directory:)` already allows.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import BurnlineCore

private func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func readsAMissingFileAsNil() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try ClaudeSettingsFile(directory: dir).read() == nil)
}

@Test func readsAnExistingFile() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try #"{"theme":"dark"}"#.write(to: file.url, atomically: true, encoding: .utf8)
    #expect(try file.read()?["theme"] as? String == "dark")
}

@Test func malformedJsonThrowsRatherThanReadingAsEmpty() throws {
    // Reading a broken file as `nil` would look identical to "no file", and we
    // would then create a fresh settings.json on top of their broken one.
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try "{ not json".write(to: file.url, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try file.read() }
}

@Test func writingBacksUpTheOriginalFirst() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try #"{"theme":"dark"}"#.write(to: file.url, atomically: true, encoding: .utf8)

    try file.write(["theme": "light"], backupSuffix: "test")

    let backup = dir.appendingPathComponent("settings.json.burnline-backup-test")
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
    #expect(restored?["theme"] as? String == "dark")
    #expect(try file.read()?["theme"] as? String == "light")
}

@Test func writingWithNoOriginalMakesNoBackup() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    try file.write(["theme": "light"], backupSuffix: "test")
    let backup = dir.appendingPathComponent("settings.json.burnline-backup-test")
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}

@Test func nestedStructuresSurviveARoundTrip() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = ClaudeSettingsFile(directory: dir)
    let original = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]},"env":{"A":"1"}}"#
    try original.write(to: file.url, atomically: true, encoding: .utf8)

    let read = try #require(try file.read())
    try file.write(StatuslineWiring.merged(into: read, helperPath: "/h"), backupSuffix: "test")

    let after = try #require(try file.read())
    let hooks = try #require(after["hooks"] as? [String: Any])
    #expect(hooks["PreToolUse"] != nil)
    #expect((after["env"] as? [String: Any])?["A"] as? String == "1")
    #expect((after["statusLine"] as? [String: Any])?["command"] as? String == "/h")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ClaudeSettingsFile`
Expected: FAIL — `cannot find 'ClaudeSettingsFile' in scope`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Reads and writes `~/.claude/settings.json`.
///
/// This is someone else's configuration file. Two rules follow from that:
/// a backup is written before any mutation, and a file we cannot parse is an
/// error rather than an empty dictionary — treating a broken file as "no file"
/// would have us write a fresh one straight over it.
public struct ClaudeSettingsFile: Sendable {
    public let url: URL

    public init(directory: URL = ClaudeSettingsFile.defaultDirectory()) {
        url = directory.appendingPathComponent("settings.json")
    }

    /// `~/.claude`. Burnline is unsandboxed, so this is the real home directory
    /// rather than a container — which is the whole reason the app can read
    /// Claude Code's files without any entitlement work.
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// `nil` when the file does not exist. Throws when it exists and cannot be
    /// parsed — see the type comment.
    public func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    /// Backs the current file up, then writes `settings` atomically.
    ///
    /// Key order is not preserved — `JSONSerialization` reorders. Accepted: the
    /// alternative is a surgical text edit of arbitrary JSON, which is most
    /// fragile exactly where being wrong is most expensive. Content is
    /// preserved exactly, and the backup makes the layout recoverable.
    public func write(_ settings: [String: Any], backupSuffix: String? = nil) throws {
        let suffix = backupSuffix ?? String(Int(Date().timeIntervalSince1970))
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.burnline-backup-\(suffix)")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ClaudeSettingsFile`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/BurnlineCore/ClaudeSettingsFile.swift Tests/BurnlineCoreTests/ClaudeSettingsFileTests.swift
git commit -m "feat: read and safely rewrite ~/.claude/settings.json"
```

---

### Task 3: Wire it into `UsageStore`

**Files:**
- Modify: `Sources/Burnline/UsageStore.swift`
- Modify: `Sources/BurnlineCore/BurnlineSettings.swift`

- [ ] **Step 1: Add `hasSeenOnboarding` to `BurnlineSettings`**

Default `false`. Follow the existing property pattern in that file exactly — it is `Codable` and decoded from an existing on-disk file, so the new key **must** have a default or every existing install fails to decode its settings.

- [ ] **Step 2: Expose the helper path**

```swift
    /// The statusline helper inside this bundle. Resolved at runtime, never
    /// hardcoded — the user may have the app somewhere other than
    /// /Applications, and it must keep working if they move it.
    var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/burnline-statusline")
            .path
    }
```

- [ ] **Step 3: Expose the state and the action**

```swift
    private(set) var wiringState: StatuslineWiring.State = .noSettingsFile
    private(set) var wiringError: String?

    func refreshWiringState() {
        do {
            wiringState = StatuslineWiring.state(
                settings: try ClaudeSettingsFile().read(), helperPath: helperPath
            )
            wiringError = nil
        } catch {
            // A settings.json we cannot parse is the user's problem to fix, and
            // we must not offer to overwrite it.
            wiringState = .conflict(command: "")
            wiringError = "~/.claude/settings.json could not be read: \(error.localizedDescription)"
        }
    }

    func configureStatusline() {
        guard wiringState.isAutomaticallyFixable else { return }
        do {
            let file = ClaudeSettingsFile()
            let existing = try file.read() ?? [:]
            try file.write(StatuslineWiring.merged(into: existing, helperPath: helperPath))
            wiringError = nil
        } catch {
            wiringError = "Could not write ~/.claude/settings.json: \(error.localizedDescription)"
        }
        refreshWiringState()
    }
```

- [ ] **Step 4: Call `refreshWiringState()` from the existing 10s rebuild loop**

So the "capture detected" indicator and the configured state both go live without a restart. This is a file read of a small file; it is not worth its own timer.

- [ ] **Step 5: Verify and commit**

```bash
swift build && swift test
```

```bash
git add Sources/Burnline/UsageStore.swift Sources/BurnlineCore/BurnlineSettings.swift
git commit -m "feat: expose statusline wiring state and setup action on UsageStore"
```

---

### Task 4: The onboarding window

**Files:**
- Create: `Sources/Burnline/OnboardingView.swift`
- Modify: `Sources/Burnline/BurnlineApp.swift`

- [ ] **Step 1: Register the scene**

Copy the existing Settings `Window` scene wiring verbatim, with `id: "onboarding"`. Both halves are required — `openWindow(id:)` **and** `NSApplication.shared.activate()`. Without the activate, the window opens behind everything and reads as a dead button.

- [ ] **Step 2: Open it on first run**

In the app's launch path: if `settings.hasSeenOnboarding == false`, open the window and set the flag to `true`. It stays reachable from the popover afterwards.

- [ ] **Step 3: Build the view**

Sections, top to bottom:

1. **What Burnline needs** — one sentence: Claude Code has to be told to send its usage data here, which is a one-line addition to `~/.claude/settings.json`.
2. **Status**, driven entirely by `wiringState`:
   - `.configured` → green check, "Connected". Plus the live capture line: "Last capture 12s ago" / "No capture yet — send a message in Claude Code".
   - `.noSettingsFile` / `.notConfigured` → "Not set up yet" + the **Set up automatically** button.
   - `.stalePath(current:)` → "Pointing at an old location" + the current path + **Update it** button.
   - `.conflict(command:)` → amber, "You already have a status line configured", their command in a monospaced box, and **no automatic button**. Text: add the snippet below to it by hand.
3. **Manual setup** — always visible, collapsed by default. `StatuslineWiring.snippet(helperPath:)` in a monospaced box with a copy-to-clipboard button.
4. `wiringError` in red when non-nil.

Follow `Theme.swift` for every color, radius and type size. `.monospacedDigit()` on the capture age.

**Status must never be conveyed by color alone** — every state carries an icon and words as well. That is a standing rule in this project and an accessibility requirement.

- [ ] **Step 4: Verify visually — do not skip this**

```bash
./build.sh --install && open -a Burnline
```

Screenshot the window in each of the four states. Three defects in this project were invisible in code review and obvious in a picture; this window has more system controls than any other and is the most likely place for the light-mode-controls bug to reappear.

To force each state, edit a **copy** of settings.json and point a debug build at a temp directory — do not experiment against your real `~/.claude/settings.json`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Burnline/OnboardingView.swift Sources/Burnline/BurnlineApp.swift
git commit -m "feat: first-run onboarding window for the statusline capture"
```

---

### Task 5: The poller's first-enable confirmation

**Files:**
- Modify: `Sources/Burnline/SettingsView.swift`
- Modify: `Sources/Burnline/OnboardingView.swift` (if the toggle is mirrored there)

`refreshesUsageAutomatically` is already correctly `false` by default, with the
reasoning recorded in `BurnlineSettings`: *"reading files is one kind of app, and
spawning processes on someone's machine is another."* That protects a user who
never touches the setting. It says nothing to one who flips it because the label
sounded useful.

- [ ] **Step 1: Write the confirmation**

An alert on the transition **off → on** only. It must state: it starts
short-lived Claude Code sessions; those sessions talk to Anthropic; it costs no
model tokens because `/usage` produces no assistant turn (measured, not assumed);
it runs at most once per the configured interval; it can be turned off at any
time.

Confirm / Cancel. **Cancel must leave the setting off** — verify the binding
actually reverts rather than rendering stale.

- [ ] **Step 2: Shown once per enable, not once ever**

No `hasSeenPollerWarning` flag. Someone re-enabling this a year later, or on a
new machine, deserves the same sentence. It is two clicks on a setting nobody
toggles often.

- [ ] **Step 3: Verify both paths by hand**

Toggle on → cancel → setting still off, no process spawned (`pgrep -f "claude --model haiku"`).
Toggle on → confirm → setting on, and a poll eventually runs
(`BURNLINE_POLL_LOG=/tmp/poll.log`).

- [ ] **Step 4: Screenshot it** in dark mode, system alert included.

- [ ] **Step 5: Commit**

---

### Task 6: Surface "Claude Code not found"

**Files:**
- Modify: `Sources/Burnline/UsagePoller.swift` (expose the resolution result)
- Modify: `Sources/Burnline/SettingsView.swift`

`resolveClaude()` checks `PATH` plus four known locations, which correctly fixes
the Finder-launched-app PATH problem. It does not cover nvm, asdf, or a custom
prefix — and when it misses, **the poll does nothing forever and the only
diagnostic is an environment variable.** A user who enables the setting and gets
silence cannot distinguish that from a working poller with nothing to do.

This is the same silent-failure class Plan 4 existed to remove.

- [ ] **Step 1: Make the resolution result observable**

Lift `resolveClaude()` to something the UI can query without spawning anything.
Keep it cheap — it is four `isExecutableFile` calls.

- [ ] **Step 2: Show it beside the toggle**

Found → the resolved path, muted, monospaced.
Not found → *"Claude Code not found — automatic refresh will do nothing"*, with
the searched locations. **Word + icon + colour, never colour alone.**

- [ ] **Step 3: Test the negative case**

The path that matters and the one that will rot. Inject the candidate list rather
than depending on the machine's real installation, so the not-found branch is
covered in CI where `claude` may not exist at all.

- [ ] **Step 4: Commit**

---

### Task 7: End-to-end on a clean account

The only test that proves this works for someone who is not you.

- [ ] **Step 1:** Create a fresh macOS user account (System Settings → Users & Groups).
- [ ] **Step 2:** Install Claude Code there and run one session, so `~/.claude` exists.
- [ ] **Step 3:** Copy `Burnline.app` over and launch it. Onboarding must appear unprompted.
- [ ] **Step 4:** Click **Set up automatically**, then send a message in Claude Code.
- [ ] **Step 5:** Within 30 seconds the window reads "Connected", and the menu bar shows a live figure rather than pace-only.
- [ ] **Step 6:** Re-run with a foreign `statusLine` in place and confirm the app **refuses** and shows the snippet.

---

## Done when

- [ ] `swift test` green, ~230 tests
- [ ] All four states screenshotted and correct in dark mode, system controls included
- [ ] A foreign statusline is never overwritten, verified by hand
- [ ] A clean user account goes from install to `.live` without reading any documentation
