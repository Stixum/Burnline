import SwiftUI
import BurnlineCore

/// One row per completed weekly window, newest first.
///
/// 🔴 **Four states, and all four occur on a real archive today.** A recorded
/// percentage carries its own age, because a week where the laptop closed on
/// Thursday holds Thursday's reading and a bare `61%` claims a final figure the
/// app never saw. A missing one reads as *not recorded* — never `0%`, which
/// would claim a week of no usage. A hole in coverage is marked as unknown, not
/// as idle. And a week whose allowance was **re-granted** mid-window says so:
/// its recorded percentage is only the climb since the last re-grant, so
/// without the note a 30% row sits beside a token total bigger than a 91%
/// week's and reads as quiet. Rows are written once, so that reading would be
/// permanent. Every one of the four is `HistoryQuery`'s or `HistoryLabels`'
/// derivation, never this file's.
///
/// Selecting a row points the breakdown at that window. The two have to be
/// aimable at the same period or their totals reconcile with nothing.
struct HistoryScoreboard: View {
    let rows: [HistoryQuery.ScoreboardRow]
    let selected: HistoryRange
    /// True only while NO row has a percentage — the normal first-open state.
    /// Once one week has a real figure the empty cells explain themselves, and
    /// a standing paragraph about them is just noise.
    let explainsMissingPercentages: Bool
    let select: (HistoryRange) -> Void

    // Fixed columns, shared by the header and every row. A per-row `Spacer`
    // layout would let the columns wander as the strings change width.
    private enum Column {
        static let week: CGFloat = 122
        static let units: CGFloat = 78
        static let percent: CGFloat = 184
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(rows, id: \.window.start) { row in
                weekRow(row)
            }
            if explainsMissingPercentages {
                missingPercentagesNote
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Week").eyebrow().frame(width: Column.week, alignment: .leading)
            Text("Units").eyebrow().frame(width: Column.units, alignment: .trailing)
            Text("Anthropic's figure").eyebrow().frame(width: Column.percent, alignment: .leading)
            Text("Notes").eyebrow()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func weekRow(_ row: HistoryQuery.ScoreboardRow) -> some View {
        let isSelected = selected == .window(start: row.window.start)
        return Button {
            select(.window(start: row.window.start))
        } label: {
            HStack(spacing: 12) {
                Text(HistoryLabels.windowRange(start: row.window.start, end: row.window.end))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: Column.week, alignment: .leading)

                // ⚠️ A window with a hole in its coverage is missing whatever
                // was burned while the app was not running, so its total is a
                // floor and says so with a ≥.
                Text(HistoryLabels.units(row.units, isLowerBound: row.hasGap))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Column.units, alignment: .trailing)

                percentColumn(row)
                    .frame(width: Column.percent, alignment: .leading)

                notes(row)
                Spacer(minLength: 0)

                // The row's connection to the bars below it. Word, not just the
                // highlight — a background tint alone is colour carrying meaning.
                if isSelected {
                    Text("In breakdown")
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase).tracking(1.1)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusRow))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this week in the breakdown below")
    }

    /// 🔴 Anthropic's own figure, its age, or an explicit absence. Never a zero.
    private func percentColumn(_ row: HistoryQuery.ScoreboardRow) -> some View {
        let reading = HistoryLabels.finalReading(percent: row.usedPercent,
                                                 at: row.window.finalPercentAt,
                                                 windowEnd: row.window.end)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(reading.value)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(reading.isRecorded ? Theme.textPrimary : Theme.textMuted)
            Text(reading.note)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
    }

    /// Ordered by severity, not by the column each one qualifies: a warning that
    /// the units are incomplete, then the annotation that reframes the
    /// percentage, then a provenance footnote about the dates. (Nearest-column
    /// ordering would put the bounds note FIRST — `Week` is the leftmost cell in
    /// the row — so the two rules disagree and this is the one being followed.)
    /// `.observed` bounds are the expected case and carry no annotation —
    /// labelling the normal state trains people to ignore the label.
    ///
    /// ⚠️ All three can appear at once, which is newly reachable now there are
    /// three. `.lineLimit(1)` because this column is the only unbounded one in
    /// the row and a wrapped note would grow the row's height out of the grid —
    /// the same reason `percentColumn`'s subtitle sets it. There is no test
    /// target here; a screenshot is what checks the width.
    @ViewBuilder private func notes(_ row: HistoryQuery.ScoreboardRow) -> some View {
        HStack(spacing: 12) {
            if row.hasGap {
                note("Gap in coverage", "exclamationmark.triangle.fill", Theme.warning,
                     help: "Burnline was not running for part of this week. Tokens burned "
                         + "then are unknown, not zero, so the total is a floor.")
            }
            // ⚠️ A text token, never a curve ramp colour, and the same symbol
            // the popover's live re-grant row carries: one event, one glyph.
            // The wording — including which day of the window it fell on — is
            // `HistoryQuery.RegrantNote`, where a test can read it.
            if let regrant = row.regrantNote {
                note(regrant.label, "arrow.counterclockwise.circle.fill", Theme.textSecondary,
                     help: regrant.help)
            }
            switch row.window.boundsSource {
            case .observed:
                EmptyView()
            case .extrapolated:
                note("Dates inferred", "arrow.uturn.backward.circle", Theme.textMuted,
                     help: "This week's reset was never seen. Its dates are counted back "
                         + "from a later reset that was, so they are right unless the "
                         + "reset has since moved.")
            case .schedule:
                note("Dates from Settings schedule", "questionmark.circle", Theme.textMuted,
                     help: "No reset has ever been observed on this Mac, so these dates "
                         + "come from the schedule in Settings. The totals are real; which "
                         + "seven days they cover is a guess.")
            }
        }
        .lineLimit(1)
    }

    /// Symbol + word + colour. Never colour alone.
    private func note(_ text: String, _ symbol: String, _ tint: Color,
                      help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5))
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(tint)
        .help(help)
    }

    /// 🔴 Without this line the feature reads as broken on the day it ships: a
    /// whole column of dashes with no explanation looks like a failure to fetch
    /// something, rather than a period that predates the recording.
    private var missingPercentagesNote: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text("Anthropic's figure is recorded for new weeks. These weeks closed before "
                 + "Burnline kept it, and it cannot be reconstructed. Units are unaffected.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}
