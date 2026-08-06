import Testing
import Foundation
@testable import SilkCore

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))
private let tiktok = Door(name: "TikTok")
private let instagram = Door(name: "Instagram")

private func policy(budget: Int = 60, caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: night,
                doors: [tiktok, instagram], doorCaps: caps)
}

/// The one pending slot, and the generation that keeps an undo offer honest
/// about which slot it describes.
///
/// This is the half of `AppModel.enact(.loosen)` that can be reached without a
/// simulator, and it is the half where the bug was. The undo window runs up to
/// five minutes (`undoSeconds`, settable to 300) with the whole app usable
/// underneath it, so two parks inside one window are ordinary rather than
/// exotic — and the offer left over from the first one used to restore blind.
@Suite struct PendingSlotTests {

    @Test func aFreshSlotHoldsNothingAndOwesNobody() {
        let slot = PendingSlot()
        #expect(slot.pending == nil)
        #expect(slot.baseline == nil)
        #expect(slot.generation == 0)
        // Nothing was ever offered against generation 0's predecessor.
        #expect(!slot.stands(-1))
    }

    @Test func anOfferMadeAtAParkStandsUntilSomethingElseParks() {
        var slot = PendingSlot()
        let generation = slot.park(policy(caps: [tiktok.id: 45]), baseline: policy())
        #expect(slot.stands(generation))
        #expect(slot.pending?.doorCaps[tiktok.id] == 45)
        #expect(slot.baseline?.doorCaps.isEmpty == true)
    }

    /// THE DATA-LOSS PIN. Park a ceiling raise on TikTok. Four minutes later —
    /// still inside a 300-second undo window — park a clearing on Instagram,
    /// which displaces it (one slot, knowingly). Then tap the first offer, which
    /// is still on screen.
    ///
    /// Unguarded, that offer parks the FIRST park's predecessor — nil — and the
    /// second, newer ask is gone: two losses in one tap, neither asked for, and
    /// the thread writes "Put back." over both. The generation is what makes the
    /// stale offer answer "I no longer describe this slot".
    @Test func aDisplacedOfferCannotDeleteTheAskThatDisplacedIt() {
        var slot = PendingSlot()
        let first = slot.park(policy(caps: [tiktok.id: 45]), baseline: policy())
        let second = slot.park(policy(caps: [instagram.id: 30]), baseline: policy())

        #expect(!slot.stands(first))          // the older offer has expired …
        #expect(slot.stands(second))          // … and the newer one has not.

        // The surface that made the first offer must now do nothing at all. What
        // it would have restored is recorded here so the loss is legible: the
        // newer ask, still standing, is the whole thing at stake.
        #expect(slot.pending?.doorCaps[instagram.id] == 30)
        #expect(slot.pending?.doorCaps[tiktok.id] == nil)
    }

    /// Clearing the slot is a park like any other — the key spent from a toast,
    /// a card or Now's row, and the boundary maturing what waited. Both leave
    /// every outstanding offer expired, for the same reason: an undo that put a
    /// withdrawn ask back over an applied one would re-park a change that has
    /// already landed.
    @Test func emptyingTheSlotExpiresEveryOfferToo() {
        var slot = PendingSlot()
        let parked = slot.park(policy(caps: [tiktok.id: 45]), baseline: policy())
        let emptied = slot.park(nil, baseline: nil)
        #expect(!slot.stands(parked))
        #expect(slot.stands(emptied))
        #expect(slot.pending == nil)
    }

    /// An offer that still stands puts back exactly what it snapshotted — the
    /// withdrawn ask's own baseline included, never the live policy. Restoring a
    /// pending against the wrong baseline makes `maturing` compare the live
    /// values against themselves and hand the snapshot a wholesale revert.
    @Test func aStandingOfferPutsBackTheAskAndItsOwnBaseline() {
        var slot = PendingSlot()
        let waiting = policy(caps: [tiktok.id: 45])
        let itsBaseline = policy(caps: [tiktok.id: 20])
        slot.park(waiting, baseline: itsBaseline)

        // A second ask arrives and is withdrawn while it still stands.
        let previous = slot.pending
        let previousBaseline = slot.baseline
        let generation = slot.park(policy(), baseline: policy(caps: [tiktok.id: 45]))
        #expect(slot.stands(generation))
        slot.park(previous, baseline: previousBaseline)

        #expect(slot.pending == waiting)
        #expect(slot.baseline == itsBaseline)
    }

    /// The generation is per process and never persisted, so a slot restored
    /// from the App Group starts at zero — a launch holds no offers, and one
    /// that appeared to stand would be an offer made by a process that is gone.
    @Test func aRestoredSlotStartsOwingNothing() {
        let slot = PendingSlot(pending: policy(caps: [tiktok.id: 45]), baseline: policy())
        #expect(slot.generation == 0)
        #expect(slot.pending != nil)
    }
}
