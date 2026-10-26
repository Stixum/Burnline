import Testing
import Foundation
@testable import BurnlineCore

private func value(_ text: String) -> Double? {
    if case .success(let percent) = CalibrationInput.parse(text) { return percent }
    return nil
}

private func problem(_ text: String) -> CalibrationInput.Problem? {
    if case .failure(let problem) = CalibrationInput.parse(text) { return problem }
    return nil
}

/// 🔴 `/usage` prints "42%", and that is what people type. `Double("42%")` is
/// nil, so the field closed and nothing happened — no anchor, no message.
@Test func aPercentSignIsAccepted() {
    #expect(value("42%") == 42)
    #expect(value(" 42 % ") == 42)
}

@Test func plainAndDecimalFiguresAreAccepted() {
    #expect(value("42") == 42)
    #expect(value("42.5") == 42.5)
    #expect(value("  7 ") == 7)
}

/// A decimal comma is how most of Europe writes 42.5.
@Test func aDecimalCommaIsAccepted() {
    #expect(value("42,5") == 42.5)
}

/// Every rejection says why, instead of closing the field on it.
@Test func eachRejectionNamesItsReason() {
    #expect(problem("") == .empty)
    #expect(problem("   ") == .empty)
    #expect(problem("forty") == .notANumber)
    #expect(problem("4 2") == .notANumber)
    #expect(problem("0") == .notAboveZero)
    #expect(problem("-3") == .notAboveZero)
    #expect(problem("250") == .tooHigh)
    #expect(problem("nan") == .notANumber)
    #expect(problem("inf") == .notANumber)
}

/// The bounds the view enforced before, kept: above 0, at most 200.
@Test func theBoundsAreUnchanged() {
    #expect(value("0.1") == 0.1)
    #expect(value("200") == 200)
    #expect(problem("200.1") == .tooHigh)
}

@Test func everyProblemHasAMessage() {
    for problem in CalibrationInput.Problem.allCases {
        #expect(!problem.message.isEmpty)
    }
}
