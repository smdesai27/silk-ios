import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// The turn: asked, answered, and everything that can happen in between.
//
// `ConversationModel` owns reply addressing, the Undo pill's window, and the
// teardown on blur — and until this file nothing tested any of it. The spine
// cannot reach it (it is in the app target), the walks do not exercise it (a
// simulator walk types one sentence and reads one reply), and `WaitLifecycle`
// drives `handle` only through the one verdict that raises a veil. What was
// left unpinned is precisely the machinery that exists because REPLIES ARRIVE
// LATE: the id-keyed landing, the guard against a late reply overwriting an
// undone turn, the offer that expires under the pill, and the blur that used to
// throw a receipt away.
//
// The last of those is why this file has a fixture that suspends `handle`
// mid-flight. It is the shape a user actually produces — type a sentence the
// grammar declines, watch "…" for a second, tap the page — and it applied the
// tighten with no sentence and no way back.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group. That
// makes state global to the process, which is why every test starts from
// `freshModel()` — `TestSupport`'s, now, rather than a seventh copy of it.

// MARK: - The conversation on its own

@Suite @MainActor struct TheTurnIsAddressedByIdentity {

    /// Replies arrive late, and a second question can be asked before the first
    /// is answered. Keyed by index, the late reply rewrites the wrong turn —
    /// which is exactly the bug the handoff calls out by name and the reason
    /// `land` takes an id. Nothing tested it.
    @Test func aLateReplyLandsOnItsOwnTurn() {
        let convo = ConversationModel()
        let first = convo.ask("block instagram")
        let second = convo.ask("how much is left")

        convo.land("40 left today.", for: second)
        #expect(convo.turns[0].reply == nil, "the first turn was answered by the second's reply")
        #expect(convo.turns[1].reply == "40 left today.")

        convo.land("Instagram closed until 7:00.", for: first)
        #expect(convo.turns[0].reply == "Instagram closed until 7:00.")
        #expect(convo.turns[1].reply == "40 left today.", "the late reply overwrote the newer turn")
    }

    /// A turn that blurred away swallows its reply rather than resurrecting
    /// itself into an empty thread.
    @Test func aReplyToAVanishedTurnIsSwallowed() {
        let convo = ConversationModel()
        let id = convo.ask("block instagram")
        convo.clear()
        convo.land("Instagram closed until 7:00.", for: id)
        #expect(convo.turns.isEmpty, "a reply resurrected a turn that was torn down")
    }

    /// "Put back." is a receipt, and a receipt may not be written over. The
    /// 480 ms window between an undo and a late reply is small and real.
    @Test func anUndoneTurnRefusesALateReply() {
        let convo = ConversationModel()
        let id = convo.ask("block instagram")
        convo.land("Instagram closed until 7:00.", undo: { true }, for: id)
        convo.undo(id)
        #expect(convo.turns[0].reply == SilkStrings.putBack)

        convo.land("Instagram closed until 9:00.", for: id)
        #expect(convo.turns[0].reply == SilkStrings.putBack, "a late reply overwrote \"Put back.\"")
    }

    /// **RECEIPTS NEVER LIE**, in the one case where the machinery could make
    /// one. An offer can expire under the pill — a later ledger mutation retires
    /// every earlier one — and when the restore does not land, only the pill
    /// goes. The reply keeps stating what actually happened, and the turn is not
    /// marked undone, because it was not. This guard had nothing pinning it.
    @Test func anExpiredUndoDropsThePillAndKeepsTheReply() {
        let convo = ConversationModel()
        let id = convo.ask("block instagram")
        convo.land("Instagram closed until 7:00.", undo: { false }, for: id)

        convo.undo(id)

        #expect(convo.turns[0].reply == "Instagram closed until 7:00.",
                "an undo that never landed rewrote the receipt anyway")
        #expect(convo.turns[0].undo == nil, "the pill survived an offer that had expired")
        #expect(convo.turns[0].undone == false, "a turn was marked undone by a restore that failed")
    }

    /// The window closes on the clock as well as on a tap. The reply stands;
    /// only the offer is withdrawn.
    @Test func expiringTheOfferLeavesTheSentence() {
        let convo = ConversationModel()
        let id = convo.ask("block instagram")
        convo.land("Instagram closed until 7:00.", undo: { true }, for: id)

        convo.expireUndo(id)

        #expect(convo.turns[0].undo == nil)
        #expect(convo.turns[0].reply == "Instagram closed until 7:00.")
    }

    /// Only the last three are in view; the rest have dissolved into the top
    /// fade. Everything asked is still addressable.
    @Test func onlyTheLastThreeTurnsAreVisible() {
        let convo = ConversationModel()
        let ids = (1...5).map { convo.ask("sentence \($0)") }
        #expect(convo.visibleTurns.count == 3)
        #expect(convo.visibleTurns.first?.you == "sentence 3")

        convo.land("answered", for: ids[0])
        #expect(convo.turns[0].reply == "answered", "a turn past the window stopped being addressable")
    }
}

// MARK: - The blur that used to throw a receipt away

@Suite @MainActor struct ABlurWaitsForTheTurnItIsHolding {

    /// The defect, stated as the sequence that produces it: a turn is asked, no
    /// reply has arrived, the user taps the page. Before `blur()` this cleared
    /// the thread, and the reply — with its Undo pill — landed on an id that no
    /// longer existed.
    @Test func aPendingTurnHoldsTheThreadOpen() {
        let convo = ConversationModel()
        convo.focused = true
        let id = convo.ask("block instagram")

        convo.blur()

        #expect(convo.focused, "the blur landed while a turn was still at \"…\"")
        #expect(convo.hasPendingTurn)
        #expect(convo.turns.count == 1, "the thread was cleared out from under a pending turn")

        // The receipt arrives, and now has somewhere to go.
        convo.land("Instagram closed until 7:00.", undo: { true }, for: id)
        #expect(convo.turns[0].reply == "Instagram closed until 7:00.")
        #expect(convo.turns[0].undo != nil, "the way back was lost with the turn")

        // And the next tap tears down normally — deferred by one reply, never
        // abandoned.
        convo.blur()
        #expect(convo.focused == false)
        #expect(convo.turns.isEmpty)
    }

    /// A blur with nothing in flight is unchanged: the thread is a moment, not
    /// a log.
    @Test func anAnsweredThreadStillClearsOnBlur() {
        let convo = ConversationModel()
        convo.focused = true
        let id = convo.ask("block instagram")
        convo.land("Instagram closed until 7:00.", for: id)

        convo.blur()

        #expect(convo.focused == false)
        #expect(convo.turns.isEmpty)
    }

    /// A dropped ask un-blocks the blur it was holding — the path `dropAsk`
    /// takes when a wait goes stale. Without it the user comes back to a
    /// five-percent-opacity page with an empty thread over it.
    @Test func droppingThePendingTurnReleasesTheBlur() {
        let convo = ConversationModel()
        convo.focused = true
        let id = convo.ask("block instagram")

        convo.blur()
        #expect(convo.focused, "the pending turn did not hold the thread")

        convo.drop(id)
        convo.blur()
        #expect(convo.focused == false, "the thread stayed dimmed after its only turn went")
        #expect(convo.turns.isEmpty)
    }
}

// MARK: - handle, end to end

@Suite(.serialized) @MainActor struct TheBarAnswersTheSentence {

    /// **A NICKNAME IS NOT A DOOR.** Doors are built `Door(name: display)` and
    /// `Door.spokenForms` is the name and nothing else now, so the catalogue's
    /// own shorthand for an app — "yt", and "ig" and "insta" before it — reaches
    /// the grammar as an unknown word.
    ///
    /// This test held the opposite fact once: the shorthand spent on its door,
    /// and its absence was what let a green CI and a broken product coexist.
    /// The nicknames went out with the bare shortcut form, for the reason
    /// PolicyState.swift:44 states — a short nickname answers yes far more often
    /// than the user meant one, and what one now reaches is a "Write it out:"
    /// hint on a door the sentence may never have named. The fact reversed; the
    /// assertion stayed, on the same door made exactly the way the app makes
    /// one, because a nickname table quietly coming back is the regression this
    /// file is placed to catch.
    ///
    /// The widener is silenced so the reply is assertable: a nickname is prose
    /// now, and prose on a phone with a model is the model's business.
    @Test(arguments: ["give me 10 minutes of yt", "10 minutes of yt", "yt for 10 minutes"])
    func theCataloguesShorthandIsNotADoor(_ sentence: String) async {
        SilkModelParser.testForceSilent = true
        defer { SilkModelParser.testForceSilent = false; unpinTheSeams() }
        UserDefaults.standard.set("0", forKey: "silkWait")
        SharedStore.wipeAll()
        let model = AppModel()
        model.completeSetup(doors: [Door(name: "YouTube")], doorSelections: [:],
                            wallSelection: .init(), budget: 40, downHours: noWindowTonight())
        // The premise, and the whole subject of this test: the DETERMINISTIC
        // grammar does NOT read the catalogue's shorthand.
        #expect(DeterministicParser.parse(sentence, state: model.policy) == .silence,
                "the grammar claims \"\(sentence)\" again — the nickname table is back")

        await model.handle(sentence)

        #expect(model.remainingMinutes == 40,
                "\"\(sentence)\" spent minutes on a word no door answers to")
        #expect(model.ledger.grants.isEmpty, "\"\(sentence)\" recorded a grant")
        let reply = model.conversation.turns.last?.reply
        #expect(reply == SilkStrings.didntGetThat, "\"\(sentence)\" answered: \(reply ?? "nil")")
        #expect(model.conversation.turns.last?.undo == nil,
                "a sentence that moved nothing offered a way back")
    }

    /// And the close, on the door's own name — which is the only name it has.
    @Test func theDoorsOwnNameClosesItsDoor() async {
        defer { unpinTheSeams() }
        SharedStore.wipeAll()
        let model = AppModel()
        let door = Door(name: "YouTube")
        model.completeSetup(doors: [door], doorSelections: [:], wallSelection: .init(),
                            budget: 40, downHours: noWindowTonight())
        // The grammar has to be the one that reads it, or this passes on the
        // simulator's widener and says nothing about the app.
        #expect(DeterministicParser.parse("no more youtube today", state: model.policy) != .silence,
                "the grammar no longer claims \"no more youtube today\" — the widener is what answered")

        await model.handle("no more youtube today")

        #expect(model.ledger.isClosed(door.id,
                                      at: .now,
                                      dayStart: DayBoundary.dayStart(now: .now,
                                                                     downHours: model.policy.downHours,
                                                                     calendar: .current)),
                "\"no more youtube today\" did not shut the door")
    }

    /// **HOURS ARE NOT MINUTES**, through the whole pipeline. This granted TWO
    /// MINUTES and answered "Instagram is open for 2 minutes." — an honest
    /// receipt for an instruction nobody gave.
    @Test func anAskInHoursGrantsHours() async {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("0", forKey: "silkWait")
        let (model, _) = freshModel(budget: 240)

        await model.handle("give me 2 hours of instagram")

        #expect(model.remainingMinutes == 120, "two hours was read as \(240 - model.remainingMinutes) minutes")
        #expect(model.conversation.turns.last?.reply?.contains("120") == true,
                "the read-back did not state the minutes actually granted")
    }

    /// The clamp still binds it, and the read-back states what was actually
    /// given rather than what was asked for.
    @Test func anHoursAskClampsToTheBalance() async {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("0", forKey: "silkWait")
        let (model, _) = freshModel(budget: 40)

        await model.handle("give me 2 hours of instagram")

        #expect(model.remainingMinutes == 0)
        #expect(model.conversation.turns.last?.reply?.contains("40") == true,
                "the read-back promised more than the pool held")
    }

    /// **THE POOL IS NOT MOVED BY A SENTENCE THAT MERELY MENTIONS BUDGETING.**
    /// "budget" was matched as a bare substring of the whole utterance, so this
    /// halved the daily allowance instantly, answered "20 left today.", and
    /// never opened the door she asked for. The pool now moves only when the
    /// pool noun owns the number.
    ///
    /// The ask itself terminates in the grammar rather than falling through to
    /// SPEND — rule 3 terminates on every path by design, and letting it fall
    /// out of its own arm is the failure that once deleted a door — so the
    /// sentence reaches the widener, which can read it as the spend it is.
    ///
    /// Which is why this asserts the POOL and not the balance: whether the
    /// on-device model answers is a property of the machine the test runs on
    /// (the simulator has it, a CI runner may not), and a test that pins a
    /// widened answer pins the weather. What cannot vary, and what the defect
    /// was, is that the daily allowance does not move.
    @Test func aSentenceThatMentionsABudgetNeverCutsThePool() async {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("0", forKey: "silkWait")
        let (model, _) = freshModel(budget: 40)

        await model.handle("give me 20 of instagram, im on a budget")

        #expect(model.policy.budgetMinutes == 40, "the sentence cut the daily allowance")
        // Without these the test passes on a no-op: a `handle` that threw the
        // sentence away entirely, or hung at "…", leaves the pool at 40 too,
        // and the one assertion above cannot tell that apart from the sentence
        // being read correctly. The turn resolving, once, is what says the
        // pipeline actually ran — and it is all that can be said here, because
        // the reply itself comes from the widener.
        #expect(model.conversation.hasPendingTurn == false, "the turn was left drawing \"…\"")
        #expect(model.conversation.turns.count == 1,
                "one sentence produced \(model.conversation.turns.count) turns")
    }

    /// The same sentence with the widener silenced: now the reply IS
    /// assertable, and it is the four words README rule 2 names. This is the
    /// only place `didntGetThat` is pinned on the `handle` path; the test
    /// above deliberately cannot be.
    @Test func anUnreadableSentenceIsRefusedWithTheFourWordsWhenTheWidenerIsSilent() async {
        SilkModelParser.testForceSilent = true
        defer { SilkModelParser.testForceSilent = false; unpinTheSeams() }
        let (model, _) = freshModel()
        let before = model.policy

        await model.handle("asdfgh qwerty zxcvb")

        #expect(model.conversation.turns.last?.reply == SilkStrings.didntGetThat)
        #expect(model.conversation.hasPendingTurn == false)
        #expect(model.policy == before, "a refused sentence moved the policy")
    }

    /// And the pool's own sentence still moves it.
    @Test func thePoolsOwnSentenceStillMovesThePool() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel(budget: 40)

        await model.handle("budget of 20")

        #expect(model.policy.budgetMinutes == 20, "the pool stopped answering to its own sentence")
    }

    /// **A TWO-INTENT SENTENCE NEVER SHUTS THE WRONG DOOR.** STATUS runs ahead
    /// of the close rule and five of its six triggers are substring tests over
    /// the whole sentence, so a close with a balance question riding along
    /// answers the balance and drops the close. That is a known imprecision and
    /// it is deliberately left standing: the gate that would fix it hands the
    /// sentence to a close rule that shuts `firstDoor` — the first door NAMED,
    /// not the door the closing verb governs — and "how much is left on tiktok,
    /// block instagram" then shuts TikTok.
    ///
    /// A dropped close costs the user the sentence and she says it again. A
    /// wrong close shuts a door she is using and canon will not let her open it
    /// again before tomorrow. This pins the direction of that trade, so nobody
    /// closes the gap without first fixing which door a close governs.
    @Test func aTwoIntentSentenceNeverShutsTheWrongDoor() async {
        defer { unpinTheSeams() }
        SharedStore.wipeAll()
        let model = AppModel()
        let instagram = Door(name: "Instagram")
        let tiktok = Door(name: "TikTok")
        model.completeSetup(doors: [instagram, tiktok], doorSelections: [:],
                            wallSelection: .init(), budget: 40,
                            downHours: noWindowTonight())

        await model.handle("how much is left on tiktok, block instagram")

        let dayStart = DayBoundary.dayStart(now: .now, downHours: model.policy.downHours,
                                            calendar: .current)
        #expect(!model.ledger.isClosed(tiktok.id, at: .now, dayStart: dayStart),
                "a sentence naming TikTok in a QUESTION shut it")
        #expect(model.conversation.turns.last?.reply?.contains("40") == true,
                "the balance question was not answered")
    }

    /// A question with no close in it is still a question.
    @Test func aBalanceQuestionIsStillAnswered() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel(budget: 40)

        await model.handle("how much is left")

        #expect(model.conversation.turns.last?.reply?.contains("40") == true,
                "the balance question stopped being answered")
        #expect(model.policy.budgetMinutes == 40)
    }

    /// A sentence nothing can read is ANSWERED — the turn does not sit at "…".
    /// This is the assertion that would go red if the widener's deadline were
    /// ever removed and the model hung.
    ///
    /// **What it may not assert is the reply.** The deterministic grammar falls
    /// silent on this string, so it reaches the on-device widener, and the
    /// simulator this suite runs on has Apple Intelligence: the answer is
    /// whatever that model makes of "asdfgh qwerty zxcvb" on the day, which on
    /// a CI runner without it is `Didn't get that.` and here is not guaranteed
    /// to be. Pinning the sentence pinned the machine. What cannot vary is that
    /// the turn resolves, exactly once, and that is now the whole test.
    @Test func anUnreadableSentenceIsRefusedAndNotLeftPending() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel()

        await model.handle("asdfgh qwerty zxcvb")

        #expect(model.conversation.hasPendingTurn == false, "the turn was left drawing \"…\"")
        #expect(model.conversation.turns.count == 1,
                "one sentence produced \(model.conversation.turns.count) turns")
    }

    /// The turn is resolved on every path `handle` can take, which is what
    /// `blur()` rests on: a thread held open for a pending turn is held open for
    /// a bounded time because every sentence gets an answer or is dropped.
    @Test(arguments: [
        "give me 10 minutes of instagram",   // grant
        "no more instagram today",           // close
        "budget of 30",                      // rule change
        "how much is left",                  // status
        "give me instagram",                 // the elliptical ask
        "asdfgh qwerty",                     // silence
    ])
    func everySentenceResolvesItsTurn(_ sentence: String) async {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("0", forKey: "silkWait")
        let (model, _) = freshModel()

        await model.handle(sentence)

        #expect(model.conversation.hasPendingTurn == false,
                "\"\(sentence)\" left its turn unanswered")
    }
}

// MARK: - An older pill may not overwrite a newer turn

@Suite(.serialized) @MainActor struct TheUndoOfferExpiresUnderALaterTurn {

    /// **A LOOSENING APPLIED INSTANTLY, OUT OF A PILL.** Two budget tightens
    /// inside one undo window, and the older pill is tapped. The closure did not
    /// ask whether the policy had moved since, so it wrote the original 40 over
    /// the live 20 — which is the one thing canon forbids doing now (saying
    /// "budget 40" out loud parks until tomorrow) — and it destroyed the second
    /// turn's tighten with no receipt, while the second turn's own pill still
    /// stood offering to put back 30.
    ///
    /// The ledger's offers have expired under `ledgerGeneration` since they
    /// shipped. The policy's did not.
    @Test func anOlderBudgetPillCannotUndoANewerTighten() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel(budget: 40)

        await model.handle("budget of 30")
        #expect(model.policy.budgetMinutes == 30, "the first tighten did not land")
        let firstTurn = model.conversation.turns.last!
        #expect(firstTurn.undo != nil, "the first tighten offered no way back")

        await model.handle("budget of 20")
        #expect(model.policy.budgetMinutes == 20, "the second tighten did not land")

        // Tap the OLDER pill.
        model.conversation.undo(firstTurn.id)

        #expect(model.policy.budgetMinutes == 20,
                "an expired offer loosened the pool to \(model.policy.budgetMinutes)")
        let settled = model.conversation.turns.first { $0.id == firstTurn.id }
        #expect(settled?.undo == nil, "the expired pill is still standing")
        #expect(settled?.reply?.contains(SilkStrings.putBack) != true,
                "an undo that never landed wrote a receipt anyway")
    }

    /// And the ordinary case is untouched: one tighten, one pill, one restore.
    @Test func theOnlyPillStillPutsItBack() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel(budget: 40)

        await model.handle("budget of 30")
        let turn = model.conversation.turns.last!
        model.conversation.undo(turn.id)

        #expect(model.policy.budgetMinutes == 40, "the only offer failed to put the pool back")
        let settled = model.conversation.turns.first { $0.id == turn.id }
        #expect(settled?.reply == SilkStrings.putBack, "the landed restore earned no receipt")
    }

    /// The newer pill still works — it is the one that owns the field.
    @Test func theNewerPillStillPutsBackItsOwnTurn() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel(budget: 40)

        await model.handle("budget of 30")
        await model.handle("budget of 20")
        let second = model.conversation.turns.last!

        model.conversation.undo(second.id)

        #expect(model.policy.budgetMinutes == 30, "the owning offer failed to put its own turn back")
        #expect(model.conversation.turns.last?.reply == SilkStrings.putBack)
    }
}
