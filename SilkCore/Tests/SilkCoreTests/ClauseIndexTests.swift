import Foundation
import Testing
@testable import SilkCore

// The clause primitive: what separates a clause, what deliberately does not,
// and the two properties that make the thing safe to build a rule on — that its
// tokens ARE the tokenizer's tokens, and that the tokenizer did not move.

private typealias Clauses = NumberParser.ClauseIndex

/// The clause ids as a plain array, rebuilt from the public questions. The type
/// keeps its ids private on purpose — an exposed id invites the "two clauses
/// apart" arithmetic that is the same counting mistake the index replaces — so
/// the tests derive them the way a rule would, from `sameClause`.
private func clauseIDs(_ text: String) -> [Int] {
    let idx = Clauses(text)
    var ids: [Int] = []
    var current = 0
    for i in idx.tokens.indices {
        if i > 0, !idx.sameClause(i - 1, i) { current += 1 }
        ids.append(current)
    }
    return ids
}

private func clauseStrings(_ text: String) -> [[String]] {
    let idx = Clauses(text)
    let ids = clauseIDs(text)
    var out: [[String]] = []
    for (token, id) in zip(idx.tokens, ids) {
        if id == out.count { out.append([]) }
        out[id].append(token)
    }
    return out
}

@Suite struct ClauseSeparatorTests {

    @Test func theSentenceThisTypeExistsFor() {
        // "drop tiktok, im at my limit" tokenizes to six words with no trace of
        // the comma, so every rule downstream was measuring the distance from
        // "drop" to "limit" across a boundary it could not see.
        let idx = Clauses("drop tiktok, im at my limit")
        #expect(idx.tokens == ["drop", "tiktok", "im", "at", "my", "limit"])
        #expect(idx.clauseCount == 2)
        #expect(idx.sameClause(0, 1))        // drop / tiktok
        #expect(!idx.sameClause(1, 5))       // tiktok / limit
    }

    @Test func eachSeparatingCharacterSeparates() {
        for sep in [",", ";", "!", "?", "\n", "\r", "\u{2014}", "\u{2013}", " - ", " — "] {
            let idx = Clauses("block tiktok\(sep) give me instagram")
            #expect(idx.clauseCount == 2, "\(sep.debugDescription) did not separate")
            #expect(!idx.sameClause(1, 3), "\(sep.debugDescription) did not separate")
        }
    }

    @Test func everyLineBreakSeparates() {
        // "\r\n" is a SINGLE extended grapheme cluster, equal to neither
        // Character("\r") nor Character("\n"), so a switch over characters
        // missed every CRLF — which is what a paste from Windows, from a mail
        // client, or from many iOS text fields produces. Two typed commands on
        // two lines arrived as one breath. The four Unicode line breaks after
        // it were not in the separator set at all.
        //
        // A loop over one-scalar strings is exactly the test shape that cannot
        // see this, because it never forms the pair. This one forms it.
        for sep in ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}",
                    "\u{0085}", "\u{2028}", "\u{2029}"] {
            let idx = Clauses("block tiktok\(sep)block instagram")
            #expect(idx.tokens == ["block", "tiktok", "block", "instagram"],
                    "\(sep.debugDescription) is not a tokenize delimiter")
            #expect(idx.clauseCount == 2, "\(sep.debugDescription) did not separate")
        }
        #expect(Clauses("first line\r\nsecond line").clauseCount == 2)
    }

    @Test func aSeparatorCarryingACombiningMarkIsNotCut() {
        // The other half of deciding separator-hood over scalars. "!" followed
        // by a combining acute is one cluster, and its second scalar is a
        // Unicode mark — marks are in `CharacterSet.alphanumerics`, so the
        // tokenizer KEEPS it as a token. Cutting the cluster would drop a token
        // the tokenizer kept and desync the index from the array a rule indexes
        // into, which is the one failure this type cannot be allowed to have.
        // A lost boundary is survivable; a lost token is not.
        let text = "block tiktok!\u{0301} give me instagram"
        let idx = Clauses(text)
        #expect(idx.tokens == NumberParser.tokenize(text))
        #expect(idx.tokens.contains("\u{0301}"))
        #expect(idx.clauseCount == 1)
    }

    @Test func aFullStopSeparatesTwoSentences() {
        #expect(clauseStrings("block tiktok. give me instagram")
                == [["block", "tiktok"], ["give", "me", "instagram"]])
        // No space needed — the stop is the boundary, not the space.
        #expect(Clauses("block tiktok.give me instagram").clauseCount == 2)
    }

    // MARK: The characters that must NOT separate

    @Test func aColonIsAClock() {
        // tokenize keeps ":" as a token character so "10:30" survives whole.
        // A clause split there would hand back two tokens where the tokenizer
        // hands back one, and the alignment contract would break on the first
        // time anyone states a time.
        let idx = Clauses("down hours start at 10:30 and end at 7:15")
        #expect(idx.tokens == NumberParser.tokenize("down hours start at 10:30 and end at 7:15"))
        #expect(idx.clauseCount == 1)
        #expect(Clauses("10:30").tokens == ["10:30"])
        #expect(Clauses("10:30").clauseCount == 1)
    }

    @Test func aDecimalPointIsNotAClauseBreak() {
        for text in ["1.5 hours of tiktok", "give me 2.30 of instagram",
                     "down hours start at 10.30", "1.5.2.3"] {
            #expect(Clauses(text).clauseCount == 1, "split a number: \(text)")
        }
        // "1.5" is two tokens today — that is tokenize's business — but they
        // must be two tokens in ONE breath.
        #expect(Clauses("1.5 hours of tiktok").sameClause(0, 1))
    }

    @Test func anAbbreviationDotIsNotAClauseBreak() {
        // Both dots of "p.m." stay quiet: the internal one because a letter is
        // glued to its right, the closing one because a dot opened the letter to
        // its left. Read as full stops they strand the hour in one clause and
        // "today" in another.
        #expect(Clauses("shut youtube until 9 p.m. today").clauseCount == 1)
        #expect(Clauses("at 9 a.m. give me tiktok").clauseCount == 1)
        #expect(Clauses("p.m.").clauseCount == 1)
        #expect(Clauses("e.g. block tiktok").clauseCount == 1)
    }

    @Test func aSingleDigitEndsASentence() {
        // The abbreviation rule above used to be `alnumRunBefore == 1` alone,
        // and a run of one is also EVERY SINGLE DIGIT and every one-letter word.
        // In a 1–300 minute domain that is not an exotic case, and each of these
        // came back as ONE clause: a cap and a cap removal, a close and a grant,
        // two doors and two numbers, all in a single breath handed to a rule
        // that had been told it was one command. It is the tighten/loosen
        // confusion that cost the cap grammar three rounds, one level down in
        // the primitive built to end it.
        #expect(clauseStrings("cap tiktok at 5. no cap on instagram")
                == [["cap", "tiktok", "at", "5"], ["no", "cap", "on", "instagram"]])
        #expect(clauseStrings("cap tiktok at 5. im at my limit")
                == [["cap", "tiktok", "at", "5"], ["im", "at", "my", "limit"]])
        for text in ["cap tiktok at 5. give me instagram",
                     "shut youtube until 9. unblock instagram",
                     "im at 9. cap tiktok at 20",
                     "give me 8. block youtube"] {
            #expect(Clauses(text).clauseCount == 2, "a digit swallowed the stop: \(text)")
        }
        // A one-letter DOOR, and X is a real door — it is in the roster and in
        // the corpus. Handled by the same rule, not by naming the letter.
        #expect(clauseStrings("block x. give me 20 of instagram")
                == [["block", "x"], ["give", "me", "20", "of", "instagram"]])
        #expect(Clauses("no cap on x. cap tiktok at 20").clauseCount == 2)
    }

    @Test func anAbbreviationEndingASentenceIsAKnownHole() {
        // NOT a wish — a pin on what the code does today, and it is wrong.
        // The closing dot of an abbreviation is suppressed even when it is also
        // ending the sentence, so one clause holds a close verb, a door, an hour
        // AND a second command. Punctuation cannot tell this from
        // "shut youtube until 9 p.m. today" above, which is one command; the
        // distinguishing signal is whether a fresh predicate follows, and that
        // needs a verb lexicon, which belongs in a rule.
        //
        // It is pinned so the cap and down-hours rules inherit it announced
        // rather than discover it: a clause may hold more than one predicate.
        #expect(Clauses("shut youtube until 9 p.m. give me tiktok back").clauseCount == 1)
        #expect(Clauses("down hours till 11 p.m. cap tiktok at 20").clauseCount == 1)
    }

    @Test func anEllipsisIsHesitationNotAStop() {
        // A typed "..." trails off inside one thought. Breaking here would put
        // the door and its number in different clauses.
        #expect(Clauses("tiktok... 20?").clauseCount == 1)
        #expect(Clauses("tiktok\u{2026} 20").clauseCount == 1)
    }

    @Test func anApostropheIsNotASeparator() {
        // "tiktok's" already arrives as two tokens; they must not become two
        // clauses, or every possessive and contraction is a sentence boundary.
        let idx = Clauses("tiktok's cap")
        #expect(idx.tokens == ["tiktok", "s", "cap"])
        #expect(idx.clauseCount == 1)
        #expect(Clauses("dont block instagram").clauseCount == 1)
        #expect(Clauses("don't block instagram").clauseCount == 1)
    }

    @Test func aHyphenInsideANumberIsNotASeparator() {
        // tokenize rewrites "-" to a space so "twenty-five" reads as 25. A
        // break there would put the tens and the units in different breaths.
        // Neither of these has whitespace on both sides, which is exactly what
        // tells them apart from a hyphen used as a clause dash.
        #expect(Clauses("twenty-five minutes of tiktok").clauseCount == 1)
        #expect(Clauses("tiktok -5 a day").clauseCount == 1)
        #expect(Clauses("-5").clauseCount == 1)
    }

    @Test func aDashBetweenTwoQuantitiesIsARange() {
        // The en dash used to separate unconditionally, and the first string
        // here is Silk's own aperture line — harvested from DoorStateTests, the
        // product's rendering of the night window — so the start of the night
        // and its end were being put in different breaths. That is the identical
        // "splitting cuts a single quantity in two" failure that keeps "and" out
        // of the openers, committed against the character English reserves for
        // ranges, and a down-hours start with no end is how a tightening becomes
        // a question or a loosening.
        for text in ["☾\u{A0} 10:00\u{A0}PM – 7:00\u{A0}AM",
                     "wind down 10:00 PM – 7:00 AM",
                     "down hours 10pm – 7am",
                     "give me 20–30 minutes of tiktok",
                     "cap tiktok at 20–25",
                     "down hours 10 - 7",
                     "10 – 7",
                     "one — two – three"] {
            #expect(Clauses(text).clauseCount == 1, "a range was cut in two: \(text)")
        }
        // The quantity may be a clock, a bare count, a meridiem, or a number
        // word — the question is what the word IS, not which dash was typed.
        #expect(Clauses("☾\u{A0} 10:00\u{A0}PM – 7:00\u{A0}AM").sameClause(0, 3))
    }

    @Test func aDashBesideAPredicateIsAClauseBreak() {
        // ...and the same rule the other way. All three spellings break, which
        // matters because the split used to run backwards against what a phone
        // keyboard produces: the typographic dashes broke and the spaced hyphen,
        // the one a user actually types, did not — so the same sentence got two
        // structures depending on which dash the keyboard chose.
        for text in ["cap tiktok at 20 - give me instagram",
                     "cap tiktok at 20 — give me instagram",
                     "cap tiktok at 20—give me instagram",
                     "cap tiktok at 20 – give me instagram"] {
            #expect(clauseStrings(text)
                    == [["cap", "tiktok", "at", "20"], ["give", "me", "instagram"]],
                    "a dash beside a verb did not break: \(text)")
        }
        #expect(clauseStrings("2 picked — tap one to remove.")
                == [["2", "picked"], ["tap", "one", "to", "remove"]])
    }

    // MARK: Trailing and doubled separators

    @Test func trailingAndDoubledSeparatorsMintNoEmptyClauses() {
        // An empty clause would shift every id after it and quietly desync the
        // index from the tokens.
        #expect(clauseStrings("tiktok 20 a day.") == [["tiktok", "20", "a", "day"]])
        #expect(clauseStrings("wait,, what") == [["wait"], ["what"]])
        #expect(clauseStrings("INSTAGRAM TEN!!!") == [["instagram", "ten"]])
        #expect(clauseStrings("hello!!! block tiktok???") == [["hello"], ["block", "tiktok"]])
        // Nothing but separators is no clauses at all, not one empty one.
        for text in ["", "   ", "...", "   ,,,   ", ".", ","] {
            let idx = Clauses(text)
            #expect(idx.tokens.isEmpty, "unexpected tokens in \(text.debugDescription)")
            #expect(idx.clauseCount == 0, "empty clause minted by \(text.debugDescription)")
        }
    }

    // MARK: Word separators

    @Test func theFourClauseOpeners() {
        #expect(clauseStrings("cap tiktok at 20 but give me instagram")
                == [["cap", "tiktok", "at", "20"], ["but", "give", "me", "instagram"]])
        #expect(Clauses("block tiktok so i stop scrolling").clauseCount == 2)
        #expect(Clauses("give me tiktok anyway").clauseCount == 2)
        #expect(Clauses("block tiktok though").clauseCount == 2)
        // The opener keeps its token — a word break moves an id, it removes
        // nothing, which is why it cannot break alignment.
        #expect(Clauses("block tiktok though").tokens == ["block", "tiktok", "though"])
    }

    @Test func anOpenerCostsRecallAndTheCostIsASilence() {
        // What "so" and "but" cost, pinned rather than argued away. The comment
        // on `clauseOpeners` once called these readings inert; they are not.
        // "cap tiktok so i only get 20 a day" puts the door in one clause and
        // its number in the next, so a bounded-scan cap rule finds a door with
        // no number and declines.
        #expect(clauseStrings("cap tiktok so i only get 20 a day")
                == [["cap", "tiktok"], ["so", "i", "only", "get", "20", "a", "day"]])
        #expect(!Clauses("cap tiktok so i only get 20 a day").sameClause(1, 6))
        #expect(Clauses("im so over tiktok, block it").clauseCount == 3)
        #expect(Clauses("i have but 20 minutes").clauseCount == 2)
        // That is the recoverable direction, and this is what it buys: a purpose
        // clause carries a quantity of its own, and glued to the command that
        // quantity is a number sitting beside a door — a cap out of thin air.
        #expect(!Clauses("block instagram so i can get 8 hours").sameClause(1, 6))
    }

    @Test func wordsThatDeliberatelyDoNotOpenAClause() {
        // Splitting at "and" would cut a single quantity in two.
        #expect(Clauses("an hour and a half of youtube").clauseCount == 1)
        #expect(NumberParser.allNumbers(in: "an hour and a half of youtube") == [90])
        #expect(Clauses("ten or twenty minutes").clauseCount == 1)
        #expect(Clauses("an hour and a half and then some").clauseCount == 1)
    }

    @Test func anOpenerAtTheStartOpensNothing() {
        // A leading "but" would otherwise close a clause holding no tokens.
        #expect(clauseStrings("but give me 20 of instagram")
                == [["but", "give", "me", "20", "of", "instagram"]])
        #expect(Clauses("so give me 20 of instagram").clauseCount == 1)
    }

    @Test func anOpenerAfterAStopBreaksOnlyOnce() {
        #expect(clauseStrings("block tiktok, but give me instagram")
                == [["block", "tiktok"], ["but", "give", "me", "instagram"]])
    }

    // MARK: The questions a rule may ask

    @Test func sameClauseIsTotalAndReflexive() {
        let idx = Clauses("cap tiktok at 20")
        for i in idx.tokens.indices { #expect(idx.sameClause(i, i)) }
        // Out of range answers "different clause" rather than trapping: a rule
        // that miscounts should decline to connect two words, not crash.
        #expect(!idx.sameClause(0, 99))
        #expect(!idx.sameClause(-1, 0))
        #expect(!Clauses("").sameClause(0, 0))
        #expect(idx.clauseRange(containing: 99) == nil)
        #expect(Clauses("").clauseRange(containing: 0) == nil)
    }

    @Test func clauseRangeIsTheClauseAndNothingElse() {
        let text = "drop tiktok, im at my limit, cap it at 20"
        let idx = Clauses(text)
        for i in idx.tokens.indices {
            guard let r = idx.clauseRange(containing: i) else {
                Issue.record("no range for token \(i)"); continue
            }
            #expect(r.contains(i))
            for j in r { #expect(idx.sameClause(i, j)) }
            if r.lowerBound > 0 { #expect(!idx.sameClause(i, r.lowerBound - 1)) }
            if r.upperBound < idx.tokens.count { #expect(!idx.sameClause(i, r.upperBound)) }
        }
        #expect(idx.clauseCount == 3)
    }
}

// MARK: - The sentences this was built for

/// The nine sentences that defeated the cap grammar, and the decomposition each
/// one needs. This suite is the PR's reason to exist stated as an assertion: if
/// it goes red, the primitive has stopped being worth building a rule on, and no
/// amount of green elsewhere makes up for it.
///
/// Six of the nine are wins only because a rule can now REJECT a combination —
/// the cap word, the door and the number are visibly not in one breath. That is
/// why the whole file leans toward splitting: a refused clause costs a silence
/// and defers to the model, while a wrongly-joined one is what read a tightening
/// as a loosening twice.
@Suite struct ClauseIndexFitness {

    @Test func theSentencesThatDefeatedTheCapGrammar() {
        let expected: [(String, [[String]])] = [
            // The door is in a different breath from "limit".
            ("drop tiktok, im at my limit",
             [["drop", "tiktok"], ["im", "at", "my", "limit"]]),
            // "capped" and the door are away from the 20.
            ("tiktok is capped, give me 20 minutes",
             [["tiktok", "is", "capped"], ["give", "me", "20", "minutes"]]),
            // The close and the door are away from the 20.
            ("block tiktok, 20 minutes a day is plenty",
             [["block", "tiktok"], ["20", "minutes", "a", "day", "is", "plenty"]]),
            // "limit" is away from the door and its number.
            ("i hit my limit, give me 20 of tiktok",
             [["i", "hit", "my", "limit"], ["give", "me", "20", "of", "tiktok"]]),
            // The door is away from "limit" and from the 20.
            ("drop instagram, ive hit my limit 20 times",
             [["drop", "instagram"], ["ive", "hit", "my", "limit", "20", "times"]]),
            // "cap" is away from the door.
            ("i want 20 of tiktok, no cap needed",
             [["i", "want", "20", "of", "tiktok"], ["no", "cap", "needed"]]),
            // The 30 has no door in its clause, so it stays a budget.
            ("make it 30 a day, instagram is killing me",
             [["make", "it", "30", "a", "day"], ["instagram", "is", "killing", "me"]]),
            // ...and the two that must NOT be split, or the grammar loses the
            // sentences it is supposed to read.
            ("cap tiktok at 20", [["cap", "tiktok", "at", "20"]]),
            ("give me 20 minutes of tiktok a day",
             [["give", "me", "20", "minutes", "of", "tiktok", "a", "day"]]),
        ]
        for (text, clauses) in expected {
            #expect(clauseStrings(text) == clauses, "wrong decomposition: \(text)")
        }
    }

    @Test func theSameSentencesWithAStopInsteadOfAComma() {
        // The same shapes a user types with a full stop, which is where the
        // single-digit hole put them all back into one breath.
        #expect(clauseStrings("drop tiktok. im at my limit")
                == [["drop", "tiktok"], ["im", "at", "my", "limit"]])
        #expect(clauseStrings("cap tiktok at 5. im at my limit")
                == [["cap", "tiktok", "at", "5"], ["im", "at", "my", "limit"]])
        #expect(clauseStrings("i want 5. no cap on tiktok")
                == [["i", "want", "5"], ["no", "cap", "on", "tiktok"]])
    }
}

// MARK: - The properties

@Suite struct ClauseAlignmentProperty {

    /// THE CONTRACT. A rule indexes into the token array; if the clause index
    /// disagrees about how many tokens there are, the rule walks off the end or
    /// asks about the wrong word. Asserted as full equality rather than as
    /// equal counts, because equal counts is the weaker half of what a rule
    /// relies on.
    @Test(arguments: ParserCorpus.all)
    func clausesAlignWithTokens(_ text: String) {
        let idx = NumberParser.ClauseIndex(text)
        let tokens = NumberParser.tokenize(text)
        #expect(idx.tokens == tokens, "clause index disagrees with tokenize on \(text.debugDescription)")
        #expect(clauseIDs(text).count == tokens.count)
    }

    /// The clauses partition the tokens: every token is in exactly one clause,
    /// the clauses are contiguous, and their ids run 0..<clauseCount with no
    /// gap. A gap would mean an empty clause, and an empty clause is how an
    /// off-by-one gets in.
    @Test(arguments: ParserCorpus.all)
    func clausesPartitionTheTokens(_ text: String) {
        let idx = NumberParser.ClauseIndex(text)
        var covered = 0
        var expectedStart = 0
        while expectedStart < idx.tokens.count {
            guard let r = idx.clauseRange(containing: expectedStart) else {
                Issue.record("no range at \(expectedStart) for \(text.debugDescription)"); return
            }
            #expect(r.lowerBound == expectedStart, "clause gap in \(text.debugDescription)")
            #expect(!r.isEmpty, "empty clause in \(text.debugDescription)")
            covered += r.count
            expectedStart = r.upperBound
        }
        #expect(covered == idx.tokens.count)
        #expect(idx.clauseCount == (clauseIDs(text).last.map { $0 + 1 } ?? 0))
    }

    @Test func theCorpusIsTheWholeSuite() {
        // A string that appears in a test and not here is a string the
        // alignment property never saw, and this is the check that says so.
        //
        // It used to say it with two counts, and counts are the wrong
        // instrument for both halves. `harvested.count == 331` stays green for
        // any 331 strings whatsoever, and `all.count == pairs.count` survives
        // any add-plus-delete pair, so a newly added corpus string could go
        // permanently un-goldened while the guard stayed green — the one thing
        // standing between a future tokenize change and a silent regression.
        // Both are set comparisons now, and a set comparison names the string
        // it is unhappy about.
        #expect(Set(TokenizeGolden.pairs.map(\.input)) == Set(ParserCorpus.all),
                "the golden and the corpus hold different strings")

        // No string counted twice. Three of the hand-written traps were re-runs
        // of strings the harvest already had, so `all.count` claimed more
        // coverage than it had and three golden rows were duplicates.
        #expect(Set(ParserCorpus.all).count == ParserCorpus.all.count,
                "duplicate corpus entries")
        #expect(Set(ParserCorpus.harvested).isDisjoint(with: Set(ParserCorpus.clauseTraps)),
                "a hand-written trap repeats a harvested string")

        // The harvest does not shrink. Not a pin on WHICH strings — the set
        // comparison above is that — but on the harvest not being quietly
        // emptied out to make something else green.
        #expect(ParserCorpus.harvested.count >= 331)
    }

    /// The tokenizer itself did not move. This PR promises zero behaviour
    /// change, and "the 220 tests still pass" is the weaker statement — the
    /// tests assert what the parser ANSWERS, and two different tokenizations
    /// can give the same answer today and diverge the moment a cap rule reads
    /// them. `TokenizeGolden` is what today's tokenizer said, frozen before the
    /// clause index was written.
    @Test(arguments: TokenizeGolden.pairs)
    func tokenizeIsUnchanged(_ pair: (input: String, tokens: [String])) {
        #expect(NumberParser.tokenize(pair.input) == pair.tokens,
                "tokenize moved on \(pair.input.debugDescription)")
    }
}

@Suite struct ClauseIndexCost {

    @Test func aHugeInputStaysLinear() {
        // Same shape as hugeInputStaysCheapAndSilent, which pins the parse cost.
        //
        // MEASURED, because a number in a comment in this file is load-bearing
        // and the first draft of this one was wrong by 9x. On this machine, the
        // 82k-character string below: `tokenize` 2.9 ms, `ClauseIndex` 80 ms.
        // Scaling is clean linear — 80 / 162 / 326 / 655 ms at 1x / 2x / 4x / 8x
        // — so the quadratic fear the bound guards against is unfounded, and the
        // ~12x headroom under a second is what the bound is really for.
        //
        // The 28x constant against `tokenize` is attributable and worth knowing
        // before a rule starts building indexes: the same string with NO
        // separators (one clause, one `tokenize` call) costs 24 ms, so the other
        // 56 ms is ~14 microseconds per clause, spent because `ClauseIndex`
        // calls `tokenize` once per piece and `tokenize` rebuilds its
        // `CharacterSet` on every call. Hoisting that set is a pure value and
        // would remove most of it — but it is an edit to `tokenize`, which this
        // PR promises not to touch, and there is no workload to measure it
        // against until a rule actually builds an index. It belongs to the PR
        // that does.
        let noise = Array(repeating: "lorem ipsum, dolor sit amet. consectetur",
                          count: 2000).joined(separator: " ")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let idx = NumberParser.ClauseIndex(noise)
            #expect(idx.tokens.count == NumberParser.tokenize(noise).count)
            // A comma and a full stop in each of the 2000 repeats.
            #expect(idx.clauseCount == 4001)
        }
        #expect(elapsed < .seconds(1), "clause index too slow on 10k words: \(elapsed)")
    }

    @Test func theDashLookaroundDoesNotGoQuadratic() {
        // The dashes are the one separator that reads a word to its RIGHT, and a
        // forward scan inside a per-character loop is the classic way to write
        // an accidental O(n²). It stays linear because the scans are disjoint:
        // each one is bounded by the whitespace gap it skips and the word it
        // reads, and no two candidates share either. Measured on the worst two
        // shapes — a dash every seven characters, and one dash behind a 40k
        // whitespace gap — 83 ms and 14 ms.
        let clock = ContinuousClock()
        let dashes = String(repeating: "aaaa - ", count: 5000)
        #expect(clock.measure { _ = NumberParser.ClauseIndex(dashes) } < .seconds(1))
        let longGap = "a" + String(repeating: " ", count: 40_000) + "- b"
        #expect(clock.measure { _ = NumberParser.ClauseIndex(longGap) } < .seconds(1))
    }

    @Test func theParserDoesNotPayForWhatItDoesNotAsk() {
        // Nothing in DeterministicParser builds a ClauseIndex yet, so a
        // sentence that asks no clause question costs exactly what it did
        // before. Stated as a test so that the first rule to build one has to
        // come back here and say what it now costs.
        let state = PolicyState(budgetMinutes: 40,
                                downHours: DownHours(start: TimeOfDay(hour: 22),
                                                     end: TimeOfDay(hour: 7)),
                                doors: [Door(name: "TikTok")])
        let noise = Array(repeating: "lorem ipsum dolor sit amet", count: 2000).joined(separator: " ")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(DeterministicParser.parse(noise, state: state) == .silence)
        }
        #expect(elapsed < .seconds(1), "parser too slow on 10k words: \(elapsed)")
    }
}
