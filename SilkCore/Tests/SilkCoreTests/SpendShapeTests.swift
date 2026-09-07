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

private let instagram = Door(name: "Instagram")
private let tiktok = Door(name: "TikTok")
private let reddit = Door(name: "Reddit")

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

/// A fixed afternoon: 2026-07-29 15:00 local — outside the night window below.
private func afternoon() -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 15))!
}

private func makeState(_ doors: [Door] = [instagram, tiktok]) -> PolicyState {
    PolicyState(budgetMinutes: 40,
                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                doors: doors)
}

/// The state the "with Reddit a door" rows run against. Instagram stays FIRST,
/// so the doorless fragments still name it.
private func stateWithReddit() -> PolicyState { makeState([instagram, tiktok, reddit]) }

private func parse(_ text: String, _ state: PolicyState = makeState()) -> ParseOutcome {
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
        guard case .command(.spend(let d, let m)) = parse(text) else {
            Issue.record("\"\(text)\" did not spend: \(parse(text))")
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
        #expect(parse(typed) == .command(.spend(door: instagram, minutes: 10)))
        #expect(parse(SilkStrings.writeItOut("TikTok", minutes: 25)
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
        expectWriteItOut(parse(row.0), row.0, door: row.1, minutes: row.2)
    }

    /// The corpus's own chatty ask, which used to grant on the request modal
    /// alone. It still names its door and its number; it just no longer opens
    /// anything without a verb.
    @Test func theChattyAskIsWrittenOut() {
        let text = "hey so i was thinking maybe like 10 minutes of reddit would be nice"
        expectWriteItOut(parse(text, stateWithReddit()), text, door: "Reddit", minutes: 10)
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
        expectWriteItOut(parse(row.0), row.0, door: row.1, minutes: nil)
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
        expectWriteItOut(parse(row.0), row.0, door: "Instagram", minutes: row.1)
    }

    @Test(arguments: [("instagram", "Instagram"), ("tiktok please", "TikTok")])
    func aDoorAlone(_ row: (String, String)) {
        expectWriteItOut(parse(row.0), row.0, door: row.1, minutes: nil)
    }

    /// Both fragment rules need a door to name, and a policy with no doors has
    /// none to guess at. Silence, not a crash and not a sentence about nothing.
    @Test func aDoorlessPolicyStaysSilent() {
        let empty = makeState([])
        #expect(parse("10 minutes", empty) == .silence)
        #expect(parse("instagram", empty) == .silence)
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
        #expect(parse(text) == .silence, "\"\(text)\" was \(parse(text))")
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
        let outcome = parse(text)
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
        #expect(parse(text) == .silence, "\"\(text)\" was \(parse(text))")
    }

    /// AND THE FRAGMENT RULES TOOK NOTHING. They stand after every other rule
    /// precisely so that a sentence some rule already claims keeps it.
    @Test func theNeighbouringCommandsStillLand() {
        #expect(parse("budget 30") == .command(.setBudget(minutes: 30)))
        #expect(parse("cap tiktok 20") == .command(.setDoorCap(door: tiktok, minutes: 20)))
        #expect(parse("how much is left") == .command(.status))
        guard case .command(.closeDoorToday(let d, _)) = parse("no more instagram today") else {
            Issue.record("\"no more instagram today\" was \(parse("no more instagram today"))")
            return
        }
        #expect(d.name == "Instagram")
    }
}

// MARK: - The Validator, and the sentence the app composes

@Suite struct TheGuidanceIsARefusalThatDebitsNothing {

    private func validate(_ text: String, at now: Date = afternoon()) -> Verdict {
        Validator.validate(parse(text), utterance: text, state: makeState(),
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
    @Test func theNightDefersIt() {
        let v = Verdict.refuseWriteItOut(door: instagram, minutes: 10)
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
        #expect(SilkStrings.hintRange == 1...300)
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
        #expect(parse(sentence) == .silence)
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
