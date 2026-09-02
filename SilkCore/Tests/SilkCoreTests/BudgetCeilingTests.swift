import Foundation
import Testing
@testable import SilkCore

// MARK: - The day's ceiling
//
// An integer-overflow trap, two bar sentences from a clean install.
//
// The pool had no ceiling anywhere. `NumberParser` reads an eighteen-digit
// literal straight through `Int(tok)`, `Validator`'s `.setBudget` arm asks only
// where the number came from and never how big it is, and `proposedState` stored
// it verbatim — so "budget 999999999999999999" was an ordinary loosening that
// parked, matured, and sat in the policy. The second sentence collected:
// `.spend` clamped the ask to a pool of 10^18 and computed `asked * 60`, which
// overflows `Int64` and traps. `NumberParser.saturating` had already paid for
// exactly this lesson on the parser's own ×60 ("THE PARSER MAY NOT CRASH ON A
// SENTENCE"); the model boundary had not learned it.
//
// The fix is a clamp at the boundary where a parsed number becomes policy, and a
// `Double` multiply behind it — because a policy also arrives from a stored blob
// that no clamp ever touched. Both halves are pinned below.

private let instagram = Door(name: "Instagram")
private let tiktok = Door(name: "TikTok")

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
}

private func dayStart(_ now: Date) -> Date {
    DayBoundary.dayStart(now: now, downHours: night, calendar: cal)
}

private func policy(budget: Int = 40, caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: night,
                doors: [instagram, tiktok], doorCaps: caps)
}

/// The two sentences, through the pipe they are actually said into.
private func say(_ utterance: String, _ state: PolicyState,
                 _ ledger: GrantLedger = GrantLedger(), at now: Date = at(12)) -> Verdict {
    Validator.validate(DeterministicParser.parse(utterance, state: state),
                       utterance: utterance, state: state, ledger: ledger,
                       now: now, calendar: cal)
}

/// The eighteen-digit literal from the report. Spelled as digits and not as
/// `Int.max` on purpose: this is the number a person can type into the bar, and
/// sixty times it is what the trap was.
private let absurd = 999_999_999_999_999_999

@Suite struct BudgetCeilingTests {

    // MARK: - The two sentences

    /// Sentence one. It still parses, it is still a loosening, and what it parks
    /// is a day rather than three hundred billion years.
    @Test func anAbsurdBudgetParksClampedToADay() {
        let p = policy()
        #expect(DeterministicParser.parse("budget \(absurd)", state: p)
                == .command(.setBudget(minutes: absurd)),
                "the sentence is still read; the bound is applied to the policy, not to the reading")

        guard case .ruleChange(let proposed, let polarity) = say("budget \(absurd)", p) else {
            Issue.record("the budget sentence stopped being a rule change")
            return
        }
        #expect(proposed.budgetMinutes == PolicyState.maxMinutesPerDay)
        #expect(proposed.budgetMinutes == 1440)
        #expect(polarity == .loosen, "a raise still parks: clamping is not refusing")
    }

    /// And the receipt names the number she is getting. The pool's own parked
    /// summary is `"\(next.budgetMinutes)"` (`AppModel.pendingSummary`), spoken
    /// through the one sentence that exists for it — so a clamped budget reads
    /// back "Tomorrow: 1440" and not "Applies tomorrow." over a number nobody
    /// can see. No new string: `parked` composes user data, as it already does
    /// for a window and a ceiling.
    @Test func theClampedBudgetReadsBackTheNumberItLandedOn() {
        guard case .ruleChange(let proposed, _) = say("budget \(absurd)", policy()) else {
            Issue.record("the budget sentence stopped being a rule change")
            return
        }
        #expect(SilkStrings.parked("\(proposed.budgetMinutes)") == "Tomorrow: 1440")
    }

    /// Sentence two, said against the policy sentence one leaves behind. This is
    /// the call that used to SIGTRAP: reaching a verdict at all is the assertion.
    @Test func theSpendAgainstThatBudgetIsBoundedAndDoesNotTrap() {
        guard case .ruleChange(let matured, _) = say("budget \(absurd)", policy()) else {
            Issue.record("the budget sentence stopped being a rule change")
            return
        }
        let verdict = say("instagram \(absurd)", matured)
        guard case .grant(let door, let minutes, let relockAt) = verdict else {
            Issue.record("the absurd spend answered \(verdict)")
            return
        }
        #expect(door.id == instagram.id)
        #expect(minutes > 0 && minutes <= PolicyState.maxMinutesPerDay)
        // Noon against a 22:00 edge: ten hours, and not one minute of tomorrow.
        #expect(minutes == 600)
        #expect(relockAt == at(22))
    }

    // MARK: - A blob the clamp never saw

    /// The clamp guards what the parser writes. A policy persisted by a build
    /// that predates it — or corrupted, or hand-edited — carries whatever it
    /// carries, and the arm that multiplies has to survive it. `Int.max`, which
    /// is the largest thing an `Int` field can hold and the value
    /// `NumberParser.saturating` itself hands back.
    @Test func aStoredIntMaxBudgetValidatesASpendWithoutTrapping() {
        let corrupt = policy(budget: .max)
        guard case .grant(_, let minutes, let relockAt) = say("instagram 90", corrupt) else {
            Issue.record("a spend against a corrupt pool was refused")
            return
        }
        #expect(minutes == 90, "the ask still binds; the pool is merely enormous")
        #expect(relockAt == at(13, 30))
    }

    /// The same blob, asked the absurd number. Both terms of the multiply are
    /// out of range now, and the answer is still a grant that fits in the day.
    @Test func anAbsurdAskAgainstAStoredIntMaxBudgetIsBounded() {
        guard case .grant(_, let minutes, _) = say("instagram \(absurd)", policy(budget: .max)) else {
            Issue.record("the absurd ask against a corrupt pool was refused")
            return
        }
        #expect(minutes == 600)
    }

    /// Caps likewise. A ceiling is the other number that reaches the clamp in
    /// `.spend`, through `ceilingRemaining`, and a stored `Int.max` there is the
    /// same arithmetic with the pool standing in for the ceiling.
    @Test func aStoredIntMaxCapValidatesASpendWithoutTrapping() {
        let corrupt = policy(budget: .max, caps: [instagram.id: .max])
        guard case .grant(_, let minutes, _) = say("instagram \(absurd)", corrupt) else {
            Issue.record("the absurd ask against a corrupt ceiling was refused")
            return
        }
        #expect(minutes == 600)
    }

    /// And the wall's subtitle reads the same bound the bar mints under, or it
    /// promises a number Silk refuses — the property
    /// `theWallPromisesOnlyWhatTheBarWillMint` pins for the ordinary fixtures,
    /// held here for the corrupt one.
    @Test func theWallDoesNotPromiseMoreThanADayEither() {
        let corrupt = policy(budget: .max, caps: [instagram.id: .max])
        let askable = Validator.askableMinutes(door: instagram, state: corrupt,
                                               ledger: GrantLedger(), now: at(12),
                                               dayStart: dayStart(at(12)), calendar: cal)
        #expect(askable == 600)
        guard case .grant(_, let minutes, _) = say("instagram \(askable)", corrupt) else {
            Issue.record("the wall promised \(askable) and the bar refused")
            return
        }
        #expect(minutes == askable)
    }

    // MARK: - The ceiling on a ceiling

    /// A cap sentence carrying the same literal. It is a TIGHTEN against an
    /// uncapped door (absent is infinity, 1440 is less), so it lands instantly —
    /// and what lands is a day, not the literal.
    @Test func anAbsurdCapIsClampedToADay() {
        let p = policy()
        guard case .ruleChange(let proposed, let polarity) = say("cap instagram at \(absurd)", p) else {
            Issue.record("the cap sentence stopped being a rule change")
            return
        }
        #expect(proposed.doorCaps[instagram.id] == PolicyState.maxMinutesPerDay)
        #expect(polarity == .tighten, "absent is infinity, so any ceiling at all is a tighten")
    }

    /// Clearing still clears. `nil` is absence, not a number, and the clamp must
    /// not manufacture a ceiling of 1440 out of it — that would turn the one
    /// sentence that REMOVES a restriction into one that imposes the tightest
    /// legal ceiling the day allows.
    @Test func clearingACeilingIsStillAbsenceAndNotADay() {
        let p = policy(caps: [instagram.id: 20])
        guard case .ruleChange(let proposed, let polarity) = say("uncap instagram", p) else {
            Issue.record("the clearing sentence stopped being a rule change")
            return
        }
        #expect(proposed.doorCaps[instagram.id] == nil)
        #expect(polarity == .loosen)
    }

    // MARK: - The constant itself

    /// The bound, stated once, in the two directions it has.
    @Test func theDailyClampIsADayAtBothEnds() {
        #expect(PolicyState.maxMinutesPerDay == 1440)
        #expect(PolicyState.clampedDaily(1440) == 1440)
        #expect(PolicyState.clampedDaily(1441) == 1440)
        #expect(PolicyState.clampedDaily(.max) == 1440)
        #expect(PolicyState.clampedDaily(30) == 30, "an ordinary number passes through untouched")
        #expect(PolicyState.clampedDaily(0) == 0, "zero is a product question, not a bounds one")
        #expect(PolicyState.clampedDaily(-1) == 0)
    }

    /// Every ordinary budget the product can actually reach is below the bound,
    /// so the clamp is invisible to the sentences people say. If a budget wheel
    /// ever grows a seat past a day, this is the test that says so.
    @Test func theClampIsInvisibleToEveryRealNumber() {
        for m in [0, 5, 15, 30, 45, 60, 90, 120, 240, 480, 1439] {
            #expect(PolicyState.clampedDaily(m) == m)
        }
        for seat in Caps.wheelTable {
            #expect(PolicyState.clampedDaily(seat) == seat)
        }
    }
}

// MARK: - The stored blob

@Suite struct AStoredPolicyReadsBackInsideTheDay {
    /// A policy persisted before the ceiling existed — or hand-corrupted — must
    /// decode to the same day the bar enforces, or the hero draws a number the
    /// bar refuses (README rule 2: the screen must not lie). The memberwise
    /// init stays raw on purpose so the validator tests above can still hand
    /// it an absurd state and prove nothing traps; the setters and the
    /// decoder are the clamp, and this test is the decoder's half.
    @Test func aBudgetAndACapPastTheDayReadBackAsOneDay() throws {
        let raw = PolicyState(budgetMinutes: Int.max, downHours: night, doors: [instagram],
                              doorCaps: [instagram.id: Int.max])
        let back = try JSONDecoder().decode(PolicyState.self, from: JSONEncoder().encode(raw))
        #expect(back.budgetMinutes == PolicyState.maxMinutesPerDay)
        #expect(back.doorCaps[instagram.id] == PolicyState.maxMinutesPerDay)
    }

    @Test func aBudgetInsideTheDayIsUntouched() throws {
        let raw = PolicyState(budgetMinutes: 90, downHours: night, doors: [instagram],
                              doorCaps: [instagram.id: 20])
        let back = try JSONDecoder().decode(PolicyState.self, from: JSONEncoder().encode(raw))
        #expect(back.budgetMinutes == 90)
        #expect(back.doorCaps[instagram.id] == 20)
    }
}
