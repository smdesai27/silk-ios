import Foundation
import Testing
@testable import SilkCore

// THE THIRD ADVERSARIAL ROUND ON THE SPEND SHAPE.
//
// Round one attacked the tightening that made a door and a number stop
// minting minutes; round two attacked the seams four commits of widening had
// opened. This round attacks the one thing both left standing: the sentences
// in which the door, the number and the opening verb are all present and
// correct, and the sentence still is not an ask.
//
// Five defects, one class each, and the class is the same each time — the
// grammar read the WORDS of an ask and not its MOOD:
//
//   D3  a doorless ask borrowed its door from the clause that restricted it
//       ("block tiktok, give me 20 minutes" → 20 minutes of TikTok);
//   D4  a negator one word further off than adjacency stopped refusing
//       ("i never said give me 20 minutes of tiktok" → 20 minutes of TikTok);
//   D5  a report frame in front of the ask's own verb stopped being a report
//       as soon as the door stood inside the quote ("she said unlock tiktok
//       for 20" → 20 minutes of TikTok);
//   D7  a first-person deliberation bought the request modal's exemption
//       ("should i unlock tiktok for 20" → 20 minutes of TikTok);
//   D8  a commitment retracted with any of English's ordinary cancelling
//       phrases kept its minutes ("i'm using instagram for 5 minutes, scratch
//       that" → 5 minutes of Instagram).
//
// The doctrine is unchanged from rounds one and two, and every rule below was
// written under it:
//
//   - a wrong GRANT is the unrecoverable direction — minutes leave the pool,
//     the wall comes down, and canon will not put either back;
//   - SILENCE is the widener's and is always an acceptable answer;
//   - every widening of a GRANT path hijacks prose, so nothing here widens
//     one: all five rules are REFUSALS, and every list they read is
//     refusal-only;
//   - and each rule was attacked with counter-sentences until a round came
//     back clean. The sentences that MUST KEEP GRANTING are pinned in this
//     file beside the ones that must not, because a guard that eats asks is
//     how a widening pays for itself twice.
//
// COLLATERAL IS DECLARED, NOT DISCOVERED. Three sections carry a row that
// falls silent and did not have to: each is an ask wearing a refusal's
// clothes, each is recoverable (the user types the sentence again, nothing
// was debited), and each is written down here with the reason rather than
// left for the next round to find.

// MARK: - Fixtures

/// The round-2 helpers, copied rather than shared: each of those is `private`
/// to its own file, and a test helper that grows a second caller grows a
/// second set of expectations with it.
private func validate(_ text: String, _ state: PolicyState = makeState(),
                      ledger: GrantLedger = GrantLedger()) -> Verdict {
    Validator.validate(parse(text, state), utterance: text, state: state,
                       ledger: ledger, now: afternoon(), calendar: cal)
}

/// The one assertion this file is built on, and both earlier rounds': a row
/// may be silence, may be a hint, may be a rule change — what it may never be
/// is minutes.
private func expectNoMinutes(_ text: String, _ why: String,
                             _ state: PolicyState = makeState(),
                             _ location: SourceLocation = #_sourceLocation) {
    if case .command(.spend(let d, let m)) = parse(text, state) {
        Issue.record("\"\(text)\" spent \(m) on \(d.name) — \(why)",
                     sourceLocation: location)
    }
}

/// And the sentences that must not even be answered with the sentence that
/// would open the app.
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
    expectNoHint(text, why, state, location)
    let outcome = parse(text, state)
    guard outcome != .silence else { return }
    Issue.record("\"\(text)\" was \(outcome), not the widener's — \(why)",
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

// MARK: - D3. A restriction does not lend its door

/// **DEFECT 3 — the doorless ask borrowed its door from the clause that
/// refused it.**
///
/// "block tiktok, give me 20 minutes" opened TikTok for twenty minutes. Both
/// halves of that are wrong at once: the close was dropped and the app the
/// sentence asked to shut was opened instead.
///
/// Two failures compound. `hasClosingVerb` lets an OPENER outrank a CLOSER —
/// the rule that keeps the substring "lock" inside "unlock" from flipping a
/// polarity — so "give" in the second breath vetoed "block" in the first and
/// no close was compiled. Then rule 7 found an ask clause naming no door, fell
/// back to the sentence's one door, and took it from the only clause that
/// named one: the refusal.
///
/// The gate is `aRestrictionLendsTheDoor`, and it reads the DONOR clause —
/// every breath except the one carrying the quantity — for a restriction word
/// (`lessWords` minus the ceiling nouns) or, under a negator, for a ceiling
/// noun.
@Suite struct ARestrictionDoesNotLendItsDoor {

    @Test(arguments: [
        ("block tiktok, give me 20 minutes", "the close was dropped and the door opened"),
        ("block tiktok, unlock tiktok for 20", "the same, with the door named twice"),
        ("close tiktok, give me 20 minutes of tiktok", "the ask names the door the close names"),
        ("i want less tiktok, give me 20 minutes", "a comparative is a restriction"),
        ("i want less tiktok, unlock tiktok for 20", "the same, spelled with Silk's own verb"),
        ("id like less tiktok, give me 20 minutes", "the polite comparative"),
        ("less tiktok please, give me 20 minutes", "the bare comparative, no verb at all"),
        ("i should quit tiktok, unlock tiktok for 20", "a stopping verb is a restriction"),
        ("i deleted tiktok, give me 20 minutes", "a door reported gone lends nothing"),
        ("i need a break from tiktok, i'd like 20 minutes", "\"break from\" is the phrase"),
        ("i want the tiktok cap lower, give me 20 minutes", "\"lower\" restricts"),
        ("the tiktok cap should be lower, give me 20 minutes", "the same, as a copula"),
        ("never raise the tiktok cap, give me 20 minutes", "a negated ceiling is a standing rule"),
        ("dont touch the tiktok cap, give me 20 minutes", "the same, in the commonest spelling"),
        ("dont remove the tiktok cap, give me 20 minutes", "the negator carries the ceiling noun"),
        ("no more tiktok, give me 20 minutes", "a close spelled with the negator is a close"),
        ("im done with tiktok, give me 20 minutes", "the same, another closing phrase"),
        ("i decided to block tiktok, give me 20 minutes", "a decision stated is not the past"),
        ("i had to block tiktok, give me 20 minutes", "an infinitive on the word is the imperative"),
        ("i was going to block tiktok, give me 20 minutes", "the same, through a plan"),
        ("block tiktok since i was weak, give me 20 minutes", "the past stands after the word"),
        ("tiktok must be kept off, give me 20 minutes", "a participle is tense-neutral"),
        ("tiktok is kept blocked, give me 20 minutes", "the same, present"),
        ("im kept off tiktok by the app, give me 20 minutes", "the same, first person"),
        ("was the block on tiktok, give me 20 minutes", "a determiner between reads the noun"),
        ("i stayed off tiktok all day, unlock tiktok for 20", "a report of the past — silent, knowingly"),
        ("tiktok was blocked all day, unlock tiktok for 20", "the same — silent, knowingly"),
        ("ive been off instagram since monday, unlock instagram for 10", "the same — silent, knowingly"),
        ("i kept tiktok closed all morning, give me 20 minutes", "the same — silent, knowingly"),
        ("tiktok was blocked and still is, give me 20 minutes", "the past with the present beside it"),
        ("close to nothing on tiktok, give me 20 minutes", "\"close to\" without a ceiling noun is the close"),
        ("keep tiktok close to zero, give me 20 minutes", "the same, as an imperative"),
        ("close to tiktok, give me 20", "the same, bare"),
    ])
    func aClauseThatRestrictsTheDoorIsNoDonor(_ row: (text: String, why: String)) {
        expectSilence(row.text, row.why)
    }

    /// AND THE CONTROLS THE DEFECT WAS MEASURED AGAINST. "limit tiktok, give
    /// me 20 minutes" and "cap tiktok, give me 20 minutes" were already
    /// silent — the ceiling family claims those and terminates — which is how
    /// the hole was found: it was exactly the restriction vocabulary the cap
    /// rules do not own.
    @Test(arguments: [
        "limit tiktok, give me 20 minutes",
        "cap tiktok, give me 20 minutes",
    ])
    func theCeilingFamilysOwnSentencesWereAlreadySilent(_ text: String) {
        expectSilence(text, "the ceiling family terminates on these, and did before")
    }

    /// **THE ROWS THIS RULE MAY NOT EAT.** Every one of them names a door in
    /// a breath other than the ask's, which is the shape the guard reads, and
    /// every one is an ask.
    ///
    ///  - a NEGATED restriction is the restriction being refused: "dont close
    ///    instagram, just give me 10" is pinned in three suites, and it is why
    ///    the vocabulary arm requires an UNNEGATED clause and the ceiling
    ///    nouns require a negated one;
    ///  - a negated PREAMBLE that restricts nothing still asks: "i dont use
    ///    instagram much, unlock instagram for 10";
    ///  - a ceiling NAMED is not a ceiling IMPOSED: "im at my limit on tiktok"
    ///    is the speaker's own state, and its sentence is the corpus's pinned
    ///    grant — which is the whole reason `restrictionWords` subtracts
    ///    `capNouns` from `lessWords`;
    ///  - a restriction naming ANOTHER door lends nothing about this one;
    ///  - and the ask's OWN breath is never the donor: "give me 20 minutes off
    ///    tiktok" spells a restriction word where it is a preposition.
    @Test(arguments: [
        ("dont close instagram, just give me 10", "Instagram", 10),
        ("i dont use instagram much, unlock instagram for 10", "Instagram", 10),
        ("im at my limit on tiktok, give me 20 minutes", "TikTok", 20),
        ("give me 20 minutes of tiktok, im at my limit on tiktok", "TikTok", 20),
        ("ive hit my limit give me 20 of tiktok", "TikTok", 20),
        ("unlock tiktok for 20, i just blocked instagram", "TikTok", 20),
        ("give me 20 minutes off tiktok", "TikTok", 20),
        ("give my tiktok a break, 20 minutes", "TikTok", 20),
        ("give tiktok a 20 minute break", "TikTok", 20),
        ("i closed my laptop, give me 20 minutes of tiktok", "TikTok", 20),
        ("block the noise, give me 20 minutes of tiktok", "TikTok", 20),
        ("im close to my tiktok limit, give me 20 minutes", "TikTok", 20),
    ])
    func theAsksBesideARestrictionStillLand(_ row: (String, String, Int)) {
        expectSpend(row.0, door: row.1, minutes: row.2)
    }

    /// AND THE VALIDATOR AGREES WITH THE GRAMMAR. A refusal that compiles to
    /// silence must not become a grant one layer up.
    @Test func theRefusedBorrowNeverReachesAVerdict() {
        #expect(validate("block tiktok, give me 20 minutes") == .silence)
        #expect(validate("never raise the tiktok cap, give me 20 minutes") == .silence)
    }
}

// MARK: - D4. The negator's window is the clause

/// **DEFECT 4 — a negator one word off the verb stopped refusing.**
///
/// `aNegatorRefusesTheAsk` read ADJACENCY: the negator standing directly on
/// the opening verb, with "ever" the single word allowed between them. English
/// does not put them that close when it refuses across a verb of speech or of
/// promise, and each of these opened the door and debited the pool.
///
/// The window is now the negator's own CLAUSE, walked forward to the first
/// opening verb in it. The clause bound is what keeps it honest — it is the
/// same bound the adjacency test already carried — and the bounded-ask carve
/// ("dont give me MORE THAN 10") is untouched.
@Suite struct TheNegatorsWindowIsTheClause {

    @Test(arguments: [
        ("i never said give me 20 minutes of tiktok", "a negator across a speech verb"),
        ("i never said unlock tiktok for 20", "the same, with Silk's own verb"),
        ("i never say unlock tiktok for 20", "the present tense of it"),
        ("never again unlock tiktok for 20", "one adverb of distance"),
        ("i would never say give me 20 minutes of tiktok", "a modal and a speech verb"),
        ("i shouldnt say unlock tiktok for 20", "a contraction two words off"),
        ("i refuse to unlock tiktok for 20", "the lexical negator and an infinitive"),
        ("i promised not to unlock tiktok for 20", "a negated promise"),
        ("remind me never to unlock tiktok for 20", "a negated instruction to Silk"),
        ("nobody should unlock tiktok for 20", "the lexical negator with a modal"),
        ("dont say give me 20 minutes of tiktok", "a negated speech act"),
        ("i dont want 20 minutes of tiktok", "a negated volition with the minutes in its breath"),
        ("i dont want to unlock tiktok for 20", "the same, through an infinitive"),
        ("i never said unlock tiktok, give me 20 minutes", "the refused breath names the door"),
        ("i promised not to unlock tiktok, give me 20 minutes", "the same, through a promise"),
        ("i told you not to unlock tiktok, give me 20 minutes", "the same, told"),
        ("i dont want any tiktok, unlock tiktok for 20", "a negated volition naming the door"),
        ("i dont need more tiktok, give me 20 minutes", "the same, comparative"),
        ("i never said unlock it, give me 20 minutes of tiktok", "a pronoun stands for the door"),
        ("i promised not to unlock it, give me 20 minutes of tiktok", "the same, through a promise"),
        ("i dont want it, unlock tiktok for 20", "a preamble that negates something else — silent, knowingly"),
        ("i dont want to give up, unlock tiktok for 20", "the same — silent, knowingly"),
        ("i dont really have time, unlock tiktok for 20", "the same — silent, knowingly"),
        ("i never said unlock the app, give me 20 minutes of tiktok", "the door by any other name"),
    ])
    func aNegatorAnywhereAheadOfTheVerbRefuses(_ row: (text: String, why: String)) {
        expectSilence(row.text, row.why)
    }

    /// **THE ROWS THIS WIDENING MAY NOT EAT.** A negator whose clause holds no
    /// opening verb governs something else, and the ask in the next breath is
    /// none of its business — which is the property the adjacency test bought
    /// and this one has to keep.
    @Test(arguments: [
        ("dont close instagram, just give me 10", "Instagram", 10),
        ("dont get mad, give me 10 minutes of instagram", "Instagram", 10),
        ("dont give me more than 10 of tiktok", "TikTok", 10),
        ("i dont use instagram much, unlock instagram for 10", "Instagram", 10),
        ("i wont be long, give me 20 minutes of tiktok", "TikTok", 20),
        ("no rush, give me 20 minutes of tiktok", "TikTok", 20),
        ("never mind, give me 20 minutes of tiktok", "TikTok", 20),
        ("i cant believe it, unlock tiktok for 20", "TikTok", 20),
        ("i dont care, just unlock tiktok for 20", "TikTok", 20),
    ])
    func aNegatorGoverningSomethingElseLeavesTheAskAlone(_ row: (String, String, Int)) {
        expectSpend(row.0, door: row.1, minutes: row.2)
    }

    /// **COLLATERAL, DECLARED (severity 4).** The comma is what ends a
    /// negator's clause, and a preamble typed without one now shares the ask's
    /// breath. These are asks and they fall silent; the same sentences with
    /// the pause still grant, and they are pinned above. Silence is
    /// recoverable — nothing is debited and she types it again — and a grant
    /// out of a refusal is not, so the round takes this trade rather than
    /// narrowing the window back to a width English does not use.
    ///
    /// **Delete a row when somebody closes it** — what would close them is a
    /// theory of which verb a negator governs, which is a class and not this
    /// defect.
    @Test(arguments: [
        "i dont care just unlock tiktok for 20",
        "dont worry give me 20 minutes of tiktok",
    ])
    func aPreambleWithoutItsCommaFallsSilent(_ text: String) {
        expectSilence(text, "the negator shares the ask's breath — declared collateral")
    }

    /// AND THE BOUNDED ASK IS STILL BOUNDED, both ways. "dont give me more
    /// than 10" negates the exceeding and grants; "never open instagram for
    /// more than 20 minutes" is a standing rule and does not.
    @Test func theBoundedAskCarveSurvivesTheWiderWindow() {
        expectSpend("dont give me more than 10 of tiktok", door: "TikTok", minutes: 10)
        expectSilence("never open instagram for more than 20 minutes",
                      "a durative negator states a rule, and granting its number is wrong twice")
    }
}

// MARK: - D5. A quoted ask is not an ask

/// **DEFECT 5 — the report frame stopped counting once the door was inside
/// the quote.**
///
/// "she said give me 20 minutes" names no door and is silent for want of one.
/// Put the door in the quote and every one of these opened the app: the gate
/// that should have caught them (`reportsRatherThanSpends`' quoted-speech arm)
/// demands a RESUMING frame — a copula closing the quote — and a report that
/// simply never resumes had no proof against it. The resumption was the
/// evidence; the frame is the fact.
///
/// `aReportFramesTheAsk` reads a reporting speech verb, or a wish, standing in
/// front of any opening verb, in that verb's own breath — every breath, not
/// only the one that carries the minutes: a frame confined to the ask's breath
/// was tried and attacked out, and the quote in a preamble is the price.
@Suite struct AQuotedAskIsNotAnAsk {

    @Test(arguments: [
        ("she said unlock tiktok for 20", "third person, past"),
        ("he said give me 20 minutes of tiktok", "the same with Silk's other verb"),
        ("the note said unlock tiktok for 20", "an inanimate reporter"),
        ("my journal says i want 20 minutes of tiktok", "a quoted volition"),
        ("he keeps saying unlock tiktok for 20", "the progressive"),
        ("i keep saying unlock tiktok for 20", "the same, first person"),
        ("my friend says open tiktok for 20", "third person, present"),
        ("my therapist suggested unlock tiktok for 20", "the RECOMMEND family reports too"),
        ("the app told me to unlock tiktok for 20", "TELL with an infinitive"),
        ("i almost said unlock tiktok for 20", "an adverb between subject and frame"),
        ("you always say unlock tiktok for 20", "second person, habitual"),
        ("last week i said give me 20 minutes of tiktok", "a fronted time phrase"),
        ("stop saying give me 20 minutes of tiktok", "an imperative ABOUT the quote"),
        ("i hate that i say give me 20 minutes of tiktok", "the quote as a complement"),
        ("the tiktok cap exists because i say give me 20 minutes", "the quote as a reason"),
        ("i wish i could unlock tiktok for 20", "a wish reports as surely as a said"),
        ("she said give me tiktok, 20 minutes", "the quoted ask names the door, its minutes follow"),
        ("my mom said unlock tiktok, 20 minutes", "the same, with Silk's own verb"),
        ("she said use it, 20 minutes of tiktok", "a pronoun stands for the door"),
        ("my mom said give it up, unlock tiktok for 20", "a quote in a preamble — silent, knowingly"),
        ("the doctor told me to have lunch, unlock tiktok for 20", "the same — silent, knowingly"),
        ("she said use the app, 20 minutes of tiktok", "the door by any other name"),
    ])
    func aFrameInFrontOfTheAsksVerbTerminates(_ row: (text: String, why: String)) {
        expectSilence(row.text, row.why)
    }

    /// **THE ONE RE-PINNED GRANT OF THIS ROUND.** "my friend said give me an
    /// hour of tiktok" was pinned in `ProseHijackTests` and in the R3 fuzz
    /// corpus as a GRANT, defended as the user ADOPTING somebody else's ask on
    /// the evidence that the quote never resumes. It is the same sentence as
    /// "my friend says open tiktok for 20" with an idiom for its quantity, and
    /// no rule silences one and mints the other without a hole in the shape of
    /// the word "hour". Canon decides it: a report gets terminating silence.
    /// Its doorless twin, "my friend said give me an hour", was already
    /// silent, and now the two compile alike.
    ///
    /// "i said unlock tiktok for 20" goes with it, and is the row the defect
    /// report named as expected collateral.
    @Test(arguments: [
        "my friend said give me an hour of tiktok",
        "i said unlock tiktok for 20",
    ])
    func theAdoptedQuoteWasReadAsAReportInstead(_ text: String) {
        expectSilence(text, "re-pinned: a report gets terminating silence")
    }

    /// **THE ROWS THIS RULE MAY NOT EAT.**
    ///
    /// The WRITING families are off this gate's lexicon on purpose
    /// (`reportingSpeechVerbs`): "write it out: …" is Silk's OWN hint sentence
    /// echoed back at it, and "text me later" is something a person says TO
    /// the app. Reporting a sentence and asking for one to be written out are
    /// opposite moods wearing one lexeme, and the first cut of this gate ate
    /// the app's own vocabulary.
    ///
    /// A frame in ANOTHER breath frames nothing, and a frame AFTER the ask is
    /// an attribution of a breath already spoken.
    @Test(arguments: [
        ("write it out: unlock tiktok for 20", "TikTok", 20),
        ("write it out unlock tiktok for 10 min", "TikTok", 10),
        ("text me later, unlock tiktok for 20", "TikTok", 20),
        ("tell me when, give me 20 minutes of tiktok", "TikTok", 20),
        ("i told you, give me 20 minutes of tiktok", "TikTok", 20),
        ("say less, give me 20 minutes of tiktok", "TikTok", 20),
        ("give me 20 minutes of tiktok, she said", "TikTok", 20),
        ("she said get ready, unlock tiktok for 20", "TikTok", 20),
    ])
    func aFrameInAnotherBreathFramesNothing(_ row: (String, String, Int)) {
        expectSpend(row.0, door: row.1, minutes: row.2)
    }

    /// AND THE CONDITIONAL IS NOT THE WISH. Round two recorded five inherited
    /// rows under "delete the row when somebody closes it"; this round closed
    /// exactly one of them — the wish — because a wish is a REPORT and the
    /// gate that reads reports could take it. The conditional and the plan for
    /// tomorrow still need the mood gate to learn the conditional clause and
    /// the future, which is a class and not this defect. They still grant.
    @Test(arguments: [
        "i'd like 10 minutes of instagram tomorrow",
        "i would use instagram for 10 minutes if i could",
        "i'd use instagram for 10 minutes if i could",
        "id use instagram for 10 minutes if i could",
    ])
    func theConditionalStillGrants(_ text: String) {
        expectSpend(text, door: "Instagram", minutes: 10)
    }
}

// MARK: - D7. A deliberation is not an ask

/// **DEFECT 7 — the deliberative modal bought the request modal's
/// exemption.**
///
/// "should i unlock tiktok for 20" opened TikTok. "should" sits on
/// `requestModals` — it has to, because the cap family's pinned setter is "my
/// tiktok limit SHOULD be 20 a day" — and that exemption is the one thing
/// standing between an ordinary report and rule 7's mint.
///
/// The split is the ADDRESSEE, and nothing else: "should i" asks the speaker
/// herself, and Silk answers questions about the balance and nothing else;
/// "would you" asks the app, and a request modal wrapping an instruction to
/// the app is exactly the politeness the exemption exists for.
@Suite struct ADeliberationIsNotAnAsk {

    @Test(arguments: [
        "should i unlock tiktok for 20",
        "should i unlock tiktok for 20?",
        "should i give me 20 minutes of tiktok",
        "should we unlock tiktok for 20",
    ])
    func theFirstPersonDeliberationTerminates(_ text: String) {
        expectSilence(text, "the answer to \"should i\" is not twenty minutes")
    }

    /// AND THE POLITE ASK KEEPS ITS EXEMPTION, decided by reading
    /// `requestModals`' own doc: a request modal is how English wraps an
    /// INSTRUCTION in politeness, and these are instructions to the app.
    /// "would you unlock tiktok for 20?" is left granting deliberately.
    @Test(arguments: [
        ("would you unlock tiktok for 20?", "TikTok", 20),
        ("could you give me 20 minutes of tiktok", "TikTok", 20),
        ("can i have 20 minutes of tiktok", "TikTok", 20),
        ("could i have 20 minutes of tiktok", "TikTok", 20),
        ("may i have 20 minutes of tiktok", "TikTok", 20),
    ])
    func thePoliteAskStillGrants(_ row: (String, String, Int)) {
        expectSpend(row.0, door: row.1, minutes: row.2)
    }

    /// **NOT CLOSED, AND RECORDED RATHER THAN GUESSED AT.** "i should unlock
    /// tiktok for 20" is the same deliberation with the pronoun in front of
    /// the modal instead of behind it, and it still grants. The rule is the
    /// INVERSION — "should i" — because that is the shape English deliberates
    /// in and the shape the defect was reported in; a rule keyed on "should"
    /// anywhere would refuse "my tiktok limit should be 20 a day" one family
    /// over. **Delete the row when somebody closes it.**
    @Test func theUninvertedDeliberationStillGrants() {
        expectSpend("i should unlock tiktok for 20", door: "TikTok", minutes: 20)
    }
}

// MARK: - D8. A retraction need not negate anything

/// **DEFECT 8 — the commitment frame's retraction vocabulary knew only
/// negation.**
///
/// `isARetraction` proves a retraction by finding a negator or a spoken
/// decline in the clause. The commonest ways English takes a sentence back
/// carry neither, so a plan the sentence itself cancels minted its minutes:
/// the door opened and the pool was debited for five minutes of Instagram the
/// user had just called off.
///
/// The fix is `retractionPhrases` — a closed class of PHRASES, read only from
/// `isARetraction`, which is read only from `aLaterClauseRetractsIt`, whose
/// only power is to turn a commitment-framed grant into the silence it was
/// before the frame existed. A phrase seated there can never mint a minute.
///
/// Phrases and not tokens, for the reason "break" is kept off `lessWords`:
/// "forget", "cancel", "ignore", "wait" and "back" are ordinary words of
/// ordinary sentences, and only the whole phrase, heading its own breath,
/// cancels anything.
@Suite struct ARetractionNeedNotNegateAnything {

    @Test(arguments: [
        ("i'm using instagram for 5 minutes, scratch that", "the commonest of them"),
        ("i'm using instagram for 5 minutes, forget it", "and the second commonest"),
        ("i'm using instagram for 5 minutes, cancel that", "the explicit one"),
        ("i'm using instagram for 5 minutes, ignore that", "addressed to the machine"),
        ("i'm using instagram for 5 minutes, disregard that", "the formal register"),
        ("i'm using instagram for 5 minutes, just kidding", "with its adverb"),
        ("i'm using instagram for 5 minutes, kidding", "and without"),
        ("i'm using instagram for 5 minutes, i changed my mind", "the whole sentence"),
        ("i'm using instagram for 5 minutes, i take it back", "the idiom"),
        ("i'm using instagram for 5 minutes, undo", "the app's own word"),
        ("i'm using instagram for 5 minutes, wait", "the hesitation"),
        ("i'm using instagram for 5 minutes, not really", "negates, but \"really\" was not vocabulary"),
        ("i'm using instagram for 5 minutes, on second thought no",
         "negates, but the phrase in front of it was not"),
    ])
    func aCancelledCommitmentMintsNothing(_ row: (text: String, why: String)) {
        expectSilence(row.text, row.why)
    }

    /// AND A COMMA IS NOT A RULE — the veto's own words, which the phrase
    /// class had to be taught a second time: the walk back over retraction
    /// VOCABULARY stops on "that", so the comma-less spelling kept granting
    /// while the comma-ed one went silent. One phrase is allowed to end where
    /// that walk stopped.
    @Test(arguments: [
        "im using instagram for 5 minutes scratch that",
        "im using instagram for 5 minutes forget it",
        "i'm using instagram for 5 minutes i changed my mind",
        "i'm using instagram for 5 minutes i take it back",
    ])
    func theSameSentenceWithoutItsPauseAlsoRetracts(_ text: String) {
        expectSilence(text, "the punctuation dependency this veto refuses to have")
    }

    /// **THE ROWS THIS CLASS MAY NOT EAT.** A second thought about something
    /// OTHER than the ask is not a retraction, a bound is not a cancellation,
    /// and a plain imperative cannot be retracted at all — what can be taken
    /// back is what was only ever promised.
    @Test(arguments: [
        ("i'm using instagram for 5 minutes, not tiktok", "Instagram", 5),
        ("i'm using instagram for 5 minutes, no more than that", "Instagram", 5),
        ("i'm using instagram for 5 minutes, ok", "Instagram", 5),
        ("i'm using instagram for 5 minutes, thanks", "Instagram", 5),
        ("i'm using instagram for 10 minutes no more", "Instagram", 10),
        ("unlock instagram for 10 min, no", "Instagram", 10),
        ("give me 10 minutes of instagram, no i wont", "Instagram", 10),
    ])
    func aSecondThoughtAboutSomethingElseStillSpends(_ row: (String, String, Int)) {
        // "i'm using instagram for 10 minutes no more" is a CLOSE, not a
        // spend: "no more" is a closing phrase and the hoisted close claims
        // it. What matters here is only that the retraction class did not
        // reach past the ask and eat it — so the row asserts the outcome the
        // grammar had before this round, whichever rule owns it.
        if row.0 == "i'm using instagram for 10 minutes no more" {
            #expect(parse(row.0) == .command(.closeDoorToday(door: instagram, until: nil)),
                    "\"\(row.0)\" -> \(parse(row.0))")
            return
        }
        expectSpend(row.0, door: row.1, minutes: row.2)
    }

    /// AND THE FRAME ITSELF IS UNTOUCHED: both commitment spellings still
    /// grant when nothing takes them back.
    @Test(arguments: [
        ("i'm using instagram for 5 minutes", "Instagram", 5),
        ("i'm going on instagram for 10 minutes", "Instagram", 10),
        ("i'll use instagram for 10 minutes", "Instagram", 10),
    ])
    func theUnretractedCommitmentStillGrants(_ row: (String, String, Int)) {
        expectSpend(row.0, door: row.1, minutes: row.2)
    }
}

// MARK: - The floor

/// THE HOT PATH IS THE FLOOR, and five refusals in one round is exactly when
/// it needs restating. Every sentence here is somebody asking Silk for
/// minutes, in the spellings the design ships and the corpus pins, and not one
/// of the five rules above may touch any of them.
@Suite struct TheHotPathSurvivesTheThirdRound {

    @Test(arguments: [
        ("give me 20 minutes of tiktok", "TikTok", 20),
        ("give me 20 of tiktok", "TikTok", 20),
        ("unlock tiktok for 20", "TikTok", 20),
        ("open tiktok for 20", "TikTok", 20),
        ("gimme 20 min of tiktok", "TikTok", 20),
        ("let me on tiktok for 20", "TikTok", 20),
        ("i want 20 minutes of tiktok", "TikTok", 20),
        ("i'd like 20 minutes of tiktok", "TikTok", 20),
        ("can i get 20 minutes of tiktok", "TikTok", 20),
        ("can i have twenty minutes of tiktok", "TikTok", 20),
        ("please unlock tiktok for 20", "TikTok", 20),
        ("unlock tiktok for 20 please", "TikTok", 20),
        ("hey, unlock tiktok for 20", "TikTok", 20),
        ("ok so give me 20 minutes of tiktok", "TikTok", 20),
        ("im done with work, give me 20 minutes of tiktok", "TikTok", 20),
        ("i finished my homework, unlock tiktok for 20", "TikTok", 20),
        ("just finished homework give me 20 of tiktok", "TikTok", 20),
        ("its been a rough day gimme fifteen minutes of instagram", "Instagram", 15),
        ("i drank so much coffee, give me 20 minutes of tiktok", "TikTok", 20),
        ("let me have 20 minutes of tiktok, i deserve it", "TikTok", 20),
        ("give me 20 minutes of tiktok, ive been good", "TikTok", 20),
        ("can i get an hour of tiktok, it stole my heart", "TikTok", 60),
        ("give me instagram until i leave the gym, 20 minutes tops", "Instagram", 20),
    ])
    func theAsksTheProductShipsStillGrant(_ row: (String, String, Int)) {
        expectSpend(row.0, door: row.1, minutes: row.2)
    }

    /// AND THE HINT IS STILL A HINT. Rule 8 answers an elliptical ask with the
    /// sentence that would open the app, and none of this round's refusals may
    /// turn one of those into silence unless the sentence asks for LESS.
    @Test(arguments: [
        ("give me tiktok", "TikTok", Int?.none),
        // The mood gate's own pinned row — a request modal marking an ask
        // whose verbless quantity gets the sentence rather than the minutes.
        ("hey so i was thinking maybe like 10 minutes of reddit would be nice",
         "Reddit", Int?.some(10)),
    ])
    func theEllipticalAskIsStillAnsweredWithTheSentence(_ row: (String, String, Int?)) {
        guard case .writeItOut(let d, let m) = parse(row.0) else {
            Issue.record("\"\(row.0)\" was \(parse(row.0)), not a hint")
            return
        }
        #expect(d.name == row.1)
        #expect(m == row.2)
    }
}
