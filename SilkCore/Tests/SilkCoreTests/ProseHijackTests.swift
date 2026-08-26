import Testing
import Foundation
@testable import SilkCore

// The prose-hijack round.
//
// One root, eleven findings: the ask/report/negation discipline lived on the
// cap family and nowhere else, so ordinary chatter — a habit complaint, a
// report of yesterday's screen time, a sentence about a budget hotel, a slang
// tail — was compiled as policy by the rules that never got the gates. Every
// suite below pins one hole with the sentences that proved it, and beside each
// hole the canonical commands that must keep landing, because the fix that
// silences the chatter and the fix that silences the command are one careless
// widening apart.

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

private func parse(_ utterance: String, _ state: PolicyState = makeState()) -> ParseOutcome {
    DeterministicParser.parse(utterance, state: state)
}

private func spend(_ utterance: String, _ state: PolicyState = makeState()) -> (String, Int)? {
    guard case .command(.spend(let door, let minutes)) = parse(utterance, state) else { return nil }
    return (door.name, minutes)
}

private func budget(_ utterance: String) -> Int? {
    guard case .command(.setBudget(let m)) = parse(utterance) else { return nil }
    return m
}

// MARK: - Findings 1 and 9: the pool

@Suite struct ThePoolIgnoresProseAboutDailyNumbers {

    /// Rule 3's doorless arm fired on "a day"/"daily" plus any single number
    /// with no mood gate and no negator scan: every one of these rewrote the
    /// shared allowance instantly, with "N left today." as the only receipt.
    @Test(arguments: [
        "i smoke 5 a day, trying to quit",
        "i drink 8 glasses of water a day",
        "my daily standup ran 45 minutes again",
        "i would never allow 60 a day",
        "no way im doing 90 a day",
    ])
    func aReportAboutADailyNumberMovesNothing(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" rewrote the budget")
    }

    /// "budget" as an adjective, and its inflections. `namesThePool` asked
    /// only whether the exact token preceded the number in one clause, so a
    /// budget hotel owned the sentence's 3 — and "budgeting" matched the stem
    /// test, failed the exact-token test, and fell into the doorless fallback.
    @Test(arguments: [
        "we stayed at a budget hotel for 3 nights",
        "my budget phone died 2 times today",
        "the budget flight was 45 dollars",
        "im budgeting 5 dollars for coffee",
    ])
    func adjectivalBudgetOwnsNoAllowance(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" rewrote the budget")
    }

    /// The canonical setters are the floor, and the pool's own speak louder
    /// than the cap gate would allow: "make IT" carries a pronoun, "40 a day
    /// IS what i already have" carries a copula, and "i told my friends id do
    /// 30 a day" opens with the flattest report frame there is. All still
    /// land.
    @Test(arguments: [
        ("make it 30 a day", 30),
        ("set my budget to 25", 25),
        ("budget of 40", 40),
        ("i told my friends id do 30 a day", 30),
        ("lets do 30 a day from now on", 30),
        ("40 a day is what i already have", 40),
        ("an hour a day", 60),
        ("actually make it 45 a day", 45),
    ])
    func theCanonicalSettersStillLand(_ row: (utterance: String, minutes: Int)) {
        #expect(budget(row.utterance) == row.minutes, "\"\(row.utterance)\"")
    }
}

// MARK: - Finding 2: the window

@Suite struct TheWindowIsNotMovedByProse {

    private func movesAnEdge(_ utterance: String) -> Bool {
        switch parse(utterance) {
        case .command(.setDownHoursStart), .command(.setDownHoursEnd):
            return true
        default:
            return false
        }
    }

    /// A substring "quiet"/"bedtime" plus the first hour-shaped number moved a
    /// window edge instantly: "work was quiet so i left at 4" was a 4 PM start
    /// — a fifteen-hour night — and "pretty quiet day, i finished 20 pages of
    /// my book" a 20:00 END against a 22:00 start, a twenty-two-hour lockdown
    /// from a sentence about a book.
    @Test(arguments: [
        "work was quiet so i left at 4",
        "the baby went down at 7, quiet night finally",
        "quiet, i got up at 6",
        "pretty quiet day, i finished 20 pages of my book",
        "i was quiet at work until 4",
    ])
    func proseWithAnHourMovesNoEdge(_ utterance: String) {
        #expect(!movesAnEdge(utterance), "\"\(utterance)\" moved a window edge")
    }

    /// The setters keep their whole inventory: the window's name shares the
    /// hour's breath in every one of them.
    @Test func theCanonicalSettersStillLand() {
        #expect(parse("down hours start at ten")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(parse("night starts at ten")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(parse("move bedtime to 11")
                == .command(.setDownHoursStart(TimeOfDay(hour: 23))))
        #expect(parse("quiet time at 10")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(parse("bedtime till 11pm")
                == .command(.setDownHoursEnd(TimeOfDay(hour: 23))))
        #expect(parse("start my quiet hours at 8 tonight")
                == .command(.setDownHoursStart(TimeOfDay(hour: 20))))
    }
}

// MARK: - Finding 3: SPEND answers asks

@Suite struct ASpendAnswersAsksNotReports {

    /// Rule 7 fired on door + one number with no ask requirement, so a report
    /// of yesterday's screen time was answered with an open door and a debited
    /// pool — non-silent, so the widener never saw the sentence.
    @Test(arguments: [
        "i watched tiktok for 45 minutes at lunch",
        "i wasted 2 hours on instagram today",
        "my screen time says 55 minutes of youtube yesterday",
        "my friend said give me 20 minutes of tiktok is what i always type",
        "meet me at 5, then we can doomscroll tiktok",
        "my number ends in 88, anyway insta was wild",
        "tiktok premium is like 9 dollars",
    ])
    func aReportOfScreenTimeOpensNothing(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" opened a door")
    }

    /// The hot path is the floor. Fragments, chatter tails, ask verbs, request
    /// modals and the corpus's own permissive rows all still grant.
    @Test(arguments: [
        ("give me 20 of tiktok", "TikTok", 20),
        ("can i have twenty minutes of tiktok", "TikTok", 20),
        ("tiktok for 20 minutes", "TikTok", 20),
        ("twenty minutes of tiktok", "TikTok", 20),
        ("tiktok 15", "TikTok", 15),
        ("reddit ten ok bye love you", "Reddit", 10),
        ("hey so i was thinking maybe like 10 minutes of reddit would be nice", "Reddit", 10),
        ("my friend said give me an hour of tiktok", "TikTok", 60),
        ("im at my limit on tiktok, give me 20 minutes", "TikTok", 20),
        ("no more than 20 of tiktok", "TikTok", 20),
        ("wait, 10 more on tiktok", "TikTok", 10),
        ("give me instagram until i leave the gym, 20 minutes tops", "Instagram", 20),
        ("tiktok, 10 pls", "TikTok", 10),
    ])
    func theHotPathStillGrants(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = spend(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }
}

// MARK: - Finding 4: seconds

@Suite struct SecondsAreNotMinutes {

    /// The reader scales hours and had no seconds handling, while the phrase
    /// whitelist admits the word — so "30 seconds" granted thirty MINUTES,
    /// sixty times the stated ask, in the loosening direction.
    @Test(arguments: [
        "give me 30 seconds of insta",
        "the youtube ad was 30 seconds long",
        "30 seconds of tiktok",
        "give me 45 secs of reddit",
        "give me 30 whole seconds of insta",
    ])
    func aSecondsAskIsDeclinedNotScaledUp(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" read seconds as minutes")
    }

    /// The cap path declines the unit the way it declines hours.
    @Test func aSecondsCeilingIsDeclined() {
        #expect(parse("cap tiktok at 30 seconds") == .silence)
    }

    /// Minutes are untouched on both paths.
    @Test func minutesStillReadAsThemselves() {
        #expect(spend("give me 30 of insta")?.1 == 30)
        #expect(spend("give me 30 minutes of insta")?.1 == 30)
    }
}

// MARK: - Finding 8: "no cap" the slang

@Suite struct NoCapAsSlangIsNotAClearing {

    private var capped: PolicyState { makeState(caps: [tiktok.id: 10]) }

    private func clearsTheCap(_ utterance: String) -> Bool {
        if case .command(.setDoorCap(_, nil)) = parse(utterance, capped) { return true }
        return false
    }

    /// "No cap" trailing a full predicate means "no lie". Each of these
    /// removed the ceiling the user set on the very app being complained
    /// about, because the report gate knows pronouns and auxiliaries and
    /// Gen-Z filler openers are neither.
    @Test(arguments: [
        "ngl tiktok ruined my sleep no cap",
        "fr tiktok got me no cap",
        "lowkey addicted to tiktok no cap",
        "me and tiktok no cap",
        "tbh tiktok cooked me today no cap",
    ])
    func aSlangTailClearsNoCeiling(_ utterance: String) {
        #expect(!clearsTheCap(utterance), "\"\(utterance)\" cleared the cap")
    }

    /// The deliberate clearings keep their shapes — the phrase leads, or only
    /// the door and the grammar's own particles stand ahead of it.
    @Test(arguments: [
        "no cap on tiktok",
        "tiktok no cap",
        "uncap tiktok no cap",
        "no cap on tiktok fr fr",
        "please no cap on tiktok",
    ])
    func aDeliberateClearingStillClears(_ utterance: String) {
        #expect(clearsTheCap(utterance), "\"\(utterance)\" no longer clears")
    }
}

// MARK: - Finding 10: verb-negated refusals

@Suite struct ARefusedOpeningVerbNeverOpens {

    /// The refusal guard only saw a negator standing on the door NOUN. A
    /// negator on the opening VERB — the plainest way to type a refusal — was
    /// invisible, the close rule vetoes itself on the opener token, and the
    /// refused app was opened for exactly the refused minutes.
    @Test(arguments: [
        "dont open tiktok for 20 minutes",
        "do not unlock reddit for 45 minutes",
        "never let me open instagram for 30 minutes",
        "dont give me tiktok for 25 minutes",
    ])
    func aNegatedOpeningVerbIsARefusal(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" opened the refused door")
    }

    /// The bounded ask and the refused close keep their grants — in both, the
    /// negation lands on something other than the giving.
    @Test func aBoundedAskAndARefusedCloseStillGrant() {
        #expect(spend("dont give me more than 10 of tiktok")?.1 == 10)
        #expect(spend("dont close instagram, just give me 10")?.1 == 10)
    }
}

// MARK: - Finding 11: habit reports

@Suite struct AHabitReportIsNotACeiling {

    private var capped: PolicyState { makeState(caps: [tiktok.id: 10, instagram.id: 10]) }

    /// A subject-less habit report compiled as standing policy, with "times"
    /// read as minutes: "checking tiktok 50 times a day" was a parked
    /// five-fold RAISE of the ten-minute cap, out of a self-flagellating
    /// complaint. The same sentence with a subject was already silent.
    @Test(arguments: [
        "checking tiktok 50 times a day",
        "opened tiktok 30 times a day last week",
        "refreshing instagram 40 times a day lately",
        "scrolling tiktok 45 minutes a day lately",
        "cap tiktok at 20 times a day",
    ])
    func aHabitCountWritesNoCeiling(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" wrote a ceiling")
    }

    /// The habitual setters are the floor.
    @Test func theHabitualSettersStillLand() {
        #expect(parse("tiktok 20 a day") == .command(.setDoorCap(door: tiktok, minutes: 20)))
        #expect(parse("20 a day for tiktok") == .command(.setDoorCap(door: tiktok, minutes: 20)))
        #expect(parse("make my instagram 15 min a day")
                == .command(.setDoorCap(door: instagram, minutes: 15)))
    }
}

// MARK: - Finding 12: the matched clock's meridiem

@Suite struct TheAmPmGuardReadsTheMatchedClock {

    private func widened(_ command: Command, saying utterance: String) -> Verdict {
        let state = makeState()
        return Validator.validate(.command(command), utterance: utterance, state: state,
                                  ledger: GrantLedger(), now: afternoon, calendar: cal)
    }

    /// Membership was checked against every clock, but the meridiem flag was
    /// read off the FIRST — so "lock me out from 10pm to 10" lent the bare
    /// trailing 10 the explicit 10pm's provenance, and a night lengthened
    /// from 9 to 12 hours landed instantly instead of being asked about.
    @Test func aBareLaterClockIsStillAskedAbout() {
        #expect(widened(.setDownHoursEnd(TimeOfDay(hour: 10)),
                        saying: "lock me out from 10pm to 10")
                == .refuseSayAmOrPm(at: TimeOfDay(hour: 10)))
    }

    /// The two-clock window sentence the widener exists for still lands: its
    /// end carries its own meridiem.
    @Test func anExplicitLaterClockStillLands() {
        guard case .ruleChange(let proposed, _) =
                widened(.setDownHoursEnd(TimeOfDay(hour: 7)),
                        saying: "lock me out from 10pm to 7am") else {
            Issue.record("the explicit two-clock window sentence stopped landing")
            return
        }
        #expect(proposed.downHours.end == TimeOfDay(hour: 7))
    }

    /// The grammar path is unmoved in both directions.
    @Test func theGrammarPathIsUnmoved() {
        let state = makeState()
        func verdict(_ text: String) -> Verdict {
            Validator.validate(DeterministicParser.parse(text, state: state),
                               utterance: text, state: state,
                               ledger: GrantLedger(), now: afternoon, calendar: cal)
        }
        #expect(verdict("down hours till 11") == .refuseSayAmOrPm(at: TimeOfDay(hour: 11)))
        guard case .ruleChange = verdict("down hours till 7") else {
            Issue.record("a morning hour that does not lengthen the night was questioned")
            return
        }
    }
}

// MARK: - Finding 15: subtractive lowering

@Suite struct ASubtractiveLoweringNeverGrants {

    private var capped: PolicyState { makeState(caps: [tiktok.id: 30, instagram.id: 30]) }

    /// The subtractive shape puts its amount OUTSIDE the clearing phrase, so
    /// the clearing rule declined instead of terminating and the ladder walked
    /// into SPEND: a request to LOWER a restriction opened the app and debited
    /// the pool — verbatim the class the family's doctrine says must
    /// terminate.
    @Test(arguments: [
        "take 20 off my tiktok limit",
        "knock 10 off the tiktok cap",
        "shave 15 off my instagram limit",
    ])
    func loweringACapOpensNothing(_ utterance: String) {
        #expect(parse(utterance, capped) == .silence, "\"\(utterance)\" opened the door")
    }

    /// A number INSIDE the phrase still identifies the ceiling being removed.
    @Test func aQuotedCeilingStillClears() {
        #expect(parse("remove the 20 minute tiktok cap", capped)
                == .command(.setDoorCap(door: tiktok, minutes: nil)))
        #expect(parse("take the cap of 20 off tiktok", capped)
                == .command(.setDoorCap(door: tiktok, minutes: nil)))
    }
}

// MARK: - The round against the gates themselves

@Suite struct TheGatesSurviveTheirOwnRound {

    /// PROJECT LAW: every widening hijacks prose, and every GATE gets attacked
    /// until a round finds nothing. This suite is that round — each sentence
    /// walked through version one of the gates above and came out a grant, a
    /// budget cut or a window move, and each fix below it is narrower than the
    /// hole it closes.
    @Test(arguments: [
        // Irregular pasts the "ed" suffix test cannot see.
        "spent 45 minutes on tiktok ugh",
        "lost 2 hours to insta today",
        // A subject conjugating the ask verb: somebody's permission, reported.
        "she let me have tiktok for 30 minutes yesterday",
        // A durative negator with a bound is a standing rule, not an ask.
        "never open insta for more than 20 minutes",
        // Round two: "ever" glued between the negator and the verb, and the
        // irregular pasts of consuming with the DOOR as their subject.
        "dont ever open tiktok for 20 minutes",
        "tiktok got me for 45 minutes today",
        "youtube ate 2 hours of my evening",
    ])
    func aSpendGateBypassIsClosed(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" still opened a door")
    }

    @Test func aPoolGateBypassIsClosed() {
        // A participle heads the report even when no subject is spoken —
        // regular or irregular.
        #expect(parse("rent dropped 5 a day") == .silence)
        #expect(parse("budget hotel wifi gave me 45 a day") == .silence)
    }

    @Test func aHabitGateBypassIsClosed() {
        // A phrase preposition heads the same subject-less report.
        let capped = makeState(caps: [tiktok.id: 10])
        #expect(parse("on tiktok 90 minutes a day lately", capped) == .silence)
    }

    @Test func aWindowGateBypassIsClosed() {
        // Past tense is a recollection, not tonight's rule.
        for utterance in ["bedtime was 9 when i was a kid", "my bedtime used to be 10"] {
            switch parse(utterance) {
            case .command(.setDownHoursStart), .command(.setDownHoursEnd):
                Issue.record("\"\(utterance)\" moved a window edge")
            default:
                break
            }
        }
    }

    /// And the closures cost none of the neighbouring asks.
    @Test func theNeighbouringCommandsStillLand() {
        #expect(spend("just finished homework give me 20 of tiktok")?.1 == 20)
        #expect(spend("ill have 20 of tiktok")?.1 == 20)
        #expect(spend("dont give me more than 10 of tiktok")?.1 == 10)
        // "got" ahead of a request modal stays the modal's ask.
        #expect(spend("ok so i just got home and i want to relax "
                      + "can i get twenty minutes of youtube before dinner")?.1 == 20)
        // Dictation junk between the door and its number is the corpus's own
        // pinned permissiveness, untouched.
        #expect(spend("insta gram ten")?.1 == 10)
        #expect(parse("down hours starting at 10")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(parse("bedtime is 10 tonight")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
    }
}

// MARK: - Finding 16: deadlines

@Suite struct ADeadlineIsNotADuration {

    /// "give me tiktok till 7" asks for the app until a CLOCK; rule 7 read
    /// the 7 as seven MINUTES — a reading no human shares, and a re-ask after
    /// them double-debits the day. The close side reads the identical words
    /// as a clock, so the two directions of one idiom parsed under two
    /// theories.
    @Test(arguments: [
        "give me tiktok till 7",
        "unlock instagram until 10",
        "let me have reddit til 9",
    ])
    func aDeadlineIsNeverReadAsMinutes(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" granted the clock digit")
    }

    /// Durations and closes with the same vocabulary are untouched.
    @Test func durationsAndClosesKeepTheirReadings() {
        #expect(spend("give me tiktok for 7")?.1 == 7)
        #expect(spend("give me 7 minutes of tiktok")?.1 == 7)
        guard case .command(.closeDoorToday(let d, let until)) = parse("block tiktok until 9") else {
            Issue.record("the close stopped reading its clock")
            return
        }
        #expect(d.name == "TikTok")
        #expect(until == TimeOfDay(hour: 21))
    }
}
