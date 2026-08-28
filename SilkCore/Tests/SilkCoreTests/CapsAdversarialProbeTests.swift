import Testing
import Foundation
@testable import SilkCore

// The caps adversarial round.
//
// Four lenses attacked the per-app cap grammar on main tip 47993b4: clause
// boundaries (ClauseIndex openers, commas, dots, newlines, dashes), negation
// and polarity (capRemovers, nounNegators, the "no cap" slang gate), chatter
// and report hijacks (the mood gates, the finance/sports/slang senses of
// "cap"), and numbers/units/aliases (seconds, hours, idioms, decimals, zero,
// saturation, hundred-poisoning, LaunchCatalog shorthand). Every sentence
// below was executed against the live parser and Validator before it was
// pinned: the passing suites are regression armor for behavior verified on
// this tip, and the round's fourteen findings — the sentences the grammar
// genuinely got wrong — are fixed and promoted into that armor, each marked
// "FINDING n, promoted" beside the seam it pins (see the FINDINGS note at the
// bottom).
//
// Repo law observed throughout: assert the policy or verdict, never a derived
// balance; every probe hermetic; residuals already accepted on this tip
// (list-bounded gates, fake-clock chains) are not re-probed here.

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private let afternoon = cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 15))!

private let instagram = Door(name: "Instagram", aliases: ["ig", "insta", "the gram"])
private let tiktok = Door(name: "TikTok")
private let youtube = Door(name: "YouTube", aliases: ["yt"])
private let reddit = Door(name: "Reddit")

private func makeState(budget: Int = 40, caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget,
                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                doors: [instagram, tiktok, youtube, reddit],
                doorCaps: caps)
}

/// TikTok at 20, Instagram at 15 — so a wrong clearing is a parked loosening
/// and a wrong set is a visible raise or a repeat.
private var capped: PolicyState { makeState(caps: [tiktok.id: 20, instagram.id: 15]) }

private func parse(_ utterance: String, _ state: PolicyState = makeState()) -> ParseOutcome {
    DeterministicParser.parse(utterance, state: state)
}

private func spend(_ utterance: String, _ state: PolicyState = makeState()) -> (String, Int)? {
    guard case .command(.spend(let door, let minutes)) = parse(utterance, state) else { return nil }
    return (door.name, minutes)
}

private func setsCap(_ utterance: String, _ state: PolicyState = makeState()) -> (String, Int)? {
    guard case .command(.setDoorCap(let door, .some(let m))) = parse(utterance, state) else { return nil }
    return (door.name, m)
}

private func clearsCap(_ utterance: String, _ state: PolicyState = capped) -> String? {
    guard case .command(.setDoorCap(let door, nil)) = parse(utterance, state) else { return nil }
    return door.name
}

private func budgetOf(_ utterance: String, _ state: PolicyState = makeState()) -> Int? {
    guard case .command(.setBudget(let minutes)) = parse(utterance, state) else { return nil }
    return minutes
}

private func verdict(_ utterance: String, _ state: PolicyState = makeState(),
                     ledger: GrantLedger = GrantLedger()) -> Verdict {
    Validator.validate(parse(utterance, state), utterance: utterance, state: state,
                       ledger: ledger, now: afternoon, calendar: cal)
}

// MARK: - Lens 1: the clause index holds the cap clause together

@Suite struct CapsAdversarialProbeClauseBoundaries {

    /// Discourse markers, sealed negators, habit-report clauses and trailing
    /// commentary must not leak into the cap clause: the setter's own breath
    /// stays whole and the neighbours stay clause-local.
    @Test(arguments: [
        ("cap tiktok at 20 though", "TikTok", 20),
        // A bare negator sealed in its own clause by the comma must not reach
        // capSet's clause-scoped refused-scan.
        ("no, cap tiktok at 20", "TikTok", 20),
        ("im not kidding, cap tiktok at 20", "TikTok", 20),
        // The "so" opener isolates the habit report from the imperative.
        ("ive been doomscrolling all morning so cap tiktok at 25", "TikTok", 25),
        // The comma bounds both the unit lookahead and the hours arm: never 1200.
        ("cap tiktok at 20, hours of homework left", "TikTok", 20),
        // "so" opens mid-tail; "im" after the number is a subject, not a report.
        ("cap tiktok at 20 im so done", "TikTok", 20),
        // The idiom's 30 occupies no token; the trailing clause must not gate it.
        ("cap tiktok at half an hour, thats plenty", "TikTok", 30),
        // Cap noun as commentary in clause A, habitual setter in clause B.
        ("thats my limit, tiktok 20 a day", "TikTok", 20),
        ("new rule, tiktok 20 a day", "TikTok", 20),
        // habitIrregular "stole" and the clock word "evening" stay clause-local.
        ("insta stole my whole evening, cap insta at 30", "Instagram", 30),
        // An ellipsis is a hesitation, not a clause break.
        ("cap tiktok... 20", "TikTok", 20),
        // "because" is deliberately not a clause opener; "cant" is a modal,
        // excluded from the finite-verb test.
        ("cap tiktok at 20 because i cant stop", "TikTok", 20),
    ])
    func aNeighbouringClauseNeitherBindsNorVetoes(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// Cap talk beside budget talk: the cap family owns the number and
    /// terminates before the pool stem is ever consulted.
    @Test func capBesideBudgetNeverTouchesThePool() {
        #expect(parse("cap tiktok at 25, my budget is fine")
                == .command(.setDoorCap(door: tiktok, minutes: 25)))
        #expect(parse("cap tiktok, and my budget is fine") == .silence)
    }

    /// A cap word stranded from its number by a comma must TERMINATE in
    /// silence — a decline here walks the ladder into SPEND and answers a
    /// restriction by unshielding the app.
    @Test(arguments: [
        "cap youtube, maybe 30",
        // "but" strands the number in a doorless clause; the fragment must
        // fail spendFragment ("only" is not phrase vocabulary).
        "cap tiktok but only 20",
        // "if" is not a clause opener: two numbers share the breath, and a
        // subordinate-clause number is ambiguity, not a second command.
        "cap tiktok at 20 if i go over 30",
        // FINDING 5, promoted: the question clause has cap+door and no
        // number, and its silence arm was vetoed because the mood gate read
        // the request modal "can" as a plain auxiliary — the decline let the
        // bare "20 minutes" fund a grant. The arm now carries the setter
        // gate's own requestModals exemption (wh-guard included) and
        // terminates whenever another breath holds a number the decline
        // would hand to SPEND; the NUMBERLESS polite ask stays rule 8's
        // sentence ("can i get a cap on tiktok" is pinned in StressTests as
        // "How long?"), and the clearing family's question refusals are
        // untouched.
        "can you cap tiktok? 20 minutes",
        // FINDING 6, promoted: dictation commas strand the quantifier from
        // its number, the noun-only silence arm fell through, and the
        // doorless "20" funded a grant. A door with a clause-FINAL trailing
        // quantifier and no number now terminates — clause-final is what
        // "stranded by the boundary" means, so "keep insta under control"
        // keeps bounding its own noun; the ask-verb exemption keeps "give me
        // tiktok max" walking to rule 8's "How long?", and the uncomma'd
        // "keep tiktok under 20 a day" is a canonical setter pinned above.
        "keep tiktok under, say, 20",
        // FINDING 3, promoted: the dative setter — the ask verb's recipient
        // is the DOOR ("give THE DOOR a ceiling", never "give ME"), the cap
        // noun trails both number and door, and rule 7 was reading it as the
        // hot path. Terminating silence; never a grant.
        "give tiktok a 20 minute ceiling",
    ])
    func aStrandedOrAmbiguousCapTerminatesInSilence(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" kept walking")
    }

    /// The comma spelling of a lower-my-cap plea: the number lives one clause
    /// over, so the clearing lands.
    @Test func aClearingWithItsReasonAcrossTheCommaStillClears() {
        #expect(clearsCap("remove the tiktok cap, 20 is too strict") == "TikTok")
    }

    /// FINDING 4, promoted. The "because" spelling of the same plea glues the
    /// reason's number and copula into the clearing's own clause; the tail
    /// guard's decline walked the ladder into SPEND, and a clearing request
    /// was answered with a grant and a debited pool. The guard now terminates
    /// on a doorful clause — the family's own doctrine — while the doorless
    /// commentary tail ("no cap needed") and the remover-led stated ceiling
    /// ("drop the tiktok limit TO 20") keep their declines, both pinned above.
    @Test func aClearingWithItsReasonInTheSameBreathNeverGrants() {
        #expect(spend("uncap tiktok because 20 was too strict", capped) == nil)
        #expect(parse("uncap tiktok because 20 was too strict", capped) == .silence)
    }

    /// First breath wins between two cap outcomes — clause order, not rule
    /// order, decides. The dropped second command is the disclosed
    /// one-command cost, pinned here so a future widening does not turn it
    /// into a .several silence or a grant.
    @Test func theFirstBreathWinsBetweenTwoCapOutcomes() {
        // "5." reads as a full stop — digit runs are never abbreviations —
        // keeping the tighten and the loosening in separate breaths.
        #expect(parse("cap tiktok at 5. no cap on instagram", capped)
                == .command(.setDoorCap(door: tiktok, minutes: 5)))
        // Mirror order: the clearing leads and wins; tiktok's cap drops.
        #expect(parse("no cap on instagram. cap tiktok at 5", capped)
                == .command(.setDoorCap(door: instagram, minutes: nil)))
        // Set leads, trailing loosening drops — the safe direction.
        #expect(parse("cap instagram at 30, uncap tiktok", capped)
                == .command(.setDoorCap(door: instagram, minutes: 30)))
        // A newline is an unconditional separator; the trailing loosening drops.
        #expect(parse("cap tiktok at 20\nuncap instagram", capped)
                == .command(.setDoorCap(door: tiktok, minutes: 20)))
        // Two doors in two clauses is NOT the one-clause two-door ambiguity:
        // doors(in:) is clause-scoped.
        #expect(parse("cap tiktok at 20, instagram too")
                == .command(.setDoorCap(door: tiktok, minutes: 20)))
    }

    /// FINDING 7, promoted. The earlier-claim guard's remover arm tested the
    /// clause's FIRST TOKEN, and the "so" opener (which keeps its word)
    /// occupies that slot — so "ok so remove instagram, no cap on tiktok"
    /// resurrected the exact defect the anchor fix closed for "hey, remove
    /// instagram…": the removal went unclaimed and the trailing loosening
    /// parked. The arm now steps over a leading clause opener, exactly as
    /// spendFragment steps over the same four words.
    ///
    /// The whole-sentence outcome is SILENCE, not the removal — the finding's
    /// draft expected .removeDoor, but rule 5's own contract (pinned in
    /// StressTests for the "hey," flavor) is that a preambled removal is not
    /// claimed either: "the cap clause declines and rule 5's own removal does
    /// not claim a preambled clause"; silence reaches the widener, which per
    /// §5.7 can produce neither a cap nor a deletion.
    @Test func anOpenerLedRemovalStillClaimsItsFirstBreath() {
        #expect(clearsCap("ok so remove instagram, no cap on tiktok") == nil)
        #expect(parse("ok so remove instagram, no cap on tiktok", capped) == .silence)
        // The unpreambled spelling keeps the removal itself, so the guard is
        // not passing by having stopped reading removals.
        #expect(parse("remove instagram, no cap on tiktok", capped)
                == .command(.removeDoor(door: instagram)))
    }

    /// FINDING 11, promoted. The earlier-claim guard respected only earlier
    /// clauses that name a DOOR, so a first-breath POOL command was invisible
    /// and the trailing LOOSENING executed — inverting the guard's own
    /// first-intent doctrine. A pool command (the budget stem with a number
    /// in its breath) now claims its clause against a trailing clearing, and
    /// the budget move lands. Scoped to the loosening direction: the
    /// tightening flavor stays the pinned recall seam above.
    @Test func aLeadingPoolCommandVetoesTheTrailingLoosening() {
        #expect(clearsCap("set my budget to 40, no cap on tiktok") == nil)
        #expect(parse("set my budget to 40, no cap on tiktok", capped)
                == .command(.setBudget(minutes: 40)))
    }

    /// windowMention is utterance-wide while the cap family is clause-scoped,
    /// so a window word in the SECOND clause poisons a clean first-clause cap.
    /// Direction-safe silence — the disclosed cross-clause poison asymmetry,
    /// pinned as a recall hole rather than a defect.
    @Test func aTrailingWindowWordPoisonsTheCapIntoSilence() {
        #expect(parse("cap tiktok at 20, big night tonight") == .silence)
    }

    /// hasClosingVerb is utterance-wide and outranks the clause-scoped cap
    /// family by rule order: a close verb inside a trailing CONDITIONAL takes
    /// the sentence. A close is the disclosed never-wrong direction, so this
    /// pins the close-hoist asymmetry announced — and above all: no grant.
    @Test func aConditionalCloseVerbHoistsTheSentenceIntoAClose() {
        guard case .command(.closeDoorToday(let d, _))
            = parse("cap tiktok at 20, if i go over 30 block it") else {
            Issue.record("the close-hoist asymmetry moved — re-adjudicate the sentence")
            return
        }
        #expect(d.name == "TikTok")
    }

    /// The earlier-claim guard's "intent" test is bare number-presence, so a
    /// habit report's 120 in clause A counts as a claimed intent on the same
    /// door and suppresses clause B's explicit cap; two whole-utterance
    /// numbers then kill SPEND too. Direction-safe silence — the recall seam
    /// between anotherDoorIsClaimedEarlier and the mood gates, pinned.
    @Test func aNumberedHabitReportSuppressesTheTrailingCapIntoSilence() {
        #expect(parse("insta stole 2 hours from me, cap insta at 30") == .silence)
    }

    /// The pool-claim hole, tightening flavor: caps run ahead of rule 3 and
    /// the earlier-claim guard sees only DOORS, so the budget raise the
    /// sentence led with is silently dropped. Both outcomes are tightenings —
    /// this pins the recall seam, and above all that no grant ever lands.
    @Test func aLeadingPoolCommandLosesToTheTrailingCap() {
        #expect(parse("make my budget 60 a day, cap tiktok at 20")
                == .command(.setDoorCap(door: tiktok, minutes: 20)))
    }

    /// FINDING 8, promoted. The spaced hyphen after a non-quantity word is a
    /// clause dash, so "tiktok - 20 a day" strands the door from its quantity:
    /// the cap rules went blind, rule 3's two door guards both missed — the
    /// number's clause names no door and no ceiling word leads one — and the
    /// doorless fallback CUT THE SHARED POOL to 20, instantly, out of a
    /// per-app habitual. A bare door name standing alone in the breath before
    /// the number is now the stranded topic of the number's own sentence, and
    /// the pool does not move on it. The undashed spelling keeps its per-door
    /// cap, and the commentary pool moves ("make it 30 a day, tiktok is my
    /// limit" — the door with a predicate of its own) are pinned elsewhere.
    @Test func aDashStrandedDoorTopicNeverCutsThePool() {
        #expect(budgetOf("tiktok - 20 a day") == nil)  // never setBudget
        #expect(parse("tiktok - 20 a day") == .silence)
        #expect(setsCap("tiktok 20 a day").map { $0 == ("TikTok", 20) } == true)
    }

    /// The hot path with a cap noun trailing as commentary in its own clause:
    /// neither capCleared nor capSet may steal it.
    @Test func theHotPathKeepsItsGrantBesideCapCommentary() {
        let a = spend("give me 20 of tiktok, thats my limit")
        #expect(a?.0 == "TikTok" && a?.1 == 20)
        let b = spend("give me 20 of tiktok, no cap needed")
        #expect(b?.0 == "TikTok" && b?.1 == 20)
        // A bare quantifier inside an ask: the hedge veto reads askVerbs as
        // clause tokens — the historical failure compiled this to a ceiling.
        let c = spend("gimme under 20 of tiktok")
        #expect(c?.0 == "TikTok" && c?.1 == 20)
        // FINDING 6's contrast row: a quantifier bounding its OWN noun is not
        // the stranded quantifier — only a clause-FINAL one terminates. (The
        // cross-door spelling of this sentence is silenced by rule 7's own
        // funding guard, so the contrast is pinned on one door.)
        let d = spend("keep tiktok under control, give me 20 of tiktok")
        #expect(d?.0 == "TikTok" && d?.1 == 20)
    }

    /// Door removal with a cap noun and a DIFFERENT door in the reason
    /// clause: rule 5's guards stay scoped to the door being removed.
    @Test func aRemovalKeepsItsReasonClauseInert() {
        #expect(parse("remove youtube, insta is my limit these days", capped)
                == .command(.removeDoor(door: youtube)))
    }
}

// MARK: - Lens 2: negation, clearing, and polarity

@Suite struct CapsAdversarialProbeClearings {

    /// The deliberate clearings, across the whole remover inventory.
    @Test(arguments: [
        // "uncap" is the one remover needing no noun beside it.
        "uncap tiktok",
        // trailingParticles admits the slang tail on a REAL clearing.
        "no cap on tiktok ngl",
        // Negated volition IS a request for absence.
        "i dont want a cap on tiktok anymore",
        "get rid of the tiktok limit",
    ])
    func aDeliberateClearingStillClears(_ utterance: String) {
        #expect(clearsCap(utterance) == "TikTok", "\"\(utterance)\" no longer clears")
    }

    @Test func theSettingsVocabularyClearingStillClears() {
        #expect(clearsCap("remove the limit on youtube") == "YouTube")
    }

    /// "never" standing directly on the bare cap noun with only the door
    /// trailing — the one shape where a bare negator clears on its own; a
    /// standing demand for absence, parked as a loosening.
    @Test func aStandingDemandForAbsenceReadsAsAClearing() {
        #expect(clearsCap("never cap insta") == "Instagram")
    }

    /// Doorless slang, subjects, and predicates: "no cap" the emphatic must
    /// never loosen anything.
    @Test(arguments: [
        "no cap fr",
        "thats no cap",
        "fr no cap tho",
        // "got" after the phrase breaks spansOneNounPhrase.
        "tbh no cap tiktok got me",
        // Fresh Gen-Z opener ahead of the negator fails the emphatic gate.
        "straight up no cap tiktok owns me",
        // FINDING 9, promoted: the door-as-afterthought spelling. Every token
        // before the negator and after the phrase was on the trailing-particle
        // and door whitelists, so both the emphatic gate and the after-span
        // veto passed and pure chatter parked a loosening. A SLANG particle
        // ahead of the negator is now emphatic evidence in its own right —
        // its whitelist seat exists for the tail of a real clearing ("no cap
        // on tiktok fr fr", pinned in ProseHijackTests), not its opening.
        "fr no cap tho tiktok",
    ])
    func theSlangEmphaticClearsNoCeiling(_ utterance: String) {
        #expect(clearsCap(utterance) == nil, "\"\(utterance)\" cleared a cap from chatter")
    }

    /// A negator whose object is the setting or the REMOVAL itself: nothing
    /// may be written and nothing may be cleared.
    @Test(arguments: [
        "dont cap tiktok",
        "never uncap tiktok",
        "dont uncap tiktok",
        "dont take the cap off tiktok",
        // Politeness ahead of the negator must not shift the ordering.
        "please dont take the cap off tiktok",
        "please dont lift the insta cap",
        // Refusal verb with the subject elided: clearingPhrase must see
        // "remove" as the negator's object.
        "refuse to remove the tiktok cap",
        // Negator over a remover-led setter: none of clear/set/removeDoor.
        "dont drop the tiktok limit to 10",
    ])
    func aNegatedRemovalNeitherClearsNorWrites(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" moved policy")
    }

    /// Refusals and vernacular double negatives around the APP or the cap:
    /// no clearing, no set — err tight.
    @Test(arguments: [
        // Refusal of the app, not the cap: no cap noun anywhere.
        "i dont want tiktok anymore",
        // "no" between "want" and "cap" breaks the dont-want span AND blocks
        // the nounNegator — the two rules cannot each half-fire.
        "i dont want no cap on tiktok",
        // "removed"/"any higher" trail the noun phrase: the after-span veto.
        "i dont want the tiktok cap removed",
        "i dont want the tiktok cap any higher",
        // The ordered pair means FORBIDDEN; the strongest tightening idiom
        // must never come back a loosening.
        "tiktok is off limits",
        // Questions and reports of fact: the answer to a question is never a
        // new rule, and one finite verb separates "tiktok is uncapped" from
        // the fragment the grammar deliberately clears.
        "is tiktok uncapped",
        "tiktok is uncapped",
        "is the tiktok limit off rn",
    ])
    func aRefusalOrReportAroundTheCapMovesNothing(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" moved policy")
    }

    /// Lexical negators ahead of the setter — with the subject elided, with a
    /// request modal riding along, with the two-token "no one" — must refuse
    /// AND terminate: a decline walks into SPEND against the app being capped.
    @Test(arguments: [
        "refuse to cap tiktok at 20",
        "nobody should cap tiktok at 20",
        "no one caps tiktok at 20 anymore",
        // "cant" is both negator and requestModal: the refusal wins.
        "cant cap tiktok at 20",
        "why not cap tiktok at 20",
    ])
    func aRefusedSetterWritesNothingAndNeverGrants(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" wrote or granted")
    }

    /// A negated-number correction across a clause boundary trips the
    /// single-number ambiguity refusal; acting on the refused 20 would be the
    /// polarity inversion this lens hunts. The in-clause spelling is FINDING
    /// 12, promoted: "but" opens a clause, "but 30" leaves the breath, the
    /// cap clause holds exactly one number, and the refused-scan looked only
    /// AHEAD of the lexeme — so the ceiling written was the number the
    /// sentence explicitly negates. A negator standing directly ON the number
    /// now refuses ("no more than 20" is untouched: its negator stands on
    /// "more", never on the number).
    @Test func aNegatedNumberCorrectionRefuses() {
        #expect(parse("not 20, 30 minutes for tiktok") == .silence)
        #expect(parse("cap tiktok at not 20 but 30") == .silence)
    }

    /// The three-way ambiguity (clear / set / removeDoor) resolved by one
    /// preposition: a remover-led STATED ceiling is a set, and the quoted
    /// ceiling inside the phrase is a clear.
    @Test func aRemoverLedStatedCeilingIsASet() {
        #expect(setsCap("drop the tiktok limit to 20", capped)?.1 == 20)
    }

    /// Polarity: a clearing reads absent-as-infinity and parks; a raise said
    /// in the vocabulary of restriction is still a loosening; a tighten is a
    /// tighten. Raw caps, never effective ceilings.
    @Test func polarityReadsRawCapsInBothDirections() {
        guard case .ruleChange(_, let clearing) = verdict("no cap on tiktok", capped),
              case .ruleChange(_, let raise) = verdict("cap tiktok at 45", capped),
              case .ruleChange(_, let tighten) = verdict("cap tiktok at 10", capped) else {
            Issue.record("a cap rule change stopped reaching the Validator")
            return
        }
        #expect(clearing == .loosen)
        #expect(raise == .loosen)
        #expect(tighten == .tighten)
    }
}

// MARK: - Lens 3: chatter, reports, and the other senses of "cap"

@Suite struct CapsAdversarialProbeReports {

    /// Past-tense, finance, tech, sports, and slang senses of "cap" beside a
    /// door name, quoted and attributed instructions, door-as-subject
    /// restatements, habit counts, incidental numbers, and the bottle: none
    /// of it is policy, and none of it may fall through to a grant.
    @Test(arguments: [
        "i capped my tiktok spending at 50 bucks last month",
        "i capped tiktok at 20 last month and it didnt help",
        "youtube says the game is capped at 60 fps",
        "reddit says he was capped at 40 points",
        "tiktok says i used 200 minutes but thats cap",
        "he said he only uses tiktok 20 minutes a day but hes capping",
        // Attributed instruction: a reported third-party sentence must not
        // write standing policy deterministically.
        "my mom said cap tiktok at 20",
        "when did the tiktok cap become 20",
        // Settings prints exactly these words; a report is not an instruction
        // even when it happens to be true.
        "my cap for tiktok is 20 already",
        "tiktoks cap reads 45 in settings",
        "insta isnt capped at 15 anymore right",
        // The fixed habit-report class stays fixed: "times" is a count.
        "i open tiktok 20 times a day",
        "i probably unlock insta 30 times a day",
        // "dropped" is simultaneously a capRemover stem and an -ed participle.
        "tiktok update dropped 3 new features",
        // The bottle-cap sense: a cap noun leading a door with no number hits
        // the terminating no-number silence arm.
        "put the cap back on the bottle before tiktok",
        "the bottle cap costs 2 bucks, anyway unlock tiktok for 15",
        // "capping" is absent from capNouns; the subject-ahead spend gate is
        // what keeps the progressive out of the grant direction.
        "im capping tiktok at 20",
    ])
    func aReportAboutCapsWritesNothing(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" compiled to policy")
    }

    /// Two doors under one ceiling must TERMINATE (.several), never decline
    /// into SPEND on whichever door was spelled first.
    @Test func twoDoorsOneCeilingTerminates() {
        #expect(parse("limit tiktok and reddit to 15 a day") == .silence)
    }

    /// FINDING 10, promoted. The requestModals exemption admits the question
    /// clause as a setter and the answering "no" was an invisible one-word
    /// clause, so a self-declined question wrote standing policy with only a
    /// toast. A question-shaped setter followed by a bare-negator clause now
    /// terminates; the leading sealed negator ("no, cap tiktok at 20") is a
    /// pinned setter and stays one, because the answer clause must TRAIL the
    /// question it declines.
    @Test func aDeclinedQuestionNeverLands() {
        #expect(parse("should i cap tiktok at 20? no") == .silence)
        #expect(setsCap("no, cap tiktok at 20").map { $0 == ("TikTok", 20) } == true)
    }

    /// The canonical setters are the floor the hijack gates must never eat.
    @Test(arguments: [
        ("cap tiktok at 20 minutes", "TikTok", 20),
        ("limit insta to 15 a day", "Instagram", 15),
        ("keep tiktok under 20 a day", "TikTok", 20),
        // Terse Settings-row echo: the whole clause is one noun phrase.
        ("tiktok limit 20", "TikTok", 20),
        // A determiner before the lexeme is tolerated — the contrast row for
        // FINDINGS 1-2, where the determiner stands between lexeme and number.
        ("make the tiktok limit 20", "TikTok", 20),
        // Number-before-noun: the cap noun leads the door.
        ("set a 15 minute cap on instagram", "Instagram", 15),
        ("put a ceiling of 20 on tiktok", "TikTok", 20),
        // The requestModals exemption for a polite second-person setter.
        ("could you cap reddit at 30 for me", "Reddit", 30),
        // The single negator carve-out: "no" belongs to the quantifier.
        ("no more than 20 of tiktok a day", "TikTok", 20),
        // The period word lifts the bare-quantifier hedge veto.
        ("give me 60 a day max on tiktok", "TikTok", 60),
    ])
    func theCanonicalSettersStillLand(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// FINDINGS 1-2, promoted. The `intervenes` scan read the door's own noun
    /// phrase as a predicate boundary — the determiner INSIDE the matched
    /// two-token alias ("cap THE GRAM at 20") and the possessive standing
    /// directly on the door ("cap MY tiktok at 20") — so the shape died and
    /// the ladder answered a restriction with a grant and the wall down. The
    /// door's matched tokens and a determiner immediately on the door's name
    /// are the setter's own object now; every other determiner keeps its
    /// boundary reading, so the ask-verb commentary class ("ive hit my limit
    /// give me 20 of tiktok" / "im at my limit on tiktok, give me 20 minutes",
    /// pinned in ProseHijackTests) still grants.
    @Test(arguments: [
        ("cap the gram at 20", "Instagram", 20),
        ("limit the gram to 20", "Instagram", 20),
        ("cap the gram at 20, insta is fine now", "Instagram", 20),
        ("cap my tiktok at 20", "TikTok", 20),
    ])
    func theDoorsOwnPhraseIsNotABoundary(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }
}

// MARK: - Lens 4: numbers, units, aliases, and arithmetic

@Suite struct CapsAdversarialProbeNumbers {

    /// Units that are not the domain unit decline — seconds (sixty times
    /// tight), hours (a loosening said as a tighten), glued and abbreviated
    /// spellings, and intensifiers the guard must see through.
    @Test(arguments: [
        "cap tiktok at 90 seconds",
        "cap tiktok at 30 secs",
        "cap tiktok at 90 whole seconds",
        "90 second limit on tiktok",
        "cap tiktok at 2 hours",
        "cap tiktok at 2 h",
        "cap tiktok at 2 whole hours",
        // Glued units are deliberately read by NEITHER side.
        "cap tiktok at 2h",
        "cap tiktok at 1 hour",
    ])
    func aNonMinuteUnitDeclines(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" wrote a ceiling")
    }

    /// The idiom table's quantities occupy no token, bypassing the per-token
    /// hours guard by design — the deliberate asymmetry with "1 hour" above.
    /// Compounds must not double-count their component words.
    @Test func theIdiomQuantitiesStillLand() {
        #expect(setsCap("cap tiktok at an hour")?.1 == 60)
        #expect(setsCap("cap tiktok at half an hour")?.1 == 30)
        #expect(setsCap("cap tiktok at an hour and a half")?.1 == 90)
    }

    /// And PolarityEngine still protects the direction the hours decline
    /// exists for: the idiom's 60 against a tighter cap parks as a loosening.
    @Test func anIdiomRaiseParksAsALoosening() {
        guard case .ruleChange(_, let polarity) = verdict("cap tiktok at an hour", capped) else {
            Issue.record("the idiom setter stopped reaching the Validator")
            return
        }
        #expect(polarity == .loosen)
    }

    /// Decimals, ranges, hundred-poisoning, from-to and subtractive deltas:
    /// two numbers (or a poisoned phrase) state no ceiling this grammar can
    /// write, and every one must TERMINATE — a decline is a grant.
    @Test(arguments: [
        "cap tiktok at 1.5 hours",
        "cap tiktok at 20-30 minutes",
        "cap tiktok at 20.5",
        "cap tiktok at one hundred minutes",
        "drop the tiktok limit from 30 to 20",
        // Subtractive lowering: the amount lives OUTSIDE the clearing phrase.
        "take 20 off the tiktok cap",
        // An unlisted leading verb must not change the subtractive answer.
        "trim 10 off the tiktok cap",
        // FINDINGS 13-14, promoted: the ADDITIVE deltas. "by" aims a relative
        // amount, and the delta was landing as an absolute ceiling — an
        // instant tighten to 10 out of a request to LOOSEN, and a 5 where the
        // sentence meant 15. The arithmetic doctrine's terminating refusal
        // now covers the "by" spellings on both directions.
        "raise the tiktok cap by 10",
        "lower the tiktok cap by 5",
        // The remover-led delta rides the same doctrine through the tail
        // guard's FINDING-4 termination.
        "drop the tiktok limit by 10",
    ])
    func anUnwritableQuantityTerminates(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" kept walking")
    }

    /// Spelled compounding works inside the shape, and clause-scoped numbers
    /// hold at the comma in the tokenizer whose word compounding crosses it.
    @Test func spelledNumbersCompoundInsideOneClauseOnly() {
        #expect(setsCap("cap tiktok at twenty five")?.1 == 25)
        // Never 25, and never any write on instagram from this clause.
        #expect(setsCap("cap tiktok at twenty, five minutes for instagram")
                .map { $0 == ("TikTok", 20) } == true)
    }

    /// The one seam where clause-scoped capSet and utterance-wide Validator
    /// provenance disagree BY CONSTRUCTION: word compounding crosses the
    /// comma, so allNumbers reads 25 where the clause read 20 — and the
    /// disagreement must always fail closed at the verdict.
    @Test func theCrossCommaCompoundFailsClosedAtTheValidator() {
        #expect(verdict("cap tiktok at twenty, five a day") == .silence)
        // And the idiom's token-less 30 must PASS the same provenance.
        guard case .ruleChange = verdict("cap tiktok at half an hour") else {
            Issue.record("the idiom's provenance stopped passing P3")
            return
        }
    }

    /// Zero is a permanent close with no costume: the parser may emit it, but
    /// the Validator's .setDoorCap arm refuses at the one point every parser
    /// passes — for every shape.
    @Test func aZeroCeilingIsRefusedAtTheSpine() {
        #expect(verdict("cap tiktok at 0") == .silence)
        #expect(verdict("0 minute limit on tiktok") == .silence)
    }

    /// The hyphen-is-space contract drops the sign: minus-five compiles as a
    /// five-minute tighten, never a trap, never a grant, never a zero or
    /// negative write. Pinned as the conscious reading of the contract.
    @Test func aNegativeNumberStaysATightenUnderTheHyphenContract() {
        #expect(setsCap("cap tiktok at -5")?.1 == 5)
    }

    /// Magnitude edges: the saturating multiply declines enormous hours
    /// without trapping, and an honest above-budget cap is stored as said —
    /// the clamp lives at the spend arm, not in the stored policy.
    @Test func magnitudeEdgesNeitherTrapNorClamp() {
        #expect(parse("cap tiktok at 999999999999999999 hours") == .silence)
        #expect(setsCap("cap tiktok at 99999999 minutes")?.1 == 99999999)
        #expect(setsCap("cap tiktok at 500")?.1 == 500)
    }

    /// Deadlines, clocks, and schedules are not durations: a cap sentence
    /// naming an hour of the day (or a window word) defers whole.
    @Test(arguments: [
        "cap tiktok till 7",
        "cap tiktok at 10 pm",
        "cap youtube at 10 tonight",
        "cap tiktok at bedtime",
    ])
    func aClockIsNeverACeiling(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" wrote a ceiling from a clock")
    }

    /// LaunchCatalog shorthand on the cap path: "yt" survives, and the three
    /// ordinary-English names ("ig", "gram") deliberately do not resolve
    /// absent a user-authored alias.
    @Test func theCatalogAliasGateHoldsOnTheCapPath() {
        let bare = PolicyState(budgetMinutes: 40,
                               downHours: DownHours(start: TimeOfDay(hour: 22),
                                                    end: TimeOfDay(hour: 7)),
                               doors: [Door(name: "Instagram"), Door(name: "TikTok"),
                                       Door(name: "YouTube"), Door(name: "Reddit")],
                               doorCaps: [:])
        #expect(parse("cap ig at 20", bare) == .silence)
        #expect(parse("put a 20 minute limit on the gram", bare) == .silence)
        #expect(setsCap("cap yt at 15", bare)?.0 == "YouTube")
    }

    /// The GrantLedger interplay: a spend against a capped door grants at
    /// most doorRemaining — the ceiling never loses to the pool. Asserted at
    /// the verdict, per the hermeticity law.
    @Test func aSpendClampsToTheDoorsOwnCeiling() {
        let state = makeState(budget: 60, caps: [tiktok.id: 20])
        guard case .grant(let door, let minutes, _)
            = verdict("give me 30 of tiktok", state) else {
            Issue.record("the clamped spend stopped granting")
            return
        }
        #expect(door.name == "TikTok")
        #expect(minutes == 20, "the debit exceeded doorRemaining")
    }
}

// MARK: - FINDINGS
//
// The round's fourteen genuinely-failing probes — verified on main tip
// 47993b4 and adjudicated against docs/design/per-app-caps.md and the rule
// comments — are all FIXED and PROMOTED into the armor above, each marked
// "FINDING n, promoted" beside the rule seam it pins. One adjudication moved
// during the fix pass: FINDING 7's draft expected the removal to land, and
// rule 5's own contract (the "hey," flavor pinned in StressTests) says a
// preambled removal is not claimed either, so the promoted probe pins the
// terminating silence instead — recorded on the probe itself.

// MARK: - Round 2: the fourteen fixes under fire
//
// A second adversarial round, aimed at the fix pass itself. Every probe below
// stacks, starves, or minimally mutates a seam the fourteen-defect fix just
// touched: the loosened `intervenes` door-phrase skip (FINDINGS 1-2), the
// dative arm (3), the clearing-family tail guard (4), the politeAsk
// termination (5), the stranded quantifier (6), the opener step-over (7), the
// bare-door topic (8), the slang-emphatic gate (9), the declined question
// (10), the pool-claim veto (11), the negated-number adjacency (12), and the
// "by" deltas (13-14). Every attacker expectation was adjudicated against the
// rule contracts before pinning; ten moved to the parser's side — the
// pool-claim and remover-claim silences are the recall seam their own doc
// comments disclose, "my budget is 40 already" is the pool's pinned
// subject-is-the-rule setter class, "im done" is a closer phrase under the
// pinned close-hoist, and the bare-door-topic veto is unconditional on the
// number clause's tail by promoted doctrine — each recorded on its probe. The
// four seams the grammar genuinely got wrong (six sentences) are commented
// out as FINDING(n1)-(n4) blocks beside the rules they break; see ROUND 2
// FINDINGS at the bottom.

@Suite struct CapsAdversarialRound2Setters {

    /// The widened `intervenes` skip, exercised one cell past each pinned row:
    /// the possessive under a different verb, the possessive on a one-token
    /// alias (doorEnd's other branch), the bare determiner on a plain door
    /// name, the two-token alias with a polite dative tail, and the alias
    /// setter opened mid-sentence by a habit report.
    @Test(arguments: [
        ("limit my tiktok to 25", "TikTok", 25),
        ("cap my insta at 30", "Instagram", 30),
        ("cap the tiktok at 20", "TikTok", 20),
        // "for me" trails as a beneficiary, not a recipient the dative arm
        // silences — the arm keys on the DOOR standing after the ask verb.
        ("cap the gram at 20 for me", "Instagram", 20),
        ("ive been doomscrolling so cap the gram at 25", "Instagram", 25),
    ])
    func theWidenedDoorPhraseFloorHolds(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// Negators and "by" OUTSIDE the proposal are not evidence about it: the
    /// adjacency test reads t[numberAt-1] only, the refused-scan reads only
    /// ahead of the phrase, the "no more than" carve-out travels to every
    /// spelling, and the delta refusal stays clause-local.
    @Test(arguments: [
        // A negator AFTER the number belongs to the idiom, not the ceiling.
        ("cap tiktok at 20 no matter what", "TikTok", 20),
        // The carve-out inside the at-phrase: "than", not the negator, stands
        // on the number.
        ("cap tiktok at no more than 20", "TikTok", 20),
        // The carve-out through a two-token alias doorEnd.
        ("no more than 20 of the gram a day", "Instagram", 20),
        // "never" leads a sealed idiom clause: not an opener, not a remover,
        // no number — all three earlier-claim arms stand down.
        ("never mind youtube, cap tiktok at 20", "TikTok", 20),
        // "by" with no number after it, glued into the clause uncomma'd: the
        // delta refusal is adjacency-keyed, never a contains("by") scan.
        ("cap tiktok at 25 by the way", "TikTok", 25),
        // The reason clause's delta may not poison the first breath's setter.
        ("cap tiktok at 20, i went over by 10 yesterday", "TikTok", 20),
        // "not youtube" leads with a nounNegator but carries a door: the
        // declined-question allSatisfy must fail, and doors(in:) stays
        // clause-scoped.
        ("cap tiktok at 20, not youtube", "TikTok", 20),
        // "no rush" leads with a nounNegator and ends with a noun: the
        // FINDING-10 veto must see "rush" and stand down.
        ("can you cap tiktok at 20 minutes, no rush", "TikTok", 20),
    ])
    func aNegatorOrByOutsideTheProposalIsNotEvidence(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// The cap noun LEADING its number is shape one wherever the recipient
    /// stands: "give ME a ceiling" caps the door it names, and "give tiktok a
    /// ceiling OF 20" is claimed by shape one before the dative arm ever runs
    /// — a grant out of either is the inversion FINDING 3 closed.
    @Test func theCapNounLeadingItsNumberStaysASet() {
        #expect(setsCap("give me a 20 minute ceiling on tiktok").map { $0 == ("TikTok", 20) } == true)
        #expect(setsCap("give tiktok a ceiling of 20 minutes").map { $0 == ("TikTok", 20) } == true)
    }

    /// FINDING 12 under the alias: the negator standing directly on the
    /// number refuses through a two-token doorEnd too.
    @Test func aNegatedNumberStillRefusesThroughTheAlias() {
        #expect(parse("cap the gram at not 20 but 30") == .silence)
    }

    /// FINDING n2, promoted. "not even 20" governs its number through a
    /// transparent intensifier: "even" holds the numberAt-1 slot, so the
    /// adjacency test reads one token — one word, "even" — further back, and
    /// the 20 the sentence negates is never written. "no more than 20" keeps
    /// its carve-out one probe up, with "than" on the number as before.
    @Test func aNegatorGovernsThroughATransparentIntensifier() {
        #expect(parse("cap tiktok at not even 20") == .silence)
    }

    /// FINDINGS 13-14, generalized: "by" aims a delta whatever verb leads —
    /// spelled numbers anchor the same adjacency, unlisted verbs ride the
    /// same preposition ("bump ... TO 20" is a pinned set, so the verb stem
    /// is live and the preposition alone carries the distinction), and the
    /// delta composes with the declined question, the FINDING-4 tail guard,
    /// and the pool-claim veto to silence, never to arithmetic.
    @Test(arguments: [
        "raise the tiktok cap by ten",
        "bump the tiktok cap up by 15",
        "should i lower the tiktok cap by 5? no",
        "drop the tiktok limit by 10 because 20 was too strict",
        // The trailing clause is a delta, not a clearing, so the pool-claim
        // veto's loosening-only scope never engages: capSet's terminating
        // by-refusal silences the sentence before rule 3 — the dropped budget
        // move is the disclosed one-command cost, and above all never
        // cap[tiktok]=5.
        "set my budget to 40, lower the tiktok cap by 5",
    ])
    func aByDeltaTerminatesWhateverVerbLeads(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" kept walking")
    }
}

@Suite struct CapsAdversarialRound2Politeness {

    /// FINDING 5's termination across punctuation, modal, alias, and hedge
    /// mutations: a polite numberless cap question beside a number in another
    /// breath terminates — the number is a habit report, a fragment with a
    /// particle, a comma'd orphan, or a hedged offer, and none of them may
    /// fund the decline.
    @Test(arguments: [
        "can you cap tiktok? i already used 20 today",
        "would you cap the gram? 15 tops",
        "can you cap tiktok, 20 minutes",
    ])
    func aPoliteQuestionBesideAStrandedNumberTerminates(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" kept walking")
    }

    /// The termination's two exemptions keep walking: the wh-guard keeps the
    /// rhetorical question OUT of the politeAsk arm so the decline still
    /// reaches the grant ("give me 20" borrows the question's door), and the
    /// numberless polite ask is rule 8's own sentence on every verb spelling.
    @Test func theWhGuardAndTheNumberlessAskKeepWalking() {
        let a = spend("why would you cap tiktok? give me 20")
        #expect(a?.0 == "TikTok" && a?.1 == 20)
        #expect(parse("can i get a limit on insta")
                == .command(.placeBoundAsk(door: instagram)))
        // The ask-verb exemption on the stranded-quantifier arm is not
        // verb-spelling-keyed: "let me have" walks to "How long?" exactly as
        // "give me tiktok max" does.
        #expect(parse("let me have insta max")
                == .command(.placeBoundAsk(door: instagram)))
    }

    /// FINDING 3's dative silence under attribution, modals, and both alias
    /// widths: the recipient is the DOOR, so the sentence terminates — never
    /// a grant, and no polite wrapper re-admits it anywhere.
    @Test(arguments: [
        "coach said give tiktok a 30 minute ceiling",
        "give the gram a 20 minute ceiling",
        "can you give tiktok a 20 minute ceiling",
    ])
    func theDativeSetterTerminatesUnderQuotesAndModals(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" moved policy or granted")
    }

    /// FINDING n4, promoted. One adjective may not resurrect the FINDING-3
    /// grant: "hard" is not noun-phrase vocabulary, so the dative arm's old
    /// whitelist broke on it, the arm declined, and the decline walked into
    /// rule 7's give-door-number hot path — a request to RESTRICT the app
    /// funding twenty minutes of it, the worst direction this grammar has.
    /// The arm now asks the closed-class boundary question instead: with the
    /// ask verb's recipient a door and a cap noun in its wake, an unknown
    /// adjective terminates, and only a real second predicate (a subject or
    /// a fresh ask verb) keeps the decline.
    @Test func oneAdjectiveMayNotResurrectTheDativeGrant() {
        #expect(parse("give tiktok a hard 20 minute cap") == .silence)
        #expect(spend("give tiktok a hard 20 minute cap") == nil)
    }

    /// And the doorless dative frame with no cap noun anywhere IS the hot
    /// path — if the dative arm ever loosens from capNouns to the frame
    /// shape, every third-person grant goes silent.
    @Test func theHotPathKeepsTheDoorlessDativeFrame() {
        let a = spend("give youtube 25 minutes")
        #expect(a?.0 == "YouTube" && a?.1 == 25)
    }

    /// FINDING 10 on the canonical polite setter: the same requestModals
    /// exemption that admits the question hands it to the bare-negator
    /// termination.
    @Test func aDeclinedQuestionStaysDeclined() {
        #expect(parse("could you cap reddit at 30? no") == .silence)
    }

    /// FINDING n3, promoted. The decline's own vocabulary counts: "nah" and
    /// "nah nvm" are the spoken spellings of the answering "no", read by the
    /// declined-question veto (`spokenDeclines`) and by nothing else — a
    /// self-declined question stays declined one synonym over from the fixed
    /// sentence, and the words can only ever subtract a written ceiling.
    @Test func theSpokenDeclineStaysDeclined() {
        #expect(parse("should i cap tiktok at 20? nah") == .silence)
        #expect(parse("should i cap tiktok at 20? nah nvm") == .silence)
    }

    /// The report gates over the widened possessive skip: a third-party or
    /// past-tense sentence whose determiner stands directly on the door is
    /// still a report, and the copula restatement keeps its boundary reading
    /// — the contrast rows proving the skip did not eat the mood gates.
    @Test(arguments: [
        "my dad capped my tiktok at 20 growing up",
        "the tutorial says cap your tiktok at 20",
        "the tiktok cap my mom set is 20",
    ])
    func aReportThroughTheSkippedDeterminerIsStillAReport(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" compiled to policy")
    }

    /// FINDING n1, promoted. The request-modal exemption guards its subject:
    /// "can you believe they capped tiktok at 20" wraps a THIRD PARTY's act
    /// in a rhetorical modal, and "my mom would cap the tiktok at 20 if she
    /// could" fronts its modal with a person who is not the rule — a
    /// third-party pronoun ahead of the phrase, or one unrecognised word
    /// before the modal, withholds the exemption and hands both back to the
    /// report gates. README rule 1's principle holds against one polite
    /// auxiliary: a report is not an instruction.
    @Test func aThirdPartyModalReportWritesNoPolicy() {
        #expect(parse("can you believe they capped tiktok at 20") == .silence)
        #expect(parse("my mom would cap the tiktok at 20 if she could") == .silence)
    }
}

@Suite struct CapsAdversarialRound2FirstBreath {

    /// FINDING 11 generalized: the leading pool command wins over a trailing
    /// loosening on every remover flavor and alias width — and over pure
    /// slang chatter, where the emphatic gate and the veto independently
    /// forbid the clearing.
    @Test func theLeadingPoolCommandStillWins() {
        #expect(parse("set my budget to 45, uncap the gram", capped)
                == .command(.setBudget(minutes: 45)))
        #expect(parse("set my budget to 40, fr no cap tho tiktok", capped)
                == .command(.setBudget(minutes: 40)))
        // ADJUDICATED AGAINST THE ATTACKER, who expected the clearing: "my
        // budget is 40 already" is the pool's own sentence, not a report —
        // `namesThePool` lists the finite-verb continuation ("my budget is
        // 30") as the pool speaking, and the mood gate's subject-is-the-rule
        // carve-out pins "40 a day is what i already have" as a setter. A
        // first breath that states the rule claims the sentence, and the
        // trailing loosening drops — FINDING 11's own doctrine.
        #expect(parse("my budget is 40 already, no cap on tiktok", capped)
                == .command(.setBudget(minutes: 40)))
    }

    /// The veto scans EARLIER clauses only, and needs BOTH prongs: a leading
    /// clearing beats a trailing pool command, and a numberless budget
    /// mention claims nothing.
    @Test func theVetoScansBackwardOnlyAndNeedsBothProngs() {
        #expect(clearsCap("no cap on tiktok, set my budget to 30") == "TikTok")
        #expect(clearsCap("budget stuff can wait, uncap tiktok") == "TikTok")
    }

    /// The pool-claim veto's recall seam, pinned as the seam it is: the
    /// intent test is bare number-presence beside a budget-stem token —
    /// disclosed on the rule as mirroring the door arm's pinned seam — so
    /// numbered budget CHATTER (an adjective, a gerund) parks a trailing
    /// clearing into silence. Direction-safe both ways: a parked loosening,
    /// and above all the chatter's number never cuts the pool.
    @Test(arguments: [
        "my budget phone died at 20 percent, no cap on tiktok",
        "im budgeting 40 bucks for gifts, uncap tiktok",
    ])
    func numberedBudgetChatterParksTheClearing(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" moved policy")
        #expect(budgetOf(utterance) == nil, "\"\(utterance)\" cut the pool")
    }

    /// The remover-claim arm reads one lead token past the opener skip, by
    /// design — "an intent is the REMOVER that OPENS THAT CLAUSE" — so a
    /// hypothetical ("though remove instagram sounds harsh") and venting
    /// ("drop the tiktok drama") claim their breath and park the trailing
    /// clearing. The same silence FINDING 7 pinned for the sincere spelling:
    /// preambled removals are not claimed either, and silence reaches the
    /// widener, which can produce neither a cap nor a deletion (§5.7).
    /// Direction-safe; pinned as the recall seam it is.
    @Test(arguments: [
        "though remove instagram sounds harsh, no cap on tiktok",
        "so drop the tiktok drama, no cap on instagram",
    ])
    func aRemoverLedFirstBreathParksTheTrailingClearing(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" moved policy")
    }

    /// And the step-over is exactly one token wide: "so what if i remove
    /// instagram" lands the claim test on "what", which removes nothing, so
    /// the rhetorical question claims no breath and the clearing lands.
    @Test func theOpenerSkipStaysOneTokenWide() {
        #expect(clearsCap("so what if i remove instagram, no cap on tiktok") == "TikTok")
    }
}

@Suite struct CapsAdversarialRound2ClearingsAndTopics {

    /// Sincere clearings survive their tails: the comma'd reason, the
    /// temporal "for today", the polite opener deliberately absent from
    /// slangEmphatics, the comma-sealed emphatic, the whitelisted slang tail,
    /// and the lone discourse opener.
    @Test(arguments: [
        "uncap tiktok, 20 wasnt enough",
        "take the cap off tiktok for today",
        // "pls" is politeness, not slang: the FINDING 9 split must not
        // collapse back to the whole particle list.
        "pls no cap on tiktok",
        // "tbh" IS a slangEmphatic, but the comma seals it in its own clause
        // and the gate scans clause-locally.
        "tbh, no cap on tiktok",
        // "rn" holds its whitelist TAIL seat; only ahead-of-negator is slang
        // evidence.
        "no cap on tiktok rn",
        "anyway, uncap tiktok",
    ])
    func aSincereClearingSurvivesItsTail(_ utterance: String) {
        #expect(clearsCap(utterance) == "TikTok", "\"\(utterance)\" no longer clears")
    }

    /// FINDING 4 and FINDING 9 hold one mutation out: the doorful-reason
    /// termination is not remover- or number-keyed (equal to the standing cap
    /// included), and slang ahead of the negator refuses the clearing even
    /// when the door trails as a two-token-alias afterthought. Above all,
    /// none of these may grant.
    @Test(arguments: [
        "lift the insta cap because 15 was brutal",
        "ngl no cap tho the gram",
        // ADJUDICATED: the attacker's primary reading was the Gen-Z grant
        // ("seriously, give me 20 of tiktok") and its own note blessed the
        // tight side. The "no" refuses the ask (aNegatorRefusesTheAsk), the
        // after-span veto refuses the clearing, and the terminating silence
        // is the doctrine's answer to a sentence wearing both readings —
        // never a clearing, never a grant.
        "no cap i need 20 of tiktok rn",
    ])
    func aClearingReasonOrSlangNeverGrantsOrClears(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" moved policy or granted")
    }

    /// The doorless commentary clearing in reversed clause order: its nil
    /// still walks to the grant in breath two, with the first-breath
    /// machinery running ahead of it.
    @Test func theCommentaryClearingStillYieldsToTheGrant() {
        let a = spend("no cap needed, give me 20 of tiktok")
        #expect(a?.0 == "TikTok" && a?.1 == 20)
    }

    /// ADJUDICATED AGAINST THE ATTACKER, who expected the clearing: "im done"
    /// is a closer phrase, `hasClosingVerb` is utterance-wide, and the
    /// close-hoist asymmetry is pinned above as disclosed — a close is the
    /// never-wrong direction. The slang reading agrees: "no cap ... im done
    /// doomscrolling" is a resolution to stop, and the door closes for the
    /// day. Above all: no grant, and no clearing out of an ambiguous breath.
    @Test func theDoneDoomscrollingCloseHoistHolds() {
        guard case .command(.closeDoorToday(let d, let until))
            = parse("no cap on tiktok today, im done doomscrolling", capped) else {
            Issue.record("the close-hoist asymmetry moved — re-adjudicate the sentence")
            return
        }
        #expect(d.name == "TikTok")
        #expect(until == nil)
    }

    /// FINDING 8 across punctuation and alias: a breath that is nothing but
    /// a door's name strands the topic, and the pool does not move on it —
    /// dash, comma, and period alike.
    @Test(arguments: [
        "the gram - 20 a day",
        "insta, 25 a day",
        // ADJUDICATED AGAINST THE ATTACKER, who wanted setBudget(45) on the
        // strength of "for everything": the promoted doctrine is
        // unconditional on the number clause's tail — a bare door name in
        // the breath before the number makes the number that door's
        // sentence, and the parked raise is the direction-safe cost.
        "tiktok. 45 a day for everything",
    ])
    func aBareDoorTopicNeverMovesThePool(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" compiled")
        #expect(budgetOf(utterance) == nil, "\"\(utterance)\" cut the pool")
    }

    /// The veto's own scoping clause, proven from the other side: a door
    /// WITH a predicate is commentary, and the pool command lands.
    @Test func aDoorWithAPredicateReleasesThePoolMove() {
        #expect(budgetOf("tiktok is brutal. 45 a day for everything") == 45)
    }

    /// FINDING 6 keyed to the boundary, not the dictation word or the door:
    /// the clause-opener and the "like" filler strand the quantifier exactly
    /// as "say" did, through a two-token doorEnd too, and the doorless
    /// number never funds a grant on the app being restricted.
    @Test(arguments: [
        "so keep tiktok under, say, 20",
        "keep the gram under, like, 15",
    ])
    func aStrandedQuantifierTerminatesOnEverySpelling(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" kept walking")
    }
}

// MARK: - ROUND 2 FINDINGS
//
// Sixty-two probes pinned green; four seams genuinely failed (six sentences),
// each left as a commented FINDING block beside the rule it broke. All four
// were fixed in the ROUND 3 pass and their probes promoted live beside their
// seams ("FINDING nX, promoted"); the list below stands as the record of what
// the round found:
//
//  n1  reportsRatherThanSets' requestModals exemption has no subject guard —
//      "can you believe they capped tiktok at 20" and "my mom would cap the
//      tiktok at 20 if she could" write standing policy from a rhetorical
//      report and an attributed hypothetical. (medium)
//  n2  the negated-number adjacency test is blind through one intensifier —
//      "cap tiktok at not even 20" writes the 20 the sentence negates. (low)
//  n3  the declined-question veto's nounNegators inventory lacks the
//      vernacular declines — "should i cap tiktok at 20? nah" (and "nah
//      nvm") writes the ceiling the asker talked themselves out of. (medium)
//  n4  the dative arm's spansOneNounPhrase breaks on one adjective and the
//      decline walks into rule 7 — "give tiktok a hard 20 minute cap" GRANTS
//      twenty minutes of the app being restricted. (high — the FINDING 3
//      inversion, resurrected)
//
// Ten attacker expectations were overturned against the rule contracts and
// pinned at the adjudicated outcome instead — the pool-claim and
// remover-claim recall seams (disclosed on their rules), the pool's
// subject-is-the-rule copula setter, the "im done" close-hoist, and the
// unconditional bare-door-topic veto — each recorded on its probe.

// MARK: - Round 3: the fix pass's four narrowings under fire
//
// A third adversarial round, aimed at the ROUND 3 fixes themselves: two
// attackers — one hijacking (chatter, reports, quotes and hypotheticals aimed
// at the subject-guarded requestModals exemption's two arms, the dative arm's
// closed-class boundary scan, the spokenDeclines inventory and the
// one-intensifier negator reach, composed with every earlier fix), one
// starving (the same four narrowings positioned to eat sincere first-person
// commands). Every expectation was adjudicated against the rule contracts
// before pinning; eleven moved to the parser's side — the modal-slot
// whitelist is a CLOSED class and refuses greetings, connectives and adverbs
// by its own doc (FINDING 7's adjudication already pinned that a preambled
// command is not claimed), the thirdPartySubjects scan is anywhere-ahead on
// purpose (attribution beats the reported committal), "they were right i
// should…" carries the mood gate's own finite verb, the pool's
// subject-is-the-rule doctrine keeps "my budget would be 40" a budget move,
// and the polite clearing's starvation is the clearing gate's disclosed
// no-exemption trade — each recorded on its probe. Seven seams genuinely
// failed (eight sentences), commented out as FINDING(n5)-(n11) blocks beside
// the rules they break; see ROUND 3 FINDINGS at the bottom.

@Suite struct CapsAdversarialRound3SubjectGuard {

    /// The n1 exemption's two arms hold against person, mood and position
    /// mutations: a non-whitelisted word standing on the modal is an
    /// attribution (arm 2), and a third-party pronoun anywhere ahead of the
    /// phrase — before the modal or riding the inversion after it — hands the
    /// clause back to the report gates (arm 1). Compositions with the
    /// FINDINGS 1-2 determiner skip, the refused-negator termination and the
    /// modal-less report gates ride along.
    @Test(arguments: [
        // Arm 2 alone: "everyone" is a subject but not modal-slot vocabulary,
        // and the post-phrase "they" stands beyond the ahead-scan by design —
        // one word over from the pinned "my mom would cap the tiktok at 20 if
        // she could".
        "everyone would cap tiktok at 20 if they could",
        // Arm 2 in isolation — no third-party pronoun, no if-clause: "dad" in
        // the slot is an attribution whatever noun holds it, so the guard is
        // the adjacency doctrine and not a pin of the fixed sentence's tail.
        "my dad would cap the tiktok at 20",
        // "it" (the software as agent) is a subject, deliberately not
        // modal-slot vocabulary: a wish about what the app should do to the
        // speaker is not the speaker's own request.
        "it should cap tiktok at 20 automatically",
        // A fronted modal satisfies arm 2 by clause-start alone; the
        // third-party scan owns the whole modal-to-phrase span.
        "would they ever cap tiktok at 20",
        // Third party composed with a negator: the refused-scan terminates
        // before the mood gates are ever consulted, and nothing walks on.
        "he would never cap tiktok at 20 himself",
        // The n1 sentence through "she" and the two-token alias: the guard
        // fires across the determiner-bearing doorEnd the FINDINGS 1-2 skip
        // widened.
        "can you believe she capped the gram at 15",
        // The contraction row with no modal anywhere: the plain report gates
        // still own the modal-less path after the exemption rework.
        "theyve capped tiktok at 20 everywhere now",
    ])
    func aThirdPartyOrAttributedModalWritesNothing(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" compiled to policy")
    }

    /// The reporter line, pinned as a minimal pair with the floor below. A
    /// PRONOUN reporter anywhere ahead withholds the exemption even with "i"
    /// standing on the modal — the anywhere-ahead scan is the rule's own
    /// disclosed design, and an attributed instruction ("my mom said cap
    /// tiktok at 20", pinned silence) beats the reported-committal shape.
    /// ADJUDICATED AGAINST THE STARVATION ATTACKER, who expected the
    /// committal to survive a pronoun reporter: the failure direction is the
    /// family's own (a starved setter terminates and reaches the widener),
    /// and the noun-reporter row below keeps the shape the adjacency design
    /// was chosen to preserve.
    @Test(arguments: [
        "she said i should cap tiktok at 20",
        "she says i should cap tiktok at 20",
        "they told me i should cap tiktok at 20",
        // ADJUDICATED: the finite "were" is the mood gate's own core test —
        // doctrine older than round 3, not the new guard — and the comma-less
        // concession is one clause wearing a report frame.
        "they were right i should cap tiktok at 20",
    ])
    func aPronounReporterStarvesTheCommittalIntoSilence(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" wrote policy")
    }

    /// And the floors the guard must never eat: the NOUN reporter with "i" on
    /// the modal (the reported first-person committal, exactly like the
    /// pinned "everyone says i should cap tiktok at 20"), the
    /// subject-is-the-rule sibling of the doc's own "my tiktok limit SHOULD
    /// be 20 a day", and the fronted polite request whose "for me" is a
    /// beneficiary, never rule 7's recipient.
    @Test(arguments: [
        ("my mom says i should cap tiktok at 20", "TikTok", 20),
        ("the tiktok cap should be 15 a day", "TikTok", 15),
        ("can you cap tiktok at 20 for me", "TikTok", 20),
    ])
    func theCommittalAndRuleSubjectFloorsStillLand(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// ADJUDICATED AGAINST THE STARVATION ATTACKER on all six: the modal-slot
    /// whitelist is a CLOSED class and refuses what it does not know — the n1
    /// fix's own doc ("an unrecognised word in that slot makes the clause an
    /// attribution, which REFUSES the exemption"), with the family's own
    /// failure direction: the starved setter terminates in silence, which
    /// reaches the widener, and §5.7 keeps it from ever becoming a cap or a
    /// grant. The greeting flavor has precedent — FINDING 7's adjudication
    /// pinned that a preambled command is not claimed — and "we" sits outside
    /// the closed person list ("i"/"you" are the speaker and the addressee).
    /// Pinned as the disclosed recall seam it is: a future widening of the
    /// slot must bring its own adversarial round.
    @Test(arguments: [
        "hey can you cap tiktok at 20",
        "also can you cap youtube at 30",
        "sorry can you cap insta at 15",
        "i really should cap tiktok at 20",
        "i honestly should just cap insta at 15",
        "we should cap tiktok at 20",
    ])
    func anOccupiedModalSlotParksTheRequestAsTheDisclosedSeam(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" moved policy")
    }

    /// FINDING n11, promoted. The polite clearing declines by disclosed
    /// design (`reportsRatherThanAsks` reads a fronted request modal as a
    /// plain auxiliary; no exemption on the clearing side, per its own
    /// comment) — and then shape one read the clearing's quoted premodifier
    /// as a proposal: "cap" led "tiktok" with the 20 ahead, the fronted
    /// modal bought the requestModals exemption, and the sentence WROTE the
    /// very ceiling it asked to remove. A capRemover standing between the
    /// cap noun and the door now terminates shape one — the "off" says the
    /// ceiling is being moved OFF the door, not aimed at it — and the bare
    /// spelling ("take the 20 minute cap off tiktok") keeps its clearing,
    /// pinned twice in StressTests, because `capCleared` claims it before
    /// shape one ever runs. ADJUDICATED: the attacker expected the clearing
    /// to land; the clearing-side starvation is the design's own trade, so
    /// the pinned outcome is the terminating silence — the WRITE was the
    /// defect.
    @Test func aPoliteClearingIsNeverClaimedAsASet() {
        #expect(parse("can you take the 20 minute cap off tiktok", capped) == .silence)
        #expect(setsCap("can you take the 20 minute cap off tiktok") == nil)
    }
}

@Suite struct CapsAdversarialRound3SetterShapes {

    /// The n4 termination is the closed-class boundary question, not an
    /// adjective list: ANY unknown adjective between the recipient door and
    /// its trailing cap noun terminates — either cap noun, either alias
    /// width, under the polite wrapper, and with the number stranded one
    /// clause over (the arm is not number-keyed, and the orphan "20 minutes"
    /// must not fund the decline — FINDING 5 doctrine riding along). Above
    /// all: never a grant.
    @Test(arguments: [
        "give tiktok a strict 30 minute limit",
        "give the gram a hard 15 minute cap",
        "can you give tiktok a hard 20 minute cap",
        "give tiktok a hard cap, 20 minutes",
    ])
    func theDativeTerminationHoldsAcrossAdjectivesAliasesAndWrappers(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" kept walking")
        #expect(spend(utterance) == nil, "\"\(utterance)\" granted")
    }

    /// The adjectived sincere imperatives are the floor the termination must
    /// not eat: the adjective stands BEFORE the number, shape one's
    /// `intervenes` scan never sees it, and the cap noun leads its door.
    @Test(arguments: [
        ("set a strict 15 minute cap on insta", "Instagram", 15),
        ("put a hard 30 minute cap on youtube", "YouTube", 30),
    ])
    func anAdjectivedImperativeStillSets(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = setsCap(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// FINDING n5, promoted. The dative arm's boundary scan read the
    /// demonstrative "that" as a second-predicate boundary: `subjects` holds
    /// it for the report gates, but between recipient-door and cap noun it
    /// is a DETERMINER opening the ceiling's own phrase, exactly as "a" is —
    /// the termination was withheld, the decline walked into rule 7's
    /// give-door-number hot path, and a request to RESTRICT the app funded
    /// twenty minutes of it: the FINDING 3 inversion, resurrected through
    /// the third demonstrative. A subject that is also a determiner is now
    /// the ceiling's own phrase opener in this one scan; "i", "you" and "we"
    /// keep their boundary reading, so the real-second-predicate declines
    /// stand.
    @Test func aDemonstrativeMayNotResurrectTheDativeGrant() {
        #expect(parse("give tiktok that 20 minute cap we talked about") == .silence)
        #expect(spend("give tiktok that 20 minute cap we talked about") == nil)
    }

    /// FINDING n6, promoted. Shape one's `intervenes` scan read a determiner
    /// ahead of the NUMBER as a predicate boundary (the FINDINGS 1-2 skip
    /// pardons only a determiner standing immediately on the DOOR), the
    /// shape died, `capSet` returned nil rather than terminating, and the
    /// ladder answered a restriction with rule 7's grant — a clause carrying
    /// a cap lexeme aimed at a door ending in SPEND, the direction repo law
    /// forbids outright. A determiner within two tokens of the number now
    /// opens the number's own phrase — two and no more, so "the tiktok cap
    /// my mom set is 20" keeps its boundary — and both round-number idioms
    /// compile to the set they state. ("an" is no negator, so the n2 reach
    /// rightly stays out of "an even 20"; the determiner boundary was the
    /// whole defect.)
    @Test func aDeterminerOnTheNumberNeverKillsTheShapeIntoAGrant() {
        #expect(setsCap("cap tiktok at a strict 20").map { $0 == ("TikTok", 20) } == true)
        #expect(setsCap("cap tiktok at an even 20").map { $0 == ("TikTok", 20) } == true)
        #expect(spend("cap tiktok at a strict 20") == nil)
        #expect(spend("cap tiktok at an even 20") == nil)
    }

    /// FINDING n7, promoted. A trailing cap noun behind a NON-ask verb
    /// matched nothing: leadsTheNumber and leadsTheDoor both fail (the noun
    /// trails number and door alike), the dative arm keyed on `askVerbs` and
    /// "set" is not one, so no cap arm ran — and the clause, carrying a cap
    /// lexeme aimed at a door, walked to rule 7 and SPENT. The FINDING 3 /
    /// n4 proposal, one verb over. The recipient frame is no longer
    /// ask-verb-keyed: a clause-leading verb outside every closed class,
    /// with the door standing directly on it as its object and a cap noun in
    /// the wake, terminates — "the tiktok cap should be 15 a day" keeps its
    /// subject-is-the-rule set because "the" is a determiner, not a verb.
    @Test func aTrailingCapNounBehindANonAskVerbNeverGrants() {
        #expect(parse("set tiktok to a 20 minute cap") == .silence)
        #expect(spend("set tiktok to a 20 minute cap") == nil)
    }

    /// FINDING n8, promoted. "capping" was absent from `capNouns` and no
    /// deinflection reaches it, so the politest wrapper of all was not
    /// cap-shaped at all — and rule 7's mood gate read the fronted "would"
    /// as the ask's own request modal and GRANTED the app being restricted.
    /// The gerund is in the lexicon now: the polite inversion compiles to
    /// the set it wraps, and the pinned "im capping tiktok at 20" still dies
    /// on the subject-ahead scan — inside the cap family's own gates instead
    /// of one rule from the grant.
    @Test func thePoliteGerundNeverFundsTheAppBeingCapped() {
        #expect(setsCap("would you mind capping tiktok at 20").map { $0 == ("TikTok", 20) } == true)
        #expect(spend("would you mind capping tiktok at 20") == nil)
    }
}

@Suite struct CapsAdversarialRound3Declines {

    /// `spokenDeclines` is read by the declined-question veto and by nothing
    /// else: a trailing decline kills the question it follows, a LEADING one
    /// vetoes nothing (the answer clause must TRAIL the question), an
    /// affirmed question lifts the veto, and the words never grow a
    /// clearing-family meaning — the doc's promise that an entry can only
    /// ever subtract a written ceiling, proven from the clearing side.
    @Test func theSpokenDeclineReadsOnlyBackwardAndOnlySubtracts() {
        #expect(parse("should i uncap tiktok? nah", capped) == .silence)  // never a clearing
        #expect(setsCap("nah, cap tiktok at 20").map { $0 == ("TikTok", 20) } == true)
        #expect(setsCap("should i cap tiktok at 20? yes").map { $0 == ("TikTok", 20) } == true)
        // "nvm" heading a numberless clause that carries its own cap noun:
        // inert outside the veto's answer arm, and no first-breath rule
        // claims a doorless breath — the second clause's sincere set lands.
        #expect(setsCap("nvm the old limit, cap tiktok at 20").map { $0 == ("TikTok", 20) } == true)
    }

    /// n2's one-token reach travels with the spelled number: "twenty" anchors
    /// the same adjacency machinery the digits do, so "not even twenty"
    /// refuses the twenty it negates.
    @Test func theNegatorReachTravelsWithSpelledNumbers() {
        #expect(parse("cap tiktok at not even twenty") == .silence)
    }

    /// The by-delta refusal composes with the round-3 vocabulary: the raise
    /// direction through the spoken decline, and third-party volition
    /// wrapped around the lowering — never a set, never a clearing, never
    /// arithmetic on the standing 20.
    @Test(arguments: [
        "should i raise the tiktok cap by 10? nah",
        "he wants the tiktok cap lowered by 10",
    ])
    func aWrappedByDeltaStaysSilent(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" kept walking")
    }

    /// FINDING n9, promoted. The declined-question veto's answer clause was
    /// an allSatisfy over nounNegators + spokenDeclines, and one transparent
    /// discourse adverb broke it: "actually no" answers no, the veto lifted,
    /// and the self-declined question wrote the ceiling the asker refused —
    /// n3 one adverb over, the n2 "even" move one gate along. "actually" is
    /// transparent filler in the answer slot now, and the clause must still
    /// CONTAIN a decline — a bare trailing "actually" answers nothing — so
    /// an entry in the inventory can only ever subtract a written ceiling,
    /// the family's safe direction.
    @Test func aDiscourseAdverbDoesNotUndoTheDecline() {
        #expect(parse("should i cap tiktok at 20? actually no") == .silence)
        #expect(setsCap("should i cap tiktok at 20? actually").map { $0 == ("TikTok", 20) } == true)
    }
}

@Suite struct CapsAdversarialRound3FirstBreath {

    /// Two separately-fixed gates in one breath: the sealed doorless "no cap"
    /// is inert chatter (FINDING 9 family), and the trailing third-party
    /// modal clause dies on the n1 subject guard — if either half regresses,
    /// the sentence loosens or writes from pure gossip.
    @Test func chatterPlusThirdPartyModalMovesNothing() {
        #expect(parse("no cap, she would limit tiktok to 20", capped) == .silence)
    }

    /// ADJUDICATED AGAINST THE ATTACKER, who expected the whole sentence
    /// silent: "my budget would be 40" is the pool's subject-is-the-rule
    /// sentence — `namesThePool` lists the finite-verb continuation as the
    /// pool speaking, the modal slot holds the pool's own noun (the class
    /// the n1 adjacency arm exists to ADMIT), and round 2 already pinned "my
    /// budget is 40 already, no cap on tiktok" as the budget move. The
    /// conditional tail is beyond every rule by the clause-opener trade.
    /// What the probe actually guards, holds: the pool-claim veto parks the
    /// trailing clearing, and nothing loosens.
    @Test func aHypotheticalPoolClauseStillClaimsItsBreathAgainstTheClearing() {
        #expect(parse("my budget would be 40 if they let me, uncap tiktok", capped)
                == .command(.setBudget(minutes: 40)))
    }

    /// FINDING n10, promoted. `namesThePool`'s shortcut had no attribution
    /// gate: the quoted "set my budget to 40" continues the pool noun with a
    /// ceiling preposition and its number, so the SHORTCUT wrote the
    /// allowance the sentence only reports — where the fallback's own mood
    /// gate (`describesRatherThanSetsThePool`) would have refused on the
    /// spoken subject "they". A speech verb ahead of the pool's number in
    /// the number's own clause now silences the shortcut into the fallback's
    /// doctrine — A REPORT IS NOT AN INSTRUCTION, this file's oldest ("my
    /// mom said cap tiktok at 20" is pinned silence) — and a quoted
    /// allowance is a parked RAISE whenever the quoted number exceeds the
    /// standing pool. Both prongs now fail closed at once: the FINDING 11
    /// pool-claim veto still parks the trailing clearing, and the pool
    /// writes nothing.
    @Test func anAttributedPoolInstructionWritesNothing() {
        #expect(parse("they said set my budget to 40, no cap on tiktok", capped) == .silence)
        #expect(budgetOf("they said set my budget to 40, no cap on tiktok") == nil)
        #expect(clearsCap("they said set my budget to 40, no cap on tiktok") == nil)
    }
}

// MARK: - ROUND 3 FINDINGS
//
// Thirty-five probes pinned green; seven seams genuinely failed (eight
// sentences), each left as a commented FINDING block beside the rule it
// breaks. All seven were fixed in the ROUND 4 pass and their probes promoted
// live beside their seams ("FINDING nX, promoted") — the demonstrative and
// the leading non-ask verb close the dative frame, the determiner-on-the-
// number pardon and the remover-between termination repair shape one from
// both sides, "capping" joins the lexicon, "actually" turns transparent in
// the answer slot, and the pool's shortcut learns attribution. The list
// below stands as the record of what the round found:
//
//  n5  the dative arm's boundary scan reads the demonstrative "that" as a
//      second predicate — "give tiktok that 20 minute cap we talked about"
//      GRANTS twenty minutes of the app being restricted. (high — the
//      FINDING 3 inversion, resurrected a third time)
//  n6  shape one's `intervenes` scan reads a determiner ahead of the number
//      as a boundary — "cap tiktok at a strict 20" and "cap tiktok at an
//      even 20" both GRANT: the shape dies as nil instead of terminating and
//      rule 7 spends. (high)
//  n7  a trailing cap noun behind a non-ask verb matches no arm — "set
//      tiktok to a 20 minute cap" GRANTS through rule 7. (high)
//  n8  "capping" is outside the cap lexicon and rule 7's request-modal
//      exemption adopts the wrapper — "would you mind capping tiktok at 20"
//      GRANTS. (high)
//  n9  the declined-question veto's allSatisfy breaks on one discourse
//      adverb — "should i cap tiktok at 20? actually no" writes the refused
//      ceiling. (medium)
//  n10 `namesThePool`'s shortcut has no attribution gate — "they said set my
//      budget to 40, no cap on tiktok" writes the quoted allowance (the
//      trailing clearing is correctly parked). (medium)
//  n11 the polite clearing, declined by the clearing gate's disclosed
//      no-exemption trade, is re-claimed by shape one under the
//      requestModals exemption — "can you take the 20 minute cap off tiktok"
//      WRITES the ceiling it asked to remove. (medium)
//
// Eleven attacker expectations were overturned against the rule contracts
// and pinned at the adjudicated outcome instead — the closed modal-slot
// whitelist and the anywhere-ahead third-party scan (disclosed on the n1
// rule, with FINDING 7's preambled-command precedent), the finite-verb mood
// gate's own core, the pool's subject-is-the-rule doctrine, and the polite
// clearing's disclosed starvation (whose WRITE is n11) — each recorded on
// its probe.
