import Testing
import Foundation
@testable import BurnlineCore

private let week: TimeInterval = 7 * 86_400

@Test func elapsedFractionAtDayFive() {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start.addingTimeInterval(week),
                        now: start.addingTimeInterval(5 * 86_400))
    #expect(abs(window.elapsedFraction - 5.0 / 7.0) < 1e-9)
    #expect(abs(window.targetPercent - 71.428571) < 1e-4)
    #expect(abs(window.dayIndex - 5.0) < 1e-9)
}

@Test func fractionClampsBelowZeroAndAboveOne() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let end = start.addingTimeInterval(week)
    let before = Window(start: start, end: end, now: start.addingTimeInterval(-500))
    let after = Window(start: start, end: end, now: end.addingTimeInterval(500))
    #expect(before.elapsedFraction == 0)
    #expect(after.elapsedFraction == 1)
}

@Test func timeRemainingNeverNegative() {
    let start = Date(timeIntervalSince1970: 0)
    let end = start.addingTimeInterval(week)
    let past = Window(start: start, end: end, now: end.addingTimeInterval(3600))
    #expect(past.timeRemaining == 0)
}

@Test func zeroDurationWindowDoesNotDivideByZero() {
    let start = Date(timeIntervalSince1970: 0)
    let window = Window(start: start, end: start, now: start)
    #expect(window.elapsedFraction == 0)
}
