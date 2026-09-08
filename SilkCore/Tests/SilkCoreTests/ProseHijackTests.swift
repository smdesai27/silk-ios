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

    /// The intensifier's "so" is a clause boundary to the splitter, so the
    /// hour's clause arrived subject-less: "it was so quiet at 3 in the
    /// morning" passed the ownership gate on the stranded "quiet", and the
    /// evening assumption read its 3 as a 15:00 down-hours start — out of a
    /// sentence about last night. The copula standing directly before the
    /// "so" is what proves the clause a description, wherever the splitter
    /// cut it.
    @Test(arguments: [
        "it was so quiet at 3 in the morning",
        "its so quiet at 3 in the morning",
        "the house got so quiet at 3",
        "i got home and it was so quiet at 2",
        "everything was so quiet at 4 am",
        "it gets so quiet here at 2",
        "the office was so quiet at 4 i left early",
        "it wasnt so quiet at 3",
        "man it was so quiet at 3 in the morning",
        "the gym was so quiet at 6",
        "felt so quiet at 4",
        "the streets were so quiet at 5 am on my run",
    ])
    func anIntensifiedDescriptionMovesNoEdge(_ utterance: String) {
        #expect(!movesAnEdge(utterance), "\"\(utterance)\" moved a window edge")
    }

    /// A stated meridiem is stated: "in the morning" outranks the evening
    /// assumption exactly as "am" does — on the setter, and on a close's
    /// "until", where the evening reading would LIFT the close twelve hours
    /// early against the sentence's own words.
    @Test func aStatedMorningIsNeverReadAsEvening() {
        #expect(parse("quiet time at 6 in the morning")
                == .command(.setDownHoursStart(TimeOfDay(hour: 6))))
        #expect(parse("quiet hours start at 9 in the morning")
                == .command(.setDownHoursStart(TimeOfDay(hour: 9))))
        // Aliases are gone, so the door is spelled out rather than "insta".
        guard case .command(.closeDoorToday(let d, let until))
            = parse("no more instagram until 6 in the morning") else {
            Issue.record("\"no more instagram until 6 in the morning\" dropped the close")
            return
        }
        #expect(d.name == "Instagram")
        #expect(until == TimeOfDay(hour: 6))
    }

    /// The stated half works in both directions: an evening named on the end
    /// edge or after a close's "until" reads as the evening it says.
    @Test func aStatedEveningIsStatedToo() {
        #expect(parse("quiet time at 9 in the evening")
                == .command(.setDownHoursStart(TimeOfDay(hour: 21))))
        #expect(parse("down hours till 7 in the morning")
                == .command(.setDownHoursEnd(TimeOfDay(hour: 7))))
        // Aliases are gone, so the door is spelled out rather than "insta".
        guard case .command(.closeDoorToday(_, let evening))
            = parse("block instagram until 7 in the evening"),
            case .command(.closeDoorToday(_, let night))
            = parse("no more tiktok until 9 at night") else {
            Issue.record("a close with a stated evening was dropped")
            return
        }
        #expect(evening == TimeOfDay(hour: 19))
        #expect(night == TimeOfDay(hour: 21))
    }

    /// The tie is adjacency: a meridiem phrase standing on some OTHER part of
    /// the sentence must not re-aim the stated hour. A substring test read
    /// this as a 10 AM start — a twenty-one-hour night out of a remark about
    /// a walk.
    @Test func aStrandedMorningPhraseDoesNotReaimTheHour() {
        #expect(parse("bedtime at 10, i walked in the morning")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
    }

    /// A discourse "so" has no copula in front of it, and still sets — and so
    /// does a description in one breath with a setter in the next.
    @Test func aDiscourseSoStillSets() {
        #expect(parse("ok so bedtime at 10")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
        #expect(parse("so quiet hours start at 9")
                == .command(.setDownHoursStart(TimeOfDay(hour: 21))))
        #expect(parse("night was so long, quiet time at 10")
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))))
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

    /// The door as SUBJECT of a consuming verb is the app reporting what it
    /// did with her day. `habitIrregulars` was a closed list without the
    /// consuming class, so "insta stole 25 minutes from me" spent 25 real
    /// minutes; and when the quantity lives in no token ("an hour"), no
    /// number anchors at all, the participle scan had nothing to walk, and
    /// the verb standing directly on the door went unread.
    @Test(arguments: [
        "insta stole 25 minutes from me",
        "insta stole an hour from me",
        "insta steals 25 minutes from me every day",
        "tiktok ate an hour of my afternoon()",
        "insta is stealing an hour of my day",
        "tiktok drained 40 minutes of my day",
        "youtube sucked 30 minutes out of my evening",
        "tiktok robbed me of 20 minutes",
        "insta threw away 45 minutes of my mornings",
        "the gram stole an hour from me",
        "tiktok took an hour of my day",
        "insta gave me 20 minutes of joy",
        "insta drank my whole evening, 30 minutes gone",
        "insta killed 20 minutes for me while i waited",
    ])
    func aConsumingReportOpensNothing(_ utterance: String) {
        #expect(parse(utterance) == .silence, "\"\(utterance)\" opened a door")
    }

    /// The refusal stays as narrow as the report shape: a door followed by
    /// anything that is not its own predicate still grants, and a consuming
    /// word in an earlier breath — or a trailing one — does not poison the
    /// ask.
    @Test func theAsksBesideTheConsumingClassStillLand() {
        // SPEND now requires an opening verb, and aliases are dead: "insta"
        // is neither a verb nor a door any more, so these two rows are kept
        // and re-pinned to what they now are — silence, naming no door at
        // all — rather than dropped.
        #expect(parse("insta for an hour") == .silence)
        #expect(parse("insta, an hour please") == .silence)
        // The identical shapes, verbed and spelled with the door's real name,
        // still grant — proving the property this test exists for: a
        // consuming word in an earlier breath, or a trailing one, does not
        // poison the ask.
        #expect(spend("give me instagram for an hour")?.1 == 60)
        #expect(spend("give me instagram for an hour")?.0 == "Instagram")
        #expect(spend("give me instagram, an hour please")?.1 == 60)
        #expect(spend("can i get an hour of tiktok, it stole my heart")?.1 == 60)
        let got = spend("i drank so much coffee, give me 20 minutes of tiktok")
        #expect(got?.0 == "TikTok" && got?.1 == 20,
                "the ask after the coffee report -> \(String(describing: got))")
    }

    /// The hot path is the floor. Ask verbs, request modals and the corpus's
    /// own permissive rows all still grant.
    ///
    /// THE QUOTED ROW IS GONE, and it is round three's one re-pinned grant.
    /// "my friend said give me an hour of tiktok" was defended here as the
    /// user ADOPTING somebody else's ask, on the evidence that the quote never
    /// resumes. It is the same sentence as "my friend says open tiktok for 20"
    /// with an idiom for its quantity, and that one opened the door and
    /// debited the pool — so the two compile alike now, both silent
    /// (`aReportFramesTheAsk`, `SpendShapeAdversarialRound3Tests`). Its
    /// doorless twin, "my friend said give me an hour", was already silent.
    @Test(arguments: [
        ("give me 20 of tiktok", "TikTok", 20),
        ("can i have twenty minutes of tiktok", "TikTok", 20),
        ("im at my limit on tiktok, give me 20 minutes", "TikTok", 20),
        ("give me instagram until i leave the gym, 20 minutes tops", "Instagram", 20),
    ])
    func theHotPathStillGrants(_ row: (utterance: String, door: String, minutes: Int)) {
        let got = spend(row.utterance)
        #expect(got?.0 == row.door && got?.1 == row.minutes,
                "\"\(row.utterance)\" -> \(String(describing: got))")
    }

    /// SPEND now requires an opening verb: the fragments and chatter tails
    /// above that carried no verb are kept — dropping a row is never the fix
    /// — and re-pinned to what they now are, `.writeItOut` with the same
    /// door and the same minutes, rather than a grant.
    @Test(arguments: [
        ("tiktok for 20 minutes", "TikTok", 20),
        ("twenty minutes of tiktok", "TikTok", 20),
        ("tiktok 15", "TikTok", 15),
        ("reddit ten ok bye love you", "Reddit", 10),
        ("hey so i was thinking maybe like 10 minutes of reddit would be nice", "Reddit", 10),
        ("no more than 20 of tiktok", "TikTok", 20),
        ("wait, 10 more on tiktok", "TikTok", 10),
        ("tiktok, 10 pls", "TikTok", 10),
    ])
    func theHotPathFragmentsWriteThemselvesOutWithoutAVerb(_ row: (utterance: String, door: String, minutes: Int)) {
        guard case .writeItOut(let d, let m) = parse(row.utterance) else {
            Issue.record("\"\(row.utterance)\" stopped writing itself out")
            return
        }
        #expect(d.name == row.door && m == row.minutes, "\"\(row.utterance)\"")
    }

    /// And the identical fragments, with the verb restored, still grant: the
    /// hot path is a verb away from every one of them, never further.
    @Test(arguments: [
        ("give me tiktok for 20 minutes", "TikTok", 20),
        ("give me twenty minutes of tiktok", "TikTok", 20),
        ("give me 15 of tiktok", "TikTok", 15),
        ("give me ten of reddit ok bye love you", "Reddit", 10),
        ("hey so i was thinking maybe can i get 10 minutes of reddit", "Reddit", 10),
        ("give me no more than 20 of tiktok", "TikTok", 20),
        ("wait, give me 10 more on tiktok", "TikTok", 10),
        ("gimme tiktok, 10 pls", "TikTok", 10),
    ])
    func theHotPathFragmentsGrantOnceVerbed(_ row: (utterance: String, door: String, minutes: Int)) {
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
        #expect(spend("give me 30 of instagram")?.1 == 30)
        #expect(spend("give me 30 minutes of instagram")?.1 == 30)
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
                                  ledger: GrantLedger(), now: afternoon(), calendar: cal)
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
                               ledger: GrantLedger(), now: afternoon(), calendar: cal)
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
        // "have" is not on the opening-verb list, so this row is kept and
        // re-pinned to what it now is — the guidance shortcut, same door and
        // minutes — rather than dropped.
        guard case .writeItOut(let d, let m) = parse("ill have 20 of tiktok") else {
            Issue.record("\"ill have 20 of tiktok\" stopped writing itself out")
            return
        }
        #expect(d.name == "TikTok" && m == 20)
        // And the identical ask, verbed, still grants.
        #expect(spend("i want 20 of tiktok")?.1 == 20)
        #expect(spend("dont give me more than 10 of tiktok")?.1 == 10)
        // "got" ahead of a request modal stays the modal's ask.
        #expect(spend("ok so i just got home and i want to relax "
                      + "can i get twenty minutes of youtube before dinner")?.1 == 20)
        // Aliases are gone: "insta gram" is two unknown words rather than a
        // dictation split of "instagram", so this row is kept and re-pinned to
        // silence — no door survives — and the identical sentence spelled with
        // the door's real name and a verb still grants.
        #expect(parse("insta gram ten") == .silence)
        #expect(spend("give me ten minutes of instagram")?.1 == 10)
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
