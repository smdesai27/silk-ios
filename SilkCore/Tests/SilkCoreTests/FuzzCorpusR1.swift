import Foundation
import Testing
@testable import SilkCore

// Fuzz-corpus runner, round 1. Every mechanizable row of the four generated
// corpora (see FuzzCorpusR1Data.swift) is driven through the real pipeline —
// DeterministicParser.parse → Validator.validate — with its stated state and
// clock precondition, and the outcome is compared against the expectation
// mini-grammar the corpora are written in. Rows whose spec cannot be
// interpreted are skipped loudly (FUZZR1-SKIP on stdout), never guessed at.
//
// The interpreter itself is `FuzzCorpusRunner.swift`, shared with R2 and R3.
// The DATA is what is frozen here, and it is untouched.

@Suite("Fuzz corpus R1")
struct FuzzCorpusR1 {

    @Test(arguments: FuzzCorpusR1Data.rows)
    func row(_ row: FuzzCorpusRow) {
        runRow(row, tag: "FUZZR1")
    }
}
