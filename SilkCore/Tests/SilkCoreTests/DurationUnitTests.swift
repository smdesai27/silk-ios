import Testing
import Foundation
@testable import SilkCore

// The unit is part of the number.
//
// Everything in this file pins one class of defect: a sentence that stated its
// duration in a unit the parser did not read, and was therefore answered with a
// number sixty times too small — or with silence, on a sentence that plainly
// named a quantity. None of it was caught by the 438 tests that preceded it,
// because every duration fixture in the suite was already spelled in minutes or
// in one of the article idioms (`an hour`, `half an hour`) that `allNumbers`
// carries by hand.
//
// The two failure directions are not equal and the tests are ordered by which
// one costs more:
//
//   SILENTLY WRONG — "give me 2 hours of tiktok" granted 2 MINUTES, debited the
//   pool, unshielded the door and answered "TikTok is open for 2 minutes." The
//   receipt was honest about what happened and the instruction was not what was
//   asked. The August 2026 fuzz campaign met this sentence and filed it
//   NO_CRASH_ONLY, which is why the corpus stayed green over it for a campaign.
//   Worse on the pool: "set my budget to 2 hours" cut the whole day's allowance
//   to two minutes, and a tightening lands instantly, so nothing but the Undo
//   pill stood between the user and a two-minute day.
//
//   SILENT — "20min of youtube" carried no number at all, because the tokenizer
//   splits on characters and there is nothing between the digits and the unit
//   to split on. The elliptical ask answered "How long?" to a sentence whose
//   whole content was how long.
//
// The last suite is the one that matters most in six months: a clock is still
// not a duration. Everything the unit reading could plausibly have swallowed —
// "until 6", "at ten", "at 2 hours" as a ceiling — is pinned to the answer it
// gave before.

/// A fixed clock, well clear of the down-hours window. A Validator test run at
/// the wall clock's whim is a test that goes red between ten at night and seven
/// in the morning, which is exactly when this suite gets written.
private let durationAfternoon = cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 14))!

private func durationState(budget: Int = 240) -> PolicyState {
    PolicyState(
        budgetMinutes: budget,
        downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
        doors: [Door(name: "Instagram"),
                Door(name: "TikTok"),
                Door(name: "YouTube"),
                Door(name: "Reddit")]
    )
}

/// The four shapes an absurd magnitude can end in, so
/// `anAbsurdMagnitudeSaturatesRatherThanTrapping` can STATE which one each row
/// takes instead of accepting any of them. Named rather than inlined because a
/// `ParseOutcome` literal would need the door, and every `durationState()` mints
/// fresh `Door` ids.
fileprivate enum Shape: Sendable { case spendsIntMax, budgetsIntMax, hint, silence }

private func spend(_ utterance: String, _ state: PolicyState = durationState()) -> (String, Int)? {
    guard case .command(.spend(let door, let minutes)) =
            DeterministicParser.parse(utterance, state: state) else { return nil }
    return (door.name, minutes)
}

@Suite struct HoursAreMinutesTimesSixty {

    /// The defect this file exists for, in its cheapest form. Every one of these
    /// granted its digit as MINUTES before the unit was read.
    @Test(arguments: [
        ("give me 1 hour of tiktok", 60),
        ("give me 1 hr of tiktok", 60),
        ("give me 2 hours of tiktok", 120),
        ("give me 2 hrs of tiktok", 120),
        ("give me two hours of tiktok", 120),
        ("unlock tiktok for 3 hours", 180),
        ("give me 2 h of tiktok", 120),
    ])
    func aStatedHourIsSixtyMinutes(_ row: (utterance: String, minutes: Int)) {
        #expect(spend(row.utterance)?.1 == row.minutes, "\"\(row.utterance)\"")
    }

    /// The idioms are untouched. They hold their quantity in no token at all —
    /// "half an hour" is 30 with no digit anywhere in the sentence — which is
    /// why they had to be spelled out by hand in the first place, and why the
    /// unit reading cannot see them to double them.
    @Test(arguments: [
        ("give me an hour of tiktok", 60),
        ("give me half an hour of tiktok", 30),
        ("give me an hour and a half of tiktok", 90),
        ("give me a quarter of an hour of tiktok", 15),
    ])
    func theIdiomsAreUnchanged(_ row: (utterance: String, minutes: Int)) {
        #expect(spend(row.utterance)?.1 == row.minutes, "\"\(row.utterance)\"")
    }

    /// THE POOL, WHICH IS WHERE IT COST MOST. A budget sentence is standing
    /// policy and a tightening, so it lands instantly and outlives the day.
    @Test(arguments: [
        ("set my budget to 2 hours", 120),
        ("make my budget 2 hours a day", 120),
        ("2 hours a day", 120),
        ("budget of 3 hours", 180),
        ("an hour a day", 60),
        ("half an hour a day", 30),
        ("make it 30 a day", 30),
    ])
    func thePoolReadsHoursToo(_ row: (utterance: String, minutes: Int)) {
        guard case .command(.setBudget(let m)) =
                DeterministicParser.parse(row.utterance, state: durationState()) else {
            Issue.record("\"\(row.utterance)\" did not set the budget")
            return
        }
        #expect(m == row.minutes, "\"\(row.utterance)\"")
    }

    /// PROVENANCE STILL HOLDS. The Validator refuses any grant whose minutes are
    /// not traceable to words the user said, and it asks `allNumbers` the same
    /// question the grammar did. Both sides had to move together or every hours
    /// sentence would parse and then be refused as invented.
    @Test func theValidatorTracesTheScaledNumber() {
        let state = durationState(budget: 240)
        let utterance = "give me 2 hours of tiktok"
        let verdict = Validator.validate(DeterministicParser.parse(utterance, state: state),
                                         utterance: utterance, state: state,
                                         ledger: GrantLedger(), now: durationAfternoon, calendar: cal)
        guard case .grant(let door, let minutes, _) = verdict else {
            Issue.record("expected a grant, got \(verdict)")
            return
        }
        #expect(door.name == "TikTok")
        #expect(minutes == 120)
        #expect(NumberParser.allNumbers(in: utterance).contains(120))
    }

    /// And the clamp still binds it. Two hours against a forty-minute pool is
    /// forty minutes, not a refusal and not a hundred and twenty.
    @Test func anHoursAskClampsToThePool() {
        let state = durationState(budget: 40)
        let utterance = "give me 2 hours of tiktok"
        guard case .grant(_, let minutes, _) =
                Validator.validate(DeterministicParser.parse(utterance, state: state),
                                   utterance: utterance, state: state,
                                   ledger: GrantLedger(), now: durationAfternoon, calendar: cal)
        else {
            Issue.record("expected a clamped grant")
            return
        }
        #expect(minutes == 40)
    }
}

@Suite struct AGluedUnitIsRead {

    /// "20min" and "2h" were split into a number and a unit for one round,
    /// taken back out, and are now read again — and the reason it is safe
    /// now is the reason it was not then. The worry was reach: "give me
    /// tiktok, its 2h until dinner" states no duration FOR THE DOOR, and a
    /// glued unit legible inside prose made it a two-hour ask. That sentence
    /// is a two-number ambiguity today only when a second number stands
    /// beside it, and the spaced spelling ("its 2 hours until dinner") was
    /// read that way all along; the glued one now behaves the same instead
    /// of differently. On the other side of the trade stands the sentence a
    /// thumb actually types — "unlock instagram for 10min" — which was
    /// answered "Write it out: unlock Instagram for 10 min.", a hint telling
    /// her to write what she believed she had just written. NumberParser
    /// .gluedUnit peels only the units the parser reads, so "9GAG" keeps its
    /// name.
    @Test(arguments: [("give me 20min of youtube", 20), ("give me 45m of youtube", 45),
                      ("give me 2h of youtube", 120), ("give me 90m of youtube", 90)])
    func aGluedDurationIsTheDurationItSpells(_ row: (utterance: String, minutes: Int)) {
        #expect(spend(row.utterance)?.1 == row.minutes, "\"\(row.utterance)\"")
    }

    /// And a glued duration in an ASIDE is a second number now, exactly as
    /// the spaced spelling always was: two numbers is the ambiguity the
    /// grammar refuses, and the sentence is the widener's.
    @Test(arguments: [
        "give me 20 of tiktok, ill be done in 5m",
        "give me 30 of instagram, my meeting is in 15m",
        "give me 20 of tiktok, its 2h until dinner",
    ])
    func anAsideWithAGluedDurationIsTwoNumbers(_ utterance: String) {
        #expect(DeterministicParser.parse(utterance, state: durationState()) == .silence, "\"\(utterance)\"")
    }

    /// The spaced spellings carry the same meaning and are read.
    @Test(arguments: [("give me 20 min of youtube", 20), ("give me 20 minutes of youtube", 20),
                      ("give me 2 hours of youtube", 120)])
    func theSpacedSpellingsStillRead(_ row: (utterance: String, minutes: Int)) {
        #expect(spend(row.utterance)?.1 == row.minutes, "\"\(row.utterance)\"")
    }
}

@Suite struct AHundredIsRefusedRatherThanRead {

    /// "one hundred minutes" used to grant ONE — the tens/units tables carry no
    /// hundred, so the leading word won and the rest of the number went on the
    /// floor. Reading it properly was tried and taken back out: the quantity a
    /// "hundred" phrase states occupies NO SINGLE TOKEN, and three separate
    /// position tests in the grammar are per-token and went blind to it —
    /// `capSet`'s number scan (so "keep tiktok under a hundred minutes" became
    /// a GRANT, where its digit spelling sets a ceiling), `numberIsNotMinutes`
    /// (so "cap tiktok at two hundred hours" wrote one), and
    /// `numberClauseNamesADoor`. See `NumberParser.hundredPoisons`.
    ///
    /// So the word poisons its phrase: the sentence carries no number, and no
    /// rule that needs one can claim it. When this suite was written that left
    /// the elliptical ask, which ANSWERED "How long?"; the spend-shape
    /// tightening replaced that question with the hint ("Write it out: unlock
    /// Reddit for 10 min."), and these rows are pinned to what the grammar
    /// does now. Either way the point is unchanged: a question, where the old
    /// reading granted a minute and the read version granted a hundred out of
    /// "a hundred percent".
    ///
    /// THE OUTCOME IS STATED, not merely un-refused. What stood here was a
    /// switch that recorded an issue for three command shapes and let every
    /// other outcome through on `default: break` — so a rule that started
    /// silencing "give me a hundred minutes of reddit" outright, losing the
    /// door and the question with it, passed this test. `door` names the door
    /// the hint must carry; nil means the sentence reaches no rule at all.
    @Test(arguments: [
        ("give me a hundred minutes of reddit", "Reddit"),
        ("give me one hundred minutes of reddit", "Reddit"),
        ("give me two hundred minutes of reddit", "Reddit"),
        ("give me tiktok a hundred percent", "TikTok"),
        ("ive told you a hundred times, open reddit", "Reddit"),
        // The RESTRICTION phrasings reach no rule: the ceiling clauses need a
        // number and the poisoned phrase carries none, so there is nothing for
        // the fragment rules to hand back either.
        ("keep tiktok under a hundred minutes", nil),
        ("tiktok at most a hundred minutes", nil),
        ("cap tiktok at two hundred hours", nil),
        ("tiktok no more than a hundred minutes a day", nil),
    ])
    func aHundredCarriesNoNumber(_ row: (utterance: String, door: String?)) {
        var state = durationState()
        let tiktok = state.doors.first { $0.name == "TikTok" }!
        state.doorCaps[tiktok.id] = 20
        let outcome = DeterministicParser.parse(row.utterance, state: state)
        guard let name = row.door else {
            #expect(outcome == .silence, "\"\(row.utterance)\" was \(outcome)")
            return
        }
        guard case .writeItOut(let door, let minutes) = outcome else {
            Issue.record("\"\(row.utterance)\" was \(outcome), not the hint")
            return
        }
        #expect(door.name == name)
        // nil minutes is the whole claim: the hundred was not read as one.
        #expect(minutes == nil, "\"\(row.utterance)\" carried \(minutes.map(String.init) ?? "nil")")
    }

    /// And the digit spelling — the one people actually type — is untouched.
    @Test func theDigitSpellingIsUnaffected() {
        #expect(spend("give me 100 minutes of reddit")?.1 == 100)
        #expect(spend("give me 200 minutes of reddit")?.1 == 200)
        guard case .command(.setDoorCap(_, let cap)) =
                DeterministicParser.parse("keep tiktok under 100 minutes", state: durationState()) else {
            Issue.record("the digit ceiling stopped landing")
            return
        }
        #expect(cap == 100)
    }
}

@Suite struct AnApostropheIsNotAWordBoundary {

    /// THE NEGATOR THAT COULD NOT BE REACHED. `tokenize` split on the
    /// apostrophe, so "don't" arrived as ["don", "t"] and matched nothing in
    /// `negators` — while "dont" matched and correctly fell silent. The two
    /// spellings of one sentence therefore did opposite things, and iOS smart
    /// punctuation makes the broken spelling the one users actually type.
    ///
    /// Against a door already capped at ten, the apostrophe spelling wrote a
    /// ceiling of TWENTY out of a sentence refusing one — a loosening, parked
    /// to mature the next morning, out of a refusal.
    @Test(arguments: [
        "dont cap tiktok at 20",
        "don't cap tiktok at 20",
        "don\u{2019}t cap tiktok at 20",     // iOS smart punctuation
        "don\u{02BC}t cap tiktok at 20",     // modifier letter apostrophe
        "i cant do 20 minutes a day on tiktok",
        "i can't do 20 minutes a day on tiktok",
        "i can\u{2019}t do 20 minutes a day on tiktok",
    ])
    func aRefusedCeilingIsNeverWritten(_ utterance: String) {
        var state = durationState()
        let tiktok = state.doors.first { $0.name == "TikTok" }!
        state.doorCaps[tiktok.id] = 10
        let outcome = DeterministicParser.parse(utterance, state: state)
        if case .command(.setDoorCap(_, let minutes)) = outcome {
            Issue.record("\"\(utterance)\" wrote a ceiling of \(minutes.map(String.init) ?? "none")")
        }
    }

    /// The "'t" family, and only it, tokenizes alike either way — which is the
    /// whole mechanism above. Every other apostrophe still splits, so a clitic
    /// glued to a door name cannot erase the door and a contracted copula
    /// cannot be eaten.
    @Test(arguments: [
        ("don't", ["dont"]), ("can't", ["cant"]), ("won't", ["wont"]),
        ("haven't", ["havent"]), ("isn't", ["isnt"]), ("shouldn't", ["shouldnt"]),
        ("tiktok's", ["tiktok", "s"]), ("tiktok'll", ["tiktok", "ll"]),
        ("cap's", ["cap", "s"]), ("who'll", ["who", "ll"]), ("i'm", ["i", "m"]),
    ])
    func onlyTheNegatorsClaimJoins(_ row: (spelling: String, tokens: [String])) {
        #expect(NumberParser.tokenize(row.spelling) == row.tokens)
        #expect(NumberParser.tokenize(row.spelling.replacingOccurrences(of: "'", with: "\u{2019}"))
                == row.tokens, "the smart-punctuation spelling read differently")
    }

    /// A possessive still names its door: the split leaves "tiktok" standing on
    /// its own and the orphaned "s" matches nothing, which is the harmless
    /// direction.
    @Test func aPossessiveDoorStillNamesItsDoor() {
        var state = durationState()
        let tiktok = state.doors.first { $0.name == "TikTok" }!
        state.doorCaps[tiktok.id] = 10
        guard case .command(.setDoorCap(let door, let minutes)) =
                DeterministicParser.parse("remove tiktok's cap", state: state) else {
            Issue.record("the possessive did not name its door")
            return
        }
        #expect(door.name == "TikTok")
        #expect(minutes == nil)
    }
}

@Suite struct AClockIsStillNotADuration {

    /// The regression suite for everything the unit reading could have
    /// swallowed. Each of these carries a number and an hour word or a clock
    /// word, and each must answer exactly what it answered before.
    @Test func statedClocksAreUnmoved() {
        let state = durationState()
        func parse(_ s: String) -> ParseOutcome { DeterministicParser.parse(s, state: state) }

        // A close's stated lift is a clock, not a length.
        guard case .command(.closeDoorToday(_, let until)) = parse("close instagram until 6") else {
            Issue.record("the close lost its hour"); return
        }
        #expect(until == TimeOfDay(hour: 18))

        // The window's edges are clocks.
        #expect(parse("down hours start at ten") == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(parse("down hours end at 6am") == .command(.setDownHoursEnd(TimeOfDay(hour: 6))))

        // A ceiling stated in hours still declines — see `numberIsNotMinutes`
        // on why the DIRECTION, not the reading, is what keeps it there.
        #expect(parse("cap tiktok at 2 hours") == .silence)
        #expect(parse("limit tiktok to 2 hours a day") == .silence)

        // And a ceiling stated in minutes still lands.
        guard case .command(.setDoorCap(_, let cap)) = parse("cap instagram at 15 a day") else {
            Issue.record("the minute ceiling stopped landing"); return
        }
        #expect(cap == 15)
    }

    /// No catalogue name may become a quantity. The unit reading widened what
    /// counts as a number, so the guarantee `LaunchCatalogTests` states for the
    /// old reading is re-asked here for the new one.
    @Test func noCatalogueNameCarriesADuration() {
        for entry in LaunchCatalog.entries {
            for name in entry.names + [entry.display] {
                #expect(NumberParser.allNumbers(in: name).isEmpty,
                        "\"\(name)\" carries a number")
            }
        }
    }
}

// MARK: - What reading the unit exposed

// Widening what counts as a number widened what every rule downstream can see,
// and three of those rules were relying on a spelling they could not read
// rather than on a reading they had made. Each suite below is a defect that
// existed before the unit was read and could only fire on the spellings the
// unit made legible — so each is pinned here, next to the change that surfaced
// it, rather than filed as unrelated.

@Suite struct ARefusalIsNotAnAsk {

    /// **THE WORST SHAPE THERE IS: a grant out of a refusal.** SPEND never
    /// checked for a negator standing on the door, so "no tiktok for 20
    /// minutes" bought twenty minutes of the app the sentence was refusing.
    /// It stayed small only because the hour spellings carried no number —
    /// "no tiktok for 2h" was silent and "no tiktok for 2 hours" granted TWO
    /// MINUTES — so reading the unit turned a two-minute mistake into a
    /// two-hour one. The hole is older than the unit; the unit is how it was
    /// found.
    @Test(arguments: [
        "no tiktok for 2h", "no tiktok for 2 hours", "no tiktok for 20 minutes",
        "no tiktok for 20min", "no tiktok for 3 hrs", "not tiktok for 2h",
        "no tiktok, 2h", "absolutely no tiktok for 2h", "no tiktok for 2h please",
        "no tiktok until 2h", "no tiktok for the next 2 hours",
    ])
    func aDoorWithANegatorOnItIsNeverSpent(_ utterance: String) {
        #expect(DeterministicParser.parse(utterance, state: durationState()) == .silence,
                "\"\(utterance)\" opened the door it refuses")
    }

    /// The negator has to stand ON the door. Where it governs a VERB the
    /// sentence is still an ask, and a clause-wide scan — the first thing tried
    /// here — read four pinned sentences wrong in exactly this way.
    @Test func aNegatorGoverningAVerbLeavesTheAskAlone() {
        let state = durationState()
        #expect(spend("dont give me more than 10 of tiktok", state)?.1 == 10)
        #expect(spend("dont close instagram, just give me 10", state)?.1 == 10)
        #expect(spend("give me no more than 20 of tiktok", state)?.1 == 20)
    }

    /// And a close is still a close. "no more tiktok" is the canonical closing
    /// phrase and it is decided above SPEND, so nothing here can reach it.
    @Test func theCloseIsUnmoved() {
        let state = durationState()
        guard case .command(.closeDoorToday(let d, _)) =
                DeterministicParser.parse("no more tiktok for 1h", state: state) else {
            Issue.record("the canonical close stopped closing")
            return
        }
        #expect(d.name == "TikTok")
    }
}

@Suite struct TheParserNeverTrapsOnAMagnitude {

    /// **A SENTENCE MAY NOT CRASH THE APP.** `scaled` multiplies by 100 and by
    /// 60, and Swift traps on `Int` overflow — so nineteen digits and the word
    /// "hours" was a SIGTRAP in the bar. `everyStringCompilesOrFallsSilentAndNeverTraps`
    /// did not catch it because it fuzzes shapes, not magnitudes.
    ///
    /// It saturates instead: an absurd number of minutes has always parsed and
    /// then been clamped to the balance, and an absurd number of hours is the
    /// same sentence with a unit on it.
    /// THE SATURATED VALUE IS THE ASSERTION, not the absence of a crash.
    ///
    /// "Reaching this line is the assertion" used to stand at the foot of this
    /// body, and a no-crash test is the weakest thing a suite can hold: it
    /// stays green for a reader that starts returning nothing, for one that
    /// truncates to a plausible-looking small number, and for a grammar that
    /// quietly stops claiming these sentences at all. The claim in the doc
    /// above is SATURATION — the multiplier tops out rather than trapping —
    /// and saturation has a value, `Int.max`, which is written down here.
    ///
    /// The rows fall into four shapes, and which shape a row takes is itself
    /// part of the record: an hours multiplier saturates and the sentence goes
    /// on to mean what it says; a "hundred" phrase carries no number at all
    /// (`NumberParser.hundredPoisons`, and the suite above), so the reader
    /// returns nothing and the fragment rules answer with the hint.
    @Test(arguments: [
        ("give me 999999999999999999 hours of tiktok", [Int.max], Shape.spendsIntMax),
        ("give me 153722867280912931 hours of tiktok", [Int.max], Shape.spendsIntMax),
        ("give me 92233720368547759 hundred minutes of tiktok", [], Shape.hint),
        ("give me 9999999999999999 hundred hours of tiktok", [], Shape.hint),
        ("999999999999999999h", [Int.max], Shape.silence),
        ("set my budget to 200000000000000000 hours", [Int.max], Shape.budgetsIntMax),
        ("cap tiktok at 1111111111111111111h a day", [Int.max], Shape.silence),
        ("9223372036854775807 hours", [Int.max], Shape.silence),
        ("9223372036854775807 hundred hundred hours", [], Shape.silence),
    ])
    fileprivate func anAbsurdMagnitudeSaturatesRatherThanTrapping(_ row: (utterance: String,
                                                             numbers: [Int],
                                                             shape: Shape)) {
        #expect(NumberParser.allNumbers(in: row.utterance) == row.numbers,
                "\"\(row.utterance)\" read \(NumberParser.allNumbers(in: row.utterance))")
        let outcome = DeterministicParser.parse(row.utterance, state: durationState())
        switch (row.shape, outcome) {
        case (.spendsIntMax, .command(.spend(let door, let minutes))):
            #expect(door.name == "TikTok")
            #expect(minutes == Int.max)
        case (.budgetsIntMax, .command(.setBudget(let minutes))):
            #expect(minutes == Int.max)
        case (.hint, .writeItOut(let door, let minutes)):
            #expect(door.name == "TikTok")
            #expect(minutes == nil)
        case (.silence, .silence):
            break
        default:
            Issue.record("\"\(row.utterance)\" was \(outcome), not \(row.shape)")
        }
    }

    /// And it is still clamped to what the pool actually holds.
    @Test func anAbsurdAskIsStillJustTheBalance() {
        let state = durationState(budget: 40)
        let utterance = "give me 999999999999999999 hours of tiktok"
        guard case .grant(_, let minutes, _) =
                Validator.validate(DeterministicParser.parse(utterance, state: state),
                                   utterance: utterance, state: state,
                                   ledger: GrantLedger(), now: durationAfternoon, calendar: cal)
        else {
            Issue.record("expected a clamped grant")
            return
        }
        #expect(minutes == 40)
    }
}

@Suite struct TheCapGuardSeesWhatTheReaderSees {

    /// A ceiling stated in hours declines — see `numberIsNotMinutes` on why the
    /// DIRECTION is what keeps it there. The guard used to look only at the
    /// NEXT token, so it could not see a glued "2h", and the one spelling it
    /// could not read was the one that wrote a two-hour ceiling: a LOOSENING,
    /// in the vocabulary of restriction, on a door already capped at ten.
    @Test(arguments: [
        "cap tiktok at 2 hours", "cap tiktok at 2h", "cap tiktok at 2hrs",
        "cap tiktok at 2h a day", "cap tiktok at 2 h a day",
        "i want tiktok capped at 2h", "limit tiktok to 2 hours a day",
        "i want a limit of 2h on tiktok",
    ])
    func noSpellingOfAnHourWritesACeiling(_ utterance: String) {
        var state = durationState()
        let tiktok = state.doors.first { $0.name == "TikTok" }!
        state.doorCaps[tiktok.id] = 10
        if case .command(.setDoorCap(_, let minutes)) =
            DeterministicParser.parse(utterance, state: state) {
            Issue.record("\"\(utterance)\" wrote a ceiling of \(minutes.map(String.init) ?? "none")")
        }
    }

    /// A ceiling stated in minutes still lands, in every spelling.
    @Test func aMinuteCeilingStillLands() {
        let state = durationState()
        for utterance in ["cap tiktok at 20 a day", "limit tiktok to 20 a day", "tiktok 20 a day"] {
            guard case .command(.setDoorCap(_, let m)) =
                    DeterministicParser.parse(utterance, state: state) else {
                Issue.record("\"\(utterance)\" stopped setting a ceiling")
                continue
            }
            #expect(m == 20)
        }
    }
}

@Suite struct AUnitBindsOnlyInsideItsOwnBreath {

    /// A unit binds to the number it stands ON, and a comma is not a space.
    /// `tokenize` erases punctuation, so the unit lookahead used to reach
    /// straight across one: "give me tiktok for 20, hours of homework left"
    /// read its twenty as twenty HOURS.
    @Test func aUnitDoesNotReachAcrossPunctuation() {
        #expect(NumberParser.allNumbers(in: "for 20, hours of homework left") == [20])
        #expect(NumberParser.allNumbers(in: "to 30, hundred things going on") == [30])
        #expect(NumberParser.allNumbers(in: "cap tiktok at 30. hour long videos are killing me") == [30])
        // …and still binds where it really does stand on the number.
        #expect(NumberParser.allNumbers(in: "for 20 hours of homework") == [1200])
    }

    /// Which keeps the grammar and the Validator reading the same sentence: the
    /// grammar reads a number clause-locally and the Validator reads the whole
    /// utterance, so a unit that reaches across a comma makes them disagree and
    /// a cap the grammar just set fails its own provenance check.
    @Test func theGrammarAndTheValidatorAgree() {
        let state = durationState()
        let utterance = "cap tiktok at 20, hours disappear on that thing"
        let outcome = DeterministicParser.parse(utterance, state: state)
        guard case .command(.setDoorCap(_, let minutes)) = outcome else {
            Issue.record("the cap stopped landing: \(outcome)")
            return
        }
        #expect(minutes == 20)
        #expect(NumberParser.allNumbers(in: utterance).contains(20),
                "the Validator would refuse the number the grammar just read")
    }

    /// Word compounding is deliberately NOT bounded the same way: "twenty,
    /// five minutes of tiktok" is still 25. That is the tokenizer's pinned
    /// contract and the fuzz campaign declined to change it on purpose.
    @Test func compoundingStillCrossesAComma() {
        #expect(NumberParser.allNumbers(in: "twenty, five minutes of tiktok") == [25])
    }
}

@Suite struct ThePoolIsNamedByItsStem {

    /// Rule 3's trigger has to be as WIDE as the sentences it must terminate,
    /// and only its decision narrow. "budget" was a bare substring of the whole
    /// utterance, which is how "give me 20 of tiktok, im on a budget" halved the
    /// daily allowance; narrowing it to the exact token went too far the other
    /// way, and a sentence rule 3 does not claim is a sentence some LATER rule
    /// claims. "last week i budgeted 60 for youtube" walked down the ladder, and
    /// "block everything, my budget is 30" lost the veto that keeps a doorless
    /// close off a sentence stating an allowance — closing every door instead.
    @Test func aPoolStemSentenceNeverFallsThrough() {
        for utterance in ["last week i budgeted 60 for youtube",
                          "budgeting 60 for youtube",
                          "my budgets blown, 15 of instagram today"] {
            switch DeterministicParser.parse(utterance, state: durationState()) {
            case .command(.removeDoor(let d)):
                Issue.record("\"\(utterance)\" DELETED the door \(d.name)")
            case .command(.spend(let d, let m)):
                Issue.record("\"\(utterance)\" granted \(m) on \(d.name)")
            default:
                break
            }
        }
    }

    /// The doorless close's veto reads the same stem, so a sentence stating an
    /// allowance is not answered by shutting every door in the product.
    @Test func aSentenceStatingAnAllowanceIsNotACloseOverEverything() {
        let outcome = DeterministicParser.parse("block everything, my budget is 30",
                                                state: durationState())
        if case .command(.closeAllToday) = outcome {
            Issue.record("a budget sentence closed every door")
        }
        #expect(outcome == .command(.setBudget(minutes: 30)))
    }

    /// And the pool still moves only when it owns the number.
    @Test func onlyTheOwnedNumberMovesThePool() {
        #expect(DeterministicParser.parse("give me 20 of instagram, im on a budget",
                                          state: durationState()) == .silence)
        #expect(DeterministicParser.parse("budget of 20", state: durationState())
                == .command(.setBudget(minutes: 20)))
    }
}

@Suite struct ProvenanceAsksWhetherTheHourWasSaid {

    /// The down-hours guards ask "did the user say this hour", and that is
    /// MEMBERSHIP, not identity with the first clock in the sentence. "lock me
    /// out from 10pm to 7am" states two, and a widened end of 07:00 is a correct
    /// reading of it — asking only for the first silenced every two-ended window
    /// sentence the widener can read.
    @Test func aSecondStatedClockIsStillTheUsersOwnWord() {
        let state = durationState()
        let utterance = "lock me out from 10pm to 7am"
        #expect(NumberParser.statedTimes(in: utterance, assumeEvening: false)
                .contains(TimeOfDay(hour: 7)))
        guard case .ruleChange(let proposed, _) =
                Validator.validate(.command(.setDownHoursEnd(TimeOfDay(hour: 7))),
                                   utterance: utterance, state: state,
                                   ledger: GrantLedger(), now: durationAfternoon, calendar: cal) else {
            Issue.record("a stated second hour was refused as invented")
            return
        }
        #expect(proposed.downHours.end == TimeOfDay(hour: 7))
    }

    /// An hour nobody said is still refused, which is the whole point.
    @Test func anUnsaidHourIsStillRefused() {
        let state = durationState()
        #expect(Validator.validate(.command(.setDownHoursEnd(TimeOfDay(hour: 10))),
                                   utterance: "do something about my mornings", state: state,
                                   ledger: GrantLedger(), now: durationAfternoon, calendar: cal) == .silence)
        #expect(Validator.validate(.command(.setDownHoursStart(TimeOfDay(hour: 19))),
                                   utterance: "lock me out from 10pm to 7am", state: state,
                                   ledger: GrantLedger(), now: durationAfternoon, calendar: cal) == .silence)
    }
}

@Suite struct AHyphenIsASpaceToTheUnitReader {

    /// The tokenizer rewrites "-" to a space before it splits, so the grammar's
    /// token stream for "2-hour" is identical to "2 hour" — everywhere except
    /// the unit reader, whose `groups` treated the hyphen as punctuation and
    /// whose lookahead then refused to cross the boundary it opened. "give me
    /// a 2-hour break from tiktok" granted TWO MINUTES where the spaced
    /// spelling grants 120: the sixty-times-too-small class this file exists
    /// to kill, through the one spelling a phone keyboard favours.
    @Test(arguments: [
        ("give me a 2-hour break from tiktok", 120),
        ("give me 2-hours of tiktok", 120),
        ("give me a 2-hr break from tiktok", 120),
        ("unlock tiktok for a 2-hour break", 120),
        ("give me a two-hour tiktok session", 120),
        ("give me a 3-hour tiktok pass", 180),
    ])
    func aHyphenatedDurationReadsLikeASpacedOne(_ row: (utterance: String, minutes: Int)) {
        #expect(spend(row.utterance)?.1 == row.minutes, "\"\(row.utterance)\"")
    }

    /// The pool, where the wrong reading landed instantly: "set my budget to
    /// 2-hours" cut the day's allowance to two minutes, because tightening
    /// does not wait.
    @Test func aHyphenatedBudgetIsNotSixtyTimesTooTight() {
        guard case .command(.setBudget(let m)) =
                DeterministicParser.parse("set my budget to 2-hours", state: durationState()) else {
            Issue.record("the hyphenated budget sentence stopped landing")
            return
        }
        #expect(m == 120)
    }

    /// What the hyphen fix must NOT have moved: the comma is still a wall to
    /// the unit ("20, hours of homework" is twenty minutes), and the
    /// tokenizer's compounding contract still reads "twenty-five" as one
    /// number.
    @Test func commasStillBoundAndCompoundsStillJoin() {
        #expect(NumberParser.allNumbers(in: "give me tiktok for 20, hours of homework left") == [20])
        #expect(spend("give me twenty-five minutes of tiktok")?.1 == 25)
        #expect(NumberParser.allNumbers(in: "give me a 2-hour break from tiktok") == [120])
        // "one-hundred" now poisons exactly as "one hundred" does — the two
        // spellings the tokenizer equates answer alike.
        #expect(NumberParser.allNumbers(in: "one-hundred minutes of reddit").isEmpty)
    }

    /// And the Validator traces the hyphenated grant, or every one of these
    /// sentences would parse and then be refused as invented.
    @Test func theValidatorTracesTheHyphenatedNumber() {
        let state = durationState()
        let utterance = "give me a 2-hour break from tiktok"
        guard case .grant(_, let minutes, _) =
                Validator.validate(DeterministicParser.parse(utterance, state: state),
                                   utterance: utterance, state: state,
                                   ledger: GrantLedger(), now: durationAfternoon, calendar: cal) else {
            Issue.record("the hyphenated grant failed its own provenance")
            return
        }
        #expect(minutes == 120)
    }
}

@Suite struct ThePoolOwnsOnlyItsOwnClause {

    /// The MIRRORED order of the sentence `namesThePool` was written to kill.
    /// The position test — pool noun before the first number — was satisfied by
    /// "[budget excuse], [spend ask]", so "im on a budget, give me 20 of
    /// tiktok" cut the shared allowance from 240 to 20, instantly, and never
    /// opened TikTok. The pool owns a number only when it stands before it in
    /// the SAME clause; these all fall silent and reach the widener as the
    /// spends they are.
    @Test(arguments: [
        "im on a budget, give me 20 of tiktok",
        "my budget is fine, give me 20 of tiktok",
        "im over budget, give me 20 minutes of tiktok",
        "im on a budget, tiktok for 20",
    ])
    func aBudgetExcuseBeforeASpendAskNeverMovesThePool(_ utterance: String) {
        #expect(DeterministicParser.parse(utterance, state: durationState()) == .silence,
                "\"\(utterance)\" moved the pool")
    }

    /// The pool's own sentences are untouched: noun before number, one breath.
    @Test(arguments: [
        ("budget of 40", 40),
        ("set the budget to 25", 25),
        ("budget of 40 for instagram", 40),
        ("bump my daily budget to 60 tiktok is killing me", 60),
        ("block everything, my budget is 30", 30),
    ])
    func thePoolsOwnSentenceStillLands(_ row: (utterance: String, minutes: Int)) {
        guard case .command(.setBudget(let m)) =
                DeterministicParser.parse(row.utterance, state: durationState()) else {
            Issue.record("\"\(row.utterance)\" stopped setting the budget")
            return
        }
        #expect(m == row.minutes, "\"\(row.utterance)\"")
    }

    /// AND THE IDIOMS ARE PLACED, NOT WAVED THROUGH. A quantity that occupies
    /// no token — "an hour" carries its 60 in no digit anywhere — used to be
    /// read as the pool's whenever the sentence mentioned budgeting, on the
    /// theory that nothing else claimed it. The competing claim was the spend
    /// ask standing right on it: "give me an hour of tiktok, im on a budget"
    /// set the shared allowance to 60, in the exact forward order the digit
    /// tests pin as fixed. The idiom's own "hour" anchors it to a clause like
    /// any other token.
    @Test(arguments: [
        "give me an hour of tiktok, im on a budget",
        "give me half an hour of instagram, im on a budget",
        "im on a budget, give me an hour of tiktok",
    ])
    func anIdiomSpendWithABudgetMentionNeverMovesThePool(_ utterance: String) {
        let outcome = DeterministicParser.parse(utterance, state: durationState())
        if case .command(.setBudget(let m)) = outcome {
            Issue.record("\"\(utterance)\" set the budget to \(m)")
        }
        #expect(outcome == .silence, "\"\(utterance)\"")
    }

    /// While an idiom the pool really does own still lands — noun before
    /// quantity, one breath — and the plain idiom spend still spends.
    @Test func anOwnedIdiomStillSetsAndAPlainIdiomStillSpends() {
        guard case .command(.setBudget(let m)) =
                DeterministicParser.parse("my budget is an hour", state: durationState()) else {
            Issue.record("\"my budget is an hour\" stopped setting the budget")
            return
        }
        #expect(m == 60)
        #expect(spend("give me an hour of tiktok")?.1 == 60)
        #expect(spend("give me half an hour of instagram")?.1 == 30)
    }
}

@Suite struct ARefusalOnAnyMentionIsStillARefusal {

    /// `aRefusalNamesTheDoor` used to locate the door with `indices.first` and
    /// test the negator only there, so any earlier un-negated mention shadowed
    /// the refusal standing on a later one: "im addicted to tiktok, no tiktok
    /// for 20 minutes" opened the door and debited the pool out of an explicit
    /// refusal — a grant that cannot be taken back, through the most natural
    /// spelling there is, a reason before the rule.
    @Test(arguments: [
        "im addicted to tiktok, no tiktok for 20 minutes",
        "i love tiktok but no tiktok for 20 minutes",
        "tiktok is my weakness, no tiktok for 2 hours",
        "i keep opening tiktok, absolutely no tiktok for 20 minutes",
    ])
    func anEarlierMentionDoesNotShadowTheRefusal(_ utterance: String) {
        #expect(DeterministicParser.parse(utterance, state: durationState()) == .silence,
                "\"\(utterance)\" opened the door it refuses")
    }

    /// The verb-governing negators still leave the ask alone — the scan is
    /// wider across occurrences, not wider across words.
    @Test func aNegatorGoverningAVerbStillLeavesTheAskAlone() {
        let state = durationState()
        #expect(spend("i love tiktok, dont give me more than 10 of tiktok", state)?.1 == 10)
        #expect(spend("tiktok tiktok tiktok, give me 20 of tiktok", state)?.1 == 20)
    }
}

@Suite struct AnIntensifierDoesNotHideTheHour {

    /// "2 whole hours" states two hours as plainly as "2 hours", and a
    /// lookahead of exactly one token read it as bare 2 — a two-minute grant
    /// out of a two-hour sentence, the sixty-times-too-small class this file's
    /// header declares closed.
    @Test(arguments: [
        ("give me 2 whole hours of tiktok", 120),
        ("give me 2 full hours of tiktok", 120),
        ("give me 2 entire hours of tiktok", 120),
        ("unlock tiktok for 3 whole hours", 180),
    ])
    func anIntensifiedHourIsStillSixtyMinutes(_ row: (utterance: String, minutes: Int)) {
        #expect(spend(row.utterance)?.1 == row.minutes, "\"\(row.utterance)\"")
    }

    /// The cap guard reads through the intensifier too, or "cap tiktok at 2
    /// whole hours" would be 120 to the reader and invisible to the guard —
    /// a two-hour ceiling (a LOOSENING against a door capped at ten) written
    /// in the vocabulary of restriction. It declines, exactly as the
    /// unadorned hour spellings do.
    @Test(arguments: [
        "cap tiktok at 2 whole hours", "cap tiktok at 2 full hours",
        "limit tiktok to 2 entire hours a day",
    ])
    func anIntensifiedHourNeverWritesACeiling(_ utterance: String) {
        var state = durationState()
        let tiktok = state.doors.first { $0.name == "TikTok" }!
        state.doorCaps[tiktok.id] = 10
        if case .command(.setDoorCap(_, let minutes)) =
            DeterministicParser.parse(utterance, state: state) {
            Issue.record("\"\(utterance)\" wrote a ceiling of \(minutes.map(String.init) ?? "none")")
        }
    }

    /// The intensifier is consulted only when an hour word stands beyond it: a
    /// minutes ceiling still lands, a trailing "full" with no unit reads
    /// nothing, and the group boundary still bounds the walk.
    @Test func theIntensifierInventsNothing() {
        guard case .command(.setDoorCap(_, let m)) =
                DeterministicParser.parse("cap tiktok at 20 whole minutes", state: durationState()) else {
            Issue.record("a minutes ceiling with an intensifier stopped landing")
            return
        }
        #expect(m == 20)
        #expect(spend("give me 20 full of tiktok")?.1 == 20)
        #expect(NumberParser.allNumbers(in: "for 2 whole, hours of homework left") == [2])
    }
}

@Suite struct EveryClockIsReadExactlyOnce {

    /// `statedTimes` used to re-run `statedTime` on the string with one leading
    /// token dropped per iteration — so the same clock was found once per
    /// suffix it led, and "lock me out from 10pm to 7am" answered with a pile
    /// of duplicate 22:00s before the 7:00 appeared. Membership hid it (the
    /// provenance guards only ask `contains`), and the COST did not: each
    /// re-run re-tokenized everything remaining, which is the quadratic hang
    /// `aHugeUtteranceValidatesInOnePass` bounds. One entry per stated clock,
    /// in order, is the reading.
    @Test func statedTimesAnswersOncePerClock() {
        #expect(NumberParser.statedTimes(in: "lock me out from 10pm to 7am",
                                         assumeEvening: false)
                == [TimeOfDay(hour: 22), TimeOfDay(hour: 7)])
        #expect(NumberParser.statedTimes(in: "night should start at 10", assumeEvening: true)
                == [TimeOfDay(hour: 22)])
        #expect(NumberParser.statedTimes(in: "no clock here at all", assumeEvening: false)
                == [])
    }

    /// And the first-clock reader is unmoved: same tokens, same meridiem
    /// handling, first answer only.
    @Test func theFirstClockReaderIsUnmoved() {
        #expect(NumberParser.statedTime(in: "lock me out from 10pm to 7am",
                                        assumeEvening: false)
                == NumberParser.StatedTime(time: TimeOfDay(hour: 22), meridiemWasStated: true))
        #expect(NumberParser.statedTime(in: "i am up till 11", assumeEvening: false)
                == NumberParser.StatedTime(time: TimeOfDay(hour: 11), meridiemWasStated: false))
    }
}
