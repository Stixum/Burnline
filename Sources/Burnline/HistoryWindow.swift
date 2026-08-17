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

    /// What a reload depends on. `.task(id:)` runs once when the window opens
    /// and again when one of these changes — not on every redraw, which is the
    /// whole reason the read is not in a view body.
    private struct LoadKey: Equatable {
        let dimension: HistoryQuery.Dimension
        let range: HistoryRange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                fillStatus

                if let model {
                    if model.isEmpty {
                        emptyArchive
                    } else {
                        sections(model)
                    }
                } else {
                    loading
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task(id: LoadKey(dimension: dimension, range: range)) {
            await load()
        }
    }

    private func load() async {
        // Read on the main actor, then hand plain values across. The snapshot's
        // window is what puts the live week on the chart, and it has no
        // `WindowRow` — one is only written once a window closes.
        let window = store.snapshot.window
        let weights = store.settings.weights
        model = await loader.viewModel(dimension: dimension, range: range,
                                       currentWindow: window, weights: weights)
    }

    // MARK: - Sections

    @ViewBuilder private func sections(_ model: HistoryViewModel) -> some View {
        Text("Completed weeks").eyebrow()
        if model.scoreboard.isEmpty {
            // Reachable: the live week has cells to draw a curve from long
            // before any window has closed. A bare column header over nothing
            // would read as a table that failed to load.
            Text("None yet — the first row is written when this week's window closes.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        } else {
            HistoryScoreboard(rows: model.scoreboard,
                              selected: model.range,
                              explainsMissingPercentages: model.noPercentagesRecorded,
                              select: { range = $0 })
        }

        Divider().overlay(Theme.hairline).padding(.vertical, 2)

        HStack(alignment: .firstTextBaseline) {
            Text("Burn curves").eyebrow()
            Text("cumulative units against how far through the window you were")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
        }
        HistoryBurnCurves(curves: model.curves,
                          nowFraction: store.snapshot.window.elapsedFraction)

        Divider().overlay(Theme.hairline).padding(.vertical, 2)

        Text("Where it went").eyebrow()
        HistoryBreakdown(rows: model.breakdown,
                         total: model.breakdownTotal,
                         windows: model.scoreboard.map(\.window),
                         dimension: $dimension,
                         range: rangeBinding(model))
    }

    /// Reads the selection back from the loaded model, so "the most recent
    /// complete window" can be the default without this view knowing which
    /// window that is — and without a resolution write-back that would trigger a
    /// second load on every open.
    private func rangeBinding(_ model: HistoryViewModel) -> Binding<HistoryRange> {
        Binding(get: { model.range }, set: { range = $0 })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Usage history").eyebrow()
            Text(coverageDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // ⚠️ Named plainly, because "units" is Burnline's own scale and
            // means nothing on its own. The absolute value is arbitrary by
            // construction — calibration divides it out — so the only claim
            // being made is that one week compares to another.
            Text("Units are Burnline's weighted measure of consumption, not tokens and not "
                 + "percent. The scale is arbitrary; only the comparison between weeks means "
                 + "anything. Transcripts see Claude Code on this Mac alone.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let model, model.hasGaps {
                warning("Coverage has holes. Usage during them is unknown, not zero — the "
                        + "affected weeks are marked below and their totals are floors.",
                        symbol: "exclamationmark.triangle.fill")
            }
            if let model, model.skippedLines > 0 {
                warning("\(model.skippedLines) archive lines could not be read and were "
                        + "skipped. Everything else is intact.",
                        symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private var coverageDescription: String {
        guard let begins = model?.coverageBegins else {
            return "Nothing archived yet."
        }
        // Claude Code deletes transcripts after 30 days, so this is a real
        // horizon rather than a starting point that will keep receding.
        return "Archived from \(HistoryLabels.day(begins)). Earlier weeks cannot be "
            + "recovered — Claude Code deletes its transcripts after 30 days."
    }

    // MARK: - States

    /// The launch fill, which is ~20 seconds over a full corpus. A spinner with
    /// no denominator reads as a hang at that length.
    @ViewBuilder private var fillStatus: some View {
        switch store.historyFillState {
        case .idle, .complete:
            EmptyView()
        case .filling(let progress):
            VStack(alignment: .leading, spacing: 5) {
                Text("Archiving transcripts — \(progress.filesOpened) of \(progress.filesTotal) files")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                ProgressView(value: fillFraction(progress))
                    .tint(Theme.accent)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
        case .failed(let message):
            warning("Some transcripts could not be read this launch, so parts of the archive "
                    + "may be missing. It retries next launch. (\(message))",
                    symbol: "exclamationmark.triangle.fill")
        }
    }

    private func fillFraction(_ progress: HistoryFill.Progress) -> Double {
        guard progress.filesTotal > 0 else { return 0 }
        return Double(progress.filesOpened) / Double(progress.filesTotal)
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

    /// 🔴 Distinct from the loading state above it. "Still filling" and
    /// "genuinely empty" mean opposite things and must never render alike.
    private var emptyArchive: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.historyFillState.isFilling
                 ? "Still reading transcripts. Weeks appear as the archive fills."
                 : "No completed weeks yet.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Burnline writes a row when a weekly window closes, so the first one appears "
                 + "after your next reset.")
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

extension HistoryFillState {
    var isFilling: Bool {
        if case .filling = self { return true }
        return false
    }
}
