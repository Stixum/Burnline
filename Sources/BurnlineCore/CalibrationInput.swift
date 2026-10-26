import Foundation

/// What the popover's calibration field accepts.
///
/// 🔴 It used to be `Double(text)` in a view body, and anything it rejected
/// closed the field with nothing saved and nothing said. `/usage` prints
/// `42%`, which is what people type, and `Double("42%")` is nil.
public enum CalibrationInput {

    /// Why a figure was refused, worded for the line under the field.
    public enum Problem: Error, Equatable, Sendable, CaseIterable {
        case empty
        case notANumber
        /// 0% has no rate in it to calibrate against.
        case notAboveZero
        /// The bound the view always had; past it the figure is a typo.
        case tooHigh

        public var message: String {
            switch self {
            case .empty:        "Enter the percentage /usage shows."
            case .notANumber:   "Enter a number, like 42."
            case .notAboveZero: "Calibrate once usage is above 0%."
            case .tooHigh:      "That's over 200%. Check /usage again."
            }
        }
    }

    public static let maximumPercent: Double = 200

    /// Accepts `42`, `42.5`, `42,5` and `42%`, with spaces around any of them.
    public static func parse(_ text: String) -> Result<Double, Problem> {
        var figure = text.trimmingCharacters(in: .whitespaces)
        if figure.hasSuffix("%") {
            figure = String(figure.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !figure.isEmpty else { return .failure(.empty) }
        // A decimal comma, as most of Europe writes it. Only one separator is
        // ever meaningful in a percentage, so there is no thousands case.
        figure = figure.replacingOccurrences(of: ",", with: ".")
        // `Double` also reads "nan" and "inf"; neither is a percentage.
        guard let value = Double(figure), value.isFinite else { return .failure(.notANumber) }
        guard value > 0 else { return .failure(.notAboveZero) }
        guard value <= maximumPercent else { return .failure(.tooHigh) }
        return .success(value)
    }
}
