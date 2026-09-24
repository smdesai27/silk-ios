import Foundation
import Testing
@testable import SilkCore

// THE VALIDATOR HOLDS EVERY SPEND TO THE SENTENCE.
//
// A spend is an opening verb, the door and the minutes; a fragment gets the
// sentence written out. The grammar keeps that rule on every fragment it can
// read, and never hands one on. But a fragment whose door the grammar cannot
// read — "tik tok for 5 mins", as dictation spells the name — is silence to
// the grammar, so it reached the on-device widener, which read the door
// through the spelling and proposed the spend. The Validator checked that the
// 5 was said and let it through: on the phone, "tik tok for 5 mins" unlocked
// TikTok while "tiktok for 2 mins", typed, wrote itself out.
//
// The Validator's spend arm now asks the grammar's own question
// (`DeterministicParser.judgeSpend`) of every spend from every source. These
// rows feed it the widener's proposals directly — `.command(.spend)` with the
// sentence the model saw — so the check is pinned without a model in the loop.

private let noon = julyAt(12)

private func verdict(_ text: String, spend door: Door, _ minutes: Int,
                     state: PolicyState = makeState()) -> Verdict {
    Validator.validate(.command(.spend(door: door, minutes: minutes)), utterance: text,
                       state: state, ledger: GrantLedger(), now: noon, calendar: cal)
}

@Suite struct TheWidenersFragmentIsWrittenOut {

    /// The model's proposal for a verb-less fragment that names the door is
    /// the written-out sentence, with the door and the number the model
    /// read — exactly the grammar's own answer to the same fragment. ("tiktok
    /// 4 5 mins", "for" dictated as a numeral, is two numbers and so silence
    /// on both paths.)
    @Test(arguments: [
        ("tiktok 5 mins pls", "the fragment with a please"),
        ("TikTok 5", "the bare shortcut, should the model ever see it"),
        ("tiktok, 5 mins, now", "the fragment in pieces"),
    ])
    func aFragmentThatNamesTheDoorIsWrittenOut(_ row: (String, String)) {
        #expect(verdict(row.0, spend: tiktok, 5) == .refuseWriteItOut(door: tiktok, minutes: 5), Comment(rawValue: row.1))
    }

    /// A fragment whose door the grammar cannot read — dictation's "tik
    /// tok", a hyphen, "tick tock" — is silence, not a hint: the door is not
    /// a door she named (a space is not nothing, and the name is exact), so
    /// the model's reading of it is not hers, and there is no door to write
    /// out. That is the sentence that unlocked TikTok on the phone.
    @Test(arguments: [
        "tik tok for 5 mins",
        "tick tock for 5 mins",
        "tik-tok for 5 mins",
        "5 minutes on tik tok",
        "unlock tik tok for 5 min",
    ])
    func aDoorTheGrammarCannotReadIsNotTheModelsToName(_ text: String) {
        #expect(verdict(text, spend: tiktok, 5) == .silence)
    }

    /// And a proposal that DOES ask, of a door she named, passes the same
    /// gates the grammar's own spends pass — every opening verb the grammar
    /// knows, and the commitment frame that counts as one. There is no
    /// sentence the grammar refuses and the Validator grants: the set of
    /// spends the model can land is exactly the set the grammar mints.
    @Test(arguments: [
        "unlock tiktok for 5 mins",
        "give me 5 mins of tiktok",
        "can i have 5 minutes of tiktok",
        "i want 5 minutes of tiktok",
        "let me on tiktok for 5",
        "i'm using tiktok for 5 minutes",
        "i'll spend 5 minutes on tiktok",
    ])
    func aProposalThatAsksIsGranted(_ text: String) {
        guard case .grant(let d, let m, _) = verdict(text, spend: tiktok, 5) else {
            Issue.record("\"\(text)\" was \(verdict(text, spend: tiktok, 5)), not a grant")
            return
        }
        #expect(d == tiktok)
        #expect(m == 5)
    }

    /// The grammar's own spends are unchanged by the check, because the check
    /// is the grammar's: every sentence it mints from carries what it asks for.
    @Test(arguments: [
        ("unlock tiktok for 5 mins", "TikTok", 5),
        ("give me 20 minutes of instagram", "Instagram", 20),
        ("can i have twenty minutes of tiktok", "TikTok", 20),
        ("i'm using instagram for 5 minutes", "Instagram", 5),
        ("i'll use instagram for 10 minutes", "Instagram", 10),
    ])
    func theGrammarsOwnSpendsStillLand(_ row: (String, String, Int)) {
        let state = makeState()
        let outcome = DeterministicParser.parse(row.0, state: state)
        guard case .command(.spend(let door, let minutes)) = outcome else {
            Issue.record("\"\(row.0)\" parsed to \(outcome), not a spend"); return
        }
        #expect(door.name == row.1 && minutes == row.2)
        let v = Validator.validate(outcome, utterance: row.0, state: state,
                                   ledger: GrantLedger(), now: noon, calendar: cal)
        guard case .grant(let d, let m, _) = v else {
            Issue.record("\"\(row.0)\" validated to \(v), not a grant"); return
        }
        #expect(d.name == row.1 && m == row.2)
    }

    /// The edges still answer first: a fragment during down hours gets the
    /// hour, against an empty pool "0 left today.", on a door closed by hand
    /// or with its ceiling spent the door and its hour — the write-out arm's
    /// own order, kept on this path, so the sentence taught is one the next
    /// turn can grant.
    @Test func theEdgesAnswerBeforeTheSentenceIsJudged() {
        let capped = makeCappedState()
        let spent = GrantLedger(grants: [Grant(door: tiktok, minutes: 10,
                                               issuedAt: julyAt(9), expiresAt: julyAt(9, 10))])
        let ceilingGone = Validator.validate(.command(.spend(door: tiktok, minutes: 5)),
                                             utterance: "tiktok 5 mins", state: capped,
                                             ledger: spent, now: noon, calendar: cal)
        guard case .refuseDoorClosed(let d, _) = ceilingGone else {
            Issue.record("a spent ceiling answered \(ceilingGone)"); return
        }
        #expect(d == tiktok)
        let shut = GrantLedger(closedToday: [tiktok.id: julyAt(9)])
        let closed = Validator.validate(.command(.spend(door: tiktok, minutes: 5)),
                                        utterance: "tiktok 5 mins", state: makeState(),
                                        ledger: shut, now: noon, calendar: cal)
        guard case .refuseDoorClosed(let c, _) = closed else {
            Issue.record("a closed door answered \(closed)"); return
        }
        #expect(c == tiktok)
        let night = Validator.validate(.command(.spend(door: tiktok, minutes: 5)),
                                       utterance: "tiktok 5 mins", state: makeState(),
                                       ledger: GrantLedger(), now: julyAt(23), calendar: cal)
        #expect(night == .refuseDownHours(until: makeState().downHours.end))
        let empty = Validator.validate(.command(.spend(door: tiktok, minutes: 5)),
                                       utterance: "tiktok 5 mins", state: makeState(budget: 0),
                                       ledger: GrantLedger(), now: noon, calendar: cal)
        #expect(empty == .refuseNothingLeft)
    }

    /// Provenance still comes first among the checks: a number the sentence
    /// never said is silence, not a hint that teaches it.
    @Test func aNumberNeverSaidIsStillSilence() {
        #expect(verdict("tiktok for a few mins", spend: tiktok, 3) == .silence)
    }
}

/// THE GRAMMAR'S VETOES HOLD ON THE MODEL'S PATH. Every sentence here is
/// silence to the grammar on purpose — a refusal, a report, a question, a
/// restriction, a unit or a deadline misread — and silence is exactly what
/// the widener is handed. Its proposal for each is the spend the grammar
/// refused, and the Validator now refuses it again, by the grammar's own
/// vetoes in the grammar's own order.
@Suite struct TheWidenerCannotBypassAVeto {

    @Test(arguments: [
        ("dont unlock tiktok for 20 min", 20, "a negator on the opening verb"),
        ("block tiktok, give me 20 minutes", 20, "a restriction lends no door"),
        ("she said unlock tiktok for 20", 20, "a report"),
        ("should i unlock tiktok for 20", 20, "a deliberation"),
        ("i never said give me 20 minutes of tiktok", 20, "a negated report"),
        ("give me 30 seconds of tiktok", 30, "seconds are not minutes"),
        ("give me tiktok till 7", 7, "a deadline is not a duration"),
        ("i dont want 20 minutes of tiktok", 20, "a negated volition"),
        ("give me 10 or 20 minutes of tiktok", 20, "two numbers is no number"),
        ("give me 20 minutes of tiktok before bedtime", 20, "a window word poisons the ask"),
    ])
    func aVetoedSentenceIsSilenceHoweverItArrives(_ row: (String, Int, String)) {
        #expect(DeterministicParser.parse(row.0, state: makeState()) == .silence, "the grammar must be silent for the row to mean anything")
        #expect(verdict(row.0, spend: tiktok, row.1) == .silence, Comment(rawValue: row.2))
    }

    /// And a door the sentence never named is silence, whatever the model
    /// resolved it to — on a spend and on a close.
    @Test(arguments: [
        ("give me ten minutes on the bird app", 10),
        ("unlock instagram for 10", 10),
        ("open my feed app for 10 minutes", 10),
    ])
    func aDoorNotNamedIsNotGranted(_ row: (String, Int)) {
        #expect(verdict(row.0, spend: tiktok, row.1) == .silence)
    }

    /// A close is the tighten direction with Undo on its receipt, so the
    /// model is trusted to aim it at a door the sentence did not spell —
    /// but only at a door on the roster.
    @Test func aCloseNeedsARosterDoorAndNothingMore() {
        let aimed = Validator.validate(.command(.closeDoorToday(door: instagram, until: nil)),
                                       utterance: "im done letting myself open that thing",
                                       state: makeState(), ledger: GrantLedger(), now: noon, calendar: cal)
        guard case .close(let d, _) = aimed else { Issue.record("the aimed close was \(aimed)"); return }
        #expect(d == instagram)
        let stranger = Validator.validate(.command(.closeDoorToday(door: Door(name: "Snapchat"), until: nil)),
                                          utterance: "close snapchat for today", state: makeState(),
                                          ledger: GrantLedger(), now: noon, calendar: cal)
        #expect(stranger == .silence)
    }
}
