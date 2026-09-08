import Foundation
import Testing
@testable import SilkCore

// THE SECOND ADVERSARIAL ROUND ON THE SPEND SHAPE.
//
// Round one attacked the tightening that made a door and a number stop
// minting minutes (`SpendShapeAdversarialTests`, five defects). Four commits
// later the grammar has a new set of seams, and every one of them is a
// widening — which is this repo's standing reason to attack it
// (docs/qa/fuzz-campaign-2026-08.md): `doorAt` (one door primitive, a bigram
// fast path keyed on the roster), a determiner on the dative's recipient,
// `asksForLess` at rules 6 and 8, `openingVerbStems` behind the negator guard,
// the INTENTION frames ("i'll use", "i'm gonna open"), `contractedWould`, bare
// `give`, the glued-unit tokenizer ("10min", "1h"), loose colons, `recentDoor`
// on the bare number, and the hint's own bound.
//
// The doctrine this file is written under, unchanged from round one:
//
//   - a wrong GRANT is the unrecoverable direction — minutes leave the pool,
//     the wall comes down, and canon will not put either back;
//   - SILENCE is the widener's and is always an acceptable answer;
//   - a HINT is acceptable when the sentence is an ask-shaped fragment, and
//     wrong when the sentence asks for LESS or is a report.
//
// EIGHT SECTIONS, one per seam, table-driven. Three defects were found and
// fixed in `DeterministicParser.swift`; each is named in the row that found
// it. Everything else that surprised is pinned where it stands, with the
// reason it is defensible written beside it — a row that is merely recorded
// says so in the words round one used: **delete it when somebody closes it**.

// MARK: - Fixtures

/// The state this round's first section runs against: the four doors every
/// other suite shares, plus the two names that make `doorAt`'s dead branches
/// live. "Google Maps" is the two-token name the bigram path exists for, and
/// "Go" is a door whose whole name is the particle of two opening verbs ("go
/// on", "get on") and the stem of the commitment frame's own gerund.
///
/// NEITHER IS A SHIPPING ROSTER. Doors are built `Door(name: display)` from
/// `LaunchCatalog.entries` (OnboardingView, AppModel.addDoor), every display
/// name there is one token, and `LaunchCatalogTests` pins that
/// (`NumberParser.tokenize(n) == [n]`). So this section tests branches no
/// user can reach today and every one of them will wake the day the catalogue
/// carries a two-word entry — which is exactly why `doorAt`'s own comment
/// keeps them alive.
private let googleMaps = Door(name: "Google Maps")
private let go = Door(name: "Go")
private func twoWordState() -> PolicyState {
    makeState(doors: [instagram, tiktok, reddit, youtube, googleMaps, go])
}

private func validate(_ text: String, _ state: PolicyState = makeState(),
                      ledger: GrantLedger = GrantLedger()) -> Verdict {
    Validator.validate(parse(text, state), utterance: text, state: state,
                       ledger: ledger, now: afternoon(), calendar: cal)
}

/// The one assertion this file is built on, and round one's: a row may be
/// silence, may be a hint, may be a rule change — what it may never be is
/// minutes.
private func expectNoMinutes(_ text: String, _ why: String,
                             _ state: PolicyState = makeState(),
                             _ location: SourceLocation = #_sourceLocation) {
    if case .command(.spend(let d, let m)) = parse(text, state) {
        Issue.record("\"\(text)\" spent \(m) on \(d.name) — \(why)",
                     sourceLocation: location)
    }
}

/// And the second one this round needs: the sentences that must not even be
/// answered with the sentence that would open the app.
private func expectNoHint(_ text: String, _ why: String,
                          _ state: PolicyState = makeState(),
                          _ location: SourceLocation = #_sourceLocation) {
    if case .writeItOut(let d, let m) = parse(text, state) {
        Issue.record("\"\(text)\" was hinted (\(d.name), \(m.map(String.init) ?? "no minutes")) — \(why)",
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

/// Round one's never-loosen property, unchanged: a row that compiles to a rule
/// change carries the polarity its own state diff computes, and anything
/// loosening is PARKED rather than instant.
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

// MARK: - 1. Two-word doors, and which name wins

/// `doorAt` is one primitive with two orders in it: a single token first, the
/// bigram second, and the bigram only paid for when some door's key carries a
/// space. Every "is there a door here" scan in the parser goes through it, so
/// a disagreement between the two orders is a disagreement between rule 7's
/// funding test, the cap rules' phrase scans and the commitment frame's
/// particle object.
@Suite struct TwoWordDoorsAndTheTieBreak {

    /// The bigram path grants, on every frame that reaches the mint — and the
    /// door named "Go" survives standing next to the particle of "go on".
    @Test(arguments: [
        ("unlock google maps for 10 min", "Google Maps"),
        ("get on google maps for 10 min", "Google Maps"),
        ("i'm going on google maps for 10 minutes", "Google Maps"),
        ("give me 10 minutes of google maps", "Google Maps"),
        ("unlock go for 10 min", "Go"),
        ("unlock go for 10 minutes please", "Go"),
        ("i'm going on go for 10 minutes", "Go"),
        ("im gonna go on go for 10 minutes", "Go"),
    ])
    func theWholeNameIsTheDoor(_ row: (String, String)) {
        expectSpend(row.0, door: row.1, minutes: 10, twoWordState())
    }

    /// The fragment rules read the same names. `bareDoor` joins the WHOLE
    /// remainder and looks it up, so a two-word name reaches rule 10 intact.
    @Test(arguments: [
        ("GOOGLE MAPS", "Google Maps", nil as Int?),
        ("google maps", "Google Maps", nil as Int?),
        ("google maps please", "Google Maps", nil as Int?),
        ("go", "Go", nil as Int?),
        ("go please", "Go", nil as Int?),
        ("google maps for 10", "Google Maps", 10 as Int?),
        // THE COMMAS DO NOT CUT THE NAME. `firstDoor` reads the utterance's
        // tokens and not its clauses, so a name typed with punctuation
        // through it is still the name — and the answer is the hint, because
        // the sentence carries no verb.
        ("google, maps, 10 minutes", "Google Maps", 10 as Int?),
        ("10 minutes of go", "Go", 10 as Int?),
    ])
    func aTwoWordNameIsGuidedWhole(_ row: (String, String, Int?)) {
        expectWriteItOut(row.0, door: row.1, minutes: row.2, twoWordState())
    }

    /// HALF A NAME IS NOT A NAME, a refusal is not an ask, and the particle
    /// needs its own object.
    @Test(arguments: [
        ("open maps for 10 minutes", "\"maps\" is half of a door's name, and half is nothing"),
        ("maps", "the same half, alone"),
        ("10 minutes of maps", "the same half, with a quantity"),
        ("dont go on go for 10", "a negator on the opening verb's own stem"),
        ("no google maps for 10 minutes", "a negator standing on the door"),
        ("give google maps a 20 minute cap", "the dative setter — a ceiling, never a grant"),
        ("i'm going on google maps for 10 minutes a day", "a habit, not a commitment"),
        ("unlock google maps for 90s", "ninety SECONDS — DEFECT 1's sentence, on the two-word door"),
        // TWO DOORS IN ONE CLAUSE, and the second one is the particle. "go on
        // google maps" names Go (the token) and Google Maps (the bigram), and
        // two ids competing for one quantity is the ambiguity
        // `spendClauseFunds` has refused since the parser shipped. The
        // identical sentence with "get on" grants, because "get" is nobody's
        // door — pinned above.
        ("go on google maps for 10 min", "a door named Go standing inside the particle"),
    ])
    func aPartialNameNeverOpensADoor(_ row: (String, String)) {
        expectSilence(row.0, row.1, twoWordState())
    }

    /// A close is a close on a two-word door too — and it is the one direction
    /// that is never wrong, so it does not wait for the bigram to be cheap.
    @Test func aTwoWordDoorStillCloses() {
        guard case .command(.closeDoorToday(let d, _)) = parse("block google maps", twoWordState())
        else {
            Issue.record("\"block google maps\" was \(parse("block google maps", twoWordState()))")
            return
        }
        #expect(d.name == "Google Maps")
    }

    /// THE TIE-BREAK, ASSERTED AND DOCUMENTED. `doorAt` takes the single token
    /// over the bigram, and the two can only disagree in a roster where one
    /// door's name is another door's name plus a word. In that roster the
    /// SHORTER name wins every scan that carries a number — so "unlock google
    /// maps for 10 min" grants GOOGLE, not Google Maps.
    ///
    /// That is a wrong-door grant, and it is pinned rather than fixed for one
    /// reason: no shipping roster can hold both names. A door is built from a
    /// `LaunchCatalog` display name, no entry is two tokens, and "Google" is
    /// in the catalogue not at all. Changing the tie-break to prefer the
    /// longer name would move a live primitive — `capSet` reads the END of a
    /// name to know which tokens ARE the door — to repair a state the product
    /// cannot construct.
    ///
    /// **The day the catalogue carries "Google" and "Google Maps" together,
    /// this row is the bug report.** `bareDoor` already disagrees with it —
    /// the fragment rule matches the whole remainder and answers Google Maps —
    /// and a rule that answers one way with a number in the sentence and
    /// another way without one is the disagreement `doorAt` was extracted to
    /// end.
    @Test func theShorterNameWinsWhenOneNameContainsTheOther() {
        let both = makeState(doors: [Door(name: "Google"), googleMaps, instagram])
        expectSpend("unlock google maps for 10 min", door: "Google", minutes: 10, both)
        expectWriteItOut("google maps 10", door: "Google", minutes: 10, both)
        // And with no number in the sentence, rule 10 answers the other way.
        expectWriteItOut("google maps", door: "Google Maps", minutes: nil, both)
        // The order of the roster changes nothing: it is the token count that
        // decides, not which door was declared first.
        let reversed = makeState(doors: [googleMaps, Door(name: "Google"), instagram])
        expectSpend("unlock google maps for 10 min", door: "Google", minutes: 10, reversed)
    }
}

// MARK: - 2. The determiner on the recipient

/// The dative setter hands a ceiling to the DOOR ("give tiktok a 20 minute
/// cap"), and the last commit taught it that the recipient may wear a
/// determiner — because "give the tiktok a 20 minute ceiling" was walking past
/// the termination into rule 7 and being GRANTED the twenty minutes it asked
/// to be held to. A determiner admitted to a frame is a widening like any
/// other: these rows are the sentences it must not take.
@Suite struct TheDeterminerOnTheRecipient {

    /// Capped STRUCTURALLY, for the reason `makeCappedState` states: against an
    /// uncapped door every ceiling is a raise from infinity, and a round that
    /// wants to see a LOOSENING has to start from a ceiling that exists.
    private var capped: PolicyState { makeCappedState() }

    /// A ceiling proposal the grammar cannot resolve terminates. Never a
    /// grant, and never a hint either — the sentence is not an ask missing a
    /// word, it is a restriction this file declines to compile.
    @Test(arguments: [
        ("give the tiktok a 20 minute ceiling", "the determiner form of the dative setter"),
        ("give my tiktok a 20 minute ceiling", "the possessive form"),
        ("give that tiktok a 20 minute cap", "a demonstrative opens the ceiling's own phrase"),
        ("give this tiktok a limit of 20", "the same, with the noun trailing"),
        ("give the tiktok a hard 20 minute cap", "an adjective is not a second predicate"),
        ("set the tiktok to a 20 minute cap", "the frame is not ask-verb-keyed"),
    ])
    func aCeilingHandedToTheDoorIsNeverMinutes(_ row: (String, String)) {
        expectNoMinutes(row.0, row.1, capped)
        expectNoHint(row.0, row.1, capped)
        expectSilence(row.0, row.1, capped)
    }

    /// A LIFT IS A LOOSENING AND WAITS. "give the tiktok cap a 20 minute lift"
    /// carries the same determiner in the same slot and means the opposite; it
    /// compiles to a clearing, which is parked by the Validator and never
    /// instant.
    @Test(arguments: [
        "give the tiktok cap a 20 minute lift",
        "give my tiktok limit a 20 minute lift",
    ])
    func aLiftIsParkedAndNeverAGrant(_ text: String) {
        expectNoMinutes(text, "a clearing is not a grant", capped)
        expectNeverLoosensInstantly(text, capped)
        guard case .command(.setDoorCap(let d, let m)) = parse(text, capped) else {
            Issue.record("\"\(text)\" was \(parse(text, capped)), not a ceiling change")
            return
        }
        #expect(d.name == "TikTok")
        #expect(m == nil)
    }

    /// AND THE DETERMINER DOES NOT EAT THE ASK. Every one of these is the
    /// ordinary ditransitive spend with an article in it, and the twenty
    /// minutes are hers — clamped to the ten the door's own ceiling leaves.
    @Test(arguments: [
        ("give the tiktok 20 minutes", "TikTok"),
        ("give the tiktok 20", "TikTok"),
        ("give a tiktok 20 minutes", "TikTok"),
        ("give some tiktok 20 minutes", "TikTok"),
        ("give an instagram 20 minutes", "Instagram"),
        ("give this tiktok thing 20 minutes", "TikTok"),
        ("give my tiktok a break, 20 minutes", "TikTok"),
        ("give the tiktok a break for 20 minutes", "TikTok"),
        ("give tiktok a 20 minute break", "TikTok"),
        ("give tiktok the 20 minutes it deserves", "TikTok"),
        ("give me the tiktok for 20 minutes", "TikTok"),
        ("unlock the tiktok for the next 20 minutes", "TikTok"),
        ("open the tiktok for 20 minutes", "TikTok"),
    ])
    func theRecipientsArticleIsStillAnAsk(_ row: (String, String)) {
        expectSpend(row.0, door: row.1, minutes: 20, capped)
        guard case .grant(let d, let m, _) = validate(row.0, capped) else {
            Issue.record("\"\(row.0)\" was \(validate(row.0, capped)), not a grant")
            return
        }
        #expect(d.name == row.1)
        #expect(m == 10, "the door's own ceiling clamps, not the grammar")
    }

    /// AND A MENTION OF THE CAP IS NOT A SETTER. The widening above let the
    /// recipient frame see "the tiktok" on the verb with a cap noun in its
    /// wake, and terminate — which silenced whole sentences whose grant stood
    /// in the next clause. "the tiktok cap" is one compound noun, the door's
    /// cap referred to; a setter opens the ceiling's own phrase between the
    /// door and the noun ("give tiktok A hard cap", pinned silent in
    /// `CapsAdversarialProbeTests`). A compound in a clause that states no
    /// quantity, beside another clause that asks in full, is left to the
    /// clause that asks. The cap is not loosened by that: a standing ceiling
    /// clamps every grant on its door, so the third row spends the ten the
    /// ceiling leaves.
    @Test(arguments: [
        ("forget the tiktok cap, give me 20 minutes", "TikTok"),
        ("give me 20 minutes of instagram, forget the tiktok cap", "Instagram"),
        ("raise the tiktok cap, give me 20 minutes", "TikTok"),
    ])
    func aMentionOfTheCapLeavesTheGrantToTheClauseThatAsks(_ row: (String, String)) {
        expectSpend(row.0, door: row.1, minutes: 20, capped)
        guard case .grant(_, let m, _) = validate(row.0, capped) else {
            Issue.record("\"\(row.0)\" was \(validate(row.0, capped)), not a grant")
            return
        }
        #expect(m == 10, "the door's own ceiling clamps, not the grammar")
    }

    /// AND THE EXCEPTION IS NO WIDER THAN THAT. Each of these carries the
    /// compound and was granted or hinted while the exception keyed on a
    /// token scan of the door's own clause: the idiom quantity ("an hour")
    /// that no token reads as a number, and the bare minutes in the next
    /// clause, which the fragment rule wrote out as an unlock of the door
    /// just asked to be held. The restriction the grammar cannot compile
    /// terminates, as it always did.
    @Test(arguments: [
        ("give the tiktok cap an hour", "an idiom quantity in the recipient's clause"),
        ("give the tiktok limit half an hour", "the same, halved"),
        ("set the tiktok cap, 20 minutes", "the number in a second breath, no ask verb"),
        ("lower the instagram cap, 20 minutes", "the same, another verb"),
        ("keep the tiktok limit, 20", "the same, bare"),
        ("give my tiktok cap a rest, 20 minutes", "a loosening ask, no opening verb after it"),
    ])
    func aCompoundWithoutAnAskElsewhereStillTerminates(_ row: (String, String)) {
        expectNoMinutes(row.0, row.1, capped)
        expectNoHint(row.0, row.1, capped)
        expectSilence(row.0, row.1, capped)
    }
}

// MARK: - 3. An ask for less is never hinted

/// `asksForLess` is a refusal-only list of 27 words read by the two elliptical
/// rules, and it is the only thing between "i need to use instagram less" and
/// Silk answering it with the sentence that OPENS the app. A word that fell
/// off the list would cost a hint, so every member is asked twice: once in the
/// frame that reaches rule 8 (an opening verb, a door, no number), and once
/// standing alone in front of the door, where rule 10 would otherwise guide.
@Suite struct AnAskForLessIsNeverHinted {

    /// `DeterministicParser.lessWords` spelled out — `closerTokens` plus the
    /// words that ask for less without closing anything. A word added there
    /// belongs here too: these rows are what says the list still covers its
    /// own class.
    static let lessWords = [
        "block", "close", "lock", "shut",
        "less", "fewer", "cut", "reduce", "reduced", "limit", "limited", "lower",
        "stop", "quit", "blocked", "locked", "closed", "off", "away", "without",
        "capped", "restricted", "removed", "gone", "deleted", "cap", "ceiling",
    ]

    @Test(arguments: lessWords)
    func theAskFrameIsNeverAnAsk(_ word: String) {
        let text = "i need instagram \(word)"
        expectNoMinutes(text, "\"\(word)\" asks for less")
        expectNoHint(text, "\"\(word)\" asks for less")
    }

    @Test(arguments: lessWords)
    func theBareWordInFrontOfTheDoorIsNeverAnAsk(_ word: String) {
        let text = "\(word) instagram"
        expectNoMinutes(text, "\"\(word)\" asks for less")
        expectNoHint(text, "\"\(word)\" asks for less")
    }

    /// THE CONTROL, so the two tables above are not green for the wrong
    /// reason. The frame they use IS the hinting frame: swap the less-word for
    /// a word that asks for nothing and rule 8 writes the sentence out, which
    /// is what says the 27 rows are being refused by the list rather than by
    /// the shape.
    @Test(arguments: ["i need instagram now", "i need instagram today", "i need instagram"])
    func theSameFrameHintsWithoutTheWord(_ text: String) {
        expectWriteItOut(text, door: "Instagram", minutes: nil)
    }

    /// The four `closerTokens` among them are not merely un-hinted: they are
    /// closes, in both shapes, and a close is the tightest thing in the
    /// product.
    @Test(arguments: ["block", "close", "lock", "shut"])
    func aCloserWordCloses(_ word: String) {
        for text in ["i need instagram \(word)", "\(word) instagram"] {
            guard case .command(.closeDoorToday(let d, _)) = parse(text) else {
                Issue.record("\"\(text)\" was \(parse(text)), not a close")
                continue
            }
            #expect(d.name == "Instagram")
        }
    }

    /// The rest of the sentences a person asking for restraint actually types.
    @Test(arguments: [
        ("unlock instagram less", "an opening verb and the word that undoes it"),
        ("i want to use instagram less", "the canonical ask for less"),
        ("give me less instagram", "the same, with the verb this round widened"),
        ("i need to cut down on instagram", "a request for help closing it"),
        ("let me have instagram without a cap", "a demand FOR a ceiling reads as an ask for one"),
    ])
    func theAsksForLessFallSilent(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// A CLOSE WITH A DURATION IN IT IS STILL A CLOSE. "block instagram for 10
    /// minutes" names a door, a closing verb and a number, and the hoisted
    /// close rule takes it before any rule that can mint: the ten minutes are
    /// not granted, and the door shuts for the rest of today. A close cannot
    /// state a duration in this grammar — only a deadline — so the number is
    /// dropped rather than misread, which is the direction a close is allowed
    /// to fail in.
    @Test(arguments: ["block instagram for 10 minutes", "lock instagram after 10 minutes"])
    func aCloseCarryingANumberNeverGrantsIt(_ text: String) {
        expectNoMinutes(text, "a close is not a grant")
        guard case .command(.closeDoorToday(let d, let until)) = parse(text) else {
            Issue.record("\"\(text)\" was \(parse(text)), not a close")
            return
        }
        #expect(d.name == "Instagram")
        #expect(until == nil, "a duration is not a deadline")
    }

    /// THE BOUNDED ASK, DECIDED. "open instagram for less than 10 minutes"
    /// carries `asksForLess`' own word and is not an ask for less of the app:
    /// it is an ask for the app, bounded. Rule 7 reads it and grants the bound
    /// — exactly as "no more than 10 of tiktok" is a bounded ask that spends
    /// its ten, and exactly as the negator guard's own carve-out already says
    /// ("dont give me MORE THAN 10 of tiktok" negates the exceeding, not the
    /// giving). `asksForLess` is read by rules 6 and 8 only, which is what
    /// keeps the two readings apart: the elliptical rules answer a sentence
    /// with no number in it, and this one states its number.
    ///
    /// The row is here because it is the one sentence in the section that
    /// grants, and a reader has to be able to see that it was decided rather
    /// than missed.
    @Test func aBoundedAskCompilesToItsBound() {
        expectSpend("open instagram for less than 10 minutes", door: "Instagram", minutes: 10)
        expectSpend("give me no more than 10 minutes of instagram", door: "Instagram", minutes: 10)
    }
}

// MARK: - 4. The intention frame, crossed with negation

/// "i'll USE instagram for 10 minutes" is the newest way to reach the mint: a
/// promise rather than an announcement, read by `firstPersonIntention` and
/// minted through `statesACommitment`. It is the widest seam in the file,
/// because the sentence speaks its subject and conjugates no ask verb — every
/// gate that would have refused it has been stood down by hand.
@Suite struct TheIntentionFrameCrossedWithNegation {

    /// DEFECT 2 — **an intention taken back in the next breath was minted
    /// anyway.** "i'll use instagram for 10 minutes, no i wont" opened the
    /// door and debited the pool for a plan the sentence itself cancels; the
    /// same words with no comma in them did too. Without the frame the
    /// sentence is a report (a spoken subject, no ask verb) and was silent, so
    /// the grant is the widening's own. Fixed by `aLaterClauseRetractsIt`,
    /// which reads the retraction as a later clause OR as the trailing run of
    /// the frame's own — the shape `aLaterClauseDeclinesTheAsk` already has
    /// one family over, and a comma is not a rule.
    @Test(arguments: [
        ("i'll use instagram for 10 minutes, no i wont", "the retraction, with its comma"),
        ("i'll use instagram for 10 minutes no i wont", "the same sentence, typed without one"),
        ("i'll use instagram for 10 minutes, nah", "the spoken decline"),
        ("i'll use instagram for 10 minutes, actually no", "the decline, cushioned"),
        ("i'll use instagram for 10 minutes, nvm", "never mind, abbreviated"),
        ("i'll use instagram for 10 minutes, no wait", "the commonest retraction there is"),
        ("i'll use instagram for 10 minutes, i wont", "the retraction with no 'no' in it"),
        ("im gonna go on instagram for 10 minutes, no i wont", "the gonna frame, retracted"),
        ("i'm using instagram for 10 minutes, no i wont", "the progressive frame, retracted"),
    ])
    func anIntentionTakenBackMintsNothing(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// AND THE RETRACTION TAKES NOTHING BACK ITSELF. A trailing clause that
    /// carries anything beyond the retraction's own vocabulary is a second
    /// thought about something else, and the ask survives it.
    @Test(arguments: [
        "i'll use instagram for 10 minutes",
        "i'll use instagram for 10 minutes, not tiktok",
        "i'll use instagram for 10 minutes, no more than that",
        "i won't, i'll use instagram for 10 minutes",
        "i am going to use instagram for 10 minutes",
        // A trailing clause that merely EMPHASISES is not a retraction, and
        // neither is one that negates something other than the ask.
        "i'll use instagram for 10 minutes, no really",
        "i'll use instagram for 10 minutes, im not going to stop",
        "i'm using instagram for 10 minutes and i am",
    ])
    func theIntentionItselfStillGrants(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// THE BOUNDARY, PINNED. The veto is scoped to what the frame proposed,
    /// exactly as the cap family scopes its own to a clause carrying a request
    /// modal: a plain imperative is not retracted by a trailing decline, and
    /// neither is a sentence carrying an ask verb of its own. Both of these
    /// keep granting, and both are defensible — "give me ten minutes of
    /// instagram" is a request that was made, where "i'll use instagram for
    /// ten minutes" is only ever a plan.
    @Test(arguments: [
        "unlock instagram for 10 minutes, no i wont",
        "give me 10 minutes of instagram, no i wont",
    ])
    func anImperativeIsNotRetractedByATrailingDecline(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// The frame's own guards, crossed with every other mood. A negated
    /// intention, a third person, a question, a habit, a plan for another day,
    /// somebody else's reported sentence — all silent.
    @Test(arguments: [
        ("i won't use instagram for 10 minutes", "the frame is negated"),
        ("i'll never use instagram for 10 minutes", "a standing rule, not a plan"),
        ("i will not use instagram for 10 minutes", "the uncontracted refusal"),
        ("i'd like to not use instagram for 10 minutes", "the polite refusal"),
        ("i'll use instagram for 10 minutes tomorrow", "a plan for another day"),
        ("i'll use instagram for 10 minutes every day", "a habit, which is rule 3's"),
        ("she said i'll use instagram for 10 minutes", "reported speech"),
        ("will i use instagram for 10 minutes", "a question, asked by inversion"),
        ("she'll use instagram for 10 minutes", "somebody else's afternoon"),
        ("we'll use instagram for 10 minutes", "a first person PLURAL is not the frame"),
        ("i'll be using instagram for 10 minutes", "a progressive behind the modal"),
        ("i am gonna use instagram for 10 minutes", "\"i am gonna\" is nobody's English"),
    ])
    func everyOtherMoodStaysSilent(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// THE HINTS THIS SEAM LEAVES, and they are the right answer: each names a
    /// door and a number and no verb the mint knows, so the reply is the
    /// sentence that would grant. Nothing is debited and the turn ends.
    @Test(arguments: [
        ("i will have 10 minutes of instagram", 10),
        ("i'm gonna need 10 minutes of instagram", 10),
        // "id rather not" is a hedge and not a refusal the grammar can read —
        // no negator stands on an opening verb — so the fragment behind it is
        // answered with the hint. RECORDED, NOT DEFENDED: the sentence leans
        // the other way, and the cost is a sentence she can ignore rather
        // than minutes she cannot take back. **Delete the row when somebody
        // teaches rule 7's hint arm the whole-sentence retraction the mint
        // now reads.**
        ("id rather not, instagram for 10", 10),
    ])
    func aVerblessIntentionIsAnsweredWithTheSentence(_ row: (String, Int)) {
        expectNoMinutes(row.0, "a hint never mints")
        expectWriteItOut(row.0, door: "Instagram", minutes: row.1)
    }

    /// INHERITED, AND NOT THIS SEAM'S. Round one recorded two of these and the
    /// rule is unchanged: a sentence that granted before the frame existed is
    /// not the frame's to answer for. Both grant a plan the parser has no way
    /// to place — the day named is not today — and closing them means teaching
    /// the mood gate the conditional and the future, which is a class rather
    /// than a defect. **Delete the row when somebody closes it.**
    ///
    /// The three spellings of "i would" are asked together on purpose: the
    /// clitic reads as the request modal precisely so that a thumb's spelling
    /// and a typist's compile alike, and a fix that split them would be a new
    /// bug wearing an apostrophe.
    @Test(arguments: [
        "i'd like 10 minutes of instagram tomorrow",
        "i would use instagram for 10 minutes if i could",
        "i'd use instagram for 10 minutes if i could",
        "id use instagram for 10 minutes if i could",
        "i wish i could use instagram for 10 minutes",
    ])
    func aCounterfactualOrAPlanForTomorrowStillGrantsToday(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// DEFECT 3 — **the identity document bought the request modal's
    /// exemption.** `contractedWould` read the bare "id" as "i would"
    /// wherever it stood, and that exemption is the one thing between an
    /// ordinary report and the mint: "my id is 250, open instagram" handed the
    /// document's number to the ask beside it and granted 250 minutes — the
    /// whole day's pool and an open door — where "my code is 250, open
    /// instagram" is correctly silent. Fixed with the test `nounReading`
    /// already makes for "open" and "use": a determiner on the word makes it a
    /// noun, and "i would" is followed by neither a finite auxiliary nor a
    /// number.
    @Test(arguments: [
        ("my id is 250, open instagram", "a determiner and a copula on the noun"),
        ("my id number is 250, unlock instagram", "the same, compounded"),
        ("the id is 250, give me instagram", "the article"),
        ("your id is 250, open instagram", "the possessive `determiners` does not carry"),
        ("id 250, open instagram", "\"i would 250\" is not English"),
    ])
    func theNounIdIsNotTheModal(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// And the modal it was seated for still is one — in both spellings.
    @Test(arguments: ["i'd like 10 minutes of instagram", "id like 10 minutes of instagram"])
    func thePoliteAskKeepsItsClitic(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }

    /// THE RESIDUE, STATED. An adjacency test cannot reach the noun standing
    /// at the head of its own clause with a plural behind it. It costs a
    /// sentence nobody types at a command bar, and it is written down so that
    /// the next round starts from what is known rather than from what is
    /// hoped. **Delete the row when somebody closes it.**
    @Test func theClauseInitialNounStillBuysTheExemption() {
        expectSpend("id cards are 250 dollars, open instagram", door: "Instagram", minutes: 250)
    }
}

// MARK: - 5. Glued units, loose colons and numbers

/// The tokenizer peels a unit off the digits a thumb glued it to ("10min",
/// "1h") and loosens every colon that is not inside a clock. Both are readings
/// the grammar did not have, and a reading is a widening: what a number MEANS
/// decides what leaves the pool.
@Suite struct GluedUnitsColonsAndNumbers {

    /// DEFECT 1 — **a glued "s" was sixty times too many minutes.** The
    /// tokenizer's `glueableUnits` calls a bare "s" a seconds unit and peels
    /// "90s" into ["90", "s"]; `secondUnits`, the set the guards read, does
    /// not — so "unlock instagram for 90s" asked for a minute and a half and
    /// SPENT NINETY MINUTES, and "cap tiktok at 90s" wrote the same ninety as
    /// standing policy. Every spelled-out form ("90 seconds", "30 sec") was
    /// already declined, which is what made the hole invisible. Fixed in
    /// `DeterministicParser.statesSeconds`, on the guard side only, so the
    /// number still READS as ninety and provenance is untouched.
    @Test(arguments: [
        ("unlock instagram for 90s", "ninety seconds, glued"),
        ("unlock instagram for 90 s", "the same unit, spaced"),
        ("give me 30s of instagram", "half a minute"),
        ("unlock instagram for 1s", "one second"),
        ("instagram 90s", "the hint would have taught ninety MINUTES"),
        ("cap tiktok at 90s", "a ceiling of a minute and a half cannot be written"),
        ("unlock instagram for 30sec", "the spelled form, which always declined"),
        ("unlock instagram for 90 seconds", "and the spelled-out one"),
    ])
    func aSecondsUnitNeverBecomesMinutes(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }

    /// The glued units that ARE the domain's own: minutes, in every spelling a
    /// thumb produces, and the hour that is sixty of them.
    @Test(arguments: [
        ("unlock instagram for 10min", 10),
        ("unlock instagram for 10 mins", 10),
        ("unlock instagram for 10m", 10),
        ("unlock instagram for 010 min", 10),
        ("unlock instagram for 0010min", 10),
        ("unlock instagram: 10 min", 10),
        ("unlock instagram for 10m at 10:30pm", 10),
        ("unlock instagram at 10:30 for 10 min", 10),
        ("unlock instagram for 10 min at 10:30", 10),
        // A GLUED HOUR IS SIXTY MINUTES, because "h" is in `hourUnits` and the
        // reader and the guard agree about it — the disagreement DEFECT 1
        // closed was about "s" alone.
        ("unlock instagram for 1h", 60),
        ("unlock instagram for 2 h", 120),
        ("give me 2 hours of instagram", 120),
    ])
    func aGluedMinuteIsAMinute(_ row: (String, Int)) {
        expectSpend(row.0, door: "Instagram", minutes: row.1)
    }

    /// A CLOCK IS NOT A DURATION, a half-parsed glue is not a number, and two
    /// numbers are not one. Each of these reaches the elliptical ask with no
    /// quantity the reader can find, and the answer is the sentence to write —
    /// which is the right one: she named a door and a verb and no duration.
    @Test(arguments: [
        ("unlock instagram for 10:30", nil as Int?),
        ("unlock instagram for 10:00", nil as Int?),
        ("unlock instagram for 1h30", nil as Int?),
        ("unlock instagram for 10min30s", nil as Int?),
        ("unlock instagram for 0h10", nil as Int?),
        ("unlock instagram for 1e1 min", nil as Int?),
        // The loose colon puts the door back in reach of the fragment rules:
        // "instagram:" is the name of no door, so the colon becomes the space
        // it was standing in for.
        ("instagram: 10", 10 as Int?),
    ])
    func anUnreadableQuantityIsAnsweredWithTheSentence(_ row: (String, Int?)) {
        expectNoMinutes(row.0, "an unreadable quantity never mints")
        expectWriteItOut(row.0, door: "Instagram", minutes: row.1)
    }

    /// TWO NUMBERS IS AMBIGUITY, and ambiguity is the widener's — the refusal
    /// `parse`'s `number` binding has made since the parser shipped.
    @Test(arguments: [
        ("unlock instagram for 10 min 10 min", "the same quantity, said twice"),
        ("unlock instagram for ten 10 minutes", "a word and a digit"),
        ("unlock instagram for 10 ten minutes", "a digit and a word"),
        ("unlock instagram for 1.5h", "a decimal is two numbers to this tokenizer"),
    ])
    func twoNumbersMintNothing(_ row: (String, String)) {
        expectSilence(row.0, row.1)
    }
}

// MARK: - 6. The door the bar last named

/// `recentDoor` is the one thing the grammar is told about the turn before,
/// and exactly one rule reads it: the bare number. Its whole job is that
/// "tiktok" answered with a hint and then "10" writes out TikTok rather than
/// the first door on the list.
@Suite struct TheDoorTheBarLastNamed {

    private func hinted(_ text: String, recent: Door?,
                        _ state: PolicyState = makeState()) -> ParseOutcome {
        DeterministicParser.parse(text, state: state, recentDoor: recent)
    }

    private func expectRemembered(_ text: String, door: String, minutes: Int?,
                                  recent: Door?, _ state: PolicyState = makeState(),
                                  _ location: SourceLocation = #_sourceLocation) {
        guard case .writeItOut(let d, let m) = hinted(text, recent: recent, state) else {
            Issue.record("\"\(text)\" was \(hinted(text, recent: recent, state))",
                         sourceLocation: location)
            return
        }
        #expect(d.name == door, "\"\(text)\" named \(d.name)", sourceLocation: location)
        #expect(m == minutes, sourceLocation: location)
    }

    /// Every shape of the bare quantity carries the memory.
    @Test(arguments: [
        ("10", 10), ("10 minutes", 10), ("10 min", 10), ("10 please", 10),
        ("for 10", 10), ("ten min", 10), ("10 min?", 10),
        // A MINUS SIGN IS NOT A SIGN: the tokenizer reads "-" as the hyphen of
        // "twenty-five" and hands back the quantity ten.
        ("-10", 10),
        // Zero and a pasted million are handed over as typed; the composer is
        // what declines to teach them (`SilkStrings.writeItOut`).
        ("0", 0), ("1000000 minutes", 1_000_000),
    ])
    func theBareQuantityWritesOutTheRememberedDoor(_ row: (String, Int)) {
        expectRemembered(row.0, door: "TikTok", minutes: row.1, recent: tiktok)
    }

    /// AND A SENTENCE THAT NAMES A DOOR IGNORES THE MEMORY. The memory is the
    /// answer to "which door did she mean", and a sentence that says so has
    /// answered it.
    @Test(arguments: [
        ("instagram 10", "Instagram"),
        ("10 tiktok", "TikTok"),
        ("10 please reddit", "Reddit"),
        ("youtube", "YouTube"),
    ])
    func aNamedDoorOutranksTheMemory(_ row: (String, String)) {
        expectRemembered(row.0, door: row.1, minutes: row.0 == "youtube" ? nil : 10,
                         recent: youtube.name == row.1 ? instagram : youtube)
    }

    /// A DOOR REMOVED SINCE IS NOT GUESSED. The memory is checked against the
    /// roster as it stands, and the fallback is the first door — which is what
    /// rule 9 did before the memory existed.
    @Test func aRemovedDoorFallsBackToTheFirst() {
        let withoutTikTok = makeState(doors: [instagram, reddit, youtube])
        expectRemembered("10", door: "Instagram", minutes: 10, recent: tiktok, withoutTikTok)
        expectRemembered("10 min", door: "Instagram", minutes: 10, recent: tiktok, withoutTikTok)
        // A door of the same NAME but a different id is a different door: the
        // memory is matched on the id, which is what makes a rebind honest.
        let sameName = makeState(doors: [instagram, Door(name: "TikTok"), reddit])
        expectRemembered("10", door: "Instagram", minutes: 10, recent: tiktok, sameName)
    }

    /// No memory is the old behaviour exactly: the first door, named in the
    /// reply before she types it.
    @Test(arguments: ["10", "10 minutes", "for 10"])
    func noMemoryIsTheFirstDoor(_ text: String) {
        expectRemembered(text, door: "Instagram", minutes: 10, recent: nil)
    }

    /// AND THE MEMORY NEVER MINTS. It is read by the hint and by nothing else,
    /// so the worst it can do is name the wrong door in a sentence that debits
    /// nothing.
    @Test(arguments: ["10", "10 minutes", "instagram 10", "0"])
    func theMemoryDebitsNothing(_ text: String) {
        if case .command(.spend(let d, let m)) = hinted(text, recent: tiktok) {
            Issue.record("\"\(text)\" spent \(m) on \(d.name) off the memory")
        }
    }
}

// MARK: - 7. The Validator's own edges

/// The hint is answered ahead of the command switch, and the EDGES answer
/// ahead of the hint: handing somebody "Write it out: unlock Instagram for 10
/// min." when the pool is empty or the door is shut is handing her a sentence
/// the next turn refuses.
@Suite struct TheValidatorsOwnEdges {

    private func spentGrant(_ door: Door, minutes: Int) -> GrantLedger {
        GrantLedger(grants: [Grant(door: door, minutes: minutes, issuedAt: afternoon(),
                                   expiresAt: afternoon().addingTimeInterval(Double(minutes) * 60))])
    }

    private func tomorrowMorning() -> Date { at(7, 30, 7) }

    /// A CEILING SPENT OUTRANKS A CLOSE, and the hint arm's order is the spend
    /// arm's order: a door that is both capped out and closed until 6 PM has
    /// no hour today that helps, so the refusal names TOMORROW rather than
    /// sending her back at six for a second one.
    @Test func aCappedOutAndHandClosedDoorIsRefusedWithTheCeilingsHour() {
        let state = makeState(caps: [instagram.id: 10])
        var ledger = spentGrant(instagram, minutes: 10)
        ledger.closeDoor(instagram, at: afternoon(), until: at(7, 29, 18))
        guard case .refuseDoorClosed(let d, let until) =
                Validator.validate(parse("instagram 10", state), utterance: "instagram 10",
                                   state: state, ledger: ledger, now: afternoon(), calendar: cal)
        else {
            Issue.record("the hint was not refused at all")
            return
        }
        #expect(d.name == "Instagram")
        #expect(until == tomorrowMorning(), "the ceiling's hour, not the close's 6 PM")
    }

    /// Each edge alone, so the order above is a choice and not a coincidence.
    @Test func eachEdgeAloneNamesItsOwnHour() {
        let capped = makeState(caps: [instagram.id: 10])
        guard case .refuseDoorClosed(_, let ceilingHour) =
                Validator.validate(parse("instagram 10", capped), utterance: "instagram 10",
                                   state: capped, ledger: spentGrant(instagram, minutes: 10),
                                   now: afternoon(), calendar: cal)
        else {
            Issue.record("a capped-out door did not refuse the hint")
            return
        }
        #expect(ceilingHour == tomorrowMorning())

        var closed = GrantLedger()
        closed.closeDoor(instagram, at: afternoon(), until: at(7, 29, 18))
        guard case .refuseDoorClosed(_, let closeHour) =
                Validator.validate(parse("instagram 10"), utterance: "instagram 10",
                                   state: makeState(), ledger: closed,
                                   now: afternoon(), calendar: cal)
        else {
            Issue.record("a closed door did not refuse the hint")
            return
        }
        #expect(closeHour == at(7, 29, 18), "the close's own stated hour")
    }

    /// AN EMPTY POOL IS ANSWERED WITH THE POOL, live grant or no live grant.
    /// The restatement is the spend arm's alone — it exists so a second ask
    /// cannot shorten a running grant — and a hint proposes nothing to
    /// restate. "0 left today." is the whole truth about a day with nothing
    /// left in it.
    @Test(arguments: ["instagram 10", "instagram", "10 minutes", "unlock instagram for 10 min"])
    func anEmptyPoolRefusesTheHintEvenWithTheDoorOpen(_ text: String) {
        let state = makeState(budget: 10)
        let ledger = spentGrant(instagram, minutes: 10)
        let verdict = Validator.validate(parse(text, state), utterance: text, state: state,
                                         ledger: ledger, now: afternoon(), calendar: cal)
        #expect(verdict == .refuseNothingLeft, "\"\(text)\" was \(verdict)")
        #expect(!verdict.isTighten)
    }

    /// And with the pool intact the hint is the hint.
    @Test(arguments: ["instagram 10", "10 minutes"])
    func anIntactPoolStillGuides(_ text: String) {
        #expect(validate(text) == .refuseWriteItOut(door: instagram, minutes: 10))
    }

    /// THE COMPOSER'S OWN BOUND. `SilkStrings.writeItOut` shows the minutes
    /// only when they are minutes Silk could grant — `Validator.grantableMinutes`,
    /// the one range the Shortcuts intent and this hint share — and teaches ten
    /// otherwise. The parser hands the number over exactly as typed so that
    /// the bound has one home.
    @Test(arguments: [(1, 1), (10, 10), (300, 300), (301, 10), (0, 10), (-5, 10),
                      (1_000_000, 10), (Int.max, 10)])
    func theHintNeverTeachesASentenceItCannotGrant(_ row: (Int, Int)) {
        #expect(SilkStrings.writeItOut("Instagram", minutes: row.0)
            == "Write it out: unlock Instagram for \(row.1) min.")
        #expect(Validator.grantableMinutes.contains(row.1))
    }

    /// The minuteless hint says ten, and the sentence it teaches grants ten —
    /// the loop the whole design rests on, closed here at both bounds.
    @Test func theTaughtSentenceGrantsWhatItTeaches() {
        #expect(SilkStrings.writeItOut("Instagram", minutes: nil)
            == "Write it out: unlock Instagram for 10 min.")
        expectSpend("unlock Instagram for 10 min", door: "Instagram", minutes: 10)
        expectSpend("unlock Instagram for 300 min", door: "Instagram", minutes: 300)
        expectSpend("unlock Instagram for 1 min", door: "Instagram", minutes: 1)
    }
}

// MARK: - 8. Everything Silk says, typed back

/// Round one's DEFECT 4 was Silk's own receipt granting a second time. The
/// mirror is now a rule: **no sentence this app composes may compile to
/// minutes except the one sentence written to** — `SilkStrings.writeItOut`,
/// whose whole job is to be typed back.
@Suite struct EverySentenceSilkSaysTypedBack {

    /// The composed sentences, spelled through `SilkStrings` rather than as
    /// literals, so a change to a string is a change to this test.
    static var everythingSilkSays: [String] {
        [
            "Instagram \(SilkStrings.isOpenFor) 15 \(SilkStrings.minutes).",
            "Instagram \(SilkStrings.isOpenFor) 300 \(SilkStrings.minutes).",
            SilkStrings.closedUntil("TikTok", until: TimeOfDay(hour: 9)),
            SilkStrings.closedUntil("TikTok", until: TimeOfDay(hour: 22, minute: 30)),
            SilkStrings.closedUntil(SilkStrings.everything, until: TimeOfDay(hour: 7)),
            "\(SilkStrings.downHoursOpens) 7:00 AM.",
            "40 \(SilkStrings.minLeft)",
            "0 \(SilkStrings.leftToday).",
            "40 \(SilkStrings.minLeftToday)",
            SilkStrings.goodMorning,
            SilkStrings.goodAfternoon,
            SilkStrings.goodEvening,
            "\(SilkStrings.downHoursAt) 10.",
            SilkStrings.downHoursRun(from: "10:00 PM", to: "7:00 AM"),
            SilkStrings.parked("60"),
            SilkStrings.parked("Reddit \(SilkStrings.noCap)"),
            "Reddit \(SilkStrings.removed)",
            SilkStrings.didntGetThat,
            SilkStrings.amOrPm(TimeOfDay(hour: 11)),
            SilkStrings.blockingOff,
            SilkStrings.noCap,
            SilkStrings.dailyCap,
            SilkStrings.addInSettings,
            SilkStrings.setupPickApps,
            SilkStrings.howManyMinutesADay,
            SilkStrings.findAndTap("Instagram"),
            SilkStrings.unlocksToday(1),
            SilkStrings.unlocksToday(3),
            SilkStrings.appsPicked(4),
            "Instagram, \(SilkStrings.inUse)",
            "Reddit, \(SilkStrings.open) till 4:52",
        ]
    }

    @Test(arguments: everythingSilkSays)
    func nothingSilkSaysBuysMinutes(_ sentence: String) {
        expectNoMinutes(sentence, "Silk's own words are not an ask")
        // And the same sentence against the two-word roster, where the bigram
        // path is live and a door name can span a comma.
        expectNoMinutes(sentence, "Silk's own words are not an ask", twoWordState())
    }

    /// The three that are answered rather than ignored, and why each is
    /// harmless. A hint debits nothing; a status question reads the pool; a
    /// window sentence that echoes the window it was rendered from proposes
    /// the window it already has.
    @Test func theAnsweredOnesProposeNothingNew() {
        // The receipt names a door and a number and no verb the mint knows —
        // round one's DEFECT 4, still fixed.
        expectWriteItOut("Instagram \(SilkStrings.isOpenFor) 15 \(SilkStrings.minutes).",
                         door: "Instagram", minutes: 15)
        // A row label, typed back, is the same shape: a door and no duration.
        expectWriteItOut("Instagram, \(SilkStrings.inUse)", door: "Instagram", minutes: nil)
        expectWriteItOut("Reddit, \(SilkStrings.open) till 4:52", door: "Reddit", minutes: nil)
        // The balance sentences are questions about the balance.
        #expect(parse("0 \(SilkStrings.leftToday).") == .command(.status))
        #expect(parse("40 \(SilkStrings.minLeftToday)") == .command(.status))
        // The window sentences read the window back, and the greeting's own
        // hour is the hour it was rendered from — so the setter it compiles to
        // is the window as it stands.
        #expect(parse("\(SilkStrings.downHoursOpens) 7:00 AM.") == .command(.downHoursQuery))
        expectNeverLoosensInstantly("\(SilkStrings.downHoursAt) 10.")
        guard case .command(.setDownHoursStart(let t)) = parse("\(SilkStrings.downHoursAt) 10.")
        else {
            Issue.record("the greeting typed back was \(parse("\(SilkStrings.downHoursAt) 10."))")
            return
        }
        #expect(t == makeState().downHours.start, "the greeting echoes the window it was drawn from")
    }

    /// AND THE ONE SENTENCE THAT IS MEANT TO GRANT STILL DOES — on every shape
    /// of door name, which is the loop the design rests on.
    @Test(arguments: ["Instagram", "TikTok", "Google Maps", "Go"])
    func onlyTheWrittenOutSentenceGrants(_ name: String) {
        let hint = SilkStrings.writeItOut(name, minutes: 25)
        let typed = String(hint.dropFirst(SilkStrings.writeItOut.count))
            .trimmingCharacters(in: .whitespaces)
        expectSpend(typed, door: name, minutes: 25, twoWordState())
    }
}
