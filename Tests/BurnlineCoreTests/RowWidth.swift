import AppKit

/// The popover's row geometry, mirrored from `PopoverView` because
/// `Sources/Burnline` has no test target. Both budgets are derived the same
/// way: the 300pt panel (`Theme.popoverWidth`), minus 14pt padding each side,
/// minus every fixed element and every stack gap in the row, minus the
/// `Spacer`'s 8pt system-default minimum. What is left is the room the label
/// and the value share.
enum RowWidth {
    /// `rejectionRow`, `regrantRow` and the extra-usage symbol rows: an
    /// `HStack(spacing: 5)` of symbol, label, Spacer, value — a 9pt symbol and
    /// three 5pt gaps.
    static let symbolRowBudget: Double = 300 - 2 * 14 - 9 - 3 * 5 - 8      // 240

    /// `row(_:_:)`: a default-spacing `HStack` of label, Spacer, value — two
    /// 8pt default gaps and no symbol.
    static let plainRowBudget: Double = 300 - 2 * 14 - 2 * 8 - 8            // 248

    // Built per call: `NSFont` is not `Sendable`, so a file-scope constant is
    // refused under Swift 6.
    enum Font { case label, digits }

    static func width(_ text: String, _ font: Font) -> Double {
        let resolved: NSFont = switch font {
        case .label: .systemFont(ofSize: 11.5)
        case .digits: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        }
        return (text as NSString).size(withAttributes: [.font: resolved]).width
    }

    /// Label in the text face plus value in the monospaced-digit face, the
    /// way the popover renders a row.
    static func pair(_ label: String, _ value: String) -> Double {
        width(label, .label) + width(value, .digits)
    }
}
