import Testing
import Foundation
@testable import SilkCore

private func policy(budget: Int = 60,
                    hours: DownHours = night,
                    doors: [Door] = [Door(name: "Instagram")],
                    wall: Bool = true,
                    caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: hours, doors: doors,
                wallEnabled: wall, doorCaps: caps)
}

/// Stable ids, because a cap is keyed by one. The default `doors:` above mints
/// a fresh `Door` on every call, which is fine for the scalar fields and is
/// exactly wrong for a dictionary keyed by door.
private func capPolicy(_ caps: [UUID: Int]) -> PolicyState {
    policy(doors: [tiktok, instagram], caps: caps)
}

/// A parked loosening matures by merge, not by assignment.
///
/// The bug these pin: `pendingLoosening` holds a whole `PolicyState`, and
/// assigning it wholesale at the day boundary silently reverts anything
/// tightened while it waited. Rule 3 says tightening is instant — which is
/// worth nothing if a sentence said yesterday can undo it tonight.
@Suite struct PendingMaturityTests {

    // MARK: - The ordinary case still works

    @Test func anUntouchedFieldMatures() {
        let baseline = policy(budget: 60)
        let pending = policy(budget: 90)
        let live = baseline

        #expect(live.maturing(pending, parkedAgainst: baseline).budgetMinutes == 90)
    }

    @Test func anUntouchedNightMatures() {
        let shorter = DownHours(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))
        let baseline = policy()
        let pending = policy(hours: shorter)

        #expect(baseline.maturing(pending, parkedAgainst: baseline).downHours == shorter)
    }

    // MARK: - The bug

    @Test func aBudgetTightenedAfterParkingSurvivesMaturity() {
        let baseline = policy(budget: 60)
        let pending = policy(budget: 90)      // "more time tomorrow"
        let live = policy(budget: 30)          // then, tonight, a tighten

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.budgetMinutes == 30, "the later tighten wins; 90 was asked for first")
    }

    @Test func aNightTightenedAfterParkingSurvivesMaturity() {
        let longer = DownHours(start: TimeOfDay(hour: 21), end: TimeOfDay(hour: 7))   // tighter
        let shorter = DownHours(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))  // looser
        let baseline = policy()
        let pending = policy(hours: shorter)   // "let me stay up"
        let live = policy(hours: longer)       // then a tighten

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.downHours == longer)
    }

    @Test func anUntouchedWallMatures() {
        let baseline = policy(wall: true)
        let pending = policy(wall: false)      // "drop the wall"
        let live = policy(wall: true)          // nobody has touched it since

        #expect(live.maturing(pending, parkedAgainst: baseline).wallEnabled == false)
    }

    /// The mirror of it, and the one that matters: the wall put back *after*
    /// the sentence was said is a tightening, and a tightening stands.
    @Test func aWallPutBackAfterParkingIsNotDroppedAgain() {
        let baseline = policy(wall: false)
        let pending = policy(wall: false)      // the sentence never moved it
        let live = policy(wall: true)          // then it was turned back on

        #expect(live.maturing(pending, parkedAgainst: baseline).wallEnabled == true)
    }

    // MARK: - The baseline itself

    /// The most dangerous input in the design, and the reason `maturing` takes
    /// an optional. A caller that "repairs" a missing baseline by substituting
    /// the live policy makes `live == baseline` true by construction, which
    /// collapses the rule to "assign whatever the pending differs from live on"
    /// — the wholesale revert, one boundary late. This is what that looks like.
    @Test func aBaselineEqualToLiveWouldRevertEverything() {
        let live = policy(budget: 30)          // tightened since
        let pending = policy(budget: 90)

        // Handed live as its own baseline, the merge cannot tell the tighten
        // happened and hands back the loosening.
        #expect(live.maturing(pending, parkedAgainst: live).budgetMinutes == 90)
        // Which is exactly why a missing baseline must not be repaired that
        // way. nil matures nothing, and the caller drops the pending.
        #expect(live.maturing(pending, parkedAgainst: nil) == live)
    }

    @Test func aMissingBaselineMaturesNothingAtAll() {
        let live = policy(budget: 30, wall: true)
        let pending = policy(budget: 90,
                             hours: DownHours(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7)),
                             wall: false)
        #expect(live.maturing(pending, parkedAgainst: nil) == live)
    }

    // MARK: - Only what the sentence moved

    @Test func aFieldThePendingNeverProposedIsLeftAlone() {
        let baseline = policy(budget: 60)
        let pending = policy(budget: 90)       // budget only
        // The night moved after parking, by a hand the pending knows nothing of.
        let moved = DownHours(start: TimeOfDay(hour: 21), end: TimeOfDay(hour: 6))
        let live = policy(budget: 60, hours: moved)

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.budgetMinutes == 90, "the proposed field matures")
        #expect(matured.downHours == moved, "the untouched field is not dragged back")
    }

    @Test func oneTouchedFieldDoesNotBlockAnother() {
        let shorter = DownHours(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))
        let baseline = policy(budget: 60)
        let pending = policy(budget: 90, hours: shorter)  // proposes both
        let live = policy(budget: 30)                     // budget tightened, night untouched

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.budgetMinutes == 30, "tightened — held")
        #expect(matured.downHours == shorter, "untouched — matured")
    }

    // MARK: - Doors are live, always

    @Test func doorsComeFromTheLivePolicyNotTheSnapshot() {
        let parked = [Door(name: "Instagram")]
        let now = [Door(name: "Instagram"), Door(name: "Reddit")]
        let baseline = policy(doors: parked)
        let pending = policy(budget: 90, doors: parked)
        let live = policy(doors: now)

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.doors == now, "a door bound in Settings since is not dropped")
        #expect(matured.budgetMinutes == 90)
    }

    @Test func aDroppedDoorIsNotResurrected() {
        let parked = [Door(name: "Instagram"), Door(name: "Reddit")]
        let baseline = policy(doors: parked)
        let pending = policy(budget: 90, doors: parked)
        let live = policy(doors: [Door(name: "Instagram")])

        #expect(live.maturing(pending, parkedAgainst: baseline).doors.count == 1)
    }

    // MARK: - Invariants

    /// "Nothing matures" is an outcome the caller has to be able to see, not a
    /// silent pass-through: it is what keeps the key from being spent on a
    /// no-op and the Now card from advertising a number that will not arrive.
    /// Every field overtaken means the merge returns live, unchanged.
    @Test func aFullyOvertakenPendingIsDetectableAsUnchanged() {
        let baseline = policy(budget: 60)
        let pending = policy(budget: 90)
        let live = policy(budget: 30)

        #expect(live.maturing(pending, parkedAgainst: baseline) == live)
    }

    @Test func maturingIsIdempotent() {
        let baseline = policy(budget: 60)
        let pending = policy(budget: 90)
        let once = baseline.maturing(pending, parkedAgainst: baseline)
        let twice = once.maturing(pending, parkedAgainst: baseline)

        // Once matured, live has left the baseline, so a second application is
        // inert. A pending applied twice must not compound.
        #expect(twice == once)
    }

    @Test func aPendingThatProposedNothingChangesNothing() {
        let live = policy(budget: 45)
        let baseline = policy(budget: 60)
        #expect(live.maturing(baseline, parkedAgainst: baseline) == live)
    }

    // MARK: - Caps merge per KEY, and never prune

    @Test func anUntouchedCapMatures() {
        let baseline = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])     // "let tiktok have 20 a day"
        let live = baseline                          // nobody has touched it since

        #expect(live.maturing(pending, parkedAgainst: baseline).doorCaps[tiktok.id] == 20)
    }

    @Test func aCapTightenedAfterParkingSurvivesMaturity() {
        let baseline = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])     // the raise, parked at 9am
        let live = capPolicy([tiktok.id: 5])         // then, tonight, a tighten

        #expect(live.maturing(pending, parkedAgainst: baseline).doorCaps[tiktok.id] == 5,
                "the later tighten wins; 20 was asked for first")
    }

    /// The counterexample that forces the merge unit to be the key. Under a
    /// whole-dictionary clause the second condition fails on INSTAGRAM's key, so
    /// the entire cap merge declines and TikTok's 20 is gone permanently —
    /// invisible before it happens, because `pendingSummary` returns nil and the
    /// "Apply now." button lives inside the row that summary draws, and
    /// unrecoverable after. This is `oneTouchedFieldDoesNotBlockAnother`
    /// reintroduced inside a dictionary.
    @Test func oneDoorsCapDoesNotBlockAnothers() {
        let baseline = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])
        let live = capPolicy([tiktok.id: 10, instagram.id: 15])

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.doorCaps == [tiktok.id: 20, instagram.id: 15])
    }

    /// A matured "No cap" is a key in the baseline absent from the pending,
    /// which only the union of both key sets can reach — and the nil-bearing
    /// subscript removes it rather than storing a sentinel.
    @Test func aMaturedClearingRemovesTheKey() {
        let baseline = capPolicy([tiktok.id: 20])
        let pending = capPolicy([:])
        let live = baseline

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.doorCaps[tiktok.id] == nil)
        #expect(matured.doorCaps.isEmpty)
    }

    /// The live-door filter, and the fixture has to be the one the filter
    /// actually decides. The door is gone but its cap entry is still sitting at
    /// the baseline value — which is what the policy looks like between a
    /// removal and whatever prunes it, and what it looks like forever if
    /// nothing does. All three arithmetic conditions hold here, so the filter is
    /// the only thing standing between the merge and a cap raised to 20 on a
    /// door no surface can show and no gesture can remove. A live policy that
    /// had also dropped the key would decline on the arithmetic alone and pin
    /// nothing.
    @Test func aCapOnADoorRemovedSinceParkingIsNotResurrected() {
        let baseline = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])
        let live = policy(doors: [instagram], caps: [tiktok.id: 10])   // TikTok is gone

        let matured = live.maturing(pending, parkedAgainst: baseline)
        #expect(matured.doorCaps[tiktok.id] == 10, "not raised to the parked 20")
        #expect(matured == live)
    }

    @Test func capMergeIsIdempotent() {
        let baseline = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])
        let once = baseline.maturing(pending, parkedAgainst: baseline)
        let twice = once.maturing(pending, parkedAgainst: baseline)

        // Once matured, live has left the baseline on that key, so the second
        // condition fails and a second pass is inert.
        #expect(twice == once)
        #expect(twice.doorCaps[tiktok.id] == 20)
    }

    @Test func aMissingBaselineMaturesNoCapEither() {
        let live = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])
        #expect(live.maturing(pending, parkedAgainst: nil) == live)
    }

    /// The key guard again, in cap form: everything the pending proposed has
    /// been overtaken, so the merge returns live exactly and `keyTapped`'s
    /// `next != policy` refuses to spend the key.
    @Test func aFullyOvertakenCapPendingLeavesMaturedEqualToLive() {
        let baseline = capPolicy([tiktok.id: 10])
        let pending = capPolicy([tiktok.id: 20])
        let live = capPolicy([tiktok.id: 5])

        #expect(live.maturing(pending, parkedAgainst: baseline) == live)
    }

    /// The key-burn regression. A `maturing` that also tidied orphan caps would
    /// make `next` differ from live when nothing matured — spending the scarce,
    /// journalled, hand-tapped key, and destroying the pending with it, to
    /// delete a dictionary entry nobody can see. The filter declines to
    /// resurrect; it prunes nothing.
    @Test func maturingNeverPrunesAnOrphanCap() {
        let baseline = policy(doors: [instagram], caps: [:])
        let pending = baseline                                  // proposes nothing
        let live = policy(doors: [instagram], caps: [tiktok.id: 20])   // an orphan

        #expect(live.maturing(pending, parkedAgainst: baseline) == live)
        #expect(live.maturing(pending, parkedAgainst: baseline).doorCaps[tiktok.id] == 20)
    }

    /// The exhaustive statement of the rule, over every combination of
    /// (proposed or not) × (touched or not) for the budget.
    @Test func aFieldMaturesOnlyIfProposedAndUntouched() {
        let baselineBudget = 60
        for proposed in [60, 90] {
            for liveBudget in [60, 30] {
                let baseline = policy(budget: baselineBudget)
                let pending = policy(budget: proposed)
                let live = policy(budget: liveBudget)

                let got = live.maturing(pending, parkedAgainst: baseline).budgetMinutes
                let shouldMature = proposed != baselineBudget && liveBudget == baselineBudget
                #expect(got == (shouldMature ? proposed : liveBudget),
                        "proposed \(proposed), live \(liveBudget)")
            }
        }
    }
}
