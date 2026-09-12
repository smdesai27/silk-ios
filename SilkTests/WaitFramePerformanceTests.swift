import Testing
import Foundation
import SwiftUI
@testable import Silk
@testable import SilkCore

// The two places the wait can cost something: every frame it is drawn, and the
// one instant it lands.
//
// `SilkCore`'s `WaitPerformanceTests` owns the arithmetic and states the budget
// this file works to — read its header first; the reasoning about frames,
// ratios, best-of-N and debug builds is there and is not repeated here. What
// could not live there is everything below, because all of it is in the app
// target: the ensō's geometry, `Monotonic`, and the App Group.
//
// ============================================================
// The two moments
// ============================================================
//
// **Every frame.** `TimelineView(.animation)` asks for a frame at the display's
// rate and the body computes, from scratch, a reading, a fraction and the ensō's
// geometry. There is no cache and deliberately so — a cached frame is a frame
// that can be stale, and the whole point of this surface is that it is a pure
// function of watched seconds. The price of that purity is that the function has
// to be cheap, and nothing until now checked whether it was.
//
// **One instant.** `AppModel.landWait` runs on the main actor at the moment the
// ink lands: it syncs the ledger out of the App Group, re-validates the original
// parse, and writes the ledger back — all while the veil is 450 ms into a fade
// it must not stall. It is the single heaviest piece of synchronous main-actor
// work anywhere in the feature, and it is scheduled at the worst possible time
// on purpose (the wait doctrine: the verdict is stale by construction, so
// the whole run is done again). If that is going to cost something, this is the
// file that should say how much.
//
// ============================================================
// What is measured, and what is an approximation
// ============================================================
//
// The geometry figures are an **under-count and are described as one**. SwiftUI
// calls `path(in:)` on each of the seven strokes and then walks the result again
// through `.trim`, which is not callable from here. So what these tests bound is
// Silk's own geometry — the paths it builds and the arc-length lookups it does —
// and not the frame. That is the right subject anyway: `.trim`'s cost is
// SwiftUI's and does not change when Silk changes, whereas everything measured
// below is code in this repo that a refactor can make quadratic.
//
// ============================================================
// Three kinds of assertion, and what each is good for
// ============================================================
//
// Not every test here is equally sharp, and reading a green tick as though they
// were would be worse than not having them. Every bound below was mutation
// tested; what follows is what the mutations actually showed.
//
//   1. **Exact structural pins** — the arc table's size, the fact that it is
//      built once, the reading's monotonicity, the precondition that a fixture
//      reached the branch it claims to time. These cannot flake and cannot pass
//      for the wrong reason. Where a fact can be pinned instead of timed, it is.
//   2. **Ratios** — the brush tip's cost at both ends of the stroke. These are
//      the sensitive instruments: they compare two measurements taken in one run
//      on one machine, so load cancels, and they catch a change of *shape*
//      rather than a change of size. Replacing `locate`'s bisection with a
//      linear scan put that ratio at 30.3 against a bound of 4.
//   3. **Absolute frame bounds** — the per-frame geometry, the landing. These are
//      backstops. They sit 30–50× above the healthy cost, because an absolute
//      bound has to be given that much room to survive somebody else's runner,
//      and that room is exactly what a moderate regression fits through. The
//      same linear-scan mutation that pushed the ratio to 30.3 did not move the
//      per-frame bound at all. They catch catastrophe — I/O in a loop, a 50×
//      blowup — and nothing finer.
//
// The practical reading: if one of these ever goes red, believe it. If they are
// all green, the arithmetic has not changed shape — it does not mean the app is
// smooth, which is measured on a device and nowhere else.

// MARK: - Budget

/// One frame at 120 Hz — every ProMotion iPhone Silk targets.
private let frame = Duration.nanoseconds(8_333_333)

/// A tenth of the frame, and the budget the per-frame work is actually held to.
///
/// The frame belongs to SwiftUI's layout, Core Animation's commit and the GPU.
/// Silk's arithmetic is a guest in it, and a guest taking a whole frame has
/// taken everything. A tenth is the conventional share for application-side work
/// in a real-time loop and it is the number this file will defend: as measured
/// (debug, simulator) a frame of the mark's geometry is ~16 µs, which is 1.9% of
/// a frame and 19% of the share.
private let silksShare = frame / 10

// MARK: - Measurement

/// Minimum of `n` runs of a single operation.
///
/// The minimum, and not the mean, and this matters more here than in the spine:
/// the landing below touches the App Group, so some iterations will be charged
/// for a flush, a page fault or a neighbour. Those are real costs but they are
/// not *this code's* cost, and a bound that includes them is a bound on the
/// machine. The minimum is the closest a wall clock gets to what the code does.
///
/// **Every caller passes a large `n` over a short body, deliberately.** A minimum
/// only estimates the uncontended cost if some attempt ran uncontended, and the
/// odds of that fall with the length of the window. The spine file measured this
/// directly: a 69 ms window on a machine at load 390 never came up clean and its
/// bound failed three times in twenty, while the same total work in fifteen 7 ms
/// windows passed twenty out of twenty. Short windows, many rounds.
private func fastestOf(_ n: Int, _ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    var best: Duration?
    for _ in 0..<n {
        let run = clock.measure(body)
        best = best.map { Swift.min($0, run) } ?? run
    }
    return best ?? .zero
}

/// Two things measured **alternately**, and the best each of them saw. Every
/// ratio in this file goes through it; `fastestOf` above is for the absolute
/// bounds, which have no counterpart to interleave with.
///
/// The reasoning is `WaitPerformanceTests.fastestPair`'s and is not repeated:
/// measuring the two arms one after the other lets a load spike land on one and
/// not the other, which moves the ratio by the size of the spike. It was measured
/// doing exactly that — three of ten runs red under fourteen spinning processes —
/// before this existed.
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

private func ratio(_ a: Duration, to b: Duration) -> Double {
    seconds(a) / max(seconds(b), .leastNormalMagnitude)
}

/// What a ratio is held to. Healthy is ~1.0; the mutation it exists to catch
/// measures 30.3.
private let ratioBound = 4.0

// MARK: - The frame

@Suite(.serialized) @MainActor struct TheMarkCostsAlmostNothingToDraw {

    /// The arc-length table is the size the flick's placement was verified
    /// against, and pinning it is what makes every timing below mean something.
    ///
    /// `EnsoGeometry.arcTable` is a `static let` of 128 samples per cubic,
    /// justified in `EnsoPath.swift` by two hand-placed flick origins it has to
    /// reproduce. Two things follow, and both are performance facts:
    ///
    ///   - it is built **lazily**, on whichever frame first asks for the brush
    ///     tip. As measured, that build is ~24 µs — three frames' worth of
    ///     Silk's share, paid once per process. It is affordable at 513 samples
    ///     and it is linear in them.
    ///   - every lookup below is a binary search over *this* table. A bound
    ///     measured against 513 entries says nothing about 8,193.
    ///
    /// So the count is asserted exactly rather than timed. An exact assertion
    /// cannot flake, cannot pass for the wrong reason on a fast machine, and
    /// catches the one change — "sample it more finely" — that would move both
    /// the build and every lookup at once. The timing tests are then free to
    /// assume the table they were written against.
    @Test func theArcTableIsTheSizeTheFlickWasVerifiedAgainst() {
        let samplesPerCubic = 128
        #expect(EnsoGeometry.arcTable.points.count
                == EnsoGeometry.curves.count * samplesPerCubic + 1)
        #expect(EnsoGeometry.arcTable.cumulative.count
                == EnsoGeometry.arcTable.points.count)
    }

    /// And it is built **once**, not per frame.
    ///
    /// The other half of the same fact, and the half with a plausible way to go
    /// wrong: `static let` is one character from `static var { }`, and the change
    /// has a reason people reach for — make the sample count configurable, make
    /// the table depend on the frame size, make it testable. A computed property
    /// returns identical values, so every assertion above and every assertion
    /// about where the flick lands keeps passing, and the ~24 µs build moves from
    /// once per process to twice per frame.
    ///
    /// Asserted by identity rather than by a clock, because identity cannot
    /// flake. Two accesses to a stored `let` share one buffer; a computed
    /// property must allocate a second one, and the first is deliberately held
    /// alive across the comparison so the allocator cannot hand back the address
    /// it just freed.
    @Test func theArcTableIsBuiltOnceAndNotPerFrame() {
        let first = EnsoGeometry.arcTable.points
        let second = EnsoGeometry.arcTable.points
        let a = first.withUnsafeBufferPointer { $0.baseAddress }
        let b = second.withUnsafeBufferPointer { $0.baseAddress }
        #expect(a != nil && a == b,
                "the arc table was rebuilt between two reads — it is no longer a `static let`")
        #expect(first.count == second.count)   // `first` is alive past the comparison
    }

    /// Finding the brush tip costs the same at the start of the stroke as at the
    /// end, because `EnsoGeometry.locate` is a binary search and must stay one.
    ///
    /// The regression this exists for is not a slow line, it is a tidy one.
    /// `locate` is nine lines of explicit `lo`/`hi` bisection over the cumulative
    /// table, and the obvious simplification —
    ///
    ///     let i = cum.firstIndex { $0 >= target } ?? cum.count - 1
    ///
    /// — is shorter, reads better, returns the same index for every input, and
    /// passes every existing assertion about where the flick lands. It also
    /// turns a nine-step lookup into a scan of up to 513 entries, twice per
    /// frame (`point` and `tangent` each locate), on the one surface in Silk
    /// that redraws at 120 Hz. And it does it *asymmetrically*: cheap near the
    /// start of the stroke, worst at the end — so the wait would get more
    /// expensive the closer it came to landing, which is precisely the moment it
    /// must not stutter.
    ///
    /// A ratio catches that and a wall-clock bound would not: a linear scan at
    /// 0.98 is still only microseconds, comfortably inside any absolute budget
    /// this file could defend. What gives it away is that it is ~50× the cost of
    /// the same call at 0.02, where bisection is flat.
    @Test func findingTheBrushTipCostsTheSameWhereverItIs() {
        let iterations = 10_000
        let rect = CGRect(x: 0, y: 0, width: 132, height: 132)
        var sink = 0.0

        // Just after the wait's mark begins — the first entries of the table —
        // against the frame the ink lands on, the last entries. Alternated, not
        // one block then the other; see `fastestPair`.
        let (nearTheStart, nearTheEnd) = fastestPair({
            for _ in 0..<iterations {
                sink += EnsoGeometry.point(atFraction: 0.02, in: rect).x
                sink += EnsoGeometry.tangent(atFraction: 0.02).dx
            }
        }, {
            for _ in 0..<iterations {
                sink += EnsoGeometry.point(atFraction: 0.98, in: rect).x
                sink += EnsoGeometry.tangent(atFraction: 0.98).dx
            }
        })
        #expect(sink != 0)

        // Built and measured: swapping the bisection for the `firstIndex` above
        // puts this at **30.3**. The whole-frame bound below did not move.
        let cost = ratio(nearTheEnd, to: nearTheStart)
        #expect(cost < ratioBound,
                """
                the brush tip cost \(String(format: "%.1f", cost))× as much to find at the end \
                of the stroke as at the start — `locate` is scanning the arc table instead of \
                bisecting it, and the wait gets slower the closer it comes to landing
                """)
    }

    /// One frame of the mark's geometry fits inside Silk's tenth of a frame.
    ///
    /// This is the buttery-smooth requirement in the only form a unit test can
    /// hold it: not "the animation is smooth", which needs a display, but "the
    /// work Silk hands SwiftUI every frame is small enough that SwiftUI's own
    /// frame cannot be Silk's fault".
    ///
    /// Everything in the loop is what `WaitOverlay`'s body does, in order and at
    /// the size it ships at (132 pt, not Now's 232): a monotonic reading, a
    /// fraction, the five body strokes plus the dry-brush hair, and the flick's
    /// point and tangent. Measured at ~16 µs, against a share of 833 µs — 52×
    /// under, and 0.19% of the whole frame.
    ///
    /// **This is a backstop and not a sharp instrument, and it is worth being
    /// clear about which.** Path construction is 14 µs of the 16 µs — legitimate
    /// work every ensō in the app already does — so the bound sits 52× above the
    /// healthy cost and only fires on something that is 50× and not 2×: a
    /// synchronous App Group read per frame, a JSON round trip, a lock, an
    /// allocation storm. When the bisection in `locate` was replaced with a
    /// linear scan, this test **did not move** and the ratio test above went red
    /// at 30.3×. That is the division of labour on purpose: ratios catch shape,
    /// absolute bounds catch catastrophe, and a file that pretended one
    /// instrument did both would be the more dangerous kind of green.
    @Test func oneFrameOfTheMarksGeometryFitsInsideSilksShareOfIt() {
        let frames = 1_500
        let rect = CGRect(x: 0, y: 0, width: 132, height: 132)

        var w = Wait(doorID: UUID(), minutes: 20, length: 6)
        w.watch(from: Monotonic.reading)
        var sink = 0.0

        let elapsed = fastestOf(15) {
            for _ in 0..<frames {
                let f = w.fraction(at: Monotonic.reading)
                // Five body layers and the hair — six paths, all `EnsoPath`.
                for _ in 0..<6 { sink += EnsoPath().path(in: rect).boundingRect.width }
                // The flick, which is the only part that reads the arc table.
                sink += EnsoGeometry.point(atFraction: max(f, 0.04), in: rect).x
                sink += EnsoGeometry.tangent(atFraction: max(f, 0.04)).dx
            }
        }
        #expect(sink > 0)

        let oneFrame = elapsed / frames
        #expect(oneFrame < silksShare,
                """
                a frame of the mark costs \(oneFrame), past the \(silksShare) Silk gets of a \
                120 Hz frame — something in `WaitOverlay`'s body is doing real work
                """)
    }

    /// The reading the mark is drawn from goes forward and costs nothing.
    ///
    /// Two claims in one test because they are the same claim about the same
    /// four lines. `Monotonic.reading` is read once per frame and its answer is
    /// the wait's entire notion of time, so it has to be cheap *and* it has to be
    /// a clock: an implementation that decomposed a `Date`, or that rebuilt its
    /// origin, would still return plausible numbers and would break the wait in
    /// a way no correctness test in either suite is looking for. Nothing else
    /// anywhere tests `Monotonic` at all.
    ///
    /// The monotonicity assertion is also what makes the spine's frame test
    /// honest: it measures a *copy* of these four lines, because the original
    /// lives in this target. If the two ever diverge, this is where it shows.
    @Test func theReadingTheMarkIsDrawnFromGoesForwardAndCostsNothing() {
        var previous = Monotonic.reading
        for _ in 0..<10_000 {
            let next = Monotonic.reading
            #expect(next >= previous, "the reading went backwards: \(previous) → \(next)")
            previous = next
        }

        let reads = 200_000
        var sink = 0.0
        let elapsed = fastestOf(3) {
            for _ in 0..<reads { sink += Monotonic.reading }
        }
        #expect(sink > 0)

        // A hundred and twenty of these is one second of the mark. Held to the
        // same tenth-of-a-frame as everything else in the body.
        let aSecondOfReadings = (elapsed / reads) * 120
        #expect(aSecondOfReadings < silksShare,
                "a second of readings costs \(aSecondOfReadings), past Silk's \(silksShare)")
    }
}

// MARK: - The landing

@Suite(.serialized) @MainActor struct TheLandingDoesNotStallTheVeilsFall {

    /// A day's worth of grants: the smallest grant anyone makes is one minute,
    /// and `GrantLedger.compact` keeps everything since day start, so forty rows
    /// is the shape of a heavily-used day. A one-grant fixture would be a bound
    /// on nothing — the blob's size is what the decode and the encode are paid
    /// for.
    private func aFullDaysLedger(door: Door) -> GrantLedger {
        var ledger = GrantLedger()
        let now = Date.now
        for i in 0..<40 {
            let issued = now.addingTimeInterval(Double(-i) * 60)
            ledger.record(Grant(door: door, minutes: 1, issuedAt: issued,
                                expiresAt: issued.addingTimeInterval(60)))
        }
        return ledger
    }

    /// Everything `landWait` does synchronously fits in one frame.
    ///
    /// The sequence is `landWait`'s, in its order: read the stamp, reload the
    /// ledger if another writer moved it, re-validate the original parse against
    /// what now stands, write the result back. It runs on the main actor at the
    /// instant `clearWait()` starts the veil's 450 ms fade, so a stall here is
    /// not an abstraction — it is a visible hitch on the last frame of the one
    /// screen in Silk whose entire purpose is to be watched.
    ///
    /// **The bound is a whole frame, not Silk's tenth of one, and that is a
    /// deliberate looser standard than the per-frame tests above.** This work
    /// happens once, and the honest requirement for a once-per-wait operation is
    /// that it not drop a frame — not that it stay a polite guest in a loop it
    /// is not in.
    ///
    /// **It is also the thinnest margin in either performance file, and worth
    /// saying out loud rather than burying under a green tick.** As measured
    /// (debug, simulator) a landing costs ~1.9 ms against a frame of 8.3 ms:
    /// 4.5× of headroom, where every other bound in these two files has ten times
    /// that. Nearly all of it is one line — `SharedStore.save(ledger:)` is ~1.5 ms
    /// of encode and App Group write, and the reload another ~0.3 ms — and those
    /// figures are very probably a simulator artifact: a `UserDefaults` write to a
    /// shared suite round-trips through `cfprefsd` here, where on device it is a
    /// cached write with a coalesced flush. No claim is made about the device
    /// number, because this file cannot measure one.
    ///
    /// So this test is not really standing over the wait. It is standing over the
    /// App Group, which is shared with three extensions, and it will only catch a
    /// regression of the order of a whole extra write or worse — a `synchronize`,
    /// a second blob, a network call. That is a real class of mistake and worth a
    /// gate. It is not a fine-grained one, and the test next door is the tight
    /// bound: `Validator.validate` is the part of the landing that is Silk's own
    /// arithmetic, it is 33× under Silk's share of a frame, and *that* is where a
    /// quadratic scan of the ledger would show up.
    @Test func everythingTheLandingDoesFitsInOneFrame() {
        SharedStore.wipeAll()
        let door = Door(name: "Instagram")
        // A window anchored twelve hours out, for `WaitLifecycleTests`' reason:
        // the shipped 22–7 would clamp or refuse depending on the hour the suite
        // runs at, and the validation below has to do its real work every time.
        let hour = (Calendar.current.component(.hour, from: .now) + 12) % 24
        let nowhere = TimeOfDay(hour: hour, minute: 30)
        // Ninety, not the shipped forty, and the precondition below is what
        // caught it: forty one-minute grants spend a forty-minute pool exactly,
        // so the Validator refused — and a refusal is the *short* path. This
        // would have been a bound on the branch that does less work, passing
        // comfortably and guarding nothing.
        let state = PolicyState(budgetMinutes: 90,
                                downHours: DownHours(start: nowhere, end: nowhere),
                                doors: [door])
        SharedStore.save(policy: state)
        SharedStore.save(ledger: aFullDaysLedger(door: door))

        // The parse `Waiting` holds, re-validated — not a command rebuilt from
        // the first verdict. Same call `landWait` makes, provenance and all.
        let outcome = ParseOutcome.command(.spend(door: door, minutes: 20))
        let utterance = "unlock instagram for twenty minutes"
        var landed = 0

        let elapsed = fastestOf(50) {
            _ = SharedStore.ledgerStamp()
            let ledger = SharedStore.loadLedger()
            let verdict = Validator.validate(outcome, utterance: utterance,
                                             state: state, ledger: ledger, now: .now)
            if case .grant = verdict { landed += 1 }
            SharedStore.save(ledger: ledger)
        }

        #expect(landed > 0, "the fixture never reached the grant branch — this timed a refusal")
        #expect(elapsed < frame,
                """
                the landing costs \(elapsed), past the \(frame) a 120 Hz frame gets — the veil \
                will hitch on the frame the ink lands
                """)
    }

    /// The re-validation itself — the only part of the landing that is Silk's own
    /// arithmetic rather than the App Group's I/O — costs a fraction of Silk's
    /// share of a frame.
    ///
    /// This is the tight half of the pair above, and it is tight because it can
    /// be: no `UserDefaults`, no encode, no `cfprefsd`, nothing whose cost is a
    /// property of the machine rather than the code. Measured at ~25 µs against a
    /// share of 833 µs, it has 33× of headroom and it is a bound that bites.
    ///
    /// What it guards is the shape of `Validator.validate` against the ledger it
    /// is handed. Spending is derived by walking today's grants, and forty of
    /// them is a real day; anything that turned that walk into a walk per grant —
    /// a per-grant re-derivation of the balance, a per-grant window check — is
    /// quadratic in a number that grows all day and would land exactly here,
    /// while every correctness test in the suite went on passing because every
    /// answer would still be right.
    @Test func revalidatingTheAskIsWellInsideSilksShareOfAFrame() {
        SharedStore.wipeAll()
        let door = Door(name: "Instagram")
        let hour = (Calendar.current.component(.hour, from: .now) + 12) % 24
        let nowhere = TimeOfDay(hour: hour, minute: 30)
        let state = PolicyState(budgetMinutes: 90,
                                downHours: DownHours(start: nowhere, end: nowhere),
                                doors: [door])
        let ledger = aFullDaysLedger(door: door)
        let outcome = ParseOutcome.command(.spend(door: door, minutes: 20))
        var granted = 0

        let elapsed = fastestOf(200) {
            let verdict = Validator.validate(outcome, utterance: "unlock instagram for twenty minutes",
                                             state: state, ledger: ledger, now: .now)
            if case .grant = verdict { granted += 1 }
        }

        #expect(granted > 0, "the fixture never reached the grant branch — this timed a refusal")
        #expect(elapsed < silksShare,
                """
                re-validating the ask costs \(elapsed), past the \(silksShare) Silk gets of a \
                120 Hz frame — the Validator's work is growing with the ledger
                """)
    }
}
