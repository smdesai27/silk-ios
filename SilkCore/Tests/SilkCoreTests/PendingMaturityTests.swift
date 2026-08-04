import Testing
import Foundation
@testable import SilkCore

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

private func policy(budget: Int = 60,
                    hours: DownHours = night,
                    doors: [Door] = [Door(name: "Instagram")],
                    wall: Bool = true) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: hours, doors: doors, wallEnabled: wall)
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
