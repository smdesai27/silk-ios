import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// The ledger side of the wait: what is written, when, and what a tap on Undo
// puts back.
//
// `WaitModelTests` owns the state machine — raise, pause, resume, land, drop.
// These own the transaction `docs/design/wait.md` §5 is an argument about:
// **nothing is debited, unshielded or armed until the ink lands**, the grant
// lands exactly once when it does, and the way back still works on the far side
// of seconds it never used to have to survive.
//
// The undo test is why this file exists. It is the highest-value missing
// assertion in the repo and it is verified by hand and by nothing else: the
// shipped walk (`testTypedTightenOffersUndoAndRestores`) undoes a *tighten*,
// and a grant's undo closure is now built inside `landWait`, over a *second*
// verdict, keyed to a ledger generation that the wait's own seconds give three
// other writers time to move. Every ingredient of that sentence is new.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group. That
// makes state global to the process, which is why every test starts from
// `freshModel()`.
//
// `.serialized` and `@MainActor` for the reason `WaitModelTests` gives. Worth
// adding, because these tests suspend and its do not: `.serialized` only orders
// THIS suite's tests against each other. What keeps a sibling suite's
// `SharedStore.wipeAll()` out of the middle of one of the sleeps below is the
// scheme's `parallelizable = "NO"` on SilkTests. If that ever becomes YES,
// these three go flaky and nothing else in the target will.

@MainActor
private func freshModel(budget: Int = 40) -> (AppModel, Door) {
    SharedStore.wipeAll()
    let model = AppModel()
    let door = Door(name: "Instagram")
    model.completeSetup(doors: [door],
                        doorSelections: [:],
                        wallSelection: .init(),
                        budget: budget,
                        downHours: nightWellClearOfNow())
    // Every wait below is born watching, and that is only true while the host
    // app is foreground. `raiseWait` parks a wait created in the background
    // (the C1 fix), so a runner that started tests before the scene activated
    // would fail nine cases at once with nine unrelated-looking messages.
    // Named here instead, once.
    #expect(UIApplication.shared.applicationState != .background,
            "the host app is not foreground — every wait below will be born parked")
    return (model, door)
}

@Suite(.serialized) @MainActor struct WaitTransactionTests {

    /// Long enough that the veil is provably still standing on the line after
    /// `handle` returns — `handle` spends its ~480 ms beat before it raises
    /// anything, so this is measured from the raise and nothing else — and
    /// short enough that no test here sleeps for more than about a second.
    /// Well over `Wait.tooShortToDraw`; under it no wait is drawn at all and
    /// every test below would be quietly asserting the old synchronous path.
    private static let waitSeconds = 0.8

    /// A proven grant sentence (`SilkCoreTests.theClampTakesTheSmallestOfThree`
    /// uses this exact string), so the deterministic grammar answers it and the
    /// on-device widener is never reached. Twenty against forty does not clamp,
    /// which is what lets the balance be asserted as a number.
    private static let ask = "give me twenty minutes of instagram"

    /// What the grant read-back says when it finally lands. Written out rather
    /// than recomposed from `SilkStrings`: recomposing it would re-derive the
    /// implementation and assert nothing, and this is a shipped sentence worth
    /// pinning.
    private static let readBack = "Instagram is open for 20 min."

    // MARK: - (b) Nothing moves while the veil stands

    /// The record-after ordering, caught at model level and then followed
    /// through to the landing.
    ///
    /// The middle block is the load-bearing one, and the App Group half of it
    /// especially. `Wall.reconcile` derives the open doors from the ledger blob
    /// and four processes recompute it independently — so **recording a grant
    /// IS unshielding**. A grant written while the veil stands would mean she
    /// presses Home, taps Instagram, and is in; the wait becomes a screen you
    /// walk around. Nothing else in the repo asserts the blob is untouched
    /// mid-wait: the UI walk can only see the hero still reading 40.
    @Test func nothingMovesWhileTheVeilStandsAndTheGrantLandsOnceWhenItFalls() async throws {
        UserDefaults.standard.set("\(Self.waitSeconds)", forKey: "silkWait")
        defer { UserDefaults.standard.removeObject(forKey: "silkWait") }

        let (model, door) = freshModel()
        let untouched = SharedStore.loadLedger()
        let said = Date.now

        await model.handle(Self.ask)

        // `handle` returned by way of `raiseWait`, not by way of `apply`: the
        // veil is up over this door and the turn is still unanswered.
        let waiting = try #require(model.waiting,
                                   "no wait was raised over a granted ask")
        #expect(waiting.door.id == door.id)
        #expect(waiting.wait.minutes == 20)
        let pending = try #require(model.conversation.turns.last)
        #expect(pending.reply == nil)
        #expect(pending.undo == nil)

        // Not one minute, in memory or in the store the shield reads.
        #expect(model.remainingMinutes == 40)
        #expect(model.ledger.grants.isEmpty)
        #expect(SharedStore.loadLedger() == untouched)
        // The wall's own derivation, asked directly. (`arm`'s two schedules are
        // the third thing §5 says is not touched yet, and they are the one part
        // no test can see — they exist only inside DeviceActivity. They ride
        // `wall.arm`, reached through `restateRelockLayers` after a commit,
        // so an empty ledger is as close to that assertion as this gets.)
        #expect(!model.ledger.openDoors(at: .now, dayStart: model.dayStart)
            .contains(door.id))
        #expect(model.state(of: door) == .live)

        let landed = await settle { model.waiting == nil }
        #expect(landed, "the ink never landed")

        // Exactly one grant, and exactly one debit. `landWait` re-arms rather
        // than returns when the clock disagrees with its task, so "twice" is
        // the way this goes wrong, and it would read here as two rows and a
        // balance of 0.
        #expect(model.ledger.grants.count == 1)
        let grant = try #require(model.ledger.grants.first)
        #expect(grant.doorID == door.id)
        #expect(grant.minutes == 20)
        #expect(model.remainingMinutes == 20)
        #expect(SharedStore.loadLedger().grants.count == 1)
        #expect(model.ledger.openDoors(at: .now, dayStart: model.dayStart)
            .contains(door.id))

        // Answered in the turn it was holding, and no second turn invented for
        // it.
        #expect(model.conversation.turns.count == 1)
        let answered = try #require(model.conversation.turns.last)
        #expect(answered.id == waiting.turn)
        #expect(answered.reply == Self.readBack)

        // Record-after restated as arithmetic. The grant is stamped when the
        // ink landed, not when the sentence was said, so none of its twenty
        // minutes was spent standing in Silk — which is the "the re-lock gets
        // more honest" bullet of §5. Under the record-before ordering
        // `issuedAt` would sit ~480 ms after `said`: the beat alone.
        #expect(grant.issuedAt.timeIntervalSince(said) >= Self.waitSeconds)
        #expect(abs(grant.expiresAt.timeIntervalSince(grant.issuedAt) - 20 * 60) < 1)
    }

    // MARK: - (a) The way back, on the far side of a wait

    /// Undo after a wait puts the minutes back and shuts the door.
    ///
    /// Everything about this offer is new. It is built inside `landWait`, from
    /// a verdict computed seconds after the sentence; its `previous` ledger is
    /// snapshotted at the landing rather than at the send; and it is keyed to
    /// `ledgerGeneration + 1`, which any movement at all — a reload folding in
    /// a Shortcuts grant, the day-turn compaction, another turn — retires. An
    /// expired offer returns false, the pill goes, and the reply keeps standing
    /// as written; so "Put back." is the receipt that the restore actually
    /// landed, and asserting it is asserting the generation survived the wait.
    ///
    /// Driven through `ConversationModel.undo` — the pill's own action — rather
    /// than by calling the closure out of the turn, because the pill is what a
    /// user has.
    @Test func undoAfterAWaitPutsTheMinutesBackAndShutsTheDoor() async throws {
        UserDefaults.standard.set("\(Self.waitSeconds)", forKey: "silkWait")
        defer { UserDefaults.standard.removeObject(forKey: "silkWait") }

        let (model, door) = freshModel()
        await model.handle(Self.ask)
        let landed = await settle { model.waiting == nil }
        #expect(landed, "the ink never landed")

        #expect(model.remainingMinutes == 20)
        #expect(model.ledger.grants.count == 1)
        #expect(model.state(of: door) != .live, "the grant never opened the door")

        let turn = try #require(model.conversation.turns.last,
                                "the wait ended without answering its turn")
        #expect(turn.reply == Self.readBack)
        #expect(turn.undo != nil, "a grant landed from a wait offered no way back")

        model.conversation.undo(turn.id)

        // The budget whole again, in memory and in the blob — and the door shut
        // with it, because the door was only ever open by derivation from the
        // row that has now gone.
        #expect(model.remainingMinutes == 40)
        #expect(model.ledger.grants.isEmpty)
        #expect(SharedStore.loadLedger().grants.isEmpty)
        #expect(!model.ledger.openDoors(at: .now, dayStart: model.dayStart)
            .contains(door.id))
        #expect(model.state(of: door) == .live)

        // Receipts never lie: "Put back." is written only over a restore that
        // happened, so this is the assertion that the offer had not expired
        // under the pill while the ink was drying.
        let after = try #require(model.conversation.turns.last)
        #expect(after.id == turn.id)
        #expect(after.reply == SilkStrings.putBack)
        #expect(after.undone)
        #expect(after.undo == nil, "the pill stayed up over a spent offer")
    }

    // MARK: - (i) A door deleted while the ink is drawing

    /// The last row of §7's table: the door is deleted mid-wait, so the turn is
    /// dropped.
    ///
    /// Checked in `landWait` rather than left to the Validator, which would
    /// answer a deleted door with "Didn't get that." — true of the sentence and
    /// a lie about what happened. So the assertion is that the thread is
    /// *empty*: not a refusal, not silence, and above all not an unresolved "…"
    /// left standing, which is the app claiming to still be thinking about a
    /// sentence it has already forgotten.
    ///
    /// Reached through Settings' own `removeDoor`, which is the real path and
    /// the one that can actually run under a veil — the veil covers Settings,
    /// but this call is also where a Shortcut and an undone add arrive.
    @Test func aDoorDeletedMidWaitDropsTheAskAndSpendsNothing() async throws {
        UserDefaults.standard.set("\(Self.waitSeconds)", forKey: "silkWait")
        defer { UserDefaults.standard.removeObject(forKey: "silkWait") }

        let (model, door) = freshModel()
        let untouched = SharedStore.loadLedger()

        await model.handle(Self.ask)
        #expect(model.waiting != nil, "no wait was raised over a granted ask")

        model.removeDoor(door)
        #expect(model.policy.doors.isEmpty, "the door did not leave the policy")
        #expect(model.waiting != nil, "removing the door lowered the veil early")

        let cleared = await settle { model.waiting == nil }
        #expect(cleared, "the veil never came down over a deleted door")

        #expect(model.conversation.turns.isEmpty,
                "the ask was answered instead of dropped")
        // Byte-identical to the state before she typed, which is what makes
        // every wait-ending path that is not a landing free.
        #expect(model.remainingMinutes == 40)
        #expect(model.ledger.grants.isEmpty)
        #expect(SharedStore.loadLedger() == untouched)
    }

    // MARK: - The second verdict is the one that lands

    /// The central claim of `landWait`, and the reason the re-validation exists
    /// at all: *"she can be answered differently than she would have been six
    /// seconds ago."*
    ///
    /// The arithmetic of that is tested one layer down —
    /// `WaitRevalidationProvenance` in the spine proves the Validator re-clamps
    /// and refuses correctly. What nothing tested is that `AppModel` actually
    /// **asks it again**: that `landWait` re-syncs against a writer it never
    /// saw, validates the held outcome against what stands now, and lands that
    /// answer rather than the one it computed before the veil rose.
    ///
    /// Land the first verdict instead — which is the shape this feature started
    /// as — and this goes red: a grant would be recorded against a pool that no
    /// longer has the minutes in it, which is invariant 4 read backwards.
    ///
    /// The other writer is not hypothetical. `SpendIntent` writes the App Group
    /// from its own process while the app sits behind a veil, and stamps the
    /// blob exactly as this does.
    @Test func aPoolEmptiedByAnotherWriterMidWaitIsRefusedRatherThanGranted() async {
        UserDefaults.standard.set("\(Self.waitSeconds)", forKey: "silkWait")
        defer { UserDefaults.standard.removeObject(forKey: "silkWait") }

        let (model, door) = freshModel()

        await model.handle(Self.ask)
        #expect(model.waiting != nil, "no wait was raised over a granted ask")
        #expect(model.remainingMinutes == 40, "the pool moved before the ink landed")

        // A second door, spent to the floor by someone else while she watches.
        let elsewhere = Door(name: "TikTok")
        var theirs = SharedStore.loadLedger()
        theirs.record(Grant(door: elsewhere, minutes: 40, issuedAt: .now,
                            expiresAt: Date.now.addingTimeInterval(40 * 60)))
        SharedStore.save(ledger: theirs)

        #expect(await settle { model.waiting == nil }, "the veil never came down")

        // The first verdict said "grant twenty". The second says there is
        // nothing left, and the second is the one that is spoken.
        let reply = model.conversation.turns.last?.reply
        #expect(reply?.contains("0 \(SilkStrings.leftToday)") == true,
                "the wait landed the verdict from before it rather than the one that is true — read \"\(reply ?? "nil")\"")
        #expect(reply?.contains(Self.readBack) == false,
                "a grant landed against a pool another writer had already emptied")

        // A refusal all the way down, not only in words: nothing on her door,
        // and nothing to take back.
        #expect(model.ledger.grants.contains { $0.doorID == door.id } == false,
                "a grant was recorded for a door with no minutes behind it")
        #expect(model.conversation.turns.last?.undo == nil,
                "a refusal offered a way back to something that never happened")
    }

    // MARK: - (g) The minute clock is put back

    /// Every wait cancels the app's minute clock, and only `clearWait` restarts
    /// it. A wait-ending path that forgot to would freeze the one thing on Now
    /// that moves by itself — deadlines would stop being reached, the day would
    /// stop turning over — silently, for the life of the process, with no other
    /// symptom.
    ///
    /// `clock` and `startClock` are both private, so this reads the clock's
    /// *output* instead: `now`, which nothing else writes once `landWait` has
    /// set it. A grant expiring shortly gives the clock a reason to wake before
    /// the next minute boundary (`nextWake` takes the sooner of the
    /// two), so the poll has something to see inside a second rather than up to
    /// sixty.
    ///
    /// **The seeded expiry has to outlive the landing, and the first draft barely
    /// did.** It expired 1.2 s after it was written while the wait lands 0.8 s
    /// later, leaving ~0.4 s — and less than that in practice, because
    /// `startClock()`'s body cannot run until `landWait` returns, so the ledger
    /// write, the re-validation and the wall reconcile all come out of the same
    /// margin. Lose that race and `nextTransition` drops the expired row
    /// (`GrantLedger.swift:163-165`), `nextWake` falls back to the next
    /// minute boundary, and the poll below fails with a message accusing
    /// `clearWait` of a defect that is not there. It is a cliff and not a
    /// gradient: win and the tick fires at 1 s, lose and it is up to 60 s out.
    /// Seeding the expiry three seconds past the landing removes the race without
    /// touching what is asserted.
    ///
    /// Delete `startClock()` from `clearWait` and `now` never moves again.
    @Test func theMinuteClockIsRunningAgainOnTheFarSideOfAWait() async {
        UserDefaults.standard.set("\(Self.waitSeconds)", forKey: "silkWait")
        defer { UserDefaults.standard.removeObject(forKey: "silkWait") }

        let (model, _) = freshModel()
        await model.handle(Self.ask)
        #expect(model.waiting != nil, "no wait was raised over a granted ask")

        // A transition for the clock to aim at, written from outside so
        // `landWait`'s own sync folds it in on the way past. Comfortably past the
        // landing, and still well inside the poll below.
        let theirExpiry = Self.waitSeconds + 3
        var theirs = SharedStore.loadLedger()
        theirs.record(Grant(door: Door(name: "TikTok"), minutes: 1, issuedAt: .now,
                            expiresAt: Date.now.addingTimeInterval(theirExpiry)))
        SharedStore.save(ledger: theirs)

        #expect(await settle { model.waiting == nil }, "the veil never came down")

        // Snapshot AFTER the landing, which sets `now` itself. From here only
        // the clock can move it.
        let landed = model.now
        #expect(await settle(within: theirExpiry + 4) { model.now > landed },
                "the minute clock never woke after the wait — clearWait did not put it back")
    }
}
