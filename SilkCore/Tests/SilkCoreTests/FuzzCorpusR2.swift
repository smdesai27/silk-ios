import Foundation
import Testing
@testable import SilkCore

// Fuzz-corpus runner, round 2 (round-3 corpora: breakfixes + statetorture) and
// round 3 (the conversation corpus). Every row of FuzzCorpusR2Data.swift and
// FuzzCorpusR3Data.swift is driven through the real pipeline —
// DeterministicParser.parse → Validator.validate — with its stated state and
// clock precondition, and the outcome compared against the expectation
// mini-grammar. Rows whose spec cannot be interpreted are skipped loudly
// (FUZZR2-SKIP / FUZZR3-SKIP on stdout), never guessed at.
//
// The interpreter is `FuzzCorpusRunner.swift`. It used to be copied into this
// file, 476 lines of it, and the header here said so; see that file for why
// the copy was not the frozen thing.

@Suite("Fuzz corpus R2")
struct FuzzCorpusR2 {

    @Test(arguments: FuzzCorpusR2Data.rows)
    func row(_ row: FuzzCorpusRow) {
        runRow(row, tag: "FUZZR2")
    }
}

// Round-3 conversation corpus (corpus-r3-conversation.json): run-ons,
// self-corrections, sign-offs, questions, negations, reported speech.
// Same spec mini-grammar, same interpreter, separate suite and grep tag.
@Suite("Fuzz corpus R3")
struct FuzzCorpusR3 {

    @Test(arguments: FuzzCorpusR3Data.rows)
    func row(_ row: FuzzCorpusRow) {
        runRow(row, tag: "FUZZR3")
    }
}
