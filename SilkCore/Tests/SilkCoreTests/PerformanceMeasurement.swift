import Foundation

// How this repo times things, in one place.
//
// Three suites now assert about cost — `WaitPerformanceTests` on the per-frame
// arithmetic, `StressTests.hugeInputStaysCheapAndSilent` on the parser, and
// `ClauseIndexCost` on the index — and all three arrived at the same two
// instruments by the same painful route. They lived as a `private` copy in one
// file and a nested copy inside a single test function in another, which is one
// implementation more than the idea deserves and two places for a fix to miss.
//
// The reasoning below is the reasoning `WaitPerformanceTests` worked out and
// stated at length; its file comment is still the long form, and is worth
// reading before writing any new bound. The short version:
//
// **Ratios wherever a ratio will do.** A wall-clock bound is a claim about the
// machine that ran it, and it reddens on a loaded one for reasons that have
// nothing to do with the code. A ratio between two measurements taken in the
// same run, on the same machine, microseconds apart, is a claim about the code.
//
// **Minimums, not means.** A minimum estimates the *uncontended* cost. A real
// regression slows every attempt; a busy neighbour only some.
//
// **Absolute bounds are backstops, not thresholds.** Where an absolute number is
// unavoidable, put it in the empty space between the measured cost and the cost
// of the mistake — orders of magnitude from both, so its exact value is doing no
// work and it stays safe on hardware nobody has seen yet.

/// The quickest `body` ever managed, over `rounds` attempts.
///
/// **Short windows and many rounds, rather than long windows and few**, and the
/// difference decides whether an absolute bound is usable on a busy machine at
/// all. A minimum is an estimator of the *uncontended* cost, and it only works if
/// at least one attempt actually ran uncontended. The chance of that falls with
/// the length of the window: on a machine at load 390 — 49× oversubscribed, which
/// this one reaches — a 69 ms window is never clean, and `WaitPerformanceTests`'
/// per-frame bound measured 943 µs against a healthy 80 µs and failed three times
/// in twenty. The same total work cut into fifteen 7 ms windows finds a quiet
/// slice and reports the true figure.
///
/// It is not a trick to make a red test green. The number being estimated is the
/// same number; what changes is whether the estimator can see it through the
/// noise. A real regression slows every window, however short.
func fastest(rounds: Int, _ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    var best: Duration?
    for _ in 0..<rounds {
        let run = clock.measure(body)
        best = best.map { Swift.min($0, run) } ?? run
    }
    return best ?? .zero
}

/// Best of three. For a single measurement with no counterpart — the absolute
/// bounds. Ratios must use `fastestPair` below.
func bestOfThree(_ body: () -> Void) -> Duration {
    fastest(rounds: 3, body)
}

/// Two things measured **alternately**, and the best each of them saw.
///
/// This exists because the first version of `WaitPerformanceTests` did the
/// obvious thing — `bestOfThree(a)` then `bestOfThree(b)`, and divided — and the
/// obvious thing does not work. A ratio only cancels contention if both arms are
/// contended equally, and two sequential best-of-three blocks are not: a load
/// spike lasting a few hundred milliseconds covers all three of one arm's runs
/// and none of the other's, and the ratio moves by the whole size of the spike.
/// It is not a theoretical concern. Under fourteen spinning processes on eight
/// cores, **three of ten runs went red** on bounds the healthy code sits at 1.0
/// against: the history ratio reached 2.18 and 2.15, the price ratio 2.74.
///
/// Interleaving fixes the mechanism rather than papering over it. Each round
/// measures both arms back to back, microseconds apart, so a spike lands on both
/// or neither; and taking each arm's minimum across the rounds means one quiet
/// round anywhere in the sequence is enough for both. Seven rounds rather than
/// three for the same reason — more chances at a quiet one.
///
/// **The `rounds:` knob is for cheap arms, not for expensive ones**, and this
/// paragraph used to say the opposite: it offered a smaller number to callers
/// whose arms cost real suite time, and named
/// `hugeInputStaysCheapAndSilent` — ten thousand words per arm — as the caller
/// taking the offer. That is backwards. The longer an arm's window, the *less*
/// likely any single round of it ran uncontended, so a long window is precisely
/// where the extra rounds are load-bearing; three rounds over a ~0.4 s window
/// made that test the most-cited flake on this repo's pre-push hook. It now
/// takes the default like everyone else. Lower the count only for an arm whose
/// window is short and whose round count is therefore already redundant.
///
/// **What interleaving does not fix.** A ratio still needs a denominator that
/// differs from its numerator by the thing under test. Two of the four ratios
/// `WaitPerformanceTests` originally carried did not have that — pricing 1 minute
/// against pricing 20,000 (identical instructions), and a frame against the clock
/// read that is most of the frame — and they went on flaking at 5.23 and 9.12
/// after interleaving, because the problem was never scheduling. Both are gone.
/// Interleaving buys robustness for a ratio that has signal; it cannot
/// manufacture signal that is not there.
func fastestPair(rounds: Int = 7,
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

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}

/// The ratio of two measurements from the same run. Unitless on purpose.
func ratio(_ a: Duration, to b: Duration) -> Double {
    seconds(a) / max(seconds(b), .leastNormalMagnitude)
}
