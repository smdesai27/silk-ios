import Foundation
import Testing
@testable import SilkCore

// THE ADVERSARIAL ROUND ON THE SPEND SHAPE.
//
// The grammar was just tightened: a door and a number no longer mint minutes
// on their own, and what stands between a mention and a debit is now an
// opening verb (`openingVerbs`) or the user's own commitment
// (`statesACommitment`). Two of those three things are WIDENINGS — a
// sixteen-entry verb list where there were six, and two new exemptions on the
// mood gate — and this repo's standing rule about widenings is that every one
// of them hijacks prose until somebody attacks it (docs/qa/fuzz-campaign
// -2026-08.md). This file is the attack.
//
// It is written as a negative suite. The tightening's own tests pin what
// grants; these rows pin what must NOT, because the failure that matters here
// is the unrecoverable one: minutes leaving the pool and a door opening on a
// sentence that asked for neither.
//
// FIVE ROUNDS, one per shape the widenings could be reached through:
//
//   1. the two new mood-gate exemptions, against reports, habits, negations,
//      attributions, plans and questions;
//   2. the verb list, against the same words used as nouns and adjectives —
//      including SILK'S OWN RECEIPT, which is a sentence with "open" in it;
//   3. rules 9 and 10, the fragment rules, which stand after every other rule
//      and must therefore take nothing off one;
//   4. the hint, which has to grant on every shape of door name there is;
//   5. the door names themselves, which are now exact.
//
// Five defects were found and fixed in `DeterministicParser.swift`; each one
// is named in the row that found it.

// MARK: - Fixtures

private let instagram = Door(name: "Instagram")
private let tiktok = Door(name: "TikTok")
private let reddit = Door(name: "Reddit")
private let youtube = Door(name: "YouTube")

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

/// 2026-07-29 15:00 local — outside the night window, so a verdict that is
/// held back is held back by the sentence and never by the hour.
private func afternoon() -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 15))!
}

/// The budget is 40, as the brief specifies: small enough that the hint's
/// hundred minutes has something to be clamped against.
private func makeState(_ doors: [Door] = [instagram, tiktok, reddit, youtube]) -> PolicyState {
    PolicyState(budgetMinutes: 40,
                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                doors: doors)
}

private func parse(_ text: String, _ state: PolicyState = makeState()) -> ParseOutcome {
    DeterministicParser.parse(text, state: state)
}

private func validate(_ text: String, _ state: PolicyState = makeState()) -> Verdict {
    Validator.validate(parse(text, state), utterance: text, state: state,
                       ledger: GrantLedger(), now: afternoon(), calendar: cal)
}

/// The one assertion this file is built on. A row may be silence, may be a
/// hint, may be a rule change — what it may never be is minutes.
private func expectNoMinutes(_ text: String, _ why: String,
                             _ state: PolicyState = makeState(),
                             _ location: SourceLocation = #_sourceLocation) {
    if case .command(.spend(let d, let m)) = parse(text, state) {
        Issue.record("\"\(text)\" spent \(m) on \(d.name) — \(why)",
                     sourceLocation: location)
    }
}

private func expectSilence(_ text: String, _ why: String,
                           _ state: PolicyState = makeState(),
                           _ location: SourceLocation = #_sourceLocation) {
    expectNoMinutes(text, why, state, location)
    let outcome = parse(text, state)
    guard outcome != .silence else { return }
    Issue.record("\"\(text)\" was \(outcome), not the widener's — \(why)",
                 sourceLocation: location)
}

private func expectWriteItOut(_ text: String, door: String, minutes: Int?,
                              _ state: PolicyState = makeState(),
                              _ location: SourceLocation = #_sourceLocation) {
    guard case .writeItOut(let d, let m) = parse(text, state) else {
        Issue.record("\"\(text)\" was \(parse(text, state)), not a write-it-out",
                     sourceLocation: location)
        return
    }
    #expect(d.name == door, "\"\(text)\" named \(d.name)", sourceLocation: location)
    #expect(m == minutes, "\"\(text)\" carried \(m.map(String.init) ?? "no") minutes",
            sourceLocation: location)
}

private func expectSpend(_ text: String, door: String, minutes: Int,
                         _ state: PolicyState = makeState(),
                         _ location: SourceLocation = #_sourceLocation) {
    guard case .command(.spend(let d, let m)) = parse(text, state) else {
        Issue.record("\"\(text)\" did not spend: \(parse(text, state))",
                     sourceLocation: location)
        return
    }
    #expect(d.name == door, "\"\(text)\" spent on \(d.name)", sourceLocation: location)
    #expect(m == minutes, "\"\(text)\" spent \(m)", sourceLocation: location)
}

/// THE NEVER-LOOSEN PROPERTY, asked of a row that compiles to a rule change.
///
/// The brief forbids comparing these against the pre-change parser, and the
/// property is the better question anyway: polarity is not parsed from words
/// but computed by state diff (`PolarityEngine`), so what a rule-change row has
/// to satisfy is that the Validator's polarity is the one the diff says, and
/// that anything loosening is PARKED — `isTighten` false, which is what keeps
/// it off the instant path and out of the down-hours exemption.
private func expectNeverLoosensInstantly(_ text: String,
                                         _ state: PolicyState = makeState(),
                                         _ location: SourceLocation = #_sourceLocation) {
    guard case .ruleChange(let proposed, let polarity) = validate(text, state) else {
        Issue.record("\"\(text)\" was \(validate(text, state)), not a rule change",
                     sourceLocation: location)
        return
    }
    #expect(polarity == PolarityEngine.classify(current: state, proposed: proposed),
            "\"\(text)\" carried a polarity its own diff does not agree with",
            sourceLocation: location)
    #expect(validate(text, state).isTighten == (polarity == .tighten),
            "\"\(text)\" is \(polarity) and instant", sourceLocation: location)
}

// MARK: - 1. The exemptions launder nothing

/// `statesACommitment` and `anInversionOpensTheClause` each stand a gate down
/// that was written to silence exactly these sentences. Every row here is a
/// report, a habit, a past, a plan, a negation, an attribution, an ambiguity
/// or a question, and every one of them must reach the widener instead.
@Suite struct TheExemptionsLaunderNothing {

    @Test(arguments: [
        // A HABIT is rule 3's sentence. The period may be spelled as a bare
        // unit phrase, as "every day", or as an adverb.
        ("i'm using instagram 2 hours a day", "a habit, stated with a period"),
        ("im using tiktok for 3 hours a day", "a habit"),
        ("i'm using instagram for 20 minutes every day", "a habit"),
        ("i'm usually using instagram for 20 minutes", "a habit, stated as an adverb"),
        ("i'm spending 10 minutes a day on instagram", "a habit"),
        // A PAST is not a plan. The frame has to be present and first-person.
        ("i've been using tiktok for 3 hours", "three hours already spent"),
        ("i was using instagram for 20 minutes", "somebody's afternoon, reported"),
        // A NEGATION is the opposite of an ask.
        ("i'm not using instagram for 10 minutes", "the frame is negated"),
        ("i'm going to bed, no instagram for 10", "a refusal in the second clause"),
        ("can i not have instagram for 10 minutes", "a negated inversion"),
        // AMBIGUITY. Two numbers has been the parser's refusal since it
        // shipped, and the exemption must not launder it.
        ("i'm using instagram for 10 minutes and tiktok for 20", "two doors, two numbers"),
        // A QUESTION is never a grant, inversion or no inversion.
        ("may i ask why instagram is capped at 10", "a wh-question about a ceiling"),
        // DEFECT 1 — "go on" is the phrasal verb that means the app only when
        // the app is what follows the particle. `statesACommitment` read the
        // particle and never its object, so a sentence COMPLAINING about
        // Instagram opened it for ten minutes. Fixed by requiring the door on
        // the particle.
        ("im going on about instagram for 10 minutes", "going on ABOUT it is complaining"),
        ("i'm going on the tiktok train for 10 minutes", "an idiom, not the app"),
        // DEFECT 2 — an attributed commitment is somebody else's sentence. The
        // quoted-speech arm was supposed to have caught this first; its proof
        // is a non-modal auxiliary in the clause, and the contraction's "m" is
        // not one, so "she said i AM using…" was silent and "she said i'M
        // using…" — the ordinary spelling — granted. Fixed by refusing a
        // speech verb ahead of the frame.
        ("she said i'm using instagram for 10 minutes", "reported speech"),
        ("he told me i'm using instagram for 10 minutes", "reported speech"),
        // DEFECT 3 — a commitment is a commitment to NOW; that is the whole of
        // why it counts as an ask. A plan for tomorrow was minted today.
        ("i'm going on instagram for 10 minutes tomorrow", "a plan for tomorrow"),
        ("i'm going on instagram for 10 minutes tonight", "a plan for tonight"),
        ("i'm using instagram for 10 minutes later", "a plan for later"),
        // NOT A COMMITMENT AT ALL: "getting instagram" has no particle, so the
        // gerund is the one that means acquiring, not opening.
        ("i'm getting instagram for 10 minutes", "no particle, so no phrasal verb"),
    ])
    func aReportIsNeverAGrant(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// A SENTENCE THAT COMPILES TO A RULE is still allowed to. What the round
    /// asks of these is only that the Validator's never-loosen property holds:
    /// the polarity is the state diff's own answer, and nothing loosening is
    /// instant.
    @Test(arguments: [
        "i'm going on holiday, cap instagram at 10",
        "i need to cap instagram at 10",
        "can i get a cap on instagram at 10",
        // A STATED PERIOD IS A CEILING, not a grant — even under the plainest
        // opening verb there is. "unlock instagram for 10 minutes A DAY" says
        // what Instagram gets every day, and rule 3 claims it long before the
        // mint sees it. Defensible and pinned here because the verb makes it
        // look like the hint.
        "unlock instagram for 10 minutes a day",
    ])
    func aRuleChangeStillCompilesAndNeverLoosensInstantly(_ text: String) {
        expectNoMinutes(text, "a rule change is not a grant")
        expectNeverLoosensInstantly(text)
        guard case .command(.setDoorCap(let d, let m)) = parse(text) else {
            Issue.record("\"\(text)\" was \(parse(text)), not a ceiling")
            return
        }
        #expect(d.name == "Instagram")
        #expect(m == 10)
    }

    /// INHERITED, AND NOT THE TIGHTENING'S. These two grant, and the round
    /// leaves them granting, because the exemption this file is attacking is
    /// not what lets them through: `requestModals` already exempts "can" and
    /// "could" from the mood gate and fires BEFORE `anInversionOpensTheClause`
    /// ever runs (the new helper's own comment says so), so the outcome is the
    /// one the parser had before the spend grammar was touched.
    ///
    /// They are recorded rather than fixed because closing them means teaching
    /// the mood gate perfect aspect — "have used", "have been" — which is a
    /// change to a gate the cap family's pinned rows were written against, and
    /// this round's mandate is the widenings, narrowly. **Delete the row when
    /// somebody closes it**; a red line here is the fix landing, not a
    /// regression.
    @Test(arguments: [
        "can i really have used 10 minutes of instagram",
        "could i have been on instagram for 10 minutes",
    ])
    func aPerfectAspectQuestionStillGrants(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// The same class, one step more defensible: this one IS an ask, spelled
    /// with the inversion the verb list names, and the only thing wrong with
    /// it is the day it names. The parser has no way to grant a sentence
    /// tomorrow, and the inversion is not the commitment frame, so the "not
    /// another time" guard that fixed DEFECT 3 does not reach it.
    @Test func anInvertedAskWithATomorrowInItStillGrantsToday() {
        expectSpend("can i have instagram for 10 minutes tomorrow",
                    door: "Instagram", minutes: 10)
    }
}

// MARK: - 2. The verb list does not claim prose

/// Ten words were added to `openingVerbs` and the list became the thing that
/// mints minutes. Half of them are also ordinary nouns and adjectives.
@Suite struct TheOpeningVerbListDoesNotClaimProse {

    @Test(arguments: [
        // "open" as an adjective, and "spend" and "use" as nouns.
        ("is instagram open for 10 minutes", "a question about state"),
        ("my instagram spend is 10 minutes", "a noun phrase and a copula"),
        ("what's the use of 10 minutes of instagram", "a wh-question"),
        // DEFECT 5 — the negated ask. `aNegatorRefusesTheAsk` reads
        // `askVerbs`, which predates the opening-verb authority and never
        // learned its last four stems, so "dont OPEN instagram for 10
        // minutes" was silent while "dont USE instagram for 10 minutes"
        // bought ten minutes of the app the sentence refused.
        ("no use, instagram for 10", "a refusal wearing the noun"),
        ("i can't get on instagram for 10 minutes", "a statement of inability"),
        ("dont use instagram for 10 minutes", "a refusal"),
        ("dont spend 10 minutes on instagram", "a refusal"),
        ("dont get on instagram for 10 minutes", "a refusal"),
    ])
    func proseIsNotAnAsk(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// DEFECT 4, AND THE WORST OF THEM: **Silk's own receipt, typed back,
    /// granted a second time.**
    ///
    /// A grant is confirmed as "Instagram is open for 15 min."
    /// (`SilkStrings.isOpenFor`). That sentence carries a door, a number and
    /// the token "open", so the mint read it as an ask and debited the pool
    /// again — fifteen more minutes and a second re-lock window, out of the
    /// app's own words, from a user who pasted back what she had just been
    /// told. `Strings.swift` pins the forward direction of this seam ("the
    /// hint typed back verbatim grants"); nothing was checking the mirror.
    ///
    /// The fix is one line in `hasOpeningVerb`: a copula or a determiner
    /// standing on the word makes it a predicate or a noun, not a request. The
    /// answer is now the hint, which is the right one — she said a door and a
    /// number and no verb.
    @Test func silksOwnReceiptDoesNotGrantASecondTime() {
        let receipt = "Instagram \(SilkStrings.isOpenFor) 15 \(SilkStrings.minutes)."
        #expect(receipt == "Instagram is open for 15 min.")
        expectNoMinutes(receipt, "the receipt is not an ask")
        expectWriteItOut(receipt, door: "Instagram", minutes: 15)
        // Every spelling of the same echo.
        expectWriteItOut("instagram is open for 10 minutes", door: "Instagram", minutes: 10)
        expectWriteItOut("instagram's open for 10 minutes", door: "Instagram", minutes: 10)
        expectWriteItOut("the open tab of instagram for 10 minutes",
                         door: "Instagram", minutes: 10)
    }

    /// THE ARGUABLE ASK, DECIDED. "go on then" is assent — the thing a person
    /// says when she has already decided — and the sentence names its door and
    /// its minutes. It grants, and the round defends it: the alternative
    /// reading ("go on" as narration) has no door and no number in it.
    @Test func assentWithADoorAndANumberIsAnAsk() {
        expectSpend("go on then, instagram 10", door: "Instagram", minutes: 10)
    }

    /// INHERITED, AND NOT THE TIGHTENING'S — the same standing as the perfect
    /// aspect rows above. Each granted before the verb list existed, because
    /// rule 7 needed no verb at all then; the tightening did not close them and
    /// did not open them. What each would need is a different guard —
    /// noun-compounding for the first ("my instagram SPEND"), a lexicon of
    /// stopping verbs for the second, a comparative for the third — and each
    /// of those is a class, not this defect. **Delete the row when somebody
    /// closes it.**
    @Test(arguments: [
        "10 minutes is my instagram spend",
        "i want to stop using instagram for 10 minutes",
        "i need less instagram, 10 minutes max",
    ])
    func aNounCompoundOrAStoppingVerbStillGrants(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// The widened list reaches rule 8 too, where the answer is a HINT and not
    /// a grant. "i need less instagram" is a door with a new opening verb and
    /// no number, so Silk writes out the sentence that would open it — a poor
    /// answer to somebody asking for restraint, and a harmless one: nothing is
    /// debited and the turn ends. Recorded so the cost of the widening is
    /// visible where it actually lands.
    @Test(arguments: ["i need less instagram"])
    func rule8AnswersProseWithAHintAndNeverWithMinutes(_ text: String) {
        expectNoMinutes(text, "rule 8 never mints")
        expectWriteItOut(text, door: "Instagram", minutes: nil)
    }

    /// And where the verb is NEGATED, rule 8 does not even hint: "no use for
    /// instagram anymore" is "no USE", the spend path's own refusal read one
    /// rule later, and the answer is the widener's silence rather than a
    /// sentence that would open the app she is renouncing.
    @Test(arguments: ["no use for instagram anymore", "dont open instagram"])
    func rule8FallsSilentOnANegatedVerb(_ text: String) {
        expectNoMinutes(text, "rule 8 never mints")
        #expect(DeterministicParser.parse(text, state: makeState()) == .silence)
    }
}

// MARK: - 3. The fragment rules take nothing

/// Rules 9 and 10 stand after every other rule so that a sentence some rule
/// already claims keeps it. These rows are the sentences they must NOT claim.
@Suite struct TheFragmentRulesStealNothing {

    /// A quantity is the number, its unit and politeness — nothing else. Two
    /// numbers is not a quantity, an unrecognised word is prose, and HOURS are
    /// deliberately off the unit list.
    @Test(arguments: [
        ("10 10", "two numbers"),
        ("10 and 20", "two numbers"),
        ("ten twenty", "two numbers"),
        ("minutes", "a unit with nothing on it"),
        ("please", "politeness alone"),
        ("", "nothing"),
        ("   ", "whitespace"),
        ("2 hours", "hours are not on the unit list"),
        ("an hour", "an idiom quantity, in hours"),
        ("half an hour", "an idiom quantity, in hours"),
        ("instagram tiktok", "two doors"),
        ("instagram and tiktok", "two doors"),
        ("instagramm", "not a door"),
        ("in stagram", "not a door"),
    ])
    func theFragmentRulesDecline(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// The fragments they DO claim, through their punctuation. A person typing
    /// back half a sentence types it the way she talks.
    @Test(arguments: [
        ("10.", 10), ("10?", 10), ("10!", 10), ("10 min?", 10),
        // A MINUS SIGN IS NOT A SIGN here: the tokenizer reads "-" as a space
        // (it is the hyphen of "twenty-five"), so "-10" is the quantity ten.
        // Harmless where it lands — a hint debits nothing — and recorded so
        // the reading is a decision rather than a surprise.
        ("-10", 10),
        // ZERO IS A NUMBER SHE TYPED. The grammar hands it over as typed;
        // the composer (`SilkStrings.writeItOut`) is what declines to teach
        // "for 0 min." and shows ten instead — see `theHintNeverTeachesAZero`
        // in SpendShapeTests. Nothing is debited on the way.
        ("0", 0), ("0 minutes", 0),
        // AND THE GRAMMAR NEVER CLAMPS. A million minutes is a million
        // minutes until the Validator meets the budget.
        ("1000000 minutes", 1_000_000),
    ])
    func aBareQuantityIsGuidedToTheFirstDoor(_ row: (String, Int)) {
        expectWriteItOut(row.0, door: "Instagram", minutes: row.1)
    }

    /// A DOOR IS NOT BARE WHEN SOMETHING ELSE IS THERE — but politeness and
    /// punctuation are not something else, and neither is a plural.
    @Test func aBareDoorIsGuided() {
        for text in ["instagram?", "instagram!", "instagram.", "Instagram, please.", "instagrams"] {
            expectWriteItOut(text, door: "Instagram", minutes: nil)
        }
        // A door with a number beside it is rule 7's sentence, not rule 9's:
        // the door named is the one she typed, never the first one.
        expectWriteItOut("10 please tiktok", door: "TikTok", minutes: 10)
    }

    /// The neighbours the fragment rules stand behind. Each still lands.
    @Test func theNeighbouringCommandsStillLand() {
        #expect(parse("budget 30") == .command(.setBudget(minutes: 30)))
        #expect(parse("cap tiktok 20") == .command(.setDoorCap(door: tiktok, minutes: 20)))
        #expect(parse("how much is left") == .command(.status))
    }

    /// A DOORLESS POLICY HAS NO DOOR TO GUESS AT.
    @Test func aDoorlessPolicyStaysSilent() {
        let empty = makeState([])
        #expect(parse("10 minutes", empty) == .silence)
        #expect(parse("instagram", empty) == .silence)
    }

    /// TEN THOUSAND TOKENS OF EACH HALF OF THE FRAGMENT SHAPE, which is what
    /// `bareDoor`'s 1...4 token bound and rule 9's single-number requirement
    /// exist for: neither may walk a paste.
    ///
    /// A RATIO AND NOT A WALL-CLOCK BOUND. An absolute millisecond figure is
    /// the most-cited flake on this repo's pre-push hook
    /// (`hugeInputStaysCheapAndSilent` says so at length) and it would be a
    /// bound on the machine rather than on the rule: a debug `swift test`
    /// build parses ten thousand words of ordinary noise — the parser's own
    /// pinned baseline, which reaches no rule at all — in about ninety
    /// milliseconds on this machine, so "under 50 ms" cannot be asked of
    /// anything. What the fragment rules have to be is no more expensive than
    /// that baseline by an order that is visibly not a walk of the paste;
    /// measured here at 0.8x for the quantity paste and 3x for the door one,
    /// against a bound of 6.
    @Test func aHugePasteIsSilentAndCheap() {
        let state = makeState()
        func bestMilliseconds(_ text: String) -> Double {
            var best = Double.infinity
            for _ in 0..<5 {
                let t0 = Date()
                _ = DeterministicParser.parse(text, state: state)
                best = min(best, Date().timeIntervalSince(t0) * 1000)
            }
            return best
        }
        let noise = Array(repeating: "lorem ipsum dolor sit amet", count: 2_000)
            .joined(separator: " ")
        let quantities = String(repeating: "10 ", count: 10_000)
        let doors = String(repeating: "instagram ", count: 10_000)

        #expect(parse(quantities, state) == .silence)
        #expect(parse(doors, state) == .silence)

        let baseline = bestMilliseconds(noise)
        let quantityCost = bestMilliseconds(quantities) / baseline
        let doorCost = bestMilliseconds(doors) / baseline
        #expect(quantityCost < 6, "ten thousand quantities cost \(quantityCost)x the baseline")
        #expect(doorCost < 6, "ten thousand doors cost \(doorCost)x the baseline")
    }
}

// MARK: - 4. The hint always grants

/// The design rests on one loop: the answer to half a sentence is the whole
/// sentence, and the whole sentence typed back opens the door. It has to close
/// on every shape of door name a user can own.
@Suite struct TheHintGrantsOnEveryDoorName {

    private func hintTypedBack(_ door: String, minutes: Int?) -> String {
        let hint = SilkStrings.writeItOut(door, minutes: minutes)
        return String(hint.dropFirst(SilkStrings.writeItOut.count))
            .trimmingCharacters(in: .whitespaces)
    }

    private var manyShapes: PolicyState {
        makeState([Door(name: "Google Maps"), Door(name: "Threads"),
                   Door(name: "X"), Door(name: "9GAG"), instagram, tiktok])
    }

    /// Two-word names, a name that ENDS IN S (the deinflection strips one, and
    /// a door whose own name carries it must survive that), a single LETTER,
    /// and a name that opens with a DIGIT.
    @Test(arguments: [
        ("Google Maps", 10), ("Threads", 10), ("X", 10), ("9GAG", 10),
        ("Instagram", 25), ("TikTok", 5),
        // THE BUDGET DOES NOT CLAMP THE GRAMMAR. A hundred minutes against a
        // forty-minute pool parses as a hundred; the Validator is the only
        // thing in this system allowed to reduce a number.
        ("Instagram", 100),
    ])
    func theHintTypedBackGrants(_ row: (String, Int)) {
        expectSpend(hintTypedBack(row.0, minutes: row.1),
                    door: row.0, minutes: row.1, manyShapes)
    }

    /// AND THE MINUTELESS HINT SAYS TEN AND GRANTS TEN, on every one of them.
    @Test func theMinutelessHintGrantsItsOwnTen() {
        for door in manyShapes.doors {
            #expect(SilkStrings.writeItOut(door.name, minutes: nil)
                == "Write it out: unlock \(door.name) for 10 min.")
            expectSpend(hintTypedBack(door.name, minutes: nil),
                        door: door.name, minutes: 10, manyShapes)
        }
    }

    /// THE CLAMP IS THE VALIDATOR'S, and here it is doing it: a hundred
    /// minutes against a forty-minute pool grants forty.
    @Test func theValidatorClampsWhatTheGrammarDidNot() {
        let text = hintTypedBack("Instagram", minutes: 100)
        guard case .grant(let d, let m, _) = validate(text) else {
            Issue.record("\"\(text)\" was \(validate(text)), not a grant")
            return
        }
        #expect(d.name == "Instagram")
        #expect(m == 40)
    }

    /// A hint that is only half typed back is answered with the hint again —
    /// the loop never terminates in silence.
    @Test func thePartialsAreGuidedAndDebitNothing() {
        #expect(validate("instagram 10") == .refuseWriteItOut(door: instagram, minutes: 10))
        #expect(validate("10 minutes") == .refuseWriteItOut(door: instagram, minutes: 10))
        #expect(!validate("instagram 10").isTighten)
    }
}

// MARK: - The second round: what the fixes themselves must not take

/// Every fix in this round is a NEW REFUSAL, and a new refusal is a widening
/// facing the other way: it can eat asks. One of them did — the guard that
/// stops Silk's receipt from granting was written over the whole verb list
/// first, and read "im done after THIS, GIVE me ten minutes of instagram" as a
/// noun phrase. These are the rows that found it and the rows that keep the
/// three narrowings honest.
@Suite struct TheFixesTakeNothingBack {

    /// The negated-verb refusal must not swallow an ask with a preamble:
    /// "dont get mad" is not "dont get on", and only the second one refuses.
    @Test(arguments: [
        "dont get mad, give me 10 minutes of instagram",
        "dont go crazy, give me 10 minutes of instagram",
        "i cant get mad, give me 10 minutes of instagram",
    ])
    func aPreambleIsNotARefusal(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// The noun-phrase guard must not swallow a determiner that belongs to the
    /// clause BEFORE the verb.
    @Test(arguments: [
        "im done after this, give me ten minutes of instagram",
        "that was nice, give me 10 minutes of instagram",
        "open instagram for 10",
        "spend 10 on instagram",
    ])
    func aDeterminerInTheOtherClauseIsNotADeterminerOnTheVerb(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// And it does still catch the noun readings it was written for.
    @Test(arguments: ["a use of 10 minutes on instagram", "the spend is 10 on instagram"])
    func aNounStaysANoun(_ text: String) {
        expectSilence(text, "a determiner heads it")
    }

    /// The particle's object is matched through `door(_:in:)` like every other
    /// door in the file, so a TWO-WORD name is still the door it governs.
    @Test func aTwoWordDoorOnTheParticleStillCommits() {
        let maps = makeState([Door(name: "Google Maps"), instagram])
        expectSpend("i'm going on google maps for 10 minutes",
                    door: "Google Maps", minutes: 10, maps)
        expectSpend("im going on google maps for 10 minutes",
                    door: "Google Maps", minutes: 10, maps)
    }
}

// MARK: - 5. A door answers to its exact name

@Suite struct ADoorAnswersToItsExactName {

    /// A NICKNAME IS AN UNKNOWN APP. A door named "Insta" is not named by
    /// "instagram", in either direction, and the sentence belongs to the
    /// widener rather than to a door the user did not name.
    @Test func aNameIsNotAPrefixOfAnother() {
        let insta = makeState([Door(name: "Insta")])
        expectSilence("10 minutes of instagram", "instagram is not insta", insta)
        expectSilence("unlock instagram for 10 min", "instagram is not insta", insta)
        let threads = makeState([Door(name: "Threads")])
        expectWriteItOut("threads", door: "Threads", minutes: nil, threads)
        expectSilence("thread", "the deinflection strips an s, it does not add one", threads)
    }

    /// THE SPACE IS PART OF THE NAME. "tik tok" is two words and TikTok is one.
    @Test func aSpaceIsNotNothing() {
        expectSilence("tik tok", "two tokens, and the door is one")
        expectSilence("give me 10 minutes of tik tok", "two tokens, and the door is one")
    }

    /// CASE IS NOT PART OF IT.
    @Test func caseFoldsBothWays() {
        expectWriteItOut("TIKTOK", door: "TikTok", minutes: nil)
        expectSpend("UNLOCK TIKTOK FOR 10 MIN", door: "TikTok", minutes: 10)
        let maps = makeState([Door(name: "Google Maps")])
        expectWriteItOut("GOOGLE MAPS", door: "Google Maps", minutes: nil, maps)
    }
}
