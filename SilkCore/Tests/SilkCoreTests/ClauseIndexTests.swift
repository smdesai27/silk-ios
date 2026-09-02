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
        //
        // The token shape moved here on purpose (see TokenizeGolden's header):
        // splitting left "don't" as ["don", "t"], which matches nothing, so the
        // apostrophe spelling of every negator in the grammar was dead and
        // "don't cap tiktok at 20" wrote the ceiling it refuses. The clause
        // claim below is the one this test was written for, and it is unmoved.
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

    /// Ten thousand words in one breath cost what the same ten thousand words cost
    /// in ten. Which is what linear MEANS, and what the name has been claiming.
    ///
    /// **This test was a stopwatch, and the stopwatch was measuring the machine.**
    /// It timed one 10k-word string, once, against `< 1 second`, and on 2026-08-12
    /// it failed one run in six on an otherwise idle laptop — 1.032 s against a
    /// bound of 1 s, with nothing whatever wrong with the index and the same suite
    /// green five runs either side. Because `.githooks/pre-push` runs
    /// `scripts/ci.sh spine`, that one-in-six landed on unrelated pushes as a retry
    /// loop, which is the exact tax `StressTests.hugeInputStaysCheapAndSilent` was
    /// rewritten to stop paying.
    ///
    /// The name was the tell. `aHugeInputStaysLinear` asserted nothing about
    /// linearity: one input size against a fixed wall clock cannot see a slope,
    /// only an intercept, and the intercept it sees belongs as much to whatever
    /// else the machine was doing. A ratio between two sizes is a claim about the
    /// code; a wall clock is a claim about the hardware.
    ///
    /// **Why the arms are the same size, which is not the obvious design.** The
    /// obvious one — time 10k, time 1k, assert the ratio is nearer 10 than 100 —
    /// was built first and measured, and it flakes for a reason worth writing down.
    /// `fastestPair` estimates each arm's *uncontended* cost by taking a minimum
    /// over rounds, and a minimum only works if some round ran clean. The 10k arm's
    /// window is ten times longer, so it is ten times less likely to find a quiet
    /// slice — the two arms are contended UNEQUALLY even when interleaved, and the
    /// bias is one-directional: the numerator inflates and the denominator does
    /// not. Measured: across 25 quiet runs the naive ratio sat inside 9.4–10.7, and
    /// across eleven runs on a heavily loaded machine it ranged **10.3 to 23.3**
    /// against a bound of 25. It would have flaked again, on a bound that looked
    /// like it had 2.5× of room.
    ///
    /// So both arms do the same total work in the same-length window: ten thousand
    /// words as ONE string, against ten thousand words as TEN strings. A linear
    /// index does identical work either way and the healthy ratio is **1.0**; a
    /// quadratic one does ten times more on the long string, because ten times the
    /// length is a hundred times the work spread over a tenth as many calls. The
    /// signal is preserved and the estimator bias is gone, because now a quiet
    /// slice is exactly as easy to find on both sides.
    ///
    /// **The numbers.** Debug, Apple silicon, best of seven. Healthy sits at
    /// **1.0**: over 25 consecutive runs on a quiet machine the ratio stayed inside
    /// **0.92–1.17**, and over 20 runs at a load average of 16–24 on eight cores —
    /// which stretched the long arm from 130 ms to 570 ms, four times slower — it
    /// stayed inside **0.91–1.16**. Forty-five runs, no failures, and the arms
    /// moved together every time. The bound is **3**.
    ///
    /// Mutation-tested rather than assumed. `bounds` rebuilt by a scan over `ids`
    /// at every clause open — the shape of a plausible "derive the bounds instead
    /// of tracking them" edit, identical answers, genuinely O(n²) — measures
    /// **9.21** and fails on the first run. Note which assertion caught it: the
    /// quadratic build took **4.63 s** and walked *under* the five-second backstop.
    /// The ratio is the instrument here; the backstop is a courtesy.
    ///
    /// So the bound sits at 3, between a healthy 1.0 and a broken 9.2 with a
    /// factor of three either side, and its exact value is doing no work — which
    /// is the property that makes it safe on hardware nobody has seen yet. What it
    /// can and cannot see, stated honestly: at 3 it fires once the quadratic term
    /// reaches about three times the linear one at ten thousand words. A quadratic
    /// scan small enough to hide under that at this size is not hiding at a
    /// hundred thousand, and nothing in this repo would notice it at ten.
    ///
    /// The absolute bound is kept, coarsened to five seconds, and demoted to what
    /// a wall clock can honestly do: catch a catastrophe. Against a measured
    /// 130–210 ms it has 25–38× of headroom quiet, and still 7× against the worst
    /// seen at load average 24 — where the old one-second bound had 12× on paper
    /// and reddened anyway.
    ///
    /// **The constant is still worth knowing** before a rule starts building
    /// indexes, and this is the only place it is written down. Measured on the
    /// 82k-character string below: `tokenize` alone **5.2 ms**, the same string
    /// with its separators stripped — one clause, one `tokenize` call — **42 ms**,
    /// and the real thing with its 4001 clauses **151 ms**. So the index costs ~29×
    /// the tokenizer, and the ~109 ms between the last two figures is ~27 µs per
    /// clause, spent because `ClauseIndex` calls `tokenize` once per piece and
    /// `tokenize` rebuilds its `CharacterSet` on every call. Hoisting that set is a
    /// pure value and would remove most of it — but it is an edit to `tokenize`,
    /// and there is no workload to measure it against until a rule actually builds
    /// an index. It belongs to the PR that does. Note what the ratio does *not*
    /// say: that 27 µs could become 270 µs without moving it at all. A ratio pins
    /// the slope; only the person who reads these figures pins the intercept.
    @Test func aHugeInputStaysLinear() {
        // Six words and two separators per repeat, so the two arms are the same
        // words, the same punctuation and the same clauses-per-word. The only
        // difference is where the string ends.
        func noise(repeats: Int) -> String {
            Array(repeating: "lorem ipsum, dolor sit amet. consectetur",
                  count: repeats).joined(separator: " ")
        }
        let inOneBreath = noise(repeats: 2000)
        // Ten separately built strings rather than one string read ten times: the
        // long arm walks 82k characters of cold memory, and a single short string
        // read ten times would sit in cache and win the comparison on the strength
        // of that alone. Ten allocations touch the same total bytes.
        let inTenBreaths = (0..<10).map { _ in noise(repeats: 200) }

        // What the index ANSWERS, asserted outside the measurement. It used to be
        // inside it, which charged the clause index for a whole extra `tokenize`
        // pass over 82k characters and for Swift Testing's own bookkeeping — a
        // measurement of the index plus the test harness, held to a bound written
        // as though it were the index alone.
        let long = NumberParser.ClauseIndex(inOneBreath)
        #expect(long.tokens.count == NumberParser.tokenize(inOneBreath).count)
        // A comma and a full stop in each repeat.
        #expect(long.clauseCount == 4001)
        #expect(inTenBreaths.allSatisfy { NumberParser.ClauseIndex($0).clauseCount == 401 })
        // The two arms really are the same amount of work — asserted, because it
        // is the whole premise of the ratio below and a change to `noise` could
        // quietly break it.
        #expect(inTenBreaths.reduce(0) { $0 + NumberParser.ClauseIndex($1).tokens.count }
                == long.tokens.count)

        var sink = 0
        let (asOneString, asTenStrings) = fastestPair({
            sink &+= NumberParser.ClauseIndex(inOneBreath).clauseCount
        }, {
            for piece in inTenBreaths {
                sink &+= NumberParser.ClauseIndex(piece).clauseCount
            }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        #expect(asOneString < .seconds(5),
                "clause index catastrophically slow on 10k words: \(asOneString)")

        let scaling = ratio(asOneString, to: asTenStrings)
        #expect(scaling < 3,
                """
                ten thousand words in one string cost \(String(format: "%.2f", scaling))× what \
                the same ten thousand cost in ten (\(asOneString) against \(asTenStrings)) — \
                the clause index is no longer linear in the length of its input
                """)
    }

    @Test func theDashLookaroundDoesNotGoQuadratic() {
        // The dashes are the one separator that reads a word to its RIGHT, and a
        // forward scan inside a per-character loop is the classic way to write
        // an accidental O(n²). It stays linear because the scans are disjoint:
        // each one is bounded by the whitespace gap it skips and the word it
        // reads, and no two candidates share either. Measured on the worst two
        // shapes — a dash every seven characters, and one dash behind a 40k
        // whitespace gap — 83 ms and 14 ms.
        //
        // Best of three against a coarse backstop, for the reason stated at
        // length on `aHugeInputStaysLinear`: this was a single un-repeated
        // measurement against a bound 12× above it, which is the shape that
        // reddened one push in six. Five seconds is where a wall clock can still
        // say something honest — the quadratic version of either shape is tens of
        // seconds and this catches it, while a busy afternoon no longer does.
        let dashes = String(repeating: "aaaa - ", count: 5000)
        #expect(bestOfThree { _ = NumberParser.ClauseIndex(dashes) } < .seconds(5))
        let longGap = "a" + String(repeating: " ", count: 40_000) + "- b"
        #expect(bestOfThree { _ = NumberParser.ClauseIndex(longGap) } < .seconds(5))
    }

    /// The cheap path — a sentence that names no door — stays linear in its own
    /// length.
    ///
    /// **The premise this test opened with is expired, and the wall clock it
    /// rested on was never the instrument.** It used to say "nothing in
    /// DeterministicParser builds a ClauseIndex yet, so a sentence that asks no
    /// clause question costs exactly what it did before", and it held that claim
    /// with a five-second absolute over a best-of-three. Both halves are gone:
    /// the cap rules build an index whenever a door is named — measured here,
    /// the same ten thousand words cost **88.8 ms** with no door in them and
    /// **403 ms** with " cap tiktok at 20 a day" on the end, a 4.5× gap that is
    /// the index and the rule ladder behind it — and the five seconds was the
    /// same five seconds, on the same size of input, that
    /// `StressTests.hugeInputStaysCheapAndSilent` measured at 6.0–17.2 s under
    /// load with a healthy parser before deleting its own copy of it. Its
    /// comment says so and asks for this one to be coarsened; a bound a healthy
    /// machine exceeds by 3.4× is not coarsened, it is replaced.
    ///
    /// So what is left is the property the doorless path deserves in its own
    /// right, in the shape `aHugeInputStaysLinear` uses: equal total work in
    /// both arms, interleaved, minimum of seven rounds, and a ratio rather than
    /// a clock. It is not redundant with the stress suite's bound, which parses
    /// arms that END in a cap sentence and therefore measures the index path.
    /// This one measures the ladder every sentence walks — the common case, and
    /// the one prose reaches — so when the two disagree the pair says where the
    /// regression is rather than only that there is one.
    ///
    /// Measured healthy across three full-suite runs, which is the contended
    /// case rather than the quiet one: **0.99, 1.35, 1.03** against the bound of
    /// 3. The 1.35 is the honest number to write down — the arms are ~0.3 s
    /// windows and the whole suite is running beside them — and it is what the
    /// remaining margin is, not the 1.0.
    @Test func theParserDoesNotPayForWhatItDoesNotAsk() {
        let state = PolicyState(budgetMinutes: 40,
                                downHours: DownHours(start: TimeOfDay(hour: 22),
                                                     end: TimeOfDay(hour: 7)),
                                doors: [Door(name: "TikTok")])
        // Five words per repeat and no separator anywhere, so the whole input is
        // ONE clause and no door is named — the sentence asks nothing, which is
        // the path under test.
        func noise(repeats: Int) -> String {
            Array(repeating: "lorem ipsum dolor sit amet", count: repeats).joined(separator: " ")
        }
        let inOneBreath = noise(repeats: 2000)
        // Ten separately built strings rather than one string parsed ten times,
        // for the reason `aHugeInputStaysLinear` states: the long arm walks its
        // input out of cold memory, and one short string read ten times would
        // sit in cache and win on the strength of that alone.
        let inTenBreaths = (0..<10).map { _ in noise(repeats: 200) }

        // What the parser ANSWERS, asserted outside the measurement — inside, the
        // short arm would pay for ten of Swift Testing's bookkeeping against the
        // long arm's one, which inflates the denominator and blinds the ratio.
        #expect(DeterministicParser.parse(inOneBreath, state: state) == .silence)
        #expect(inTenBreaths.allSatisfy { DeterministicParser.parse($0, state: state) == .silence })

        // A coarse ceiling beside the ratio. The ratio cannot see a regression
        // that multiplies both arms alike — a per-token allocation, a regex
        // compiled in the loop — and the bar holds a ~480 ms beat. Thirty
        // seconds is two orders of magnitude over the ~90 ms measured, wide
        // enough that no loaded afternoon reaches it and narrow enough that a
        // parse that went to minutes cannot hide behind a healthy ratio.
        let coarse = ContinuousClock()
        let started = coarse.now
        _ = DeterministicParser.parse(inOneBreath, state: state)
        #expect(coarse.now - started < .seconds(30),
                "a ten-thousand-word parse took longer than thirty seconds")

        // The two arms really are the same amount of work — asserted, because it
        // is the whole premise of the ratio and a change to `noise` could quietly
        // break it.
        #expect(NumberParser.tokenize(inOneBreath).count == 10_000)
        #expect(inTenBreaths.allSatisfy { NumberParser.tokenize($0).count == 1_000 })

        var sink = 0
        let (asOneString, asTenStrings) = fastestPair({
            if DeterministicParser.parse(inOneBreath, state: state) == .silence { sink &+= 1 }
        }, {
            for piece in inTenBreaths
            where DeterministicParser.parse(piece, state: state) == .silence { sink &+= 1 }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let scaling = ratio(asOneString, to: asTenStrings)
        #expect(scaling < 3,
                """
                ten thousand doorless words in one string cost \
                \(String(format: "%.2f", scaling))× what the same ten thousand cost in ten \
                (\(asOneString) against \(asTenStrings)) — the rule ladder every sentence \
                walks is no longer linear in the length of its input
                """)
    }
}
