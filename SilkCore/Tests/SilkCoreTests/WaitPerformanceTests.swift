import Foundation
import Testing
@testable import SilkCore

// The wait's arithmetic, timed — because "buttery smooth is the core principle
// in this app" is the one requirement in `docs/design/wait.md` that no other
// test in either suite can fail on.
//
// Everything else about this feature is a fact: the door opens or it does not,
// the minutes are debited or they are not, the veil is up or down. Smoothness is
// not a fact, it is a budget, and a budget nobody states is a budget nobody
// keeps. So this file states it.
//
// ============================================================
// The budget
// ============================================================
//
// `WaitOverlay` draws inside `TimelineView(.animation)`, which asks for a frame
// as often as the display will take one — 120 Hz on every ProMotion iPhone Silk
// targets. That is **8.333 ms** for the whole frame, and the whole frame is
// SwiftUI's layout, SwiftUI's rendering, Core Animation's commit, and Silk's
// own arithmetic. Silk's share of it has to be a rounding error or the other
// three have nothing to work with.
//
// So the bounds below are written in frames rather than milliseconds. A number
// of milliseconds is a fact about a machine; a frame is the thing the number has
// to be smaller than, and it stays the right question when the machine changes.
//
// ============================================================
// What these can and cannot see
// ============================================================
//
// They cannot see smoothness. Frame pacing, GPU time and hitch ratio are
// properties of a display and a compositor, and there is no display in a unit
// test — the only honest instrument for those is `XCTOSSignpostMetric
// .animationHitches` on hardware, which is a device-lab measurement and not a
// merge gate. Claiming otherwise here would be the worst kind of green.
//
// What they can see is the part Silk can be *wrong* about: the work handed to
// SwiftUI every frame, and whether its cost is a constant or a function of
// something. A frame budget cannot be blown by arithmetic that is 0.01% of it;
// it is blown by arithmetic that was 0.01% of it until the thing it loops over
// grew. That is what is measured.
//
// ============================================================
// Why the numbers are shaped the way they are
// ============================================================
//
// **Ratios wherever a ratio will do.** A wall-clock bound is a claim about the
// machine that ran it and fails on a loaded runner for reasons that have
// nothing to do with the code — this repo already carries one such gate
// (`StressTests.hugeInputStaysCheapAndSilent`) and it reddens under load. A
// ratio between two measurements taken in the same run, on the same machine,
// microseconds apart, is a claim about the code and survives the runner being
// busy, slow, or somebody else's.
//
// **Best of three, for the reason `hugeInputStaysCheapAndSilent` gives.** The
// minimum filters out preemption. A real regression slows every run; a busy
// neighbour only some.
//
// **Both suites build Debug, and that is the safe direction.** `swift test` and
// `xcodebuild test` are unoptimised, so everything below is measured several
// times slower than what ships — every figure in a comment here is a debug
// figure. A bound met in debug is met by a wider margin in release, so the
// error this introduces is a false red and never a false green. It is also why
// the headroom is set at two orders of magnitude rather than two: at 100× the
// measured cost, no amount of optimisation-level difference can reach the bound,
// and nothing short of a real regression can either.
//
// **The bounds are sides of a gap, not thresholds.** Nothing below is tuned. In
// each case the measured cost and the cost of the mistake being guarded against
// are separated by three or four orders of magnitude, and the bound is put in
// the empty space between them. Its exact value is not doing any work — which
// is the property that makes it safe to leave running on somebody else's
// hardware for years.

// MARK: - Fixtures

private let door = UUID()

/// One ProMotion frame. Every absolute bound in this file is stated against it.
private let frame = Duration.nanoseconds(8_333_333)

/// A tenth of the frame, and the budget the per-frame work is actually held to.
///
/// The frame belongs to SwiftUI's layout, Core Animation's commit and the GPU.
/// Silk's arithmetic is a guest in it, and a guest taking a whole frame has taken
/// everything. A tenth is the conventional share for application-side work in a
/// real-time loop, and unlike the whole frame it is a bound that *bites* — see
/// `aSecondOfTheMarkFitsInsideSilksShareOfAFrame` for the mutation that walked
/// straight through the looser version.
private let silksShare = frame / 10

/// 120 Hz for one second — the unit the mark is actually drawn in.
private let framesPerSecond = 120

/// Best of three, then the per-operation cost. For a single measurement with no
/// counterpart — the absolute bounds. Ratios must use `fastestPair` below.
private func bestOfThree(_ body: () -> Void) -> Duration {
    fastest(rounds: 3, body)
}

/// The quickest `body` ever managed, over `rounds` attempts.
///
/// **Short windows and many rounds, rather than long windows and few**, and the
/// difference decides whether an absolute bound is usable on a busy machine at
/// all. A minimum is an estimator of the *uncontended* cost, and it only works if
/// at least one attempt actually ran uncontended. The chance of that falls with
/// the length of the window: on a machine at load 390 — 49× oversubscribed, which
/// this one reaches — a 69 ms window is never clean, and the per-frame bound
/// measured 943 µs against a healthy 80 µs and failed three times in twenty. The
/// same total work cut into fifteen 7 ms windows finds a quiet slice and reports
/// the true figure.
///
/// It is not a trick to make a red test green. The number being estimated is the
/// same number; what changes is whether the estimator can see it through the
/// noise. A real regression slows every window, however short.
private func fastest(rounds: Int, _ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    var best: Duration?
    for _ in 0..<rounds {
        let run = clock.measure(body)
        best = best.map { Swift.min($0, run) } ?? run
    }
    return best ?? .zero
}

/// Two things measured **alternately**, and the best each of them saw.
///
/// This exists because the first version of this file did the obvious thing —
/// `bestOfThree(a)` then `bestOfThree(b)`, and divided — and the obvious thing
/// does not work. A ratio only cancels contention if both arms are contended
/// equally, and two sequential best-of-three blocks are not: a load spike lasting
/// a few hundred milliseconds covers all three of one arm's runs and none of the
/// other's, and the ratio moves by the whole size of the spike. It is not a
/// theoretical concern. Under fourteen spinning processes on eight cores, **three
/// of ten runs went red** on bounds the healthy code sits at 1.0 against: the
/// history ratio reached 2.18 and 2.15, the price ratio 2.74.
///
/// Interleaving fixes the mechanism rather than papering over it. Each round
/// measures both arms back to back, microseconds apart, so a spike lands on both
/// or neither; and taking each arm's minimum across the rounds means one quiet
/// round anywhere in the sequence is enough for both. Seven rounds rather than
/// three for the same reason — more chances at a quiet one.
///
/// The bounds were widened alongside this, to 4 where they were 2. Both changes
/// point the same way and neither costs sensitivity: the mistakes these ratios
/// exist to catch measure in the thousands and at 30.3, so the bound has orders of
/// magnitude of empty space to sit in and no reason to sit near the noise floor.
///
/// **What interleaving does not fix, and what was removed because of it.** A ratio
/// still needs a denominator that differs from its numerator by the thing under
/// test. Two of the four ratios this file originally carried did not have that —
/// pricing 1 minute against pricing 20,000 (identical instructions), and a frame
/// against the clock read that is most of the frame — and they went on flaking at
/// 5.23 and 9.12 after interleaving, because the problem was never scheduling. Both
/// are gone: the price is an absolute bound now, and the frame keeps only its
/// tenth-of-a-frame backstop. Interleaving buys robustness for a ratio that has
/// signal; it cannot manufacture signal that is not there.
private func fastestPair(rounds: Int = 7,
                         _ first: () -> Void,
                         _ second: () -> Void) -> (first: Duration, second: Duration) {
    let clock = ContinuousClock()
    var bestFirst: Duration?
    var bestSecond: Duration?
    for _ in 0..<rounds {
        let a = clock.measure(first)
        let b = clock.measure(second)
        bestFirst = bestFirst.map { Swift.min($0, a) } ?? a
        bestSecond = bestSecond.map { Swift.min($0, b) } ?? b
    }
    return (bestFirst ?? .zero, bestSecond ?? .zero)
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}

/// The ratio of two measurements from the same run. Unitless on purpose.
private func ratio(_ a: Duration, to b: Duration) -> Double {
    seconds(a) / max(seconds(b), .leastNormalMagnitude)
}

/// What a ratio is held to. Healthy is ~1.0 in every case below.
private let ratioBound = 4.0

@Suite struct WaitCostsNothingToAsk {

    // MARK: - The reader is a constant

    /// A wait she has left and come back to two thousand times answers as fast
    /// as one she has never left.
    ///
    /// This is the most load-bearing test in the file, because it is the only
    /// mistake this type is actually likely to make. `Wait` banks a *scalar* —
    /// `watched` is one `TimeInterval` and every pause adds to it — and the
    /// obvious alternative, which is what you write if you are asked to make the
    /// history inspectable or the pauses auditable, is to keep the spans:
    ///
    ///     var spans: [(start: TimeInterval, end: TimeInterval)]
    ///     func watched(at r: TimeInterval) -> TimeInterval {
    ///         spans.reduce(0) { $0 + ($1.end - $1.start) } + inFlight(r)
    ///     }
    ///
    /// That version is correct. It returns exactly the same numbers, and every
    /// assertion in `WaitTests` asks about a number — so nothing over there can
    /// tell the two apart, by construction. What it changes is the per-frame cost
    /// of the one screen in Silk that redraws at 120 Hz: it becomes a function of
    /// how often she has looked away, on a surface whose entire reason for
    /// existing is that looking away is the expected thing to do. Nothing but a
    /// clock catches it.
    ///
    /// **Four hundred departures is not a scenario.** A wait is at most twenty
    /// seconds long and nobody leaves an app twenty times a second. It is a
    /// number picked for how the test *fails*: large enough that a linear
    /// implementation is unmistakable rather than arguable — built and measured,
    /// the span-walking version above comes out at **3,223× the scalar** against a
    /// bound of 4 — and small enough that it says so promptly, in about three
    /// minutes. The first draft used ten thousand spans and a hundred thousand
    /// reads and the mutated build did not go red so much as go away: 10⁹
    /// additions in an unoptimised build is a suite that looks hung rather than
    /// failed, and a hang is a worse signal than a failure.
    @Test func theCostOfAnsweringDoesNotGrowWithHowOftenSheHasLookedAway() {
        let iterations = 20_000
        let departures = 400

        var fresh = Wait(doorID: door, minutes: 20, length: 6)
        fresh.watch(from: 0)

        var churned = Wait(doorID: door, minutes: 20, length: 6)
        for i in 0..<departures {
            churned.watch(from: Double(i) * 2)
            churned.lookAway(at: Double(i) * 2 + 0.0001, wallClock: .now)
        }
        churned.watch(from: 100_000)

        // Same length, same watching span in flight, same arithmetic to do —
        // the only difference between these two waits is what happened to them
        // before the measurement started.
        var sink = 0.0
        let (onAFreshWait, onAChurnedWait) = fastestPair({
            for i in 0..<iterations { sink += fresh.fraction(at: Double(i) * 1e-4) }
        }, {
            for i in 0..<iterations { sink += churned.fraction(at: 100_000 + Double(i) * 1e-4) }
        })
        #expect(sink > 0)   // the compiler may not delete the loops

        let cost = ratio(onAChurnedWait, to: onAFreshWait)
        #expect(cost < ratioBound,
                """
                the fraction got \(String(format: "%.1f", cost))× more expensive after \
                \(departures) departures — `watched(at:)` is walking a history instead of \
                reading a scalar
                """)
    }

    // MARK: - The whole second fits in one frame

    /// A full second of the mark — every reading and every fraction SwiftUI will
    /// ask for at 120 Hz — costs less than a tenth of one frame of the display it
    /// is drawn on.
    ///
    /// Which is the strongest form the smoothness claim can take without a
    /// display: not "the frame is fast enough", which needs a compositor to be
    /// true or false, but "a hundred and twenty frames of Silk's arithmetic do
    /// not add up to a tenth of one of them". At that margin no scheduling
    /// decision SwiftUI makes can be Silk's fault.
    ///
    /// The clock read is inside the measurement deliberately. `Monotonic.reading`
    /// lives in the app target and cannot be called from here, but
    /// `ContinuousClock.now` is what it is made of, and it is the more expensive
    /// half of the pair — leaving it out would measure the cheap part and call it
    /// the frame. Measured (debug, Apple silicon, three runs): **77–86 µs** for a
    /// second of frames, against a share of 833 µs. Ten times under, and 1% of
    /// the whole frame.
    ///
    /// **The bound was one whole frame until a mutation walked through it.** A
    /// `JSONEncoder().encode` dropped into `fraction(at:)` — the shape of a
    /// plausible "log the frame while we debug this" — made a second of the mark
    /// 15–25× more expensive and *passed*, because even at 1.97 ms it was still
    /// inside 8.33 ms. A tenth of a frame catches it. That is why the budget here
    /// is `silksShare` and not `frame`.
    ///
    /// **There is no sharper instrument available here, and two attempts at one
    /// were removed rather than left in.** The natural idea is a ratio against the
    /// clock read the frame is built from, and it does not work: the reading *is*
    /// most of the frame, so the ratio has almost no signal under it — healthy it
    /// wanders 0.9–1.6, and under fourteen spinning processes it reached 5.76 and
    /// 9.12, against a mutated value of 15.1. Healthy-under-load and broken had
    /// started to overlap, so the ratio was answering the machine rather than the
    /// question. Interleaving the two arms (`fastestPair`) fixed the sibling
    /// ratios in this file and did not fix this one, because the problem is not
    /// how the arms are scheduled — it is that they measure nearly the same thing.
    /// A ratio needs a denominator that differs from its numerator by the thing
    /// under test; this one does not have that, so it is gone.
    ///
    /// What is left is honest about its resolution: the absolute bound fires on a
    /// per-frame regression of roughly 10× or worse. The JSON encode is caught at
    /// **7.54 ms** of drawing per second against a budget of 833 µs — nine times
    /// over, and red in fourteen seconds. A per-frame allocation an order of
    /// magnitude *cheaper* than a JSON encode would not be caught here by
    /// anything, and no test in this file pretends otherwise.
    @Test func aSecondOfTheMarkFitsInsideSilksShareOfAFrame() {
        // 120 frames is too few to time against a clock with any confidence, so
        // a hundred seconds' worth are measured and the result is scaled back
        // down to one. Same arithmetic, resolution the timer can actually see —
        // and a window short enough to fit in a quiet slice of a busy machine,
        // which is why there are fifteen of them. See `fastest`.
        let secondsOfDrawing = 100
        let calls = secondsOfDrawing * framesPerSecond

        var w = Wait(doorID: door, minutes: 20, length: 6)
        w.watch(from: 0)

        // `Monotonic.reading`, copied rather than called: it lives in the app
        // target. Copied *exactly*, including the attosecond decomposition,
        // because that decomposition is the per-frame cost and a paraphrase
        // would be measuring something else.
        let origin = ContinuousClock.now
        var sink = 0.0
        let elapsed = fastest(rounds: 15) {
            for _ in 0..<calls {
                let d = origin.duration(to: ContinuousClock.now)
                let reading = Double(d.components.seconds)
                    + Double(d.components.attoseconds) * 1e-18
                sink += w.fraction(at: reading)
            }
        }
        #expect(sink > 0)

        let aSecondOfFrames = elapsed / secondsOfDrawing
        #expect(aSecondOfFrames < silksShare,
                """
                one second of the mark costs \(aSecondOfFrames), past the \(silksShare) Silk \
                gets of a 120 Hz frame — something in the per-frame path is doing real work
                """)
    }

    // MARK: - The price does not depend on the ask

    /// Pricing a fortnight-long ask is as cheap as pricing any other, because
    /// `length(forMinutes:)` is a multiply and a `min` and must stay one.
    ///
    /// Worth asserting: the price is read on the grant path before the veil
    /// rises, and the shape most likely to replace a closed form here is a table
    /// or a loop — a per-minute accumulation, a lookup built on first use —
    /// either of which turns a constant into a function of the number she
    /// happened to say. Nothing else in the suite would notice, since every
    /// existing assertion is about the *value* and every value would still be
    /// right.
    ///
    /// **This one is an absolute bound and not a ratio, which is the opposite of
    /// the rest of the file, and the reason is worth stating.** A ratio needs its
    /// two arms to differ in the thing being measured and agree in everything
    /// else. Here they would not differ at all: pricing 1 minute and pricing
    /// 20,000 run the identical two instructions, so the healthy ratio is 1.0
    /// with *no* signal underneath it, and every wobble the machine contributes
    /// is the entire measurement. It behaved exactly that way — under fourteen
    /// spinning processes it reached 5.23 against a bound of 4, while the two
    /// real ratios in this file, which do have signal, passed the same runs.
    /// A ratio with nothing to divide is a random number generator.
    ///
    /// The absolute form has no such problem because the gap is enormous: a
    /// thousand closed-form calls are ~250 µs, a thousand per-minute loops over
    /// 20,000 minutes are ~20 s. The bound sits at 100 ms — 400× above healthy,
    /// 200× below the mistake — and a thousand iterations keeps the mutated build
    /// failing in twenty seconds rather than hanging.
    @Test func pricingAnAskCostsTheSameWhateverTheAskIs() {
        // A fortnight of screen time in one sentence: comfortably past the
        // ceiling, past anything a person says, and past the point where a
        // per-minute loop could hide.
        let absurdAsk = 20_000
        let iterations = 1_000
        var sink = 0.0

        let elapsed = bestOfThree {
            for _ in 0..<iterations { sink += Wait.length(forMinutes: absurdAsk) }
        }
        #expect(sink > 0)
        #expect(Wait.length(forMinutes: absurdAsk) == Wait.ceiling)   // it took the branch

        #expect(elapsed < .milliseconds(100),
                """
                pricing \(absurdAsk) minutes \(iterations) times took \(elapsed) — the price is \
                no longer a closed form in the number asked for
                """)
    }
}
