import Foundation
import Testing
@testable import SilkCore

// THE SHAPE OF A SPEND.
//
// A grant needs three things and the grammar used to require two: an opening
// verb, an app name, and minutes. "instagram 10" bought ten real minutes of
// Instagram off a sentence that asked for nothing, and so did every sentence
// that happened to put an app beside a number.
//
// The third answer is what makes the tightening affordable. A bare shortcut is
// not refused into silence — silence goes to the widener, which is a model, and
// a model reads "instagram 10" as the grant this file just declined. It is
// answered with the sentence that WOULD grant, in the user's own door and her
// own number: "Write it out: unlock Instagram for 10 min." Nothing is debited,
// nothing opens, and the turn ends there.
//
// Three tables, one per outcome, plus the seams: the Validator's rendering of
// the new outcome, the sentence the app layer composes from it, and the door
// whose nickname table is gone.

// MARK: - Fixtures

private func spendShapeState(_ doors: [Door] = [instagram, tiktok]) -> PolicyState {
    PolicyState(budgetMinutes: 40,
                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                doors: doors)
}

/// The state the "with Reddit a door" rows run against. Instagram stays FIRST,
/// so the doorless fragments still name it.
private func stateWithReddit() -> PolicyState { spendShapeState([instagram, tiktok, reddit]) }

private func spendParse(_ text: String, _ state: PolicyState = spendShapeState()) -> ParseOutcome {
    DeterministicParser.parse(text, state: state)
}

// MARK: - Grants: a verb, a door, and minutes

@Suite struct AVerbADoorAndMinutesGrants {

    /// Every opening verb in the authority, both word orders, digits and words,
    /// three spellings of the unit, trailing politeness, capitals and commas.
    /// One row per verb at least, because the list is now the only thing
    /// standing between a mention and a debit.
    @Test(arguments: [
        // give me / gimme
        ("give me 20 minutes of instagram", "Instagram", 20),
        ("give me instagram for 20 minutes", "Instagram", 20),
        ("gimme 10 of tiktok", "TikTok", 10),
        // open / unlock
        ("open tiktok for 15", "TikTok", 15),
        ("unlock instagram for 10 minutes", "Instagram", 10),
        ("unlock Instagram for 10 min", "Instagram", 10),
        ("unlock instagram for 10 mins", "Instagram", 10),
        // let me / lemme
        ("let me have 10 minutes of instagram", "Instagram", 10),
        ("lemme get 10 minutes of tiktok", "TikTok", 10),
        // i want / i need
        ("i want 10 minutes of tiktok", "TikTok", 10),
        ("i need 5 minutes of instagram", "Instagram", 5),
        // can i / could i / may i
        ("can i have instagram for ten minutes please", "Instagram", 10),
        ("could i get 10 on tiktok", "TikTok", 10),
        ("may i have 10 minutes of instagram", "Instagram", 10),
        // spend / use / using
        ("spend 10 on instagram", "Instagram", 10),
        ("use instagram for 10 min", "Instagram", 10),
        ("im using instagram for 5 min", "Instagram", 5),
        ("i'm using instagram for 5 minutes", "Instagram", 5),
        ("i am using tiktok for 10 minutes", "TikTok", 10),
        // go on / get on
        ("go on instagram for 10 minutes", "Instagram", 10),
        ("get on tiktok for 10 minutes", "TikTok", 10),
        ("i'm going on instagram for 10", "Instagram", 10),
        ("i'm spending 10 on instagram", "Instagram", 10),
        // capitals, punctuation, politeness
        ("Unlock Instagram for 10 min.", "Instagram", 10),
        ("unlock instagram, 10 minutes", "Instagram", 10),
        ("open tiktok for 15 please", "TikTok", 15),
        ("give me twenty five minutes of tiktok", "TikTok", 25),
    ])
    func grants(_ row: (String, String, Int)) {
        let (text, door, minutes) = row
        guard case .command(.spend(let d, let m)) = spendParse(text) else {
            Issue.record("\"\(text)\" did not spend: \(spendParse(text))")
            return
        }
        #expect(d.name == door, "\"\(text)\" spent on \(d.name)")
        #expect(m == minutes, "\"\(text)\" spent \(m)")
    }

    /// THE HINT, TYPED BACK VERBATIM, MUST GRANT. The whole design rests on
    /// this one row: a reply that shows a sentence Silk cannot then read is
    /// worse than "How long?" ever was.
    @Test func theHintItselfGrants() {
        let hint = SilkStrings.writeItOut("Instagram", minutes: nil)
        #expect(hint == "Write it out: unlock Instagram for 10 min.")
        let typed = String(hint.dropFirst(SilkStrings.writeItOut.count))
            .trimmingCharacters(in: .whitespaces)
        #expect(spendParse(typed) == .command(.spend(door: instagram, minutes: 10)))
        #expect(spendParse(SilkStrings.writeItOut("TikTok", minutes: 25)
            .replacingOccurrences(of: SilkStrings.writeItOut, with: ""))
            == .command(.spend(door: tiktok, minutes: 25)))
    }
}

// MARK: - Write it out: the partial spends

@Suite struct APartialSpendIsWrittenOut {

    /// A door and a number with no verb between them. Every one of these was a
    /// GRANT before the verb was required.
    @Test(arguments: [
        ("instagram 10", "Instagram", 10),
        ("instagram, ten", "Instagram", 10),
        ("10 minutes of instagram", "Instagram", 10),
        ("tiktok for 15", "TikTok", 15),
        ("instagram for 10 min", "Instagram", 10),
        ("ten of instagram", "Instagram", 10),
        ("instagram 20 while im at the gym", "Instagram", 20),
    ])
    func aDoorAndANumber(_ row: (String, String, Int)) {
        expectWriteItOut(spendParse(row.0), row.0, door: row.1, minutes: row.2)
    }

    /// The corpus's own chatty ask, which used to grant on the request modal
    /// alone. It still names its door and its number; it just no longer opens
    /// anything without a verb.
    @Test func theChattyAskIsWrittenOut() {
        let text = "hey so i was thinking maybe like 10 minutes of reddit would be nice"
        expectWriteItOut(spendParse(text, stateWithReddit()), text, door: "Reddit", minutes: 10)
    }

    /// A door with an opening verb and no duration — rule 8, which used to
    /// answer "How long?" and then read whatever fragment came back as the
    /// whole ask. And rule 6's place binding, which is the same absence.
    @Test(arguments: [
        ("open tiktok", "TikTok"),
        ("give me instagram", "Instagram"),
        ("instagram while im at the gym", "Instagram"),
        ("let me on tiktok", "TikTok"),
    ])
    func aDoorWithNoDuration(_ row: (String, String)) {
        expectWriteItOut(spendParse(row.0), row.0, door: row.1, minutes: nil)
    }

    /// THE FRAGMENTS. Somebody who was just shown the sentence and typed back
    /// the half she thought was missing gets guided again, not refused. The
    /// door is the first one, because a number names none.
    @Test(arguments: [
        ("10", 10),
        ("10 minutes", 10),
        ("ten min please", 10),
        ("for 10 mins", 10),
    ])
    func aNumberAlone(_ row: (String, Int)) {
        expectWriteItOut(spendParse(row.0), row.0, door: "Instagram", minutes: row.1)
    }

    @Test(arguments: [("instagram", "Instagram"), ("tiktok please", "TikTok")])
    func aDoorAlone(_ row: (String, String)) {
        expectWriteItOut(spendParse(row.0), row.0, door: row.1, minutes: nil)
    }

    /// Both fragment rules need a door to name, and a policy with no doors has
    /// none to guess at. Silence, not a crash and not a sentence about nothing.
    @Test func aDoorlessPolicyStaysSilent() {
        let empty = spendShapeState([])
        #expect(spendParse("10 minutes", empty) == .silence)
        #expect(spendParse("instagram", empty) == .silence)
    }
}

// MARK: - Silence: what still belongs to the widener

@Suite struct TheWidenerKeepsWhatItHad {

    /// An unknown app is not a door, and a NICKNAME is now an unknown app:
    /// the alias table and the catalogue's own names are gone from matching.
    @Test(arguments: [
        "snapchat 10",
        "10 minutes of insta",
        "ten on ig",
        "gimme the gram",
        "give me 10 minutes of ig",
    ])
    func anUnknownAppIsSilent(_ text: String) {
        #expect(spendParse(text) == .silence, "\"\(text)\" was \(spendParse(text))")
    }

    /// A report, a habit, a past. The mood gate's narrowing admits the
    /// first-person present progressive and nothing either side of it.
    @Test(arguments: [
        "i use instagram 30 minutes a day",
        "i'm using instagram 2 hours a day",
        "im using instagram 30 minutes every day",
        "i've been using tiktok for 3 hours",
        "i was on instagram for 20 minutes",
        "i watched tiktok for 45 minutes at lunch",
    ])
    func aReportIsSilent(_ text: String) {
        let outcome = spendParse(text)
        if case .command(.spend(let d, let m)) = outcome {
            Issue.record("\"\(text)\" spent \(m) on \(d.name)")
        }
        if case .writeItOut = outcome {
            Issue.record("\"\(text)\" was written out rather than left to the widener")
        }
    }

    /// The guards rule 7 already had. Each returns silence and stays silent:
    /// a refusal, a deadline and a seconds ask are not partial spends, they are
    /// sentences this grammar cannot read.
    @Test(arguments: [
        "don't give me instagram for 10 minutes",
        "dont open tiktok for 20 minutes",
        "instagram until 10",
        "give me tiktok till 7",
        "give me 30 seconds of instagram",
        "asdfgh qwerty",
    ])
    func theOldGuardsStillSilence(_ text: String) {
        #expect(spendParse(text) == .silence, "\"\(text)\" was \(spendParse(text))")
    }

    /// AND THE FRAGMENT RULES TOOK NOTHING. They stand after every other rule
    /// precisely so that a sentence some rule already claims keeps it.
    @Test func theNeighbouringCommandsStillLand() {
        #expect(spendParse("budget 30") == .command(.setBudget(minutes: 30)))
        #expect(spendParse("cap tiktok 20") == .command(.setDoorCap(door: tiktok, minutes: 20)))
        #expect(spendParse("how much is left") == .command(.status))
        guard case .command(.closeDoorToday(let d, _)) = spendParse("no more instagram today") else {
            Issue.record("\"no more instagram today\" was \(spendParse("no more instagram today"))")
            return
        }
        #expect(d.name == "Instagram")
    }
}

// MARK: - The Validator, and the sentence the app composes

@Suite struct TheGuidanceIsARefusalThatDebitsNothing {

    private func validate(_ text: String, at now: Date = afternoon()) -> Verdict {
        Validator.validate(spendParse(text), utterance: text, state: spendShapeState(),
                           ledger: GrantLedger(), now: now, calendar: cal)
    }

    @Test func aWrittenOutSpendBecomesTheGuidanceRefusal() {
        #expect(validate("instagram 10") == .refuseWriteItOut(door: instagram, minutes: 10))
        #expect(validate("give me instagram") == .refuseWriteItOut(door: instagram, minutes: nil))
        #expect(validate("10 minutes") == .refuseWriteItOut(door: instagram, minutes: 10))
    }

    /// THE NIGHT ANSWERS IT LIKE ANY OTHER ASK. A partial ask at eleven at
    /// night is told when the wall opens, exactly as a whole one is — the
    /// guidance is not on the down-hours exemption list, and writing the
    /// sentence out for somebody who cannot use it tonight would send her back
    /// for a second refusal.
    ///
    /// Run end to end, because a constructed `Verdict` could only ever prove
    /// the property of the case and never that the night's own instant
    /// produces it. The Validator's `.writeItOut` arm does NOT gate on down
    /// hours itself — the app layer does, off `deferredByDownHours` — so the
    /// composed proof is both halves: the verdict the night actually yields,
    /// and that the flag on it sends the app to the wall.
    @Test func theNightDefersIt() {
        let atEleven = cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 23))!
        #expect(spendShapeState().downHours.contains(TimeOfDay(hour: 23)),
                "the instant must be inside the night for the test to mean anything")
        let v = validate("instagram 10", at: atEleven)
        #expect(v == .refuseWriteItOut(door: instagram, minutes: 10))
        #expect(v.deferredByDownHours)
        #expect(!v.isTighten)
    }

    /// The reply the app layer composes. The door and the number are the
    /// user's own; ten minutes is what the sentence says when she named none.
    @Test func theSentenceIsTheUsersOwnWords() {
        #expect(SilkStrings.writeItOut("Instagram", minutes: nil)
            == "Write it out: unlock Instagram for 10 min.")
        #expect(SilkStrings.writeItOut("Instagram", minutes: 25)
            == "Write it out: unlock Instagram for 25 min.")
        #expect(SilkStrings.writeItOut("TikTok", minutes: 5)
            == "Write it out: unlock TikTok for 5 min.")
    }

    /// A hint teaches a sentence that grants. "for 0 min." cannot, and a
    /// nineteen-digit number cannot either, so the composer shows ten for any
    /// number outside the range the Shortcuts intent accepts — the parser
    /// still hands the number over exactly as typed, so the bound has one
    /// home.
    @Test func theHintNeverTeachesAZero() {
        #expect(Validator.grantableMinutes == 1...300)
        #expect(SilkStrings.writeItOut("Instagram", minutes: 0)
            == "Write it out: unlock Instagram for 10 min.")
        #expect(SilkStrings.writeItOut("Instagram", minutes: -10)
            == "Write it out: unlock Instagram for 10 min.")
        #expect(SilkStrings.writeItOut("Instagram", minutes: 301)
            == "Write it out: unlock Instagram for 10 min.")
        #expect(SilkStrings.writeItOut("Instagram", minutes: 300)
            == "Write it out: unlock Instagram for 300 min.")
        #expect(SilkStrings.writeItOut("Instagram", minutes: 1)
            == "Write it out: unlock Instagram for 1 min.")
        #expect(SilkStrings.writeItOut("Instagram", minutes: Int.max)
            == "Write it out: unlock Instagram for 10 min.")
    }

    /// A negated ask is not a partial ask. "dont give me tiktok" carries an
    /// opening verb and means its opposite; the honest answer is silence (the
    /// widener's, if there is one), never a sentence that would open TikTok.
    @Test(arguments: [
        "dont give me tiktok",
        "don't open instagram",
        "whatever you do do not open instagram tonight",
        "never unlock tiktok",
        "dont give me instagram while im at work",
        "do not let me on tiktok while im at the gym",
    ])
    func aNegatedAskIsNotWrittenOut(_ sentence: String) {
        #expect(spendParse(sentence) == .silence)
    }
}

// MARK: - The second round: what the probe found on the built app

/// Units glued to the number, the way a thumb types them. "10min" used to be
/// one token the number parser could not read, so "unlock instagram for
/// 10min" answered with a hint telling her to write what she believed she had
/// just written.
@Suite struct AGluedUnitIsStillAUnit {
    @Test(arguments: [
        ("unlock instagram for 10min", 10), ("unlock instagram for 10mins", 10),
        ("unlock instagram for 10m", 10), ("unlock instagram 10m", 10),
        ("unlock instagram for 1h", 60), ("unlock instagram for 2hrs", 120),
        ("unlock instagram for 1hr", 60), ("gimme 15min of instagram", 15),
    ])
    func aGluedUnitReadsAsTwoTokens(_ row: (String, Int)) {
        #expect(spendParse(row.0) == .command(.spend(door: instagram, minutes: row.1)))
    }

    @Test(arguments: [("instagram 10min", 10), ("instagram 10m", 10), ("10min", 10)])
    func aGluedUnitStillMakesAFragmentAFragment(_ row: (String, Int)) {
        #expect(spendParse(row.0) == .writeItOut(door: instagram, minutes: row.1))
    }

    /// A colon is punctuation everywhere but inside a clock time.
    @Test func aColonOnTheDoorIsNotPartOfItsName() {
        #expect(spendParse("unlock instagram: 10 minutes") == .command(.spend(door: instagram, minutes: 10)))
        #expect(spendParse("instagram: 10") == .writeItOut(door: instagram, minutes: 10))
        #expect(spendParse("down hours start at 7:30") == .command(.setDownHoursStart(TimeOfDay(hour: 19, minute: 30))))
    }

    /// A door named with a digit and a letter glued keeps its name: only the
    /// units the number parser reads are peeled off.
    @Test func aDoorNamedWithDigitsIsNotSplit() {
        let ninegag = Door(name: "9GAG")
        let state = spendShapeState([instagram, ninegag])
        #expect(spendParse("unlock 9gag for 10 minutes", state) == .command(.spend(door: ninegag, minutes: 10)))
    }
}

/// The promise, as well as the announcement: "i'll use", "i will spend", "i'm
/// going to open", "i'm gonna go on" — and the polite ask, "i'd like".
@Suite struct AnIntentionIsACommitment {
    /// The expected door and number are STATED, not read back out of the
    /// sentence: deriving them from the input made the row assert only that
    /// the parser agreed with a substring search, and a rule that dropped the
    /// door entirely would have taken the expectation down with it.
    @Test(arguments: [
        ("i will use instagram for 10 minutes", "Instagram", 10),
        ("i'll use instagram for 10 minutes", "Instagram", 10),
        ("ill use instagram for 10 minutes", "Instagram", 10),
        ("i'll spend 10 minutes on instagram", "Instagram", 10),
        ("i'm going to use instagram for 10 minutes", "Instagram", 10),
        ("im going to open instagram for 10 minutes", "Instagram", 10),
        ("i'm gonna go on instagram for 10 minutes", "Instagram", 10),
        ("i am going to unlock instagram for 10 minutes", "Instagram", 10),
        ("i'd like 10 minutes of instagram", "Instagram", 10),
        ("id like 10 minutes of instagram", "Instagram", 10),
        ("i would like 10 minutes of instagram", "Instagram", 10),
        ("i'd like instagram for 10 minutes", "Instagram", 10),
        ("i'd like to use instagram for 10 minutes", "Instagram", 10),
        ("im getting ready, im going on instagram for 10 minutes", "Instagram", 10),
        ("give instagram 10 minutes", "Instagram", 10),
        ("give tiktok 20 minutes", "TikTok", 20),
    ])
    func anIntentionGrants(_ row: (sentence: String, door: String, minutes: Int)) {
        let door = row.door == "TikTok" ? tiktok : instagram
        #expect(spendParse(row.sentence) == .command(.spend(door: door, minutes: row.minutes)))
    }

    @Test(arguments: [
        "i'll never use instagram for 10 minutes", "i won't use instagram for 10 minutes",
        "i will not open instagram for 10 minutes", "she will use instagram for 10 minutes",
        "i will use instagram 30 minutes a day", "i'll use instagram for 10 minutes tomorrow",
        "i'll be on instagram for 10 minutes", "i'm on instagram for 10 minutes",
        "i'll get instagram for 10 minutes",
    ])
    func aNegatedPlannedOrHabitualIntentionStaysSilent(_ sentence: String) {
        #expect(spendParse(sentence) == .silence)
    }

    /// Bare "using" is a participle, not a verb on the list: without its
    /// first-person frame the sentence reads as a report and is the
    /// widener's. What matters is that no list entry mints it.
    @Test func aBareParticipleNeverMints() {
        #expect(spendParse("using instagram for 10 minutes") == .silence)
    }
}

/// Rule 2's window setter keeps the verb list it was measured against; the
/// spend grammar's wider one must not silence it.
@Suite struct TheWindowSetterKeepsItsOwnVerbs {
    @Test func aNeedToMoveTheWindowMovesIt() {
        #expect(spendParse("i need down hours to start at 11") == .command(.setDownHoursStart(TimeOfDay(hour: 23))))
        #expect(spendParse("i need quiet hours at 10") == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(spendParse("lemme have bedtime at 11") == .command(.setDownHoursStart(TimeOfDay(hour: 23))))
        #expect(spendParse("gimme quiet from 11") == .command(.setDownHoursStart(TimeOfDay(hour: 23))))
    }

    /// A negated preamble does not refuse the ask that follows it — not even
    /// when the ask is Silk's own hint sentence.
    @Test(arguments: [
        "i dont use instagram much, unlock instagram for 10 min",
        "i dont use instagram much, give me 10 minutes of instagram",
        "i shouldnt use instagram, but give me 10 minutes of instagram",
    ])
    func aNegatedPreambleLeavesTheAskStanding(_ sentence: String) {
        #expect(spendParse(sentence) == .command(.spend(door: instagram, minutes: 10)))
    }

    @Test(arguments: ["dont use instagram for 10 minutes", "no use, instagram for 10",
                      "dont spend 10 minutes on instagram"])
    func aNegatedAskItselfStaysRefused(_ sentence: String) {
        if case .command(.spend) = spendParse(sentence) { Issue.record("a negated ask granted: \(sentence)") }
    }
    @Test func aDoorlessAskBeforeBedtimeIsStillNotAWindow() {
        let o = spendParse("give me 20 minutes before bedtime")
        if case .command(.setDownHoursStart) = o { Issue.record("a doorless ask moved the night") }
    }

    // MARK: - askingForLessIsNotAnAsk
    //
    // (Its own single-test suite until now. It belongs beside the rows above:
    // both are the same question — which words, standing inside a sentence
    // that otherwise has the shape of an ask, take it away from the spend
    // grammar.)

    /// THE FRAME IS AN ASK. Everything below is that frame with one word of
    /// `asksForLess` in it, so this row is what makes the rest mean anything:
    /// without it a rule that silenced "i want instagram" outright would take
    /// the whole table green with it.
    @Test func theFrameWithoutALessWordIsTheHint() {
        #expect(spendParse("i want instagram") == .writeItOut(door: instagram, minutes: nil))
    }

    /// EVERY WORD OF `lessWords`, one sentence each.
    ///
    /// A sentence asking for LESS of the app, with an opening verb and no
    /// number, is not answered with the sentence that OPENS it — that is the
    /// refusal-only list `asksForLess` reads, and it is the only thing standing
    /// between "i need to use instagram less" and a hint teaching her to unlock
    /// Instagram. Five of the twenty-eight words were exercised before this
    /// table; the other twenty-three were carried by a `Set` literal alone, and
    /// a word dropped from it — or a word whose sentence some LATER rule
    /// quietly claimed — read as an ask with nothing to say so.
    ///
    /// The list is transcribed from `DeterministicParser.lessWords`, which is
    /// `closerTokens` (block/close/lock/shut) unioned with twenty-four words
    /// that ask for less without closing anything. It is `private` there, so
    /// this table cannot be generated from it and is instead kept honest two
    /// ways: `word` is asserted to be a real token of `sentence`, so a row
    /// cannot drift off the word it claims; and `closes` records which of the
    /// two ways the sentence is taken away from the spend grammar — the four
    /// closing verbs are claimed by the CLOSE rule, decided above SPEND, and
    /// everything else falls to silence and the widener.
    @Test(arguments: [
        ("less", "i need to use instagram less", false),
        ("fewer", "i want fewer instagram sessions", false),
        ("cut", "i want to cut down on instagram", false),
        ("reduce", "i want to reduce instagram", false),
        ("reduced", "i want instagram reduced", false),
        ("limit", "i want to limit instagram", false),
        ("limited", "i want instagram limited", false),
        ("lower", "i want to lower instagram", false),
        ("stop", "i need to stop using instagram", false),
        ("quit", "i want to quit instagram", false),
        ("blocked", "i want instagram blocked", false),
        ("locked", "i want instagram locked", false),
        ("closed", "i want instagram closed", false),
        ("off", "let me off instagram", false),
        ("away", "keep instagram away from me", false),
        ("without", "i want to go without instagram", false),
        ("capped", "i want instagram capped", false),
        ("restricted", "i want instagram restricted", false),
        ("removed", "i want instagram removed", false),
        ("gone", "i want instagram gone", false),
        ("deleted", "i want instagram deleted", false),
        ("cap", "i want a cap on instagram", false),
        ("ceiling", "i want a ceiling on instagram", false),
        // `closerTokens`, the four that shut the door outright.
        ("block", "i want to block instagram", true),
        ("close", "i want to close instagram", true),
        ("lock", "i want to lock instagram", true),
        ("shut", "i want instagram shut", true),
    ])
    func aReductionIsNeverTheSentenceThatOpensIt(_ row: (word: String, sentence: String, closes: Bool)) {
        #expect(NumberParser.tokenize(row.sentence).contains(row.word),
                "\"\(row.sentence)\" does not carry the word \"\(row.word)\" it stands for")
        let outcome = spendParse(row.sentence)
        if row.closes {
            guard case .command(.closeDoorToday(let door, _)) = outcome else {
                Issue.record("\"\(row.sentence)\" was \(outcome), not a close")
                return
            }
            #expect(door == instagram)
        } else {
            #expect(outcome == .silence, "\"\(row.sentence)\" was \(outcome)")
        }
    }

    /// RULE 6, THE PLACE BINDING, reads the same list. A bound sentence has a
    /// door, a frame and a place and no number — the exact shape rule 6 answers
    /// with the written-out ask — and "off" is all that stands between "keep
    /// instagram off while im at work" and a hint offering to open it. The
    /// place-binding rows next door pin the opening direction ("instagram while
    /// i'm at work" writes itself out); this is the closing one.
    @Test func aPlaceBoundReductionIsNotAPlaceBoundAsk() {
        #expect(spendParse("keep instagram off while im at work") == .silence)
        #expect(spendParse("instagram while im at work")
                == .writeItOut(door: instagram, minutes: nil),
                "the same binding without the less-word must still reach the hint")
    }
}

/// The bare number names the door the bar last wrote out, when the app says
/// which that was.
@Suite struct TheBareNumberRemembersTheDoor {
    @Test func theRememberedDoorWins() {
        #expect(DeterministicParser.parse("10", state: spendShapeState(), recentDoor: tiktok)
            == .writeItOut(door: tiktok, minutes: 10))
    }
    @Test func aDoorNoLongerHersIsNotGuessed() {
        let gone = Door(name: "Reddit")
        #expect(DeterministicParser.parse("10", state: spendShapeState(), recentDoor: gone)
            == .writeItOut(door: instagram, minutes: 10))
    }
    @Test func aNamedDoorIgnoresTheMemory() {
        #expect(DeterministicParser.parse("instagram 10", state: spendShapeState(), recentDoor: tiktok)
            == .writeItOut(door: instagram, minutes: 10))
    }
}

/// The edges answer a fragment as they would the whole sentence.
@Suite struct AFragmentMeetsTheEdgesFirst {
    /// The spent grant is anchored to the DAY, not to the wall clock. Built
    /// from `Date() - 3600` it fell outside the established day whenever the
    /// suite ran between 07:00 and 08:00 — the day starts when down hours end,
    /// so an hour before eight in the morning is yesterday, the ledger read as
    /// empty, and this test failed for one hour a day.
    @Test func anEmptyPoolSaysSo() {
        let state = spendShapeState()
        let now = Date()
        let dayStart = DayBoundary.dayStart(now: now, downHours: state.downHours)
        let issued = dayStart.addingTimeInterval(60)
        let spent = GrantLedger(grants: [Grant(door: instagram, minutes: 40,
                                               issuedAt: issued,
                                               expiresAt: issued.addingTimeInterval(2400))])
        let v = Validator.validate(.writeItOut(door: instagram, minutes: 10), utterance: "instagram 10",
                                   state: state, ledger: spent, now: now)
        #expect(v == .refuseNothingLeft)
    }
    /// The refusal names the instant the close lifts, and a close with a stated
    /// hour lifts at that hour — so the `until:` is asserted, not discarded.
    @Test func aClosedDoorSaysSo() {
        let state = spendShapeState()
        let now = afternoon()
        let lift = cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 18))!
        let closed = GrantLedger(closedToday: [tiktok.id: now],
                                 closedUntil: [tiktok.id: lift])
        let v = Validator.validate(.writeItOut(door: tiktok, minutes: nil), utterance: "tiktok",
                                   state: state, ledger: closed, now: now, calendar: cal)
        #expect(v == .refuseDoorClosed(door: tiktok, until: lift))
    }
    /// A door with no stated hour is shut for the rest of the Silk day, so the
    /// refusal names the NEXT day start — 07:00 tomorrow, not midnight.
    @Test func aCloseWithNoStatedHourRunsToTheDayBoundary() {
        let state = spendShapeState()
        let now = afternoon()
        let tomorrowMorning = cal.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 7))!
        let closed = GrantLedger(closedToday: [tiktok.id: now])
        let v = Validator.validate(.writeItOut(door: tiktok, minutes: nil), utterance: "tiktok",
                                   state: state, ledger: closed, now: now, calendar: cal)
        #expect(v == .refuseDoorClosed(door: tiktok, until: tomorrowMorning))
    }
    /// A CEILING SPENT TO ZERO SHUTS THE DOOR, with no close on the ledger at
    /// all. The pool still has thirty of its forty minutes, so nothing but the
    /// door's own cap can produce this — and the hour it names is the day
    /// boundary, because a cap refills with the day and not before.
    @Test func anExhaustedCapShutsTheDoor() {
        let state = PolicyState(budgetMinutes: 40,
                                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                                doors: [instagram, tiktok],
                                doorCaps: [instagram.id: 20])
        let now = afternoon()
        let dayStart = DayBoundary.dayStart(now: now, downHours: state.downHours, calendar: cal)
        let tomorrowMorning = DayBoundary.nextDayStart(after: dayStart, calendar: cal)
        let spent = GrantLedger(grants: [Grant(door: instagram, minutes: 20,
                                               issuedAt: dayStart.addingTimeInterval(60),
                                               expiresAt: dayStart.addingTimeInterval(1260))])
        let v = Validator.validate(.writeItOut(door: instagram, minutes: 10), utterance: "instagram 10",
                                   state: state, ledger: spent, now: now, calendar: cal)
        #expect(v == .refuseDoorClosed(door: instagram, until: tomorrowMorning))
        // The pool is NOT what refused: it still holds twenty of its forty.
        #expect(spent.remainingMinutes(budget: 40, dayStart: dayStart, calendar: cal) == 20)
    }
    @Test func anOpenPoolAndAnOpenDoorGetTheHint() {
        let v = Validator.validate(.writeItOut(door: instagram, minutes: 10), utterance: "instagram 10",
                                   state: spendShapeState(), ledger: GrantLedger(), now: Date())
        #expect(v == .refuseWriteItOut(door: instagram, minutes: 10))
    }
}

// MARK: - The door, without its nickname table

@Suite struct ADoorAnswersToItsNameAlone {

    @Test func spokenFormsAreTheNameAndNothingElse() {
        #expect(Door(name: "Instagram").spokenForms == ["instagram"])
        #expect(Door(name: "TikTok").spokenForms == ["tiktok"])
    }

    /// A blob written by a build that stored an alias table still decodes: the
    /// synthesized decoder ignores a key it has no property for, so nothing
    /// migrates and no door is lost.
    @Test func aLegacyAliasKeyStillDecodes() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Instagram","aliases":["ig","insta"]}
        """
        let door = try JSONDecoder().decode(Door.self, from: Data(json.utf8))
        #expect(door.id == id)
        #expect(door.name == "Instagram")
        #expect(door.spokenForms == ["instagram"])
    }

    /// `key` IS NOT ENCODED, and the round trip is what says so.
    ///
    /// It is the door's name lowercased, kept as a stored `let` because
    /// `door(named:)` is asked once per token and once per bigram of every
    /// sentence and used to lowercase every name again for each ask
    /// (`PolicyState.swift`, `Door.key`). A derived field that is stored is a
    /// field that can be persisted by accident, and a persisted `key` is a
    /// second source of truth for the door's identity: a blob written under
    /// one build and decoded under another could carry a key that no longer
    /// matches its name, and every match in the parser would then run off the
    /// stale one. Hence the hand-written `CodingKeys`, which name only `id`
    /// and `name` — and hence this test, which pins BOTH halves: that the
    /// encoded JSON has no `"key"` in it, and that decoding rebuilds one
    /// anyway.
    @Test func theLoweredKeyIsDerivedOnEveryDecodeAndStoredInNoBlob() throws {
        let door = Door(name: "TikTok")
        #expect(door.key == "tiktok")

        let data = try JSONEncoder().encode(door)
        let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["id", "name"],
                "the encoder wrote \(Set(fields.keys).sorted())")
        #expect(fields["key"] == nil, "the derived key was persisted")

        let back = try JSONDecoder().decode(Door.self, from: data)
        #expect(back == door)
        #expect(back.key == "tiktok", "the decoder did not rebuild the key from the name")
        #expect(back.spokenForms == ["tiktok"])
    }
}

// MARK: - Shared expectation

private func expectWriteItOut(_ outcome: ParseOutcome, _ text: String,
                              door: String, minutes: Int?,
                              _ location: SourceLocation = #_sourceLocation) {
    guard case .writeItOut(let d, let m) = outcome else {
        Issue.record("\"\(text)\" was \(outcome), not a write-it-out",
                     sourceLocation: location)
        return
    }
    #expect(d.name == door, "\"\(text)\" named \(d.name)", sourceLocation: location)
    #expect(m == minutes, "\"\(text)\" carried \(m.map(String.init) ?? "no") minutes",
            sourceLocation: location)
}
