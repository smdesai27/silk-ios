import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

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

// MARK: - The phantom grant
//
// A grant minted while the device clock was transiently forward carries a
// future issuedAt/expiresAt. Under the open-ended spend filter it satisfied
// `issuedAt >= dayStart` on EVERY subsequent real day — the same minutes
// deducted from the budget again each morning — and `compact` kept the row
// forever because its expiry never fell behind a day start. One Siri spend
// during a time-cheat evening cost the whole budget daily for months, with
// nothing short of wipeAll able to remove it.

@Suite struct AGrantFromADayThatNeverHappenedCannotSpendForever {

    /// Ninety real days after the fake evening, the phantom must charge
    /// nothing — the spend is the day's spend, not "everything issued since".
    @Test func aFutureIssuedGrantDebitsNoRealDay() {
        let phantom = grant(instagram, from: at(10, 28, 20), to: at(10, 28, 20, 30))
        var ledger = GrantLedger()
        ledger.record(phantom)

        for now in [at(7, 30, 9), at(8, 15, 12), at(9, 1, 7, 30)] {
            let start = dayStart(now)
            #expect(ledger.spentMinutes(dayStart: start) == 0)
            #expect(ledger.remainingMinutes(budget: 60, dayStart: start) == 60)
            #expect(ledger.spentMinutes(doorID: instagram.id, dayStart: start) == 0)
            #expect(ledger.remainingMinutes(cap: 30, doorID: instagram.id,
                                            dayStart: start) == 30)
        }
    }

    /// And the row itself is mortal: the day-turn sweep drops a grant issued
    /// past the day's end, so the zombie can never lie in wait to go active —
    /// and drop the wall — when its fake window finally arrives.
    @Test func compactionDropsTheFutureIssuedRow() {
        let phantom = grant(instagram, from: at(10, 28, 20), to: at(10, 28, 20, 30))
        var ledger = GrantLedger()
        ledger.record(phantom)

        ledger.compact(dayStart: dayStart(at(7, 30, 9)))

        #expect(ledger.grants.isEmpty)
        #expect(ledger.nextTransition(after: at(7, 30, 9)) == nil)
    }

    /// The boundary of the rule: everything issued inside the sweeping day —
    /// including a grant still running into tomorrow — is an honest row and
    /// survives, and still counts.
    @Test func todaysOwnGrantsAreNotPhantoms() {
        let now = at(7, 30, 22)
        let start = dayStart(now)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: at(7, 30, 9), to: at(7, 30, 9, 20)))
        // Issued late tonight, expiring after tomorrow's boundary.
        ledger.record(grant(tiktok, from: at(7, 30, 21, 50), to: at(7, 31, 7, 20)))

        ledger.compact(dayStart: start)

        #expect(ledger.grants.count == 2)
        #expect(ledger.spentMinutes(dayStart: start) > 0)
        #expect(ledger.openDoors(at: now, dayStart: start) == [tiktok.id])
    }
}
