import Foundation
import Testing
@testable import SilkCore

// What one ordinary sentence costs.
//
// Three suites in this package already assert about cost, and not one of them
// would have gone red if the hot path had got ten times slower. They measure
// TEN-THOUSAND-WORD inputs — `hugeInputStaysCheapAndSilent`, `ClauseIndexCost`,
// `tenThousandWordsInOneBreathCostWhatTheyCostInTen` — against five-second
// backstops and against ratios whose two arms move together. That is the right
// instrument for the question they ask (does a paste stay linear) and it is
// blind to the question this file asks: what does "give me 20 minutes of
// instagram" cost, on the MainActor, inside the 480 ms beat the user is
// watching.
//
// It was not a hypothetical gap. `tokenize` was building and INVERTING a
// Unicode CharacterSet on every call, and the same sentence was tokenized many
// times over in one parse — by `allNumbers` on an idiom-stripped copy, by
// `statedTime` on a meridiem-rewritten one, by the parser on the trimmed one,
// and once per token again by every clause guard. Hoisting that set to a
// `static let` — one line, no behaviour change — took the mean parse over a
// twelve-sentence corpus from **176 µs to 73 µs**, and the whole suite from
// 4.2 s to 2.4 s. Nothing went red when it was slow, and nothing went green
// when it was fixed. (The mean sat at 65 µs after the rest of that change
// landed around it.)
//
// The count has come down since. The per-token asks (`readsAsNumber`,
// `readsAsHour`) settle an ordinary word on its bytes instead of running a
// reader over it; the helpers that re-derived the parser's words from its text
// (`hasClosingVerb`, `isStatusAsk`, `isStart`, `statedDayHalf`) are handed the
// parser's tokens; and the clause index hands a sentence with no separator in
// it straight to one tokenization instead of walking it a Character at a time.
// What is left on the hot sentence is the parser's own tokenization, the one
// inside `allNumbers`, and the clause index's when a rule asks for one.
//
// The instruments are `PerformanceMeasurement`'s, and its reasoning is the long
// form: ratios wherever a ratio will do, minimums rather than means, and
// absolute numbers only as backstops sitting in the empty space between the
// measured cost and the cost of the mistake. What is added here is the choice
// of DENOMINATOR, which is where a cost ratio lives or dies: each one below is
// paired with work that does not move when the thing under test regresses.
//
// What the suite bounds, in order: the tokenizer against itself with its set
// rebuilt (`tokenizeDoesNotPayPerCallSetupCost` on the Unicode road,
// `aLowercaseWordNeverReachesTheSet` on the byte path), a smart-apostrophe
// contraction against the same sentence without one
// (`aContractionStaysOnTheBytePath`), a one-clause index against one
// tokenization (`aOneClauseIndexCostsAFewTokenizations`), the hot sentence's
// parse against its tokenization and against a frame, every sentence family,
// a doorless paste against its tokenization
// (`aDoorlessPasteParsesInAFewTokenizations`), a window sentence riding on
// that paste against the paste alone
// (`aWindowSentenceCostsAFewParsesOfThePasteItRidesOn`), a negator-dense
// clause in one breath against the same words in ten
// (`aNegatorDenseClauseParsesInLinearTime`), and validation of a huge
// utterance. The bounds added with the byte paths and the tokens-in-hand
// helpers were written without a toolchain to run them, so each is generous
// and each says where its healthy figure is to be recorded.

private let doors = ["Instagram", "TikTok", "YouTube", "Reddit", "X", "Snapchat"]
    .map { Door(name: $0) }

private let state = PolicyState(
    budgetMinutes: 240,
    downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
    doors: doors
)

/// The hot path, and nothing else: the sentence the SPEND rule exists for.
private let sentence = "give me 20 minutes of instagram"

/// The shortest real input the tokenizer is ever handed — the bare door name
/// rule 10 answers. It was the numerator of `tokenizeDoesNotPayPerCallSetupCost`
/// because a per-call constant's SHARE of the work is largest on one word:
/// that test records 1.08x for a paste, 3.3x for the sentence above, and 5.4x
/// for a single word. The bound that catches the regression is the same in all
/// three; only the margin above it differs, and margin is what a cost test on a
/// contended machine is short of.
///
/// It is no longer that numerator, because it no longer reaches the set: a
/// lowercase ASCII word takes `asciiComponents` and never reads `separators`.
/// It now feeds `aLowercaseWordNeverReachesTheSet`, and the set is measured on
/// `oneNonASCIIWord` below.
private let oneWord = "instagram"

/// The shortest input that still takes the road the separator set is read on.
///
/// `separators` is read in exactly one place, the
/// `components(separatedBy: separators)` of a string that is not ASCII, so the
/// word has to carry a non-ASCII letter. NOT a smart apostrophe: a string whose
/// only non-ASCII scalar is U+2019 is straightened and tokenized as the ASCII
/// string it then is, which is the byte path again. And no apostrophe, hyphen
/// or colon of any spelling, so neither arm rewrites anything and the two
/// differ only by where the set is built. Written as an escape so the literal's
/// normalisation cannot vary.
private let oneNonASCIIWord = "caf\u{E9}"

/// Ten thousand words of prose that names no door, states no number and says
/// nothing about the window: the same noise `StressTests` and `ClauseIndexCost`
/// parse. It walks the rule ladder every sentence walks and comes back silence.
private let paste = Array(repeating: "lorem ipsum dolor sit amet", count: 2_000)
    .joined(separator: " ")

/// Whether `Foundation` here is Darwin's, which two bounds below depend on.
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
/// So on Linux a bound with the headroom this file asks for is out of reach
/// before the arms' deliberate asymmetry is even counted. (The shipped
/// `tokenize` also scans for an apostrophe, and now tries to straighten a
/// smart one, where the denominator arm does neither on purpose; the scan
/// alone took the in-suite measurement the rest of the way down to a
/// repeatable 1.26–1.33x when that figure was taken, under today's 1.5.)
/// Lowering the bound to fit would cost the guard its job on the platform Silk
/// ships to, where the healthy figure is several times the regression's ~1.
/// So the ratio is asked only where its premise holds; the half of
/// that test which is about the code and not the machine moved out to
/// `theTwoArmsAreTheSameTokenizer`, and runs everywhere.
///
/// `aLowercaseWordNeverReachesTheSet` shares the denominator, so it shares the
/// gate. Its Linux figure has never been taken.
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
    /// THE INPUT HAS TO REACH THE SET, and for a while it did not. This test
    /// measured `oneWord` until the byte path arrived; since then a lowercase
    /// ASCII word takes `asciiComponents` and never reads `separators`, so the
    /// shipped arm cost the same whether the set was hoisted or rebuilt on
    /// every call and the ratio could not fall for the regression this test is
    /// named for. The set is read only on the Unicode road, so the numerator is
    /// `oneNonASCIIWord` — see its note for why a smart apostrophe would not do.
    ///
    /// If the set is ever built inside the function again, the two arms become
    /// the same function and the ratio collapses to about 1: both build and
    /// invert the set, and what is left between them is small work on each
    /// side (the shipped arm's byte scans and apostrophe check against the
    /// denominator's hyphen rewrite).
    ///
    /// A SHORT string on purpose, and the reason is the whole point of the
    /// measurement. Building the set is a CONSTANT per call, so it is
    /// amortised away by a paragraph and dominates a sentence — measured here,
    /// on this road and before the byte path existed, at 3.3x for the hot-path
    /// sentence, 5.4x for a single word, and 1.08x for a forty-line paste. The
    /// instrument that would have caught this is therefore the opposite of the
    /// one the existing cost tests use, which is exactly why they did not catch
    /// it: every one of them measures ten thousand words.
    ///
    /// THE BOUND IS 1.5, AND THE HEALTHY FIGURE FOR THIS WORD IS UNRECORDED.
    /// The 5.4x above is the neighbourhood it should land in, and 1.5 sits more
    /// than three times under that, while the regression lands near 1. It is
    /// not the 2 this test carried: that was set against figures measured with
    /// the old numerator, and this one has no figure yet. Run
    /// `swift test --filter tokenizeDoesNotPayPerCallSetupCost` on a Mac a few
    /// times and write the readings here, the way the byte path's 18.4–18.9 is
    /// written on `aLowercaseWordNeverReachesTheSet`. If they come in under
    /// 4.5, this bound no longer has three times of room and wants rethinking
    /// rather than lowering.
    ///
    /// Darwin only, and `darwinFoundation` above carries the whole reason: the
    /// share of a tokenization that building the set accounts for is a property
    /// of the Foundation underneath, and on swift-corelibs it is small enough
    /// that no bound with room to spare is reachable however healthy the code
    /// is. Skipped rather than `#if`'d out so a Linux run says so out loud.
    @Test(.enabled(if: darwinFoundation,
                   "the bound is the Darwin CharacterSet's; swift-corelibs tops out near 1.8x"))
    func tokenizeDoesNotPayPerCallSetupCost() {
        // ONE measurement, and the asymmetry is what carries it.
        //
        // This test used to take up to five `fastestPair` reads and keep the
        // best, because a single read gave 1.35 on a machine also building the
        // app for a phone and 3.3 on the same tree alone. Five chances at a
        // bound is not a fix for that: `fastestPair` is ALREADY the answer to
        // contention — seven interleaved rounds, each arm's minimum — and
        // wrapping a retry around it says the instrument was not trusted while
        // still relying on it. Worse, it changes what a red means: a genuine
        // regression that happened to read 2.1 once in five would pass.
        //
        // The real defect was the numerator. Building the set is a CONSTANT
        // per call, so the shorter the input the larger its share, and a
        // single word buys the robustness the retry was reaching for in the
        // SIGNAL instead of in the sampling. The contended read that prompted
        // the retry was 41% of the healthy figure; 41% of the expected 5.4 is
        // 2.2, which still clears 1.5.
        //
        // A hundred iterations per arm rather than twenty, so the short input
        // still gives `fastestPair` a window it can time.
        let word = oneNonASCIIWord
        let (hoisted, perCall) = fastestPair(
            { for _ in 0..<100 { _ = NumberParser.tokenize(word) } },
            { for _ in 0..<100 { _ = Self.tokenizeRebuildingTheSet(word) } }
        )
        let saved = ratio(perCall, to: hoisted)
        #expect(saved > 1.5,
                "the separator set looks like it is being rebuilt per call (only \(String(format: "%.1f", saved))x)")
    }

    /// **A LOWERCASE ASCII WORD NEVER REACHES THE SET AT ALL.** The same two
    /// arms as above, fed `oneWord`: the shipped tokenizer takes
    /// `asciiComponents` and touches no `CharacterSet`, while the denominator
    /// builds and inverts one for a nine-byte string and splits through
    /// Foundation.
    ///
    /// This WAS `tokenizeDoesNotPayPerCallSetupCost`, until the byte path made
    /// it measure something else, and what it measures is worth being exact
    /// about: the byte path's margin over the Foundation road with its set
    /// rebuilt. It cannot see the set — the shipped arm never reads it, so a
    /// rebuild moves nothing here — and a byte path lost to the Foundation road
    /// with the set still hoisted would read near the 5.4x the test above
    /// expects, which clears 2. What goes red is a lowercase word costing half
    /// of what the denominator costs: both of those regressions at once, or a
    /// byte path gone that badly wrong. A coarse bound, kept because the
    /// figure below is the only measured record of the byte path's margin.
    ///
    /// Measured on this tree before the non-ASCII arm existed, four
    /// consecutive runs: 18.4, 18.6, 18.8, 18.9. The bound of 2 is nine times
    /// under that, so the contended read that once prompted a retry here (41%
    /// of the healthy figure) would land near 7.6 and clear it outright.
    ///
    /// Darwin only because its denominator is the one above.
    @Test(.enabled(if: darwinFoundation,
                   "measured only against Darwin's Foundation; the Linux figure has never been taken"))
    func aLowercaseWordNeverReachesTheSet() {
        let (bytePath, perCall) = fastestPair(
            { for _ in 0..<100 { _ = NumberParser.tokenize(oneWord) } },
            { for _ in 0..<100 { _ = Self.tokenizeRebuildingTheSet(oneWord) } }
        )
        let margin = ratio(perCall, to: bytePath)
        #expect(margin > 2,
                "a lowercase word nears the rebuilt-set tokenizer's cost (only \(String(format: "%.1f", margin))x under it)")
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
    ///
    /// And checked on the road the set is read on. The first two strings are
    /// ASCII, which the shipped tokenizer answers on the byte path; the last
    /// two are not, so they compare the two arms where the ratio above is
    /// actually taken.
    @Test func theTwoArmsAreTheSameTokenizer() {
        #expect(NumberParser.tokenize(sentence) == Self.tokenizeRebuildingTheSet(sentence))
        #expect(NumberParser.tokenize("dont cap tiktok 20 a day")
                == Self.tokenizeRebuildingTheSet("dont cap tiktok 20 a day"))
        #expect(NumberParser.tokenize(oneNonASCIIWord)
                == Self.tokenizeRebuildingTheSet(oneNonASCIIWord))
        #expect(NumberParser.tokenize("caf\u{E9} \u{FC}nlock instagram 20")
                == Self.tokenizeRebuildingTheSet("caf\u{E9} \u{FC}nlock instagram 20"))
    }

    /// `tokenize` exactly as it stood before the set was hoisted. Kept in the
    /// test target, never in the shipping one — its only job is to be the arm
    /// the shipped version is measured against.
    /// Apostrophe-free on purpose: the arms must differ ONLY by where the
    /// separator set is built, so both are given input with no mark in it and
    /// the apostrophe folding stays out of the measurement entirely.
    /// It has no byte path: every string it is handed takes the Foundation
    /// split, which is what makes it the denominator for both ratios above.
    private static func tokenizeRebuildingTheSet(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: ":")).inverted)
            .filter { !$0.isEmpty }
    }

    /// **A CONTRACTION IS NOT A REASON TO LEAVE THE BYTE PATH.**
    ///
    /// iOS smart punctuation spells every contraction with U+2019, and that
    /// one non-ASCII scalar used to send the whole sentence down the Unicode
    /// road: a Unicode case fold, a Character-level apostrophe fold, and a
    /// Foundation split — once for every whole-sentence tokenization in a
    /// parse. `tokenize` now writes a lone U+2019 as "'" and folds the ASCII
    /// apostrophe a byte at a time, so the ordinary contraction costs two
    /// extra byte passes and their buffers.
    ///
    /// The arms are ONE sentence, spelled without the mark and with the smart
    /// one, and they must tokenize alike — asserted first, with the straight
    /// spelling beside them, because arms that answer differently measure two
    /// different questions. So the ratio is the price of the apostrophe and
    /// nothing else.
    ///
    /// The bound is 8, and the healthy figure is UNRECORDED: by reading it
    /// should sit near 2 to 2.5 (a straightening pass and a fold, each a byte
    /// walk into a fresh buffer, on top of the byte path both arms share), so 8
    /// leaves more than three times that. What the Unicode road costs on this
    /// sentence is unrecorded too. The tokenizer tests above put its Foundation
    /// split, set hoisted, at roughly three byte-path tokenizations of one word
    /// (18.4x with the set rebuilt, divided by the 5.4x the rebuild costs), and
    /// the Unicode case fold and the Character-level fold came on top of that.
    /// So 8 refuses the road coming back only if that sum exceeds it — record
    /// both figures here, and if the old road reads under 8, this bound is a
    /// backstop and not a guard. Not Darwin-gated: both arms run on bytes when
    /// the code is healthy, so the healthy figure does not depend on the
    /// Foundation underneath.
    @Test func aContractionStaysOnTheBytePath() {
        let plain = "dont give me 20 minutes of tiktok"
        let straight = "don't give me 20 minutes of tiktok"
        let smart = "don\u{2019}t give me 20 minutes of tiktok"
        #expect(NumberParser.tokenize(straight) == NumberParser.tokenize(plain))
        #expect(NumberParser.tokenize(smart) == NumberParser.tokenize(plain))

        // Short windows and many rounds, `fastest`'s own rule: both arms are
        // one short sentence.
        let (bytePath, contraction) = fastestPair(
            rounds: 40,
            { for _ in 0..<50 { _ = NumberParser.tokenize(plain) } },
            { for _ in 0..<50 { _ = NumberParser.tokenize(smart) } }
        )
        let r = ratio(contraction, to: bytePath)
        #expect(r < 8, "a smart apostrophe costs \(String(format: "%.1f", r))x its sentence without one")
    }

    /// **A SENTENCE WITH NO SEPARATOR IS ONE CLAUSE, AND IS NOT WALKED FOR ONE.**
    ///
    /// The clause index used to find its clauses by stepping every Character
    /// of the sentence — three grapheme steps, a set probe and two Unicode
    /// properties apiece — and on the hot sentence all of that returned the one
    /// piece it started with. A byte scan now settles that no separator is
    /// there, and the index costs one tokenization plus its own small arrays.
    /// The index is built for every sentence that names a door, and again by
    /// the Validator for every spend.
    ///
    /// The denominator is one tokenization of the same sentence, and the index
    /// must hand back exactly those tokens as one clause — asserted first, so
    /// the ratio cannot be taken against an index that stopped being one.
    ///
    /// The bound is 6, and the healthy figure is UNRECORDED: by reading it
    /// should sit near 2 (the tokenization itself, a byte scan of the
    /// sentence, and two short arrays), so 6 leaves three times that. The only
    /// recorded figure for the Character walk is `ClauseIndexCost`'s — one
    /// clause cost 42 ms against 5.2 ms for `tokenize` alone on an
    /// 82k-character string, before the tokenizer got its byte path — which
    /// puts the walk at several tokenizations on its own. Record the first
    /// healthy readings here.
    @Test func aOneClauseIndexCostsAFewTokenizations() {
        let index = NumberParser.ClauseIndex(sentence)
        #expect(index.tokens == NumberParser.tokenize(sentence))
        #expect(index.clauseCount == 1)

        let (indexed, tokenized) = fastestPair(
            rounds: 40,
            { for _ in 0..<20 { _ = NumberParser.ClauseIndex(sentence) } },
            { for _ in 0..<20 { _ = NumberParser.tokenize(sentence) } }
        )
        let r = ratio(indexed, to: tokenized)
        #expect(r < 6, "a one-clause index costs \(String(format: "%.1f", r)) tokenizations")
    }

    /// **ONE SENTENCE'S PARSE, AGAINST ONE SENTENCE'S TOKENIZATION.**
    ///
    /// The denominator is the single cheapest thing the parse must do, measured
    /// interleaved with it. It moves only if the tokenizer moves — which the
    /// tests above pin separately — so this ratio isolates everything the
    /// GRAMMAR adds on top: the substring scans, the clause index when a rule
    /// asks for one, the door matching, the number reading.
    ///
    /// Measured at ~51 tokenizations per parse when this file was written,
    /// and ~96 later — the grammar grew, and a ratio's headroom erodes
    /// silently when its bound stands still. That ~96 was taken before the
    /// helpers that re-tokenized the parser's text were handed its tokens and
    /// before a one-clause sentence stopped being walked a Character at a
    /// time for a separator; the figure since is unrecorded, should be lower,
    /// and belongs here when it is taken. The bound is 3x the ~96,
    /// generous on purpose: this arm is the coarse one, and its job
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

    /// **A PASTE THAT ASKS NOTHING COSTS A FEW TOKENIZATIONS OF ITSELF.**
    ///
    /// The per-sentence bound above is the hot path; this is the other end,
    /// ten thousand words naming no door, which walk the rule ladder every
    /// sentence walks and come back silence. On a paste every whole-sentence
    /// pass is a pass over ten thousand words, so each helper that
    /// re-tokenized the parser's text — `hasClosingVerb` on every sentence
    /// that reaches the close rule, and building a set of every word to ask
    /// about eight; `isStatusAsk` on every doorless one — was a whole
    /// tokenization of the paste, and they are handed the parser's tokens now.
    /// The denominator is ten tokenizations of the same paste, scaled back to
    /// one, measured interleaved with the parse, so the ratio counts the passes
    /// the ladder makes and is blind to how fast the machine is.
    ///
    /// The bound is 60, and the healthy figure is UNRECORDED. By reading, the
    /// parse is the tokenization itself, the one inside `allNumbers`, a door
    /// probe per word, and a score of byte scans for the ladder's phrases —
    /// something like five to twenty tokenizations — so 60 leaves three times
    /// the top of that. It is the coarse arm, as
    /// `aShortSentenceParsesInAFewTokenizations` is: the helpers'
    /// re-tokenizations were a few passes of that, which no bound with this
    /// room can see, and what it refuses is the change that multiplies the
    /// ladder — the whole number or clock reader run over every word, or a
    /// new pass per word. `ClauseIndexCost.theParserDoesNotPayForWhatItDoesNotAsk`
    /// holds this same path linear; this holds its constant. Record the first
    /// healthy readings here.
    @Test func aDoorlessPasteParsesInAFewTokenizations() {
        // What the parser ANSWERS, asserted outside the measurement: a paste
        // that stopped being silent is walking a different path, and the ratio
        // would measure that path instead.
        #expect(DeterministicParser.parse(paste, state: state) == .silence,
                "the paste stopped being silent, so the ratio below measures a different path")
        #expect(NumberParser.tokenize(paste).count == 10_000)

        // Ten tokenizations per round in the denominator, not one, so the two
        // windows sit within a small factor of each other. Across a gap of ten
        // or twenty times, interleaving cannot cancel contention — the short
        // arm finds a quiet slice while every long window stays contended, and
        // only the numerator inflates (`aShortSentenceParsesInAFewTokenizations`
        // says so at length). The ratio is scaled back to one tokenization, so
        // the bound keeps its unit. The shared default of seven rounds: both
        // windows are long, and `PerformanceMeasurement.swift` says why a long
        // window wants more rounds, never fewer.
        var sink = 0
        let (parse, tenTokenizations) = fastestPair({
            if DeterministicParser.parse(paste, state: state) == .silence { sink &+= 1 }
        }, {
            for _ in 0..<10 { sink &+= NumberParser.tokenize(paste).count }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let r = 10 * ratio(parse, to: tenTokenizations)
        #expect(r < 60, "a doorless paste costs \(String(format: "%.1f", r)) tokenizations of itself")
    }

    /// **A WINDOW SENTENCE ON A PASTE COSTS A FEW PARSES OF THE PASTE.**
    ///
    /// The window setter walks every token of the sentence three times with
    /// `readsAsHour` — `isStart` to the first stated hour, the setter's own
    /// gate to the same hour, and `statedDayHalf` over all of it — and each
    /// ask used to run the whole clock reader over one word: a tokenization,
    /// a meridiem split, table probes, to be told that "lorem" is not an hour.
    /// A word with no digit that is no number word is now settled on its
    /// bytes. Prose that mentions the night and names no door reaches this
    /// path whatever its length.
    ///
    /// The arms are the same paste with and without "night should start at
    /// 10" on the end, so the ratio is what the window setter adds to the
    /// ladder the paste walks anyway, and the answer the setter must reach is
    /// asserted first — it is the one `aHugeUtteranceValidatesInOnePass` pins
    /// below on a shorter paste.
    ///
    /// The bound is 8, and the healthy figure is UNRECORDED. By reading, the
    /// window arm adds a clause index (one tokenization, the paste having no
    /// separator in it), one reading of the clock over the whole text, and
    /// three cheap walks, against a paste parse of several tokenizations — so
    /// something near 2, and 8 leaves more than three times that. It is
    /// coarse, and honestly so: the per-word reader this was written after
    /// cost, by the same reading, about as much again as the rest of the parse
    /// — a ratio near 4 or 5 — which a bound with this room cannot tell from a
    /// healthy run. What it refuses is the window path growing a pass that is
    /// several whole parses of the paste. Record both figures here; if the
    /// healthy one is well under 2, the bound can come down to catch the
    /// reader coming back.
    @Test func aWindowSentenceCostsAFewParsesOfThePasteItRidesOn() {
        let window = paste + " night should start at 10"
        #expect(DeterministicParser.parse(window, state: state)
                == .command(.setDownHoursStart(TimeOfDay(hour: 22))),
                "the window sentence stopped compiling, so the ratio below measures nothing")
        #expect(DeterministicParser.parse(paste, state: state) == .silence)

        var sink = 0
        let (withWindow, without) = fastestPair({
            if DeterministicParser.parse(window, state: state) != .silence { sink &+= 1 }
        }, {
            if DeterministicParser.parse(paste, state: state) == .silence { sink &+= 1 }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let r = ratio(withWindow, to: without)
        #expect(r < 8, "the window setter costs \(String(format: "%.1f", r))x the paste it rides on")
    }

    /// **A CLAUSE DENSE IN NEGATORS AND VERBS STAYS LINEAR.**
    ///
    /// `aNegatorRefusesTheAsk` walked forward from every negator to every
    /// opening verb after it in the clause, and for each such pair re-read
    /// the whole clause for a number and for a "more than" — facts of the
    /// clause alone. A clause dense in both cost the CUBE of its length:
    /// "dont use " said two hundred times ahead of ", tiktok 10" is twenty
    /// thousand pairs, each reading four hundred words, on the MainActor, and
    /// again in `judgeSpend`. Those facts are now read once per clause.
    ///
    /// The shape is `StressTests.hugeInputStaysCheapAndSilent`'s: one string of
    /// m repeats against ten strings of m/10, the same words in both arms, so
    /// a linear parse reads about 1, a quadratic one about 10, and a cubic one
    /// about 100. Two hundred repeats and not more so that the cubic mistake,
    /// which is what this is here to refuse, fails in seconds rather than
    /// minutes.
    ///
    /// THE ANSWER IS PINNED TOO, and it is a grant. The negated verb is a
    /// derived stem ("use", not an ask verb), its negator is a contraction and
    /// not a bare "no"/"not", and the number stands in the NEXT clause — the
    /// preamble reading `aNegatorRefusesTheAsk` documents, the one that lets
    /// "i dont use instagram much, unlock instagram for 10" ask. Nothing else
    /// in the ladder claims it: no status word, no window word, no closer and
    /// no opener token, no ceiling word, no period, and the number's own
    /// clause names TikTok; the sentence's "use" is its opening verb. So a
    /// rewrite of the negator scan that changed this answer is caught here as
    /// a behaviour, not only as a cost.
    ///
    /// The bound is 30, and the healthy figure is UNRECORDED. Not the 3 the
    /// stress test holds: by reading, another guard on this path is quadratic
    /// in this clause — `clearingPhrase` walks from every negator to the
    /// clause's end looking for a ceiling word that is not there — and a pure
    /// quadratic reads 10 on this construction. Each short string also pays a
    /// parse's fixed cost ten times over, which pulls the healthy figure down.
    /// So the healthy ratio sits somewhere under 10 whatever that guard costs,
    /// 30 leaves three times the worst of it, and the cubic scan this replaced
    /// reads near 100. Record the first healthy readings here.
    @Test func aNegatorDenseClauseParsesInLinearTime() {
        func refusedThenAsked(_ repeats: Int) -> String {
            String(repeating: "dont use ", count: repeats) + ", tiktok 10"
        }
        let inOneBreath = refusedThenAsked(200)
        // Ten separately built strings rather than one string parsed ten
        // times, for the reason the stress test states: the long arm walks its
        // input out of cold memory, and one short string read ten times would
        // sit in cache and win on the strength of that alone.
        let inTenBreaths = (0..<10).map { _ in refusedThenAsked(20) }

        // What the parser ANSWERS, asserted outside the measurement. `doors[1]`
        // is TikTok, and `state` holds the same `Door` values, ids included.
        let tiktok = doors[1]
        #expect(tiktok.name == "TikTok")
        let granted = ParseOutcome.command(.spend(door: tiktok, minutes: 10))
        #expect(DeterministicParser.parse(inOneBreath, state: state) == granted)
        #expect(inTenBreaths.allSatisfy { DeterministicParser.parse($0, state: state) == granted })

        // The two arms really are the same words. The short arm carries
        // ", tiktok 10" ten times over rather than once, so it does 420 tokens
        // of work against the long arm's 402: MORE, which biases the ratio
        // down and is therefore the conservative direction.
        #expect(NumberParser.tokenize(inOneBreath).count == 402)
        #expect(inTenBreaths.allSatisfy { NumberParser.tokenize($0).count == 42 })

        var sink = 0
        let (asOneString, asTenStrings) = fastestPair({
            if DeterministicParser.parse(inOneBreath, state: state) != .silence { sink &+= 1 }
        }, {
            for piece in inTenBreaths
            where DeterministicParser.parse(piece, state: state) != .silence { sink &+= 1 }
        })
        #expect(sink > 0)   // the compiler may not delete the work

        let scaling = ratio(asOneString, to: asTenStrings)
        #expect(scaling < 30,
                """
                two hundred negated verbs in one clause cost \(String(format: "%.1f", scaling))× \
                what the same words cost in ten sentences — the negator scan is no longer \
                linear in its clause
                """)
    }

    // MARK: - validationCostIsOnTheSameBudget
    //
    // A one-test suite of its own until now, and the file's other suite is the
    // suite for exactly this question: what does one utterance cost. Kept as a
    // MARK so the proposition it was named for is still what you read past.

    /// **THE VALIDATOR IS ON THE COST BUDGET TOO.** Every huge-input bound in the
    /// package stops at `DeterministicParser.parse` — `hugeInputStaysCheapAndSilent`
    /// and `tenThousandWordsInOneBreathCostWhatTheyCostInTen` never call
    /// `Validator.validate` — and the gap was not hypothetical: `statedTimes`
    /// re-ran `statedTime` on the utterance with one leading token dropped per
    /// iteration, each run re-tokenizing everything that remained. A clock near
    /// the END of a long text made the provenance guards quadratic: three
    /// thousand ordinary words ending "night should start at 10" parsed in
    /// ~50 ms and then hung validation for ~4.6 s on the machine that measured
    /// it — a paste plus one sentence, on the deterministic path, worse on a
    /// phone and 4x worse per doubling.
    ///
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
