import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private let instagram = Door(name: "Instagram")
private let youtube = Door(name: "YouTube")

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func dayStart(_ now: Date) -> Date {
    DayBoundary.dayStart(now: now, downHours: night, calendar: cal)
}

private func grant(_ door: Door, at issued: Date, minutes: Int) -> Grant {
    Grant(door: door, minutes: minutes, issuedAt: issued,
          expiresAt: issued.addingTimeInterval(Double(minutes) * 60))
}

// MARK: - The number under the key

/// `unlocks(dayStart:)` is what Mirror's footnote prints. It answers "how many
/// times did I open a door today", which is a different question from
/// `spentMinutes` and has to stay one — the whole reason the line was moved off
/// the lifetime key journal is that a number you cannot act on is not worth the
/// space under a screen made of single days.
@Suite struct DayUnlocksTests {

    /// The plain case: three grants inside the day, three unlocks.
    @Test func countsGrantsIssuedToday() {
        let now = at(7, 30, 14)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, at: at(7, 30, 9), minutes: 10))
        ledger.record(grant(youtube, at: at(7, 30, 11), minutes: 5))
        ledger.record(grant(instagram, at: at(7, 30, 13), minutes: 15))
        #expect(ledger.unlocks(dayStart: dayStart(now), calendar: cal) == 3)
    }

    /// Sessions, not minutes — and this is the point of the line rather than an
    /// incidental property. Fifteen minutes taken in one piece is one unlock;
    /// the same fifteen taken as "five more, five more, five more" is three,
    /// and `spentMinutes` cannot tell the two days apart at all.
    @Test func countsSessionsNotMinutes() {
        let now = at(7, 30, 14)

        var chained = GrantLedger()
        chained.record(grant(instagram, at: at(7, 30, 9), minutes: 5))
        chained.record(grant(instagram, at: at(7, 30, 9, 5), minutes: 5))
        chained.record(grant(instagram, at: at(7, 30, 9, 10), minutes: 5))

        var single = GrantLedger()
        single.record(grant(instagram, at: at(7, 30, 9), minutes: 15))

        #expect(chained.spentMinutes(dayStart: dayStart(now), calendar: cal)
                == single.spentMinutes(dayStart: dayStart(now), calendar: cal))
        #expect(chained.unlocks(dayStart: dayStart(now), calendar: cal) == 3)
        #expect(single.unlocks(dayStart: dayStart(now), calendar: cal) == 1)
    }

    /// The Silk day opens when down hours end (07:00), not at midnight. A grant
    /// taken at 06:00 belongs to the night before and must not be counted into
    /// the morning that follows it.
    @Test func theDayStartsWhenDownHoursEnd() {
        let now = at(7, 30, 9)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, at: at(7, 30, 6), minutes: 10))   // before the boundary
        ledger.record(grant(instagram, at: at(7, 30, 8), minutes: 10))   // after it
        #expect(ledger.unlocks(dayStart: dayStart(now), calendar: cal) == 1)
    }

    /// Yesterday is not today, however recently it ended.
    @Test func yesterdayDoesNotCount() {
        let now = at(7, 30, 9)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, at: at(7, 29, 15), minutes: 30))
        #expect(ledger.unlocks(dayStart: dayStart(now), calendar: cal) == 0)
    }

    /// The far edge is load-bearing, and this is the failure it exists to stop.
    /// A grant minted while the device clock was transiently forward carries an
    /// `issuedAt` in the future. Under an open-ended `issuedAt >= dayStart` it
    /// satisfies every later day too, so the footnote would print a count that
    /// never went back down — the one shape of wrong a daily number must not
    /// take. Clipped, the phantom is charged to the day it claims and no other.
    @Test func phantomFutureGrantCountsOnlyTheDayItClaims() {
        var ledger = GrantLedger()
        ledger.record(grant(instagram, at: at(8, 5, 12), minutes: 10))

        #expect(ledger.unlocks(dayStart: dayStart(at(7, 30, 9)), calendar: cal) == 0)
        #expect(ledger.unlocks(dayStart: dayStart(at(7, 31, 9)), calendar: cal) == 0)
        #expect(ledger.unlocks(dayStart: dayStart(at(8, 5, 14)), calendar: cal) == 1)
    }

    /// A day nothing was opened on reads zero, and zero is a real answer here —
    /// the footnote prints it rather than going blank.
    @Test func untouchedDayIsZero() {
        #expect(GrantLedger().unlocks(dayStart: dayStart(at(7, 30, 9)), calendar: cal) == 0)
    }

    /// Two doors, two unlocks: the line counts openings, not doors.
    @Test func differentDoorsBothCount() {
        let now = at(7, 30, 14)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, at: at(7, 30, 9), minutes: 10))
        ledger.record(grant(youtube, at: at(7, 30, 10), minutes: 10))
        #expect(ledger.unlocks(dayStart: dayStart(now), calendar: cal) == 2)
    }

    /// Today's grants cannot be compacted out from under the count — `compact`
    /// drops a grant only once its `expiresAt` precedes `dayStart`, and one
    /// issued today expires after today began. This is why the footnote needs
    /// no journal of its own.
    @Test func compactionLeavesTodaysCountAlone() {
        let now = at(7, 30, 14)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, at: at(7, 29, 15), minutes: 30))   // yesterday
        ledger.record(grant(instagram, at: at(7, 30, 9), minutes: 10))    // today
        ledger.record(grant(youtube, at: at(7, 30, 11), minutes: 5))      // today

        let before = ledger.unlocks(dayStart: dayStart(now), calendar: cal)
        ledger.compact(dayStart: dayStart(now))
        #expect(ledger.unlocks(dayStart: dayStart(now), calendar: cal) == before)
        #expect(before == 2)
    }
}
