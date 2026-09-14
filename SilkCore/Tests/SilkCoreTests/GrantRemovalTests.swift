import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

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
    /// `endGrants(for:at:)` is the other failure-path primitive: the bar's
    /// landing, when a re-lock will not arm over a door that already had a
    /// grant running. It ends that door's live grants and writes nothing
    /// else — a close some other writer landed keeps its lift hour, the
    /// minutes stay spent, a neighbouring door's grant stands, and an already
    /// ended grant is left alone.
    @Test func endingGrantsShutsTheDoorAndRecordsNoClose() {
        let now = at(8, 4, 10)
        let start = dayStart(now)
        var ledger = GrantLedger()
        let running = Grant(door: tiktok, minutes: 20, issuedAt: at(8, 4, 9, 55),
                            expiresAt: at(8, 4, 10, 15))
        let bystander = Grant(door: instagram, minutes: 15, issuedAt: at(8, 4, 9),
                              expiresAt: at(8, 4, 9, 15))
        ledger.record(bystander)
        ledger.record(running)
        // Somebody else's close on the bystander's door, with a stated lift.
        ledger.closeDoor(instagram, at: at(8, 4, 9, 30), until: at(8, 4, 11))

        ledger.endGrants(for: tiktok, at: now)

        #expect(ledger.openDoors(at: now, dayStart: start).isEmpty)
        #expect(ledger.activeGrant(for: tiktok, at: now) == nil)
        #expect(ledger.grants.map(\.id) == [bystander.id, running.id])
        #expect(ledger.spentMinutes(dayStart: start) == 35)
        // No close of its own, and the other close untouched.
        #expect(ledger.closedToday[tiktok.id] == nil)
        #expect(ledger.closedUntil[tiktok.id] == nil)
        #expect(ledger.closedUntil[instagram.id] == at(8, 4, 11))
        // Idempotent.
        let again = ledger
        ledger.endGrants(for: tiktok, at: now.addingTimeInterval(60))
        #expect(ledger == again)
    }

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
