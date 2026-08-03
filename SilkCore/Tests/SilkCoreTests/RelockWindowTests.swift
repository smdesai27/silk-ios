import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29,
                                  hour: hour, minute: minute, second: second))!
}

/// What the wall can actually ask for: a DeviceActivitySchedule carries hours
/// and minutes, so the end it fires on is the minute mark below the Date the
/// window computed. Every claim about "after expiry" has to survive this.
private func asScheduled(_ d: Date) -> Date {
    cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: d))!
}

@Suite struct RelockWindowTests {
    @Test func aGrantLongerThanTheFloorSchedulesAtItsOwnExpiry() {
        let w = RelockWindow(now: at(14, 3), relockAt: at(14, 33))

        #expect(w.clamped == false)
        #expect(w.primaryEnd == at(14, 33))
        #expect(w.backupEnd == at(14, 35))
        #expect(w.thresholdMinutes == 30)
    }

    @Test func aGrantShorterThanTheFloorSchedulesLateNeverEarly() {
        let now = at(14, 3)
        let relockAt = at(14, 8)
        let w = RelockWindow(now: now, relockAt: relockAt)

        #expect(w.clamped)
        #expect(w.primaryEnd == now.addingTimeInterval(RelockWindow.scheduleFloor))
        #expect(w.primaryEnd > relockAt)
        // The threshold keeps the five minutes actually granted: it is spent
        // usage, not wall clock, and nothing forces it up to the floor.
        #expect(w.thresholdMinutes == 5)
    }

    @Test func theStaggeredScheduleIsTheOneThatSurvivesTruncationToTheMinute() {
        // A grant asked at 14:03:47 expires at 14:33:47, and the primary can
        // only be scheduled for 14:33 — forty-seven seconds before the ledger
        // stops calling the grant live, so its reconcile finds nothing to
        // close. This is why arming the staggered schedule is not optional,
        // and why a spend through the intent is refused if either throws.
        let relockAt = at(14, 33, 47)
        let w = RelockWindow(now: at(14, 3, 47), relockAt: relockAt)

        #expect(asScheduled(w.primaryEnd) < relockAt)
        #expect(asScheduled(w.backupEnd) > relockAt)
    }

    @Test func theThresholdRoundsUpSoItNeverUndercutsTheMinutesGranted() {
        let w = RelockWindow(now: at(14, 3), relockAt: at(14, 23, 1))

        #expect(w.thresholdMinutes == 21)
    }

    @Test func aGrantWithNothingLeftOnItStillArmsAMinuteOfThreshold() {
        // The Validator truncates a grant at the night edge, and a spend a
        // second before that edge can arrive here with no time on it. A
        // threshold of zero arms nothing at all.
        let now = at(21, 59, 59)
        let w = RelockWindow(now: now, relockAt: now)

        #expect(w.clamped)
        #expect(w.thresholdMinutes == 1)
        #expect(w.primaryEnd > now)
    }
}
