import Testing
import Foundation
@testable import Silk
@testable import SilkCore

// The Spend intent raises no wait — docs/design/wait.md §5, "Not waited on".
//
// Said plainly first, because it decides what this file is allowed to contain:
// `SpendIntent` shares NO code with the wait. The wait lives in `AppModel`
// (`raiseWait` … `landWait`), the intent never builds one, and there is no
// shared instance for it to reach — `AppModel()` is written exactly once in the
// whole app, at `SilkApp.swift:7`, inside the scene. So the assertion of the
// obvious shape — perform the intent, expect `model.waiting == nil` — is a
// tautology. It would be asked of a model the intent cannot touch, it would
// pass for a reason unrelated to the thing it claims to check, and no plausible
// change could ever make it fail. It is deliberately not written here.
//
// What can fail is written instead, and it is the observable content of "never
// raises a wait" from outside the model:
//
//   1. the answer is not priced — `perform` does not stand through the seconds
//      of watching the same ask would cost at the bar;
//   2. the transaction is finished when `perform` returns — the debit is in the
//      ledger, or it is not and nothing at all was written, with no third state
//      in which the answer is given now and the minutes land later.
//
// A wait bolted onto this path breaks one or the other.
//
// One honest limitation, stated rather than papered over, and measured rather
// than guessed. The grant branch ends in `WallController.arm`, and the intent
// takes its own grant back out of the ledger when the re-lock will not
// schedule. `DeviceActivityCenter` will not schedule without Screen Time
// authorization, which no test can grant itself — so **on the simulator this
// path always takes the rollback leg**, verified by instrumenting it once. That
// is not a reason to assert only the leg that runs: the same test on hardware,
// authorized, takes the other one, and a rollback-only assertion would pass
// there for the wrong reason. Both legs are written; the fork is named where it
// happens. The one branch with no such dependency — the idempotency guard,
// which answers before the Validator and before the wall is touched at all —
// is asserted exactly.
//
// So what the simulator actually proves here is the rollback: exact, surgical,
// and finished before the dialog. Which is worth having — nothing else in
// either suite reaches that path at all.

/// Performed the way Shortcuts performs it: off the main actor, in a process
/// with no scene and no `AppModel` in it.
///
/// A free function and not a method on the suite, for a compiler reason and a
/// truth reason. `IntentResult` is not `Sendable`, so returning one from this
/// nonisolated call into a `@MainActor` test would not build; and the intent
/// really does run outside the main actor, hopping onto it only for the wall,
/// which is exactly what this shape reproduces.
private func performSpend(door: String, minutes: Int) async throws {
    // `let`, and not an oversight: `@Parameter`'s setter is nonmutating — the
    // wrapper holds its value in a box — so the intent is configured exactly the
    // way the AppIntents runtime configures it.
    let intent = SpendIntent()
    intent.doorName = door
    intent.minutes = minutes
    _ = try await intent.perform()
}

/// The intent's whole world is the App Group, so the fixture writes a policy and
/// stops there.
///
/// Deliberately no `AppModel`: a model starts its minute clock, and a clock that
/// syncs the ledger and reconciles the wall on its own schedule is a second
/// writer standing inside a test whose entire subject is which write happened
/// when.
@MainActor
private func freshPolicy(budget: Int = 40) -> Door {
    SharedStore.wipeAll()
    let door = Door(name: "Instagram")
    SharedStore.save(policy: PolicyState(budgetMinutes: budget,
                                         downHours: nightWellClearOfNow(),
                                         doors: [door]))
    return door
}

@Suite(.serialized) @MainActor struct SpendIntentIsNotGated {

    /// The wait is seconds of watching, and this path has nobody watching. If a
    /// price were ever charged here it would have to be charged as a delay, and
    /// a delay is the one thing a caller can time.
    ///
    /// The bound is the ask's own price at the bar — six seconds for twenty
    /// minutes — and not a stopwatch figure, so the test states the rule rather
    /// than the machine it ran on. What it actually costs is App Group I/O and
    /// one hop to the main actor, in milliseconds.
    @Test func theAnswerIsNotPricedInSecondsOfWatching() async throws {
        let door = freshPolicy()
        defer { WallController().stopMonitoring(door: door) }

        // The same ask at the bar would draw a mark; that is what makes the
        // bound below mean something. That it is drawable at all belongs to
        // `WaitPrice.aWaitShorterThanTheVeilsRiseIsNotDrawnAtAll`, not here.
        let price = Wait.length(forMinutes: 20)

        let started = ContinuousClock.now
        try await performSpend(door: door.name, minutes: 20)
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .seconds(price))
    }

    /// Nothing is debited until the ink lands — and there is no ink here, so the
    /// debit is done by the time the dialog is spoken. The fork is `arm`: with
    /// the re-lock scheduled the grant stands, and without it the intent removes
    /// exactly the grant it recorded and leaves the ledger where it found it.
    /// Both ends are terminal, which is the property under test; a wait would
    /// produce a third state — answered now, debited later — and neither branch
    /// below would hold.
    ///
    /// The ledger starts non-empty on purpose, and that is what makes the
    /// failure branch mean anything.
    ///
    /// Started from empty, both legs passed against a *broken* rollback: one
    /// that failed to remove its own grant still leaves exactly one active
    /// grant on the right door, which satisfies every assertion in the first
    /// branch. Seeded with somebody else's grant first, `atReturn == before` is
    /// a real claim — that `SpendIntent`'s surgical rollback
    /// (`ledger.removeGrant(id:)` over a *reloaded* blob, not a put-back of a
    /// snapshot) preserves a write it did not make and never saw.
    @Test func theWholeTransactionIsFinishedWhenPerformReturns() async throws {
        let door = freshPolicy()
        defer { WallController().stopMonitoring(door: door) }

        // A grant on a door this intent will not touch, standing before it runs.
        let other = Door(name: "TikTok")
        var seeded = GrantLedger()
        seeded.record(Grant(door: other, minutes: 5, issuedAt: .now,
                            expiresAt: Date.now.addingTimeInterval(5 * 60)))
        SharedStore.save(ledger: seeded)
        let before = SharedStore.loadLedger()
        #expect(before.grants.count == 1)

        try await performSpend(door: door.name, minutes: 20)

        let atReturn = SharedStore.loadLedger()
        if let mine = atReturn.grants.first(where: { $0.doorID == door.id }) {
            // The wall took the schedule: the minutes are already spent, on this
            // door, and the door is already open — with the other writer's
            // grant still standing beside it.
            #expect(atReturn.grants.count == 2)
            #expect(mine.minutes > 0)
            #expect(mine.isActive(at: .now))
            #expect(atReturn.grants.contains { $0.doorID == other.id })
        } else {
            // The wall refused it: the rollback took out exactly what this
            // intent recorded and left the rest of the blob alone.
            #expect(atReturn == before)
        }
    }

    /// The one branch that reaches no wall and no Validator, and therefore the
    /// one that is exact on any machine: a repeat inside a live grant re-reads
    /// the balance instead of debiting again.
    ///
    /// `.result(opensIntent:)` is developer-reported to double-invoke under
    /// Siri, and a second debit would be the single-currency promise broken in
    /// the one context with no screen to notice it. Nothing anywhere pinned
    /// this; it is asserted here because it is the same question the file is
    /// about — whether an answer on this path can cost minutes twice, or later.
    @Test func aRepeatInsideALiveGrantRestatesAndDebitsNothing() async throws {
        // No `defer` disarming anything here, deliberately: this branch answers
        // before the wall is touched, so a test that cleaned up after it would
        // be hiding the fact that there is nothing to clean up.
        let door = freshPolicy()

        let now = Date.now
        var ledger = GrantLedger()
        ledger.record(Grant(door: door, minutes: 20, issuedAt: now,
                            expiresAt: now.addingTimeInterval(20 * 60)))
        SharedStore.save(ledger: ledger)
        let before = SharedStore.loadLedger()

        try await performSpend(door: door.name, minutes: 20)

        // Not one minute more, and no second grant to expire out of step with
        // the first.
        #expect(SharedStore.loadLedger() == before)
        #expect(SharedStore.loadLedger().grants.count == 1)
    }
}
