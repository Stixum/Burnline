import Foundation

/// What VoiceOver says for the History charts.
///
/// Swift Charts describes each mark by its raw plotted values — "Elapsed 0.34,
/// Units 412883977" — several hundred times per chart. These replace that with
/// the one thing each chart is for: where each week ended. Strings are resolved
/// here, like every other figure a view shows, so they can be tested.
public enum HistoryAccessibility {

    /// One drawn week: its legend label and where its line currently ends.
    public struct WeekEnd: Equatable, Sendable {
        public let label: String
        public let value: Double

        public init(label: String, value: Double) {
            self.label = label
            self.value = value
        }
    }

    public static let unitCurvesLabel = "Burn curves, weighted units by time through the week"
    public static let percentCurvesLabel = "Usage, Anthropic's percentage by time through the week"

    /// "This week, 180 million units; Nov 13 – Nov 20, 885 million units".
    public static func unitCurvesValue(_ weeks: [WeekEnd]) -> String {
        summary(weeks) { "\(spokenUnits($0)) units" }
    }

    /// "This week, 20 percent; Nov 13 – Nov 20, 84 percent".
    public static func percentCurvesValue(_ weeks: [WeekEnd]) -> String {
        summary(weeks) { spokenPercent(HistoryLabels.percent($0)) }
    }

    /// A breakdown bar: "440 million units, 50 percent".
    public static func breakdownValue(units: Double, share: Double) -> String {
        "\(spokenUnits(units)) units, \(spokenPercent(HistoryLabels.share(share)))"
    }

    private static func summary(_ weeks: [WeekEnd], _ value: (Double) -> String) -> String {
        guard !weeks.isEmpty else { return "No weeks recorded yet" }
        return weeks.map { "\($0.label), \(value($0.value))" }.joined(separator: "; ")
    }

    /// `HistoryLabels.units` with its suffix spelled out. "885M" is read letter
    /// by letter, or as "885 metres".
    static func spokenUnits(_ value: Double) -> String {
        let compact = HistoryLabels.units(value)
        let words: [Character: String] = ["K": "thousand", "M": "million", "B": "billion", "T": "trillion"]
        guard let last = compact.last, let word = words[last] else {
            return compact == "—" ? "unknown" : compact
        }
        return "\(compact.dropLast()) \(word)"
    }

    /// "50%" → "50 percent", "<1%" → "under 1 percent", ">99%" → "over 99 percent".
    static func spokenPercent(_ text: String) -> String {
        guard text.hasSuffix("%") else { return text == "—" ? "unknown" : text }
        var number = String(text.dropLast())
        var prefix = ""
        if number.hasPrefix("<") { prefix = "under "; number.removeFirst() }
        if number.hasPrefix(">") { prefix = "over "; number.removeFirst() }
        return "\(prefix)\(number) percent"
    }
}
