import Foundation
import Observation
import UserNotifications
import BurnlineCore

// `HistoryFillState` is in `BurnlineCore`, next to the two rules it carries:
// which transitions force the History window to re-read the archive, and what
// that window draws for each state. Both are tested there.

/// Decides which of a fill's progress reports are worth a hop to the main actor.
///
/// A full corpus is ~2,470 files. Publishing every one would be ~2,470 hops to
/// move a bar by 0.04% each — and the fill runs off the main actor precisely so
/// the menu bar comes up while it works, so flooding the actor with updates
/// hands back the thing being bought. **The stride is 25 files**: ~100 updates
/// across the measured 20.4 seconds, smooth to the eye and nothing to the actor.
///
/// Files rather than milliseconds, because this fires thousands of times and a
/// file count is already in hand where a clock read would not be.
///
/// The first and last reports pass whatever the stride says. The first is what
/// turns an indeterminate spinner into a real denominator; the last is what
/// proves the range finished, and a bar frozen at 2,450 of 2,470 is exactly the
/// hang this was built to stop showing.
private final class ProgressGate: @unchecked Sendable {
    private static let filesBetweenUpdates = 25

    private let lock = NSLock()
    private var lastPublished = -1

    func admits(_ progress: HistoryFill.Progress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard progress.filesOpened != lastPublished else { return false }
        guard progress.filesOpened == 0
                || progress.filesOpened == progress.filesTotal
                || progress.filesOpened - lastPublished >= Self.filesBetweenUpdates
        else { return false }
        lastPublished = progress.filesOpened
        return true
    }
}

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot: Snapshot
    private(set) var isScanning = false

    /// How the launch fill is going. Observed, so a History window can show real
    /// progress for the 20.4 seconds rather than a spinner that reads as a hang.
    private(set) var historyFillState: HistoryFillState = .idle

    /// Written through to disk on every mutation, so SwiftUI bindings in the
    /// settings window persist without any explicit save step.
    @ObservationIgnored private var storedSettings: BurnlineSettings
    var settings: BurnlineSettings {
        get {
            access(keyPath: \.settings)
            return storedSettings
        }
        set {
            // Single choke point for validation, so a hand-edited settings.json
            // is covered as well as the Settings text fields.
            var sanitized = newValue
            sanitized.weights = newValue.weights.sanitized()
            sanitized.notifications = newValue.notifications.sanitized()
            withMutation(keyPath: \.settings) { storedSettings = sanitized }
            try? settingsStore.save(sanitized)
            rebuild()
        }
    }

    /// What `~/.claude/settings.json` says about the statusline.
    ///
    /// Deliberately **not** refreshed on the capture timer. It only changes when
    /// the user (or this app) edits that file, so re-parsing someone's JSON
    /// every tick forever would buy nothing — and it would be doing it to drive
    /// an indicator in a window that is usually closed. Refreshed when the
    /// onboarding window appears, and after we write.
    private(set) var wiringState: StatuslineWiring.State = .noSettingsFile
    /// Non-nil when we could not read or write the settings file. Distinct from
    /// a conflict: a conflict is a decision, this is a failure.
    private(set) var wiringError: String?

    @ObservationIgnored private var cache: ScanCache
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let cacheStore = CacheStore()
    @ObservationIgnored private let rateLimitStore = RateLimitStore()
    @ObservationIgnored private let captureDirectory = CaptureDirectory()
    @ObservationIgnored private let utilizationStore = UtilizationStore()
    @ObservationIgnored private let poller = UsagePoller()
    @ObservationIgnored private var lastPollAt: Date?
    @ObservationIgnored private let highWaterStore = HighWaterStore()
    @ObservationIgnored private var highWater = HighWaterStore().load()

    @ObservationIgnored private let marksStore = NotificationMarksStore()
    @ObservationIgnored private var notificationMarks = NotificationMarksStore().load()
    @ObservationIgnored private let notifier = Notifier()

    /// Refreshed when Settings appears, and after the toggle changes it — not
    /// on the capture timer; it only changes when the user acts.
    private(set) var notificationAuthorization: UNAuthorizationStatus?

    /// The archive's sole writer, built once and never replaced. Two paths feed
    /// it — the launch fill and the 60s flush — and the serialization that makes
    /// them safe is a property of this one instance.
    ///
    /// The schedule is a snapshot of the settings at launch. It is only the
    /// fallback for window bounds on a machine that has never seen a capture, so
    /// a mid-session change taking effect at the next launch is a fair trade for
    /// keeping a single writer.
    @ObservationIgnored private let historyWriter: HistoryWriter
    @ObservationIgnored private let historyFill = HistoryFill(rootURL: TranscriptScanner.defaultRoot)
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    /// The live capture as the archive wants it, refreshed on every rebuild.
    /// Nil whenever the capture is not Anthropic's own figure for the window now
    /// on screen.
    @ObservationIgnored private var currentObservation: TrackingEntry?
    /// The last entry handed to the writer. Saves an actor hop and a file read
    /// every 10 seconds forever; `HistoryWriter.observe` stays the authority on
    /// what the archive already holds.
    @ObservationIgnored private var lastObservationSent: TrackingEntry?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var isRefreshing = false

    /// The transcript scan — the expensive half, 36ms warm and ~6s cold.
    private static let scanInterval: Duration = .seconds(60)
    /// Re-reading the capture: 141 bytes and a pure rebuild. It used to be
    /// welded to the scan, so a capture landing just after a tick sat unread for
    /// most of a minute even though the statusline writes every 30s.
    private static let captureInterval: Duration = .seconds(10)
    /// Floor between popover-triggered refreshes.
    private static let manualRefreshFloor: TimeInterval = 5

    init() {
        // Sanitize on load, not just on write: the settings setter is the choke
        // point for mutations, but a hand-edited settings.json (say,
        // `behindPacePoints: 0`) would otherwise be live from launch until the
        // first mutation.
        var loadedSettings = settingsStore.load()
        loadedSettings.weights = loadedSettings.weights.sanitized()
        loadedSettings.notifications = loadedSettings.notifications.sanitized()
        let loadedCache = cacheStore.load()
        storedSettings = loadedSettings
        cache = loadedCache
        historyWriter = HistoryWriter(
            store: HistoryStore(directory: ApplicationSupport.historyDirectory()),
            schedule: loadedSettings.resetSchedule
        )
        // A cold cache means the first scan is a few seconds; say so in the label.
        snapshot = SnapshotBuilder.build(cache: loadedCache, settings: loadedSettings,
                                         now: Date(), isScanning: loadedCache.files.isEmpty)
    }

    func start() {
        guard scanTask == nil else { return }

        notifier.activate()
        refreshNotificationAuthorization()

        startHistoryFill()

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: UsageStore.scanInterval)
            }
        }

        // Decoupled from the scan on purpose. Rebuilding is a 141-byte read and
        // a pure snapshot build, so pacing it to the cost of the scan was
        // wasting most of a minute of freshness for nothing. It also makes the
        // pace target advance smoothly instead of stepping once a minute.
        // Sleeps first: `refresh()` above already rebuilds at launch.
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: UsageStore.captureInterval)
                guard !Task.isCancelled else { return }
                // No `await`: `Task {}` inherits this class's MainActor
                // isolation, so `rebuild()` is already on the right actor.
                self?.rebuild()
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        captureTask?.cancel()
        captureTask = nil
        fillTask?.cancel()
        fillTask = nil
    }

    // MARK: - History archive

    /// Archives every bucket range the archive does not already hold, back to
    /// one day past Claude Code's 30-day `cleanupPeriodDays` default — far
    /// enough to reach everything that can still exist, without walking further
    /// back on every launch forever.
    ///
    /// ⚠️ **Detached and deliberately never awaited.** Over a full corpus this
    /// is 15–25 seconds of file I/O, and the menu bar has to be live long before
    /// that; nothing in the UI may wait on it.
    ///
    /// It collides with the first flush on the very first launch, because
    /// `start()` kicks `refresh()` immediately. That is expected: `HistoryWriter`
    /// is what serializes the two, and a second guard here would only hide the
    /// case it already handles.
    private func startHistoryFill() {
        let writer = historyWriter
        let fill = historyFill
        fillTask = Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            let horizon = Int(now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970)
            // A read hint only — it narrows which transcripts get opened. The
            // writer re-decides what is genuinely uncovered at commit, inside
            // the actor, so a range that went stale in between is harmless.
            let uncovered = await writer.currentCoverage()
                .uncovered(from: horizon, through: Int(now.timeIntervalSince1970))

            var failure: String?

            for range in uncovered {
                // Nothing is published on cancellation. `stop()` is the app
                // going away, so the last state anyone could see is moot.
                guard !Task.isCancelled else { return }

                // Per range, because each range counts its own files. A second
                // range restarts the bar, which is honest — the total genuinely
                // changed — and on the launch this matters for there is one.
                let gate = ProgressGate()
                do {
                    let result = try fill.cells(
                        from: Date(timeIntervalSince1970: Double(range.lowerBound)),
                        to: Date(timeIntervalSince1970: Double(range.upperBound))
                    ) { progress in
                        // Synchronous, called from the fill's own thread: it
                        // cannot await the main actor without giving back the
                        // 20 seconds of responsiveness this whole path buys.
                        // So the hop is fire-and-forget, and `publish` is what
                        // copes with the reports arriving out of order.
                        guard gate.admits(progress) else { return }
                        Task { @MainActor in self?.publishFillProgress(progress) }
                    }

                    // The span reaches `now`, which is inside the still-filling
                    // bucket. `HistoryWriter.commit` clamps it — clamping here as
                    // well would drop a bucket the flush is entitled to restate.
                    await writer.commit(payload: .init(rows: result.rows, span: range,
                                                       truncated: result.truncated),
                                        filledBy: "fill", observation: nil)
                } catch {
                    // A range that could not be read claims no coverage: skipping
                    // the commit leaves it uncovered for the next launch to retry,
                    // where claiming a range never written is unrecoverable.
                    // Recorded rather than thrown, so one bad range does not cost
                    // the others — but it must still reach the UI, because a fill
                    // that quietly did less than it said is how a gap goes unseen.
                    failure = error.localizedDescription
                }
            }

            await self?.finishHistoryFill(failure: failure)
        }
    }

    /// Publishes a progress report, ignoring any that would walk the bar
    /// backwards or reopen a finished fill.
    ///
    /// The reports leave the fill in order and arrive here as unordered
    /// fire-and-forget hops, so the ordering guarantee has to be re-established
    /// on this side. `filesTotal` is part of the comparison because it is fixed
    /// within a range: without it, this would suppress the next range's opening
    /// report for looking like a regression.
    private func publishFillProgress(_ progress: HistoryFill.Progress) {
        if case .complete = historyFillState { return }
        if case .failed = historyFillState { return }
        if case .filling(let current) = historyFillState,
           current.filesTotal == progress.filesTotal,
           current.filesOpened > progress.filesOpened { return }
        historyFillState = .filling(progress)
    }

    /// The terminal state, and the one a UI actually branches on: past this
    /// point an empty archive means empty, not "not yet".
    private func finishHistoryFill(failure: String?) {
        historyFillState = failure.map { .failed($0) } ?? .complete
    }

    /// The archive's forward path, run after every successful scan.
    ///
    /// Off the main actor throughout: `payload` walks every cell in the cache
    /// and the commit is file I/O. Awaiting it does not block the UI — the main
    /// actor is free while it runs — and it keeps the flush ordered behind the
    /// scan that produced it.
    private func flushHistory(cache: ScanCache, observation: TrackingEntry?, now: Date) async {
        let writer = historyWriter
        await Task.detached(priority: .utility) {
            // Again a read hint, narrowing what the payload has to compute.
            let payload = HistoryArchive.payload(from: cache,
                                                 coverage: await writer.currentCoverage(),
                                                 through: Int(now.timeIntervalSince1970))
            await writer.commit(payload: payload, filledBy: "scan", observation: observation)
        }.value
    }

    /// Called when the popover opens. Debounced so repeated clicks don't rescan.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > Self.manualRefreshFloor else { return }
        Task { await refresh() }
    }

    func refresh() async {
        // `lastRefresh` isn't set until a scan finishes, so during a cold scan
        // the debounce above lets every popover open start another one. One at a
        // time: a second scan of the same tree would only repeat the work.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        isScanning = true
        rebuild()

        let scanner = TranscriptScanner()
        let current = cache
        let now = Date()
        let store = cacheStore

        // ScanCache, TranscriptScanner and CacheStore are all Sendable,
        // so the scan hops off the main actor cleanly with no locking. Persisting
        // goes with it: the cache is a few hundred KB and encoding it has no
        // business on the UI thread.
        let updated = await Task.detached(priority: .utility) {
            guard let scanned = try? scanner.scan(cache: current, now: now) else { return current }
            // Only when something actually moved. The timer fires every 60s
            // whether or not Claude Code ran, and an idle machine would otherwise
            // rewrite the whole cache overnight for no change at all.
            if scanned != current { try? store.save(scanned) }
            return scanned
        }.value

        cache = updated
        lastRefresh = Date()
        isScanning = false
        rebuild()

        // After the rebuild, so the observation handed to the writer is the one
        // that matches the snapshot now on screen. `now` is the scan's clock,
        // not a fresh one: the cache was built against it, so anything later
        // would claim coverage for buckets this scan never read.
        await flushHistory(cache: updated, observation: currentObservation, now: now)

        // On the 60s scan path, not the 10s rebuild: this is directory I/O plus
        // deletes. Placed after `rebuild()` so `snapshot.window` is the current
        // one — pruning from inside `rebuild()` would, for one tick after a
        // reset, prune against the previous window and delete the very capture
        // proving the new one had started.
        captureDirectory.prune(before: snapshot.window.start.timeIntervalSince1970)

        // Last, and only when the anchor has actually gone stale. Nothing else
        // on this Mac will move it: an idle session republishes its cached
        // reading forever, and a desktop session never publishes at all.
        // Adaptive: the tighter the pressure on any limit, the more often the
        // anchor is worth 3.5 CPU-seconds and a ~27s process.
        let interval = PollDecision.interval(
            weeklyPercent: snapshot.estimatedPercent,
            fiveHourPercent: snapshot.fiveHour?.usedPercent,
            projectedPercent: snapshot.projectedPercent,
            ceiling: storedSettings.usageRefreshInterval)

        if PollDecision.shouldPoll(enabled: storedSettings.refreshesUsageAutomatically,
                                   anchorAge: snapshot.liveAge,
                                   lastPollAt: lastPollAt,
                                   interval: interval,
                                   now: Date()) {
            lastPollAt = Date()
            await poller.poll()
            // The poll refreshed ~/.claude.json, not our own files.
            rebuild()
        }
    }

    /// Where `claude` was found, or nil if it wasn't.
    ///
    /// Cached rather than resolved in a view body: it is four `stat` calls, and
    /// it only changes when the user installs or moves Claude Code. Refreshed
    /// when Settings appears.
    private(set) var claudeExecutable: String?

    func refreshClaudeExecutable() {
        claudeExecutable = ClaudeExecutable.resolve()
    }

    /// True while a manual check is running, so the button can say so. A poll
    /// takes roughly half a minute; without feedback it looks like nothing
    /// happened.
    private(set) var isPolling = false

    /// Refresh the anchor right now, because the user asked.
    ///
    /// Deliberately independent of `refreshesUsageAutomatically`. That setting
    /// governs whether Burnline may start a Claude Code session *on its own
    /// initiative*, which is the part that warrants an up-front confirmation.
    /// Pressing a button labelled "Check now" is the consent, and it gives
    /// people who would rather nothing ran in the background a way to get a
    /// current figure on demand.
    ///
    /// Does nothing if Claude Code cannot be found; the popover hides the button
    /// in that case rather than leaving a control that cannot work.
    func pollNow() async {
        guard !isPolling, ClaudeExecutable.resolve() != nil else { return }
        isPolling = true
        defer { isPolling = false }

        lastPollAt = Date()
        await poller.poll()
        // The poll refreshes ~/.claude.json, not our own files, so a rebuild is
        // what surfaces it.
        rebuild()
    }

    // MARK: - Statusline wiring

    /// The capture helper inside *this* bundle.
    ///
    /// Resolved at runtime, never hardcoded: the user may have Burnline
    /// somewhere other than /Applications, and moving it must not silently
    /// break the statusline. `StatuslineWiring.stalePath` is what detects that
    /// afterwards, and it can only work if this is the real current path.
    var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/burnline-statusline")
            .path
    }

    func refreshWiringState() {
        do {
            wiringState = StatuslineWiring.state(
                settings: try ClaudeSettingsFile().read(), helperPath: helperPath
            )
            wiringError = nil
        } catch {
            // A settings.json we cannot parse is the user's to fix, and we must
            // not offer to overwrite it. Reported as a conflict so the
            // automatic button stays hidden, plus an explicit error so the
            // window can say what actually went wrong.
            wiringState = .conflict(command: "")
            wiringError = "~/.claude/settings.json could not be read: \(error.localizedDescription)"
        }
    }

    /// Writes our statusline into `~/.claude/settings.json`.
    ///
    /// Guarded on `isAutomaticallyFixable`, so a foreign statusline is never
    /// overwritten even if a caller asks. `ClaudeSettingsFile` backs the file up
    /// first regardless.
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

    /// Marks onboarding as offered. Called once at launch whatever the user
    /// then does — declining is an answer.
    func markOnboardingSeen() {
        guard !storedSettings.hasSeenOnboarding else { return }
        var updated = storedSettings
        updated.hasSeenOnboarding = true
        settings = updated
    }

    /// Records a `/usage` reading as a calibration anchor. Only a fallback now —
    /// a live capture takes precedence over anchors.
    func calibrate(observedPercent: Double) {
        let now = Date()
        // Anchor against the window actually on screen, which may have come
        // from a live capture rather than the configured schedule.
        let window = snapshot.window
        let units = cache.units(from: window.start, to: window.end, weights: storedSettings.weights)
        var updated = storedSettings
        updated.calibrationAnchors.append(
            CalibrationAnchor(timestamp: now, observedPercent: observedPercent, unitsInWindow: units)
        )
        // Prune on write. `validAnchors` only filters what the fit may use, so
        // without this the stored list — and the Settings display — grows forever.
        updated.calibrationAnchors = Calibration.retained(updated.calibrationAnchors, now: now)
        settings = updated
    }

    func removeAnchor(_ anchor: CalibrationAnchor) {
        var updated = storedSettings
        updated.calibrationAnchors.removeAll { $0.id == anchor.id }
        settings = updated
    }

    private func rebuild() {
        // Re-read every time: the statusline script rewrites this file from
        // another process whenever Claude Code produces a response.
        //
        // Reconcile against the high-water mark before trusting it. Every open
        // Claude Code session writes this same file on its own timer, and an idle
        // one keeps publishing the stale rate_limits snapshot it started with —
        // so the last writer is routinely not the freshest.
        //
        // Dating happens here, not in the helper: reading a transcript is file
        // I/O, and the helper runs every 30s in every open session under a
        // contract that it never fails and never delays the user's prompt.
        // Per-session files plus the shared one, all dated, freshest wins. The
        // shared file competes on equal terms rather than being preferred or
        // ignored: the rollback script writes only it, and so does a payload
        // that carries no session_id.
        // Three sources now, competing on age with no precedence between them:
        // per-session statusline captures, the shared statusline file, and
        // `cachedUsageUtilization` from ~/.claude.json. The last carries its own
        // explicit `fetchedAtMs` and no session, so dating leaves it alone.
        let utilization = utilizationStore.load()
        let dated = (captureDirectory.load()
                     + [rateLimitStore.load()].compactMap { $0 }
                     + [utilization?.asCapture()].compactMap { $0 })
            .map { loaded in
                loaded.dated(mintedAt: loaded.transcriptPath.flatMap {
                    TranscriptDating.mintedAt(transcriptPath: $0, observedAt: loaded.capturedAt)
                })
            }
        var capture = CaptureDirectory.freshest(of: dated)
        // Kept so the popover can say the file was overridden. Silently
        // disagreeing with the user's own terminal status line reads as a broken
        // app rather than as the protection it is.
        var rejected: RateLimitHighWater.RejectedReading?
        if let incoming = capture {
            let (resolved, mark) = RateLimitHighWater.reconcile(incoming, against: highWater)
            rejected = RateLimitHighWater.rejection(onDisk: incoming, resolved: resolved)
            capture = resolved
            if mark != highWater {
                highWater = mark
                try? highWaterStore.save(mark)
            }
        }

        snapshot = SnapshotBuilder.build(cache: cache, settings: storedSettings,
                                         rateLimit: capture,
                                         now: Date(), isScanning: isScanning,
                                         rejected: rejected,
                                         scopedWeekly: utilization?.scopedWeekly)

        // Before the observation feed's guards: the evaluation must run on
        // every rebuild, and the block below returns early.
        evaluateNotifications()

        // The archive's observation feed. Gated on `capturedPercent` rather than
        // on the capture existing: that is non-nil only when the reading is
        // Anthropic's own figure for the window now on screen, so an
        // extrapolated percentage — or one belonging to a window that has
        // already reset — can never reach a file that cannot be recomputed.
        //
        // `capture` is the high-water-reconciled reading the snapshot was built
        // from, so both halves of the entry come from the same capture.
        guard snapshot.capturedPercent != nil, let capture else {
            currentObservation = nil
            return
        }
        let entry = TrackingEntry(percent: capture.sevenDay.usedPercent,
                                  at: capture.capturedDate,
                                  resetsAt: capture.sevenDay.resetsDate)
        currentObservation = entry

        // Fire and forget. `rebuild()` is @MainActor and runs every 10 seconds
        // plus on every settings mutation — it may never wait on the actor, and
        // it may never write a file itself.
        guard entry != lastObservationSent else { return }
        lastObservationSent = entry
        let writer = historyWriter
        Task.detached(priority: .utility) { await writer.observe(entry) }
    }

    // MARK: - Notifications

    /// The notification evaluation site: every rebuild, so both the 10s loop
    /// and settings edits are covered. All decisions are in
    /// `NotificationDecision`; this only persists marks and hands off I/O.
    private func evaluateNotifications() {
        // Never mint a mark for a notification the system would drop: while
        // authorization is undetermined, denied, or not yet read, skip
        // evaluation entirely — the crossing then fires (late, once) when
        // permission arrives and the next rebuild runs.
        guard notificationAuthorization == .authorized
                || notificationAuthorization == .provisional else { return }
        let (emissions, updated) = NotificationDecision.evaluate(
            snapshot: snapshot,
            settings: storedSettings.notifications,
            targetMode: storedSettings.targetMode,
            marks: notificationMarks)
        if updated != notificationMarks {
            notificationMarks = updated
            // Fire and forget: rebuild() may never write a file itself. Saves
            // are unordered and can be lost to a quit; both are bounded by the
            // same worst case the marks versioning accepts — one repeated
            // notification at the next launch.
            let store = marksStore
            Task.detached(priority: .utility) { try? store.save(updated) }
        }
        guard !emissions.isEmpty else { return }
        // Residual race: a revocation in System Settings mid-run leaves
        // `notificationAuthorization` stale until the next refresh — bounded by
        // the same one-repeated-or-one-lost-notification worst case the marks
        // already accept.
        notifier.deliver(emissions)
    }

    /// The master-toggle path. Turning it on requests notification permission
    /// if the system has never asked — keyed on `.notDetermined`, not a stored
    /// flag, so resetting permissions re-asks on the next enable.
    func setNotificationsEnabled(_ enabled: Bool) {
        var updated = storedSettings
        updated.notifications.enabled = enabled
        settings = updated
        guard enabled else { return }
        Task {
            await notifier.requestAuthorizationIfNeeded()
            notificationAuthorization = await notifier.authorizationStatus()
        }
    }

    func refreshNotificationAuthorization() {
        Task { notificationAuthorization = await notifier.authorizationStatus() }
    }
}
