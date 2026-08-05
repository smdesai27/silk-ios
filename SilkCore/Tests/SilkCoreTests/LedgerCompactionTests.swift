import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private let instagram = Door(name: "Instagram")
private let youtube = Door(name: "YouTube")
private let tiktok = Door(name: "TikTok")

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

private func grant(_ door: Door, from: Date, to: Date) -> Grant {
    Grant(door: door, minutes: Int(to.timeIntervalSince(from) / 60), issuedAt: from, expiresAt: to)
}

// MARK: - The day-turn sweep

/// `compact(dayStart:)` runs at the boundary — the app's clock and
/// `SpendIntent` both call it there — so what it must and must not drop is
/// the whole contract: yesterday leaves, today survives untouched, and the
/// arithmetic every hot path reads is byte-identical before and after.
@Suite struct LedgerCompactionTests {
    /// The common morning: yesterday's spent grant and yesterday's close are
    /// history, and history does not ride in the hot ledger.
    @Test func dayTurnDropsYesterdayWhole() {
        let now = at(7, 30, 9)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: at(7, 29, 15), to: at(7, 29, 15, 30)))
        ledger.closeDoor(youtube, at: at(7, 29, 16), until: at(7, 29, 18))

        ledger.compact(dayStart: dayStart(now))

        #expect(ledger.grants.isEmpty)
        #expect(ledger.closedToday.isEmpty)
        #expect(ledger.closedUntil.isEmpty)
    }

    /// Today's records are not history: the grant keeps its debit, the close
    /// keeps its stated hour, and both predicates answer as before.
    @Test func todaySurvivesTheSweep() {
        let now = at(7, 30, 9)
        let start = dayStart(now)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: at(7, 30, 8), to: at(7, 30, 8, 20)))
        ledger.closeDoor(tiktok, at: at(7, 30, 8, 30), until: at(7, 30, 17))

        ledger.compact(dayStart: start)

        #expect(ledger.spentMinutes(dayStart: start) == 20)
        #expect(ledger.closedUntil[tiktok.id] == at(7, 30, 17))
        #expect(ledger.isClosed(tiktok.id, at: now, dayStart: start))
    }

    /// The fail-closed reading must not move: remaining minutes — pool and
    /// per-door cap alike — are the same number on either side of the sweep,
    /// or the boundary would be silently refunding or debiting.
    @Test func compactionMovesNoArithmetic() {
        let now = at(7, 30, 9)
        let start = dayStart(now)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: at(7, 29, 15), to: at(7, 29, 15, 30)))
        ledger.record(grant(instagram, from: at(7, 30, 8), to: at(7, 30, 8, 20)))
        ledger.closeDoor(youtube, at: at(7, 29, 16))

        let before = (ledger.remainingMinutes(budget: 40, dayStart: start),
                      ledger.remainingMinutes(cap: 25, doorID: instagram.id, dayStart: start),
                      ledger.openDoors(at: now, dayStart: start))
        ledger.compact(dayStart: start)
        let after = (ledger.remainingMinutes(budget: 40, dayStart: start),
                     ledger.remainingMinutes(cap: 25, doorID: instagram.id, dayStart: start),
                     ledger.openDoors(at: now, dayStart: start))

        #expect(before == after)
        #expect(after.0 == 20)
    }

    /// A grant still running across the boundary is not history yet: its
    /// expiry is ahead of the day start, and the door it holds open must not
    /// slam shut because a sweep ran mid-grant.
    @Test func grantRunningAcrossTheBoundarySurvives() {
        let now = at(7, 30, 7, 5)
        let start = dayStart(now)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: at(7, 30, 6, 50), to: at(7, 30, 7, 10)))

        ledger.compact(dayStart: start)

        #expect(ledger.openDoors(at: now, dayStart: start) == [instagram.id])
        // Issued before the boundary, so it debits nothing from the new day —
        // the same rule `spentMinutes` has always read.
        #expect(ledger.spentMinutes(dayStart: start) == 0)
    }

    /// A stated hour whose close was swept goes with it, even when the hour
    /// itself is still ahead: `closedUntil` is a clause on a close, and a
    /// clause with no sentence is an orphan `nextTransition` would keep
    /// waking for.
    @Test func orphanedLiftFollowsItsClose() {
        let now = at(7, 30, 8)
        var ledger = GrantLedger()
        ledger.closeDoor(youtube, at: at(7, 29, 21), until: at(7, 30, 9))

        ledger.compact(dayStart: dayStart(now))

        #expect(ledger.closedUntil.isEmpty)
        #expect(ledger.nextTransition(after: now) == nil)
    }
}
