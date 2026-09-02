import SwiftUI
import BurnlineCore

enum HistoryWindow {
    static let id = "burnline-history"

    /// Both halves required, same as `SettingsWindow` and `OnboardingWindow`: an
    /// `LSUIElement` process is never activated, so `openWindow` alone creates
    /// the window behind everything and the click reads as a dead button.
    @MainActor
    static func open(using openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The History window: week-over-week totals, overlaid burn curves, and where
/// the units went.
///
/// Everything drawn here comes from one `HistoryViewModel`, loaded off the main
/// actor. **Nil is the loading state** and is not the same as an empty archive —
/// the launch fill is a measured 20 seconds over a real corpus, which is long
/// enough for someone to reach the wrong conclusion and act on it, so the fill's
/// own progress is shown while it runs.
///
/// 🔴 **The model is a snapshot of a file the window does not own.** The launch
/// fill and the 60-second flush both write the archive from outside this view,
/// so every reload trigger has to be declared in `LoadKey`. Miss one and the
/// window is not slow, it is wrong: it keeps drawing an archive that stopped
/// existing, and looks settled while it does it.
struct HistoryView: View {
    @Bindable var store: UsageStore

    /// ⚠️ Resolved once for the process, not per view init. A `@State` initial
    /// value expression is evaluated every time the view struct is created —
    /// which is every redraw — and `historyDirectory()` creates a directory on
    /// the way past. The override it honours is read from the environment at
    /// launch and cannot change afterwards, so there is nothing to re-resolve.
    private enum Directory {
        static let url = ApplicationSupport.historyDirectory()
    }

    @State private var loader = HistoryLoader(directory: Directory.url)
    @State private var model: HistoryViewModel?
    @State private var dimension: HistoryQuery.Dimension = .project
    /// Unresolved until the archive is read — the loader turns it into the most
    /// recent complete window, and `model.range` is what the picker displays.
    @State private var range: HistoryRange = .newestWindow

    /// Which series the chart area is drawing.
    ///
    /// ⚠️ **Not persisted, and it starts on `.units` every time.** A toggle's
    /// cost is a mode you can occupy without noticing, and a restored mode is
    /// one nobody chose in this sitting. Units is also the mode that has data
    /// for every archived week; percent is sparse by construction and only
    /// fills in going forward.
    ///
    /// Deliberately NOT part of `LoadKey`: both series come off the same read,
    /// so flipping this redraws and never touches disk.
    @State private var chartMode: HistoryChartMode = .units

    /// The fill phase the model on screen was read under, so a reload knows
    /// whether the archive can have changed under it.
    @State private var loadedPhase: HistoryFillState.ReloadPhase?

    /// What a reload depends on. `.task(id:)` runs once when the window opens
    /// and again when one of these changes — not on every redraw, which is the
    /// whole reason the read is not in a view body.
    ///
    /// 🔴 **The fill phase is a load input, not decoration.** Without it the
    /// window read the archive once, on open, and never again: on a first run
    /// that read lands before the fill has written anything, so the window sat
    /// on "Nothing archived yet" while six weeks were committed behind it, and
    /// only a close-and-reopen showed them. The archive is written by something
    /// this view does not drive, so the view has to be told when it moved.
    private struct LoadKey: Equatable {
        let dimension: HistoryQuery.Dimension
        let range: HistoryRange
        let fill: HistoryFillState.ReloadPhase
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                fillFailure

                switch store.historyFillState.display(archiveIsEmpty: model?.isEmpty) {
                case .filling(let progress):
                    filling(progress)
                case .loading:
                    loading
                case .empty:
                    emptyArchive
                case .content:
                    if let model { sections(model) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task(id: LoadKey(dimension: dimension, range: range,
                          fill: store.historyFillState.reloadPhase)) {
            await load()
        }
    }

    private func load() async {
        // Read on the main actor, then hand plain values across. The snapshot's
        // window is what puts the live week on the chart, and it has no
        // `WindowRow` — one is only written once a window closes.
        let phase = store.historyFillState.reloadPhase
        let window = store.snapshot.window
        let weights = store.settings.weights

        // The loader holds its read for 15 seconds so the pickers never hit
        // disk. A fill that has just changed phase is the one case where that
        // cache is guaranteed to be the stale answer, so it is dropped here and
        // nowhere else: a picker change still re-aggregates from memory.
        if phase != loadedPhase { await loader.invalidate() }
        let loaded = await loader.viewModel(dimension: dimension, range: range,
                                            currentWindow: window, weights: weights)

        // A superseded read must never land on top of a newer one. `.task(id:)`
        // cancels the outgoing task, but a cancelled task still resumes and
        // would otherwise assign — which is this defect again, in miniature.
        guard !Task.isCancelled else { return }
        loadedPhase = phase
        model = loaded
    }

    // MARK: - Sections

    @ViewBuilder private func sections(_ model: HistoryViewModel) -> some View {
        Text("Completed weeks").eyebrow()
        if model.scoreboard.isEmpty {
            // Reachable: the live week has cells to draw a curve from long
            // before any window has closed. A bare column header over nothing
            // would read as a table that failed to load.
            Text("The first week appears after your next reset.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        } else {
            HistoryScoreboard(rows: model.scoreboard,
                              selected: selection(model),
                              explainsMissingPercentages: model.noPercentagesRecorded,
                              select: { range = $0 })
        }

        Divider().overlay(Theme.hairline).padding(.vertical, 2)

        burnCurves(model)

        Divider().overlay(Theme.hairline).padding(.vertical, 2)

        Text("Where it went").eyebrow()
        HistoryBreakdown(rows: model.breakdown,
                         total: model.breakdownTotal,
                         windows: model.scoreboard.map(\.window),
                         dimension: $dimension,
                         range: rangeBinding(model))
    }

    /// One chart area, two series, a segmented control between them.
    ///
    /// 🔴 **The heading is not the mode indicator — the subtitle, the caveat and
    /// the y-axis unit are.** All three change with `chartMode`, and none of
    /// them is written here: `HistoryChartMode` owns every one, because
    /// `Sources/Burnline` has no test target and a rule spelled inline in a
    /// `body` is a rule nothing can hold upright. Reading a percent trend while
    /// believing it is the units curve is a wrong conclusion, not a cosmetic
    /// slip — the two series have opposite blind spots.
    @ViewBuilder private func burnCurves(_ model: HistoryViewModel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Burn curves").eyebrow()
                Text(chartMode.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                modePicker
            }

            Text(chartMode.caveat)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            switch chartMode {
            case .units:
                HistoryBurnCurves(curves: model.curves,
                                  nowFraction: store.snapshot.window.elapsedFraction)
            case .percent:
                HistoryPercentTrend(curves: model.percentCurves,
                                    nowFraction: store.snapshot.window.elapsedFraction)
            }
        }
    }

    private var modePicker: some View {
        // ⚠️ A real label, then `.labelsHidden()`. Visually identical to an
        // empty string and the difference is the whole accessible name: an
        // unnamed segmented control announces only its selected segment.
        Picker("Chart series", selection: $chartMode) {
            ForEach(HistoryChartMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        // ⚠️ `.tint` genuinely lands on a segmented picker, unlike on
        // `.borderedProminent`, which ignores it and renders a grey system pill
        // (see `AccentButtonStyle`). Two system controls, opposite behaviour;
        // the documented trap about one is not evidence about the other. Without
        // this the selected segment inherits the *system* accent and comes out
        // macOS blue in an app whose accent is violet — invisible in the source,
        // obvious in a screenshot.
        .tint(Theme.accent)
        .labelsHidden()
        .frame(width: 150)
    }

    /// The selection to display, which is not always the one that is loaded.
    ///
    /// Only the *unresolved* default defers to the model — that is how "the most
    /// recent complete window" can be the initial selection without this view
    /// knowing which window that is, and without a resolution write-back that
    /// would cost a second load on every open. Once the user has picked
    /// something, their choice shows immediately rather than snapping back to
    /// the old value for as long as the reload takes.
    private func selection(_ model: HistoryViewModel) -> HistoryRange {
        range == .newestWindow ? model.range : range
    }

    private func rangeBinding(_ model: HistoryViewModel) -> Binding<HistoryRange> {
        Binding(get: { selection(model) }, set: { range = $0 })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Usage history").eyebrow()
            if let coverageDescription {
                Text(coverageDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ⚠️ Named plainly, because "units" is Burnline's own scale and
            // means nothing on its own. The absolute value is arbitrary by
            // construction — calibration divides it out — so the only claim
            // being made is that one week compares to another.
            Text("Units are Burnline's own weighted measure, not tokens or percent. The "
                 + "scale is arbitrary; only week-to-week comparison means anything. "
                 + "This Mac's Claude Code only.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let model, model.hasGaps {
                warning("The history has gaps. Usage during them is unknown, not zero. "
                        + "Affected weeks are marked below; their totals are floors.",
                        symbol: "exclamationmark.triangle.fill")
            }
            if let model, model.skippedLines > 0 {
                warning("\(model.skippedLines) archive entries could not be read and were "
                        + "skipped. Everything else is intact.",
                        symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// The header's one line about how far back the history goes — nil unless
    /// there is a date to name.
    ///
    /// It used to fall back to "Nothing archived yet" once the fill had
    /// finished. That was already guarded against asserting finality over a
    /// running progress bar, which was the first-run defect; what the guard
    /// could not fix is that the *finished* case renders three lines above
    /// `emptyArchive`'s own headline, so one state got announced twice in two
    /// wordings. Absence is that state's to report, and it reports it better.
    private var coverageDescription: String? {
        if let begins = model?.coverageBegins {
            // Claude Code deletes transcripts after 30 days, so this is a real
            // horizon rather than a starting point that will keep receding.
            return "Archived from \(HistoryLabels.day(begins)). Earlier weeks are gone: "
                + "Claude Code deletes transcripts after 30 days."
        }
        // 🔴 Nil, not "Nothing archived yet." That headline could render three
        // lines above `emptyArchive`'s own — two announcements of one state, in
        // two wordings, one of them a subtitle to a heading it contradicts. The
        // empty state below is the one that owns this, and it says what happens
        // next rather than only what is absent.
        return nil
    }

    // MARK: - States

    /// The launch fill, which is ~20 seconds over a full corpus.
    ///
    /// 🔴 **Determinate, and it says the work is one-off.** A bare spinner at
    /// that length reads as a hang, and this runs on someone's first launch,
    /// before they have any reason to extend the app credit. The count is the
    /// denominator the fill goes to the trouble of settling before it opens a
    /// single file.
    private func filling(_ progress: HistoryFill.Progress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Building your usage history")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Reading the transcripts Claude Code still has. One-time, about 20 "
                 + "seconds. You can close this window.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: progress.fraction)
                .tint(Theme.accent)
                .padding(.top, 1)
            Text("\(progress.filesOpened) of \(progress.filesTotal) transcripts")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    /// Tolerated, never silent: the archive is short by however much that range
    /// held, and nothing else on screen would say so.
    @ViewBuilder private var fillFailure: some View {
        if case .failed(let message) = store.historyFillState {
            warning("Some transcripts could not be read, so the history may have gaps. "
                    + "Burnline retries next launch. (\(message))",
                    symbol: "exclamationmark.triangle.fill")
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the archive…")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 30)
    }

    /// 🔴 Only reachable once the fill has finished — `HistoryFillState.display`
    /// is what guarantees that. "Still filling" and "genuinely empty" mean
    /// opposite things, and this copy makes a claim about the future that is
    /// simply false while transcripts are still being read.
    private var emptyArchive: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No completed weeks yet.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("The first week appears after your next reset.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 24)
    }

    /// Symbol + word + colour. Never colour alone.
    private func warning(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.warning)
    }
}
