import Foundation
import Testing
@testable import SilkCore

// What one ordinary sentence costs.
//
// Three suites in this package already assert about cost, and not one of them
// would have gone red if the hot path had got ten times slower. They measure
// TEN-THOUSAND-WORD inputs — `hugeInputStaysCheapAndSilent`, `ClauseIndexCost`,
// `aHugeInputStaysLinear` — against five-second backstops and against ratios
// whose two arms move together. That is the right instrument for the question
// they ask (does a paste stay linear) and it is blind to the question this file
// asks: what does "give me 20 minutes of instagram" cost, on the MainActor,
// inside the 480 ms beat the user is watching.
//
// It was not a hypothetical gap. `tokenize` was building and INVERTING a
// Unicode CharacterSet on every call, and the same sentence is tokenized many
// times over in one parse — by `allNumbers` on an idiom-stripped copy, by
// `statedTime` on a meridiem-rewritten one, by the parser on the trimmed one,
// and once per token again by every clause guard. Hoisting that set to a
// `static let` — one line, no behaviour change — took the mean parse over a
// twelve-sentence corpus from **176 µs to 73 µs**, and the whole suite from
// 4.2 s to 2.4 s. Nothing went red when it was slow, and nothing went green
// when it was fixed. (The mean sits at 65 µs today, after the rest of the
// change landed around it.)
//
// The instruments are `PerformanceMeasurement`'s, and its reasoning is the long
// form: ratios wherever a ratio will do, minimums rather than means, and
// absolute numbers only as backstops sitting in the empty space between the
// measured cost and the cost of the mistake. What is added here is the choice
// of DENOMINATOR, which is where a cost ratio lives or dies: each one below is
// paired with work that does not move when the thing under test regresses.

private let doors = ["Instagram", "TikTok", "YouTube", "Reddit", "X", "Snapchat"]
    .map { Door(name: $0) }

private let state = PolicyState(
    budgetMinutes: 240,
    downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
    doors: doors
)

/// The hot path, and nothing else: the sentence the SPEND rule exists for.
private let sentence = "give me 20 minutes of instagram"

/// Whether `Foundation` here is Darwin's, which one bound below depends on.
///
/// Every other ratio in this package is a claim about the code, and portable
/// for exactly the reason `PerformanceMeasurement` states: both arms move
/// together on any machine. `tokenizeDoesNotPayPerCallSetupCost` is the one
/// that is not, and it is worth being precise about why rather than calling it
/// flaky. Its two arms differ by ONE thing — where a `CharacterSet` is built —
/// so the ratio it measures is the cost of building that set, expressed as a
/// share of a tokenization. That share is a property of the `Foundation`
/// underneath, and the two Foundations do not agree:
///
/// | | build+invert the set, as a share of one per-call `tokenize` | best possible ratio |
/// |---|---|---|
/// | Darwin | ~70% (implied by the 3.3x this file records) | 3.3x |
/// | swift-corelibs | 38–40% (measured, Swift 6.2.4, aarch64 Linux) | ~1.8x |
///
/// So on Linux the bound of 2 is unreachable *in isolation* — before the arms'
/// deliberate asymmetry is even counted. (The shipped `tokenize` also scans for
/// an apostrophe, which the denominator arm omits on purpose; that is what
/// takes the in-suite measurement the rest of the way down to a repeatable
/// 1.26–1.33x.) Lowering the bound to fit would cost the guard its job on the
/// platform Silk ships to, where the regression it exists to catch is a 3.3x
/// one. So the bound stays at 2 and the ratio is asked only where its premise
/// holds; the half of that test which is about the code and not the machine
/// moved out to `theTwoArmsAreTheSameTokenizer`, and runs everywhere.
private let darwinFoundation: Bool = {
    #if canImport(Darwin)
    return true
    #else
    return false
    #endif
}()

@Suite struct OneSentenceStaysCheap {

    /// **THE TOKENIZER IS NOT ALLOWED TO REBUILD ITS WORLD.**
    ///
    /// The denominator is the tokenizer as it was WRITTEN — the same function
    /// with the separator set constructed and inverted per call, copied below
    /// so the comparison is between two implementations of one idea rather than
    /// between the code and a wall clock. That is what makes this bound a claim
    /// about the code and not about the machine: both arms do identical work
    /// except for the thing under test, they are measured interleaved
    /// microseconds apart, and the ratio is meaningless in any unit.
    ///
    /// If the `static let` is ever inlined back into the function body, the two
    /// arms become the same function and the ratio collapses to 1. The bound is
    /// 2 — half the improvement actually measured, so a slow or contended
    /// machine cannot fake it, and nowhere near 1, so the regression cannot
    /// hide under it.
    ///
    /// A SHORT string on purpose, and the reason is the whole point of the
    /// measurement. Building the set is a CONSTANT per call, so it is
    /// amortised away by a paragraph and dominates a sentence — measured here
    /// at 3.3x for the hot-path sentence, 5.4x for a single word, and 1.08x for
    /// a forty-line paste. The instrument that would have caught this is
    /// therefore the opposite of the one the existing cost tests use, which is
    /// exactly why they did not catch it: every one of them measures ten
    /// thousand words.
    ///
    /// Darwin only, and `darwinFoundation` above carries the whole reason: the
    /// share of a tokenization that building the set accounts for is a property
    /// of the Foundation underneath, and on swift-corelibs it is small enough
    /// that 2 is unreachable however healthy the code is. Skipped rather than
    /// `#if`'d out so a Linux run says so out loud.
    @Test(.enabled(if: darwinFoundation,
                   "the bound is the Darwin CharacterSet's; swift-corelibs tops out near 1.8x"))
    func tokenizeDoesNotPayPerCallSetupCost() {
        // Up to five independent measurements, the best kept. One `fastestPair`
        // is about ten milliseconds of wall clock, and on a machine that is
        // also building the app for a phone a preemption inside that window
        // lands on one arm and not the other: this read 1.35 twice on a push
        // with an xcodebuild alongside, and 3.3 on the same tree alone, in
        // both checkouts, minutes later. Re-measuring answers contention
        // without lowering the bound; a genuine regression reads near 1 on
        // every one of the five.
        var saved = 0.0
        for _ in 0..<5 where saved <= 2 {
            let (hoisted, perCall) = fastestPair(
                { for _ in 0..<20 { _ = NumberParser.tokenize(sentence) } },
                { for _ in 0..<20 { _ = Self.tokenizeRebuildingTheSet(sentence) } }
            )
            saved = max(saved, ratio(perCall, to: hoisted))
        }
        #expect(saved > 2,
                "the separator set looks like it is being rebuilt per call (only \(String(format: "%.1f", saved))x)")
    }

    /// The two arms are one tokenizer, differing only by where the set is built.
    ///
    /// It lived inside the ratio test, guarding it: a denominator that has
    /// drifted into a *different* function measures nothing, and the ratio
    /// would go on reporting a healthy number while proving nothing at all.
    /// That is precisely why it is out here now. The drift it catches is
    /// platform-independent, and it is the only thing standing behind a
    /// measurement that — since the split above — no longer runs on every
    /// machine in CI. The arm the Darwin bound is read against has to be
    /// checked somewhere that always runs.
    @Test func theTwoArmsAreTheSameTokenizer() {
        #expect(NumberParser.tokenize(sentence) == Self.tokenizeRebuildingTheSet(sentence))
        #expect(NumberParser.tokenize("dont cap tiktok 20 a day")
                == Self.tokenizeRebuildingTheSet("dont cap tiktok 20 a day"))
    }

    /// `tokenize` exactly as it stood before the set was hoisted. Kept in the
    /// test target, never in the shipping one — its only job is to be the arm
    /// the shipped version is measured against.
    /// Apostrophe-free on purpose: the arms must differ ONLY by where the
    /// separator set is built, so both are given input with no mark in it and
    /// the apostrophe folding stays out of the measurement entirely.
    private static func tokenizeRebuildingTheSet(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: ":")).inverted)
            .filter { !$0.isEmpty }
    }

    /// **ONE SENTENCE'S PARSE, AGAINST ONE SENTENCE'S TOKENIZATION.**
    ///
    /// The denominator is the single cheapest thing the parse must do, measured
    /// interleaved with it. It moves only if the tokenizer moves — which the
    /// test above pins separately — so this ratio isolates everything the
    /// GRAMMAR adds on top: the substring scans, the clause index when a rule
    /// asks for one, the door matching, the number reading.
    ///
    /// Measured at ~51 tokenizations per parse when this file was written,
    /// and ~96 today — the grammar grew, and a ratio's headroom erodes
    /// silently when its bound stands still. The bound is 3x the measured
    /// figure, generous on purpose: this arm is the coarse one, and its job
    /// is to refuse the shape of change that TRIPLES the parse — another
    /// whole-utterance pass for every sentence behind it — not to hold the
    /// felt cost, which the absolute backstops below own. At the old 150 the
    /// healthy ~96 sat 1.5x from the line, and a full parallel `swift test`
    /// crossed it once in eighteen runs.
    @Test func aShortSentenceParsesInAFewTokenizations() {
        // Short windows and many rounds — `fastest`'s own rule, applied to a
        // ratio whose arms are ASYMMETRIC. At 20 iterations per round the
        // parse arm was a ~6 ms window against the tokenize arm's ~0.1 ms,
        // and interleaving cannot cancel contention across that gap: the
        // short arm finds a quiet slice while every long window stays
        // contended, and only the numerator inflates. Three iterations per
        // round puts both windows in the same regime (measured: the healthy
        // ratio is unchanged); forty rounds gives each minimum forty chances
        // at a quiet slice. A real regression slows every window, however
        // short.
        let (parse, tokenize) = fastestPair(
            rounds: 40,
            { for _ in 0..<3 { _ = DeterministicParser.parse(sentence, state: state) } },
            { for _ in 0..<3 { _ = NumberParser.tokenize(sentence) } }
        )
        let r = ratio(parse, to: tokenize)
        #expect(r < 300, "the parse costs \(String(format: "%.1f", r)) tokenizations")
    }

    /// **AND THE ABSOLUTE BACKSTOP**, which is a claim about the machine and is
    /// therefore placed where its exact value does no work.
    ///
    /// One parse measures ~320 µs in this suite's debug build on the machine
    /// it was written on, and ~120 µs optimised. A parse costs a user nothing
    /// until it is felt, and it is felt when it starts eating frames on the
    /// MainActor — 8.3 ms at 120 Hz. Five milliseconds is fifteen times the
    /// measured debug cost and still inside one frame, so it is safe on
    /// hardware nobody has seen yet and it still refuses the class of change
    /// that would put a visible hitch behind the bar.
    @Test func aShortSentenceParsesWellInsideAFrame() {
        let cost = fastest(rounds: 15) {
            for _ in 0..<20 { _ = DeterministicParser.parse(sentence, state: state) }
        }
        let each = seconds(cost) / 20
        #expect(each < 0.005, "one parse costs \(String(format: "%.0f", each * 1e6)) µs")
    }

    /// **EVERY SHAPE, NOT JUST THE ONE.** A rule added to the front of the
    /// ladder is paid for by every sentence behind it, so the bound is asked of
    /// a corpus that reaches each family — spend, close, budget, cap, status,
    /// the window — rather than of the one sentence a fix was measured against.
    @Test func noSentenceFamilyIsAnOutlier() {
        let corpus = [
            "give me 20 minutes of instagram", "instagram twenty five", "ten on tiktok",
            "half an hour of youtube", "no more instagram today", "block tiktok until 9",
            "make it thirty minutes a day", "down hours start at ten", "hows my budget",
            "cap tiktok at 20 a day", "unlock reddit for 15 minutes please", "20min of x",
        ]
        for text in corpus {
            let cost = fastest(rounds: 10) {
                for _ in 0..<10 { _ = DeterministicParser.parse(text, state: state) }
            }
            let each = seconds(cost) / 10
            #expect(each < 0.005,
                    "\"\(text)\" costs \(String(format: "%.0f", each * 1e6)) µs")
        }
    }
}

/// **THE VALIDATOR IS ON THE COST BUDGET TOO.** Every huge-input bound in the
/// package stops at `DeterministicParser.parse` — `hugeInputStaysCheapAndSilent`
/// and `aHugeInputStaysLinear` never call `Validator.validate` — and the gap
/// was not hypothetical: `statedTimes` re-ran `statedTime` on the utterance
/// with one leading token dropped per iteration, each run re-tokenizing
/// everything that remained. A clock near the END of a long text made the
/// provenance guards quadratic: three thousand ordinary words ending "night
/// should start at 10" parsed in ~50 ms and then hung validation for ~4.6 s on
/// the machine that measured it — a paste plus one sentence, on the
/// deterministic path, worse on a phone and 4x worse per doubling.
@Suite struct ValidationCost {

    /// The hang case, end to end. The input is prose that compiles (rule 2
    /// reads the trailing clause), so validation must run the very guard that
    /// was quadratic — `statedTimes` over the whole utterance. One second is
    /// the same shape of backstop the parser's huge-input bounds use: an order
    /// of magnitude above the linear cost measured (~10 ms debug), and several
    /// below the quadratic one it refuses.
    @Test func aHugeUtteranceValidatesInOnePass() {
        let noise = Array(repeating: "lorem ipsum dolor sit amet", count: 600)
            .joined(separator: " ")
        let utterance = noise + " night should start at 10"

        let outcome = DeterministicParser.parse(utterance, state: state)
        #expect(outcome == .command(.setDownHoursStart(TimeOfDay(hour: 22))),
                "the probe sentence stopped compiling, so the bound below measures nothing")

        let cost = bestOfThree {
            _ = Validator.validate(outcome, utterance: utterance, state: state,
                                   ledger: GrantLedger(), now: Date())
        }
        #expect(seconds(cost) < 1.0,
                "validating 3000 words cost \(String(format: "%.2f", seconds(cost))) s")
    }
}
