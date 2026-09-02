import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures
//
// `Int` stands in for `ApplicationToken`. The plan compares and unions tokens
// and does nothing else with them, so an opaque FamilyControls blob and an
// integer are the same thing as far as this decision is concerned — which is
// the whole reason the decision was lifted out of the process that holds the
// real ones.

private let instagram = Door(name: "Instagram")
private let youtube = Door(name: "YouTube")

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

private func policy(wallEnabled: Bool = true) -> PolicyState {
    PolicyState(budgetMinutes: 30, downHours: night, doors: [instagram, youtube],
                wallEnabled: wallEnabled)
}

/// Tokens: 1–2 are Instagram's, 3–4 YouTube's, 9 is an extra the wall blocks
/// without a door of its own.
private let doorTokens: [UUID: Set<Int>] = [instagram.id: [1, 2], youtube.id: [3, 4]]
private let extras: Set<Int> = [9]

/// The exception source. `nothingOpen` is the closed wall; `open(_:)` opens
/// exactly the doors named, by looking their tokens up in the map the plan
/// hands back — the same lookup `SharedStore.openDoorTokens` does with a
/// ledger behind it.
private func nothingOpen(_: PolicyState, _: [UUID: Set<Int>]) -> Set<Int> { [] }

private func open(_ doors: Door...) -> (PolicyState, [UUID: Set<Int>]) -> Set<Int> {
    { _, map in
        doors.reduce(into: Set<Int>()) { $0.formUnion(map[$1.id] ?? []) }
    }
}

/// Records whether the plan asked for the exceptions at all — the refusing
/// paths must not, and the corrupt-policy path must not either (it shields the
/// union with no exceptions on purpose).
private final class ExceptionProbe: @unchecked Sendable {
    var asked = false
    lazy var openDoors: (PolicyState, [UUID: Set<Int>]) -> Set<Int> = { [self] _, _ in
        asked = true
        return [1, 2]
    }
}

// MARK: - The policy's own three states

@Suite struct WallPlanPolicyTests {
    @Test func absentPolicyLeavesTheWallAlone() {
        let plan = WallPlan.plan(policy: Decoded<PolicyState>.absent,
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: nothingOpen)
        #expect(plan == .leaveUntouched)
    }

    @Test func absentPolicyNeverAsksForExceptions() {
        let probe = ExceptionProbe()
        _ = WallPlan.plan(policy: Decoded<PolicyState>.absent,
                          extras: .value(extras),
                          doors: .value(doorTokens),
                          openDoors: probe.openDoors)
        #expect(probe.asked == false)
    }

    @Test func corruptPolicyShieldsTheWholeUnion() {
        let plan = WallPlan.plan(policy: Decoded<PolicyState>.corrupt,
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: open(instagram))
        // Every token, and the open door's among them: a policy that will not
        // decode cannot tell an honoured grant from a retracted one.
        #expect(plan == .shield([1, 2, 3, 4, 9]))
    }

    @Test func corruptPolicyDoesNotEvenAskWhichDoorsAreOpen() {
        let probe = ExceptionProbe()
        _ = WallPlan.plan(policy: Decoded<PolicyState>.corrupt,
                          extras: .value(extras),
                          doors: .value(doorTokens),
                          openDoors: probe.openDoors)
        #expect(probe.asked == false)
    }

    @Test func corruptPolicyWithAnEmptyUnionRefusesToWrite() {
        // Both keys readable and genuinely empty. Writing `.shield([])` here
        // would tear the standing shield down under a policy this process
        // cannot read — the fail-open the refusal exists to prevent.
        let plan = WallPlan.plan(policy: Decoded<PolicyState>.corrupt,
                                 extras: Decoded<Set<Int>>.value([]),
                                 doors: Decoded<[UUID: Set<Int>]>.value([:]),
                                 openDoors: nothingOpen)
        #expect(plan == .leaveUntouched)
    }

    @Test func corruptPolicyWithAbsentSelectionsRefusesToWrite() {
        let plan = WallPlan.plan(policy: Decoded<PolicyState>.corrupt,
                                 extras: Decoded<Set<Int>>.absent,
                                 doors: Decoded<[UUID: Set<Int>]>.absent,
                                 openDoors: nothingOpen)
        #expect(plan == .leaveUntouched)
    }
}

// MARK: - The selections' three states
//
// The bug this suite exists for: a policy that decodes, a token blob that does
// not, and a wall that came down because an unreadable set was read as an
// empty one.

@Suite struct WallPlanSelectionTests {
    @Test func corruptExtrasUnderAGoodPolicyLeavesTheWallAlone() {
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: Decoded<Set<Int>>.corrupt,
                                 doors: .value(doorTokens),
                                 openDoors: nothingOpen)
        #expect(plan == .leaveUntouched)
    }

    @Test func corruptDoorsUnderAGoodPolicyLeavesTheWallAlone() {
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: .value(extras),
                                 doors: Decoded<[UUID: Set<Int>]>.corrupt,
                                 openDoors: nothingOpen)
        #expect(plan == .leaveUntouched)
    }

    @Test func corruptSelectionsNeverAskWhichDoorsAreOpen() {
        // The refusal is decided before the ledger is consulted: there is no
        // set of open doors that could make a partial union safe to write.
        let probe = ExceptionProbe()
        _ = WallPlan.plan(policy: .value(policy()),
                          extras: .value(extras),
                          doors: Decoded<[UUID: Set<Int>]>.corrupt,
                          openDoors: probe.openDoors)
        #expect(probe.asked == false)
    }

    @Test func corruptSelectionsUnderACorruptPolicyLeaveTheWallAlone() {
        // Both inputs unreadable at once — the realistic post-upgrade shape.
        // A partial union is not fail-closed: the half it cannot read is the
        // half that would come out of the shield.
        let plan = WallPlan.plan(policy: Decoded<PolicyState>.corrupt,
                                 extras: .value(extras),
                                 doors: Decoded<[UUID: Set<Int>]>.corrupt,
                                 openDoors: nothingOpen)
        #expect(plan == .leaveUntouched)
    }

    @Test func absentSelectionsAreEmptyOnesAndStillCarryTheOtherKey() {
        // An absent key is a wall nobody configured that way, not one nobody
        // could read: the doors alone can carry the whole policy, and so can
        // the extras alone.
        #expect(WallPlan.plan(policy: .value(policy()),
                              extras: Decoded<Set<Int>>.absent,
                              doors: .value(doorTokens),
                              openDoors: nothingOpen) == .shield([1, 2, 3, 4]))
        #expect(WallPlan.plan(policy: .value(policy()),
                              extras: .value(extras),
                              doors: Decoded<[UUID: Set<Int>]>.absent,
                              openDoors: nothingOpen) == .shield([9]))
    }

    @Test func bothSelectionsAbsentUnderAGoodPolicyShieldsNothing() {
        // Not a refusal: the policy decoded, said the wall is on, and named no
        // tokens. `.shield([])` is what "on, with nothing chosen yet" means,
        // and it is the state onboarding leaves behind before the picker runs.
        #expect(WallPlan.plan(policy: .value(policy()),
                              extras: Decoded<Set<Int>>.absent,
                              doors: Decoded<[UUID: Set<Int>]>.absent,
                              openDoors: nothingOpen) == .shield([]))
    }
}

// MARK: - The switch

@Suite struct WallPlanWallOffTests {
    @Test func wallOffClearsEverything() {
        let plan = WallPlan.plan(policy: .value(policy(wallEnabled: false)),
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: nothingOpen)
        #expect(plan == .clearAll)
    }

    @Test func wallOffClearsEverythingEvenWithCorruptSelections() {
        // Off means down whatever the token blobs say. The policy decoded and
        // said off; fail-closed governs the doors, not the switch.
        #expect(WallPlan.plan(policy: .value(policy(wallEnabled: false)),
                              extras: Decoded<Set<Int>>.corrupt,
                              doors: .value(doorTokens),
                              openDoors: nothingOpen) == .clearAll)
        #expect(WallPlan.plan(policy: .value(policy(wallEnabled: false)),
                              extras: .value(extras),
                              doors: Decoded<[UUID: Set<Int>]>.corrupt,
                              openDoors: nothingOpen) == .clearAll)
        #expect(WallPlan.plan(policy: .value(policy(wallEnabled: false)),
                              extras: Decoded<Set<Int>>.corrupt,
                              doors: Decoded<[UUID: Set<Int>]>.corrupt,
                              openDoors: nothingOpen) == .clearAll)
    }

    @Test func wallOffNeverAsksWhichDoorsAreOpen() {
        let probe = ExceptionProbe()
        _ = WallPlan.plan(policy: .value(policy(wallEnabled: false)),
                          extras: .value(extras),
                          doors: .value(doorTokens),
                          openDoors: probe.openDoors)
        #expect(probe.asked == false)
    }
}

// MARK: - The ordinary day

@Suite struct WallPlanEnabledTests {
    @Test func enabledShieldsTheUnion() {
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: nothingOpen)
        #expect(plan == .shield([1, 2, 3, 4, 9]))
    }

    @Test func anOpenDoorSubtractsItsOwnTokensAndNoOthers() {
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: open(instagram))
        // Instagram's 1 and 2 come out; YouTube's 3 and 4 — a closed door —
        // stay, and so does the extra, which no grant can ever open.
        #expect(plan == .shield([3, 4, 9]))
    }

    @Test func twoOpenDoorsSubtractBoth() {
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: open(instagram, youtube))
        #expect(plan == .shield([9]))
    }

    @Test func theExceptionsAreAskedAgainstTheDoorMapThatWasRead() {
        // The map handed to `openDoors` is the one the plan actually unioned,
        // not a second read: a door whose tokens are not in the map cannot
        // subtract anything, and one whose tokens are, subtracts exactly them.
        var seen: [UUID: Set<Int>] = [:]
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: .value(extras),
                                 doors: .value([instagram.id: [1, 2]]),
                                 openDoors: { _, map in
                                     seen = map
                                     return map[youtube.id] ?? []
                                 })
        #expect(seen == [instagram.id: [1, 2]])
        #expect(plan == .shield([1, 2, 9]))
    }

    @Test func theDecodedPolicyItselfReachesTheExceptions() {
        // `openDoors` needs the established day, which comes off `downHours`
        // — so it must be handed the policy that decoded, not a copy.
        var seen: PolicyState?
        _ = WallPlan.plan(policy: .value(policy()),
                          extras: .value(extras),
                          doors: .value(doorTokens),
                          openDoors: { p, _ in
                              seen = p
                              return []
                          })
        #expect(seen == policy())
    }

    @Test func anExceptionForATokenNothingBlocksChangesNothing() {
        // Subtraction, not assertion: a stale door id in the ledger whose
        // tokens are no longer in any selection cannot punch a hole in the
        // wall, because there is nothing there to subtract.
        let plan = WallPlan.plan(policy: .value(policy()),
                                 extras: .value(extras),
                                 doors: .value(doorTokens),
                                 openDoors: { _, _ in [77, 88] })
        #expect(plan == .shield([1, 2, 3, 4, 9]))
    }
}

// MARK: - The three-way read itself

@Suite struct DecodedTests {
    @Test func orEmptyFillsInTheAbsentKeyAndRefusesTheCorruptOne() {
        #expect(Decoded<Set<Int>>.absent.orEmpty([]) == [])
        #expect(Decoded<Set<Int>>.value([1]).orEmpty([]) == [1])
        #expect(Decoded<Set<Int>>.corrupt.orEmpty([]) == nil)
    }

    @Test func isCorruptNamesOnlyTheUnreadableState() {
        #expect(Decoded<Int>.corrupt.isCorrupt)
        #expect(!Decoded<Int>.absent.isCorrupt)
        #expect(!Decoded<Int>.value(1).isCorrupt)
    }

    @Test func mapCarriesTheStateAndNotJustTheValue() {
        // The mapping the reconcile does to get token sets out of the
        // selections must not turn an unreadable blob into a readable empty
        // one on the way through.
        #expect(Decoded<[Int]>.corrupt.map(Set.init).isCorrupt)
        #expect(Decoded<[Int]>.absent.map(Set.init).orEmpty([]) == [])
        #expect(Decoded<[Int]>.value([1, 1, 2]).map(Set.init).orEmpty([]) == [1, 2])
    }
}
