import Foundation
import Testing
@testable import SilkCore

// The shapes the other cost suites never feed their instruments.
//
// Every parse the other cost suites time is plain ASCII, no paste they parse
// has more than two clauses or names a door in more than one, one command
// family is timed through the Validator, and the ledger and the attempts fold
// have no cost test at all.
// Each suite below closes one of those gaps, and every bound but one is the
// construction `PerformanceMeasurement` states and `hugeInputStaysCheapAndSilent`
// settled on: two arms measured alternately through `fastestPair`, each arm's
// minimum, and a ratio whose arms differ only by the thing under test. Where
// the arms are one long input against ten short ones, a linear path reads about
// 1.0 and a quadratic one about 10, whatever the machine. The one exception is
// the contraction backstop, an absolute bound copied from its ASCII sibling.
//
// **None of these bounds has been measured.** They were written where no
// toolchain could run them, so every one of them is set from arithmetic at
// three times or more the healthy figure it expects, and every doc comment
// says what that expectation is. The first green runs should write the real
// figures into the comment on each test, from both the Linux spine lane and
// the macOS lane, the way `hugeInputStaysCheapAndSilent` records its 1.01,
// 1.03 and 1.01. A bound is tightened only after several readings are written
// down, and never to less than three times the worst of them.

// MARK: - The attempts fold

@Suite struct AFoldPaysForTheWindowNotTheBlob {

    /// **THE MEMBERSHIP SET IS BUILT OVER THE WINDOW, NOT THE BLOB.**
    /// `DayLog.foldedAttempts` promises that the set it filters a tail against
    /// holds only the blob's last `attemptsTailCap * 2` entries, "rather than
    /// being built over all 2000 entries on every read". `AttemptsTailTests`
    /// pins what the fold returns, and nothing pinned what it pays.
    ///
    /// The arms fold the same 64-entry tail into a full 2,000-entry blob and
    /// into a 200-entry one. Both blobs are longer than the 128-entry window,
    /// so both arms build the same size of set and filter the same tail against
    /// it, and every tail entry is new, so the filter keeps all of them. What
    /// is left between the arms is copying 2,000 dates rather than 200, plus
    /// the cap's own copy on the full side: plain memory copies. By that
    /// arithmetic the healthy ratio is about 1.0 to 1.3. A `Set(blob)`
    /// regression hashes 2,000 dates against 200 and reads about 7.
    ///
    /// The bound is 4, three times the expected healthy figure. The healthy
    /// figure is unrecorded: write the first readings here.
    @Test func theMembershipSetIsBuiltOverTheWindowOnly() {
        let base = afternoon()
        func minutes(_ n: Int, from start: Date) -> [Date] {
            (0..<n).map { start.addingTimeInterval(Double($0) * 60) }
        }
        // The blobs end a day before the tail begins, so no tail entry is
        // already known and the filter does real work on both sides.
        let fullBlob = minutes(DayLog.attemptsCap, from: base.addingTimeInterval(-200_000))
        let shortBlob = minutes(DayLog.attemptsCap / 10, from: base.addingTimeInterval(-200_000))
        let tail = minutes(DayLog.attemptsTailCap, from: base)

        // Asserted outside the measurement: both arms build a set of the same
        // size, the short blob is not capped, and the full one is.
        #expect(shortBlob.count >= DayLog.attemptsTailCap * 2,
                "the short blob is inside the window, so its set is smaller and the arms no longer differ only by the copy")
        #expect(DayLog.foldedAttempts(blob: shortBlob, tail: tail).count == shortBlob.count + tail.count)
        #expect(DayLog.foldedAttempts(blob: fullBlob, tail: tail).count == DayLog.attemptsCap)
        #expect(DayLog.foldedAttempts(blob: fullBlob, tail: tail).last == tail.last)

        var sink = 0
        let (full, short) = fastestPair({
            for _ in 0..<200 { sink &+= DayLog.foldedAttempts(blob: fullBlob, tail: tail).count }
        }, {
            for _ in 0..<200 { sink &+= DayLog.foldedAttempts(blob: shortBlob, tail: tail).count }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let r = ratio(full, to: short)
        #expect(r < 4,
                """
                folding into 2,000 attempts cost \(String(format: "%.2f", r))× folding into \
                200 — the membership set looks like it is built over the whole blob
                """)
    }
}

// MARK: - Off the ASCII road

@Suite struct ASentenceOffTheASCIIRoadStaysCheap {

    /// **A CONTRACTION IS AN ORDINARY SENTENCE.** Every sentence
    /// `OneSentenceStaysCheap` parses is ASCII with no apostrophe, while iOS
    /// smart punctuation types U+2019 in every contraction;
    /// `aContractionStaysOnTheBytePath` times that spelling through `tokenize`
    /// alone, and nothing timed a parse of it. `tokenize` hands a string whose
    /// only non-ASCII scalar is U+2019 to the byte path, and U+02BC, the
    /// modifier letter apostrophe, takes the Unicode road: `lowercased()`, the
    /// Character-level fold and Foundation's split, on every whole-sentence
    /// tokenization a parse makes. One sentence in each spelling, against the
    /// same 5 ms backstop and the same reasoning as
    /// `aShortSentenceParsesWellInsideAFrame`: a frame at 120 Hz is 8.3 ms, and
    /// that test's sentence measured about 320 µs in a debug build.
    ///
    /// An absolute bound, so it catches only a catastrophe: a parse on this
    /// road that grew to a visible hitch. The per-parse figure for these two
    /// spellings is unrecorded: write the first readings here.
    @Test func aContractionParsesWellInsideAFrame() {
        let state = makeState()
        // Every spelling tokenizes as the straight one does, so each must parse
        // as it does; and that answer must not be silence, or the bound times
        // a parse that stopped at the first rule.
        let expected = DeterministicParser.parse("i'm using instagram for 5 minutes", state: state)
        #expect(expected != .silence, "the probe stopped compiling, so the bound measures nothing")
        let spellings = [
            "i\u{2019}m using instagram for 5 minutes",   // what the iOS keyboard types
            "i\u{02BC}m using instagram for 5 minutes",   // the spelling that keeps the Unicode road
        ]
        for text in spellings {
            #expect(DeterministicParser.parse(text, state: state) == expected,
                    "\"\(sanitize(text))\" read differently from its straight spelling")
            let cost = fastest(rounds: 15) {
                for _ in 0..<20 { _ = DeterministicParser.parse(text, state: state) }
            }
            let each = seconds(cost) / 20
            #expect(each < 0.005,
                    "\"\(sanitize(text))\" costs \(String(format: "%.0f", each * 1e6)) µs")
        }
    }

    /// **A NON-ASCII PASTE STAYS LINEAR.** `hugeInputStaysCheapAndSilent` holds
    /// the parser linear on ASCII noise, which never leaves the byte path.
    /// Accented noise does, for every whole-text tokenization in the parse,
    /// and nothing timed that road at length.
    ///
    /// The construction is that test's: two thousand words as ONE string
    /// against the same words as TEN strings of two hundred, each ending in the
    /// same cap sentence so the clause index and the cap rules run. A linear
    /// parser reads 1.0 and a quadratic one about 10. Two thousand words
    /// rather than ten thousand because the Unicode road costs more per word
    /// and the suite pays for seven rounds of both arms.
    ///
    /// The bound is 3, as there, three times the healthy 1.0 that test
    /// records. This input's own healthy figure is unrecorded: write the first
    /// readings here.
    @Test func aNonASCIIPasteStaysLinear() {
        let state = makeState()
        func noise(words: Int) -> String {
            Array(repeating: "l\u{F6}rem ips\u{FC}m dol\u{F6}r sit \u{E4}met", count: words / 5)
                .joined(separator: " ")
        }
        let cap = " cap tiktok at 20 a day"
        let inOneBreath = noise(words: 2_000) + cap
        let inTenBreaths = (0..<10).map { _ in noise(words: 200) + cap }

        // What the parser answers and how much it reads, asserted outside the
        // measurement: the arms must reach the same outcome, and the short
        // side carries the cap sentence ten times over, which is slightly more
        // work and biases the ratio down, the conservative direction.
        let expected = DeterministicParser.parse(inOneBreath, state: state)
        #expect(expected != .silence, "the cap sentence stopped compiling, so the index path is not timed")
        #expect(inTenBreaths.allSatisfy { DeterministicParser.parse($0, state: state) == expected })
        #expect(NumberParser.tokenize(inOneBreath).count == 2_006)
        #expect(inTenBreaths.allSatisfy { NumberParser.tokenize($0).count == 206 })

        var sink = 0
        let (asOneString, asTenStrings) = fastestPair({
            if DeterministicParser.parse(inOneBreath, state: state) == expected { sink &+= 1 }
        }, {
            for piece in inTenBreaths
            where DeterministicParser.parse(piece, state: state) == expected { sink &+= 1 }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let scaling = ratio(asOneString, to: asTenStrings)
        #expect(scaling < 3,
                """
                two thousand accented words in one string cost \(String(format: "%.2f", scaling))× \
                what the same words cost in ten — the Unicode road is no longer linear
                """)
    }
}

// MARK: - Many clauses, each naming a door

@Suite struct AManyClausePasteStaysLinear {

    /// **A PASTE OF COMMANDS IS NOT A PASTE OF NOISE.** The linear-paste
    /// tests either have no separator, so the whole input is one clause
    /// (`hugeInputStaysCheapAndSilent`, `theParserDoesNotPayForWhatItDoesNotAsk`),
    /// or split once and name a door in the last breath only
    /// (`aNegatorDenseClauseParsesInLinearTime`), or build the clause index
    /// and name no door (`tenThousandWordsInOneBreathCostWhatTheyCostInTen`).
    /// A rule that rescans the clause list once per door mention or per number
    /// would be quadratic in exactly the shape none of them builds: many
    /// clauses, and a door and a number in every one.
    ///
    /// Two hundred two-clause units in one string against twenty in each of
    /// ten, so both arms read the same words, the same separators and the
    /// same doors. A linear parser reads 1.0 and a quadratic one about 10.
    /// Two hundred rather than more, so a quadratic rule fails this in
    /// seconds instead of holding the lane for minutes. The bound is 3, three
    /// times that healthy figure. The healthy figure is unrecorded: write the
    /// first readings here.
    @Test func fourHundredClausesCostWhatTheyCostInTen() {
        let state = makeState()
        let unit = "cap tiktok at 20 a day, unlock instagram for 10 minutes. "
        let inOneBreath = String(repeating: unit, count: 200)
        let inTenBreaths = (0..<10).map { _ in String(repeating: unit, count: 20) }

        // The premise, asserted: really many clauses (a comma and a full stop
        // per unit; a trailing separator mints no empty clause), the same
        // tokens on both sides, and the same answer from both arms, so a
        // change that makes one arm bail early cannot make the ratio vacuous.
        #expect(NumberParser.ClauseIndex(inOneBreath).clauseCount == 400)
        #expect(inTenBreaths.allSatisfy { NumberParser.ClauseIndex($0).clauseCount == 40 })
        #expect(NumberParser.tokenize(inOneBreath).count == 2_200)
        #expect(inTenBreaths.allSatisfy { NumberParser.tokenize($0).count == 220 })
        let expected = DeterministicParser.parse(inOneBreath, state: state)
        #expect(inTenBreaths.allSatisfy { DeterministicParser.parse($0, state: state) == expected },
                "two hundred units and twenty answer differently, so the arms walk different paths")

        var sink = 0
        let (asOneString, asTenStrings) = fastestPair({
            if DeterministicParser.parse(inOneBreath, state: state) == expected { sink &+= 1 }
        }, {
            for piece in inTenBreaths
            where DeterministicParser.parse(piece, state: state) == expected { sink &+= 1 }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let scaling = ratio(asOneString, to: asTenStrings)
        #expect(scaling < 3,
                """
                four hundred door-naming clauses in one string cost \
                \(String(format: "%.2f", scaling))× what the same clauses cost in ten — a rule \
                is rescanning the clauses per mention
                """)
    }
}

// MARK: - The Validator, on a paste, for the families that re-read it

@Suite struct AHugeUtteranceValidatesLinearlyForEveryFamily {

    /// **THE VALIDATOR RE-READS THE SENTENCE, AND ONLY ONE FAMILY WAS TIMED.**
    /// `aHugeUtteranceValidatesInOnePass` bounds `.setDownHoursStart`, whose
    /// provenance guard was the one found quadratic. The spend arm re-reads
    /// the utterance too: `allNumbers` for provenance and then
    /// `DeterministicParser.judgeSpend`, a fresh clause index and the spend
    /// gates. The cap arm runs its own `allNumbers`. Neither was bounded on a
    /// paste.
    ///
    /// Three thousand words ending in the command, once, against ten strings
    /// of three hundred ending in the same command. The outcomes are parsed
    /// OUTSIDE the measurement, so both arms time validation alone and a
    /// parse cannot dilute the denominator. A linear Validator reads 1.0 and a
    /// quadratic one about 10. The bound is 3, three times that healthy
    /// figure. The healthy figure for each family is unrecorded: write the
    /// first readings here.
    @Test func eachFamilyValidatesAPasteInOnePass() {
        let state = makeState()
        let ledger = GrantLedger()
        let now = afternoon()          // 15:00, outside the night window
        let calendar = cal
        func noise(words: Int) -> String {
            Array(repeating: "lorem ipsum dolor sit amet", count: words / 5).joined(separator: " ")
        }
        let families: [(tail: String, outcome: ParseOutcome)] = [
            (" unlock instagram for 10 minutes", .command(.spend(door: instagram, minutes: 10))),
            (" cap tiktok at 20 a day", .command(.setDoorCap(door: tiktok, minutes: 20))),
        ]
        for family in families {
            let inOneBreath = noise(words: 3_000) + family.tail
            let inTenBreaths = (0..<10).map { _ in noise(words: 300) + family.tail }

            // The probe compiles to the family it is named for, on both sides,
            // and validation answers both sides alike and not with silence.
            #expect(DeterministicParser.parse(inOneBreath, state: state) == family.outcome,
                    "\"\(family.tail)\" stopped compiling after a paste, so its bound measures nothing")
            #expect(inTenBreaths.allSatisfy { DeterministicParser.parse($0, state: state) == family.outcome })
            let verdict = Validator.validate(family.outcome, utterance: inOneBreath, state: state,
                                             ledger: ledger, now: now, calendar: calendar)
            #expect(verdict != .silence, "\"\(family.tail)\" was refused, so the gates were not all run")
            #expect(inTenBreaths.allSatisfy {
                Validator.validate(family.outcome, utterance: $0, state: state,
                                   ledger: ledger, now: now, calendar: calendar) == verdict
            })

            var sink = 0
            let (asOneString, asTenStrings) = fastestPair({
                if Validator.validate(family.outcome, utterance: inOneBreath, state: state,
                                      ledger: ledger, now: now, calendar: calendar) == verdict {
                    sink &+= 1
                }
            }, {
                for piece in inTenBreaths
                where Validator.validate(family.outcome, utterance: piece, state: state,
                                         ledger: ledger, now: now, calendar: calendar) == verdict {
                    sink &+= 1
                }
            })
            #expect(sink > 0)   // the compiler may not delete the work

            let scaling = ratio(asOneString, to: asTenStrings)
            #expect(scaling < 3,
                    """
                    validating "\(family.tail)" after three thousand words cost \
                    \(String(format: "%.2f", scaling))× what the same words cost in ten — \
                    a provenance guard is no longer linear in the utterance
                    """)
        }
    }
}

// MARK: - The ledger, at the size the app allows

@Suite struct TheLedgerReadsAreLinearInItsRows {

    /// Rows one second apart and one minute long, the newest issued two
    /// minutes before `now`, so every row sits inside one Silk day and every
    /// row has expired: nothing is open, and every read walks every row.
    static func ledger(rows: Int, before now: Date) -> GrantLedger {
        var l = GrantLedger()
        for i in 0..<rows {
            let issued = now.addingTimeInterval(-120 - Double(i))
            l.record(Grant(door: instagram, minutes: 1, issuedAt: issued,
                           expiresAt: issued.addingTimeInterval(60)))
        }
        return l
    }

    /// The reads a sentence and a Now pass make of the ledger: the pool, one
    /// door's draw, the row's live grant, the next wake, the Mirror's granted
    /// minutes, and the Validator's own spend path over all of them.
    static func reads(_ l: GrantLedger, state: PolicyState, now: Date,
                      dayStart: Date, dayEnd: Date, calendar: Calendar) -> Int {
        var n = l.spentMinutes(dayStart: dayStart, calendar: calendar)
        n &+= l.spentMinutes(doorID: instagram.id, dayStart: dayStart, calendar: calendar)
        n &+= l.activeGrant(for: instagram, at: now) == nil ? 0 : 1
        n &+= l.nextTransition(after: now) == nil ? 0 : 1
        n &+= DayLog.grantedMinutes(l.grants, from: dayStart, to: dayEnd)
        if case .grant = Validator.validate(.command(.spend(door: instagram, minutes: 5)),
                                            utterance: "unlock instagram for 5 minutes",
                                            state: state, ledger: l, now: now, calendar: calendar) {
            n &+= 1
        }
        return n
    }

    /// **NOTHING BUILT A LEDGER LARGER THAN FORTY ROWS.** `GrantLedger.grants`
    /// has no cap, the budget ceiling allows about 1,400 one-minute grants in
    /// a day, and the ledger keeps every row until `compact`. The reads above
    /// run on every sentence, every Now body pass and every wake, and a read
    /// that re-derived something per grant would be quadratic in a number
    /// nothing held down.
    ///
    /// 1,400 rows read once against 140 rows read ten times: the same rows in
    /// total. Healthy should sit under 1.0, because the Validator's fixed
    /// per-sentence cost (the spend gates over the utterance) is paid ten
    /// times on the short side, and `grantedMinutes`' sort adds about 1.5×
    /// the other way by arithmetic. A per-grant re-derivation reads about 8.
    /// The bound is 3, three times the 1.0 the healthy figure should stay
    /// under. The healthy figure is unrecorded: write the first readings here.
    @Test func fourteenHundredRowsCostWhatTheyCostInTen() {
        let state = makeState(budget: PolicyState.maxMinutesPerDay)
        let now = afternoon()
        let calendar = cal
        let dayStart = DayBoundary.dayStart(now: now, downHours: state.downHours, calendar: calendar)
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)
        let big = Self.ledger(rows: 1_400, before: now)
        let small = (0..<10).map { _ in Self.ledger(rows: 140, before: now) }

        // The premise, asserted outside the measurement: every row is in the
        // day, and the spend path reaches a grant on both sides (1,440 less
        // 1,400 leaves 40 minutes against a 5-minute ask), so neither arm is
        // timing an early refusal.
        #expect(big.spentMinutes(dayStart: dayStart, calendar: calendar) == 1_400)
        #expect(small.allSatisfy { $0.spentMinutes(dayStart: dayStart, calendar: calendar) == 140 })
        func grants(_ l: GrantLedger) -> Bool {
            if case .grant = Validator.validate(.command(.spend(door: instagram, minutes: 5)),
                                                utterance: "unlock instagram for 5 minutes",
                                                state: state, ledger: l, now: now, calendar: calendar) {
                return true
            }
            return false
        }
        #expect(grants(big), "the spend was refused on the full ledger, so the Validator arm times a refusal")
        #expect(small.allSatisfy { grants($0) })

        var sink = 0
        let (once, inTen) = fastestPair(rounds: 15, {
            sink &+= Self.reads(big, state: state, now: now, dayStart: dayStart,
                                dayEnd: dayEnd, calendar: calendar)
        }, {
            for l in small {
                sink &+= Self.reads(l, state: state, now: now, dayStart: dayStart,
                                    dayEnd: dayEnd, calendar: calendar)
            }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let scaling = ratio(once, to: inTen)
        #expect(scaling < 3,
                """
                reading 1,400 grants cost \(String(format: "%.2f", scaling))× reading 140 grants \
                ten times — a ledger read is no longer linear in its rows
                """)
    }
}
