import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private let instagram = Door(name: "Instagram")
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

// MARK: - Surgical rollback

/// `removeGrant(id:)` is the failure path of a writer whose grant would not
/// arm downstream (SpendIntent, across an `await`). Its whole contract is
/// surgery: exactly the named grant leaves, and every other row — a close the
/// user landed during the suspension, a neighbouring grant — stands untouched.
/// Wholesale snapshot-restore is the clobber this API exists to end.
@Suite struct GrantRemovalTests {
    /// The rollback refunds exactly its own debit and nothing else: the
    /// neighbouring grant keeps its minutes, and the pool reads as if the
    /// removed grant had never been recorded.
    @Test func removesExactlyTheNamedGrant() {
        let now = at(8, 4, 10)
        let start = dayStart(now)
        var ledger = GrantLedger()
        let failed = Grant(door: tiktok, minutes: 20, issuedAt: now,
                           expiresAt: now.addingTimeInterval(20 * 60))
        let bystander = Grant(door: instagram, minutes: 15, issuedAt: at(8, 4, 9),
                              expiresAt: at(8, 4, 9, 15))
        ledger.record(bystander)
        ledger.record(failed)

        ledger.removeGrant(id: failed.id)

        #expect(ledger.grants.map(\.id) == [bystander.id])
        #expect(ledger.spentMinutes(dayStart: start) == 15)
        // The failed grant held TikTok open; with it gone the wall reads shut.
        #expect(ledger.openDoors(at: now, dayStart: start).isEmpty)
    }

    /// The scenario the API was cut for: a close lands on ANOTHER door while
    /// the failing writer sits across its await. The rollback removes the
    /// failed grant and the close survives whole — stated hour included.
    @Test func closeLandedDuringTheAwaitSurvives() {
        let now = at(8, 4, 10)
        let start = dayStart(now)
        var ledger = GrantLedger()
        let failed = Grant(door: tiktok, minutes: 20, issuedAt: now,
                           expiresAt: now.addingTimeInterval(20 * 60))
        ledger.record(failed)
        // The bar-side tighten that arrives mid-await.
        ledger.closeDoor(instagram, at: now, until: at(8, 4, 17))

        ledger.removeGrant(id: failed.id)

        #expect(ledger.grants.isEmpty)
        #expect(ledger.isClosed(instagram.id, at: now, dayStart: start))
        #expect(ledger.closedUntil[instagram.id] == at(8, 4, 17))
    }

    /// A close on the SAME door truncates the grant but keeps its id — the
    /// refund must still find it. And an id the ledger does not hold removes
    /// nothing: the rollback is idempotent, run twice or against a ledger an
    /// external writer already rewrote.
    @Test func truncatedGrantStillFound_unknownIdIsANoOp() {
        let now = at(8, 4, 10)
        let start = dayStart(now)
        var ledger = GrantLedger()
        let failed = Grant(door: tiktok, minutes: 20, issuedAt: now,
                           expiresAt: now.addingTimeInterval(20 * 60))
        ledger.record(failed)
        ledger.closeDoor(tiktok, at: at(8, 4, 10, 5))

        ledger.removeGrant(id: failed.id)
        #expect(ledger.grants.isEmpty)
        #expect(ledger.spentMinutes(dayStart: start) == 0)

        let before = ledger
        ledger.removeGrant(id: UUID())
        ledger.removeGrant(id: failed.id)
        #expect(ledger == before)
        // The close itself is not the grant's row: it stands.
        #expect(ledger.isClosed(tiktok.id, at: now, dayStart: start))
    }
}
