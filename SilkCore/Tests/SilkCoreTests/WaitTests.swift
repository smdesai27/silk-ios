import Foundation
import Testing
@testable import SilkCore

// The wait's one promise, said four ways: it advances only while watched, it
// never resets, it never runs backwards, and it can only ever END while someone
// is looking at it. Every test below is one of those four, or the price.
//
// No clock is read anywhere in this file. `Wait` takes its readings as
// arguments precisely so the whole contract can be checked at whatever speed a
// test wants to run at, and the numbers here are seconds because that is what
// the app will hand it.

private let door = UUID()

/// Named `ask` and not `wait`: `wait(_:)` is already in scope from Darwin, and
/// a defaulted first argument collides with it in a way the compiler reports
/// as a wrong argument label.
private func ask(length: TimeInterval = 10, watched: TimeInterval = 0) -> Wait {
    Wait(doorID: door, minutes: 20, length: length, watched: watched)
}

/// Wall clock only matters to staleness, so it is a fixture rather than a
/// parameter of every call.
private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct WaitWatching {

    @Test func aWaitNobodyIsLookingAtDoesNotMove() {
        let w = ask()

        // A thousand seconds of reading, and not one of them watched.
        #expect(w.isWatching == false)
        #expect(w.watched(at: 1000) == 0)
        #expect(w.fraction(at: 1000) == 0)
        #expect(w.isOver(at: 1000) == false)
    }

    @Test func watchingAccruesFromTheReadingItStartedAt() {
        var w = ask()
        w.watch(from: 100)

        #expect(w.isWatching)
        #expect(w.watched(at: 104) == 4)
        #expect(w.fraction(at: 105) == 0.5)
    }

    @Test func lookingAwayFreezesItExactlyWhereItStopped() {
        var w = ask()
        w.watch(from: 100)
        w.lookAway(at: 103, wallClock: noon)

        // Three seconds banked, and the reading may run as far as it likes.
        #expect(w.watched == 3)
        #expect(w.watched(at: 103) == 3)
        #expect(w.watched(at: 9999) == 3)
        #expect(w.isWatching == false)
    }

    @Test func comingBackResumesAndDoesNotReset() {
        var w = ask()
        w.watch(from: 100)
        w.lookAway(at: 103, wallClock: noon)      // 3 watched
        w.watch(from: 500)                        // away for 397 seconds; irrelevant
        #expect(w.watched(at: 502) == 5)          // 3 + 2, not 2

        w.lookAway(at: 505, wallClock: noon)
        #expect(w.watched == 8)
        w.watch(from: 1000)
        #expect(w.isOver(at: 1002) == true)       // 8 + 2 = 10
    }

    @Test func theSumOfManyShortLooksIsTheSumOfTheirSpans() {
        var w = ask(length: 60)
        var reading: TimeInterval = 0
        // Twelve half-second glances, each an hour apart in reading time.
        for _ in 0..<12 {
            w.watch(from: reading)
            w.lookAway(at: reading + 0.5, wallClock: noon)
            reading += 3600
        }
        #expect(abs(w.watched - 6) < 1e-9)
    }
}

@Suite struct WaitCanOnlyEndWhileWatched {

    /// The property the whole surface rests on. If a wait could finish while
    /// nobody was looking, she would come back to a completed wait sitting
    /// there — and the app would either post her into Instagram without her
    /// present, or hold a finished screen with nothing to do. Neither state
    /// exists, and the reason is arithmetic: `watched` moves only inside a
    /// watching span.
    @Test func aParkedWaitNeverFinishesOnItsOwn() {
        var w = ask()
        w.watch(from: 0)
        w.lookAway(at: 9.9, wallClock: noon)      // one tenth of a second short

        // A century of readings, and it is still one tenth short.
        for reading in stride(from: 10.0, through: 1_000_000.0, by: 100_000.0) {
            #expect(w.isOver(at: reading) == false)
        }
        #expect(w.fraction(at: 1_000_000) == 0.99)
    }

    /// Said as an invariant so a future change to `watched(at:)` that reads a
    /// clock of its own breaks a test rather than a promise.
    @Test func theInvariantIsDeclaredOnTheType() {
        #expect(ask().canOnlyEndWhileWatched)
    }
}

@Suite struct WaitIsIdempotent {

    /// iOS hands out `.active` more than once without an intervening leave — a
    /// Face ID sheet dismissing, a system alert going away. Restarting the span
    /// on the second one would silently throw away everything watched since the
    /// first.
    @Test func aSecondWatchDoesNotRestartTheSpan() {
        var w = ask()
        w.watch(from: 100)
        w.watch(from: 108)                        // the one that would have cost 8s

        #expect(w.watched(at: 109) == 9)
    }

    /// The mirror failure, and the worse one: banking twice off a single span
    /// would credit attention nobody paid, which is the one direction this type
    /// may not fail in.
    @Test func aSecondLookAwayDoesNotBankTwice() {
        var w = ask()
        w.watch(from: 100)
        w.lookAway(at: 104, wallClock: noon)
        w.lookAway(at: 108, wallClock: noon)

        #expect(w.watched == 4)
    }

    @Test func lookingAwayFromAWaitNobodyWasWatchingIsANoOp() {
        var w = ask(watched: 3)
        w.lookAway(at: 500, wallClock: noon)

        #expect(w.watched == 3)
        #expect(w.isWatching == false)
    }
}

@Suite struct WaitNeverRunsBackwards {

    /// A monotonic source cannot go backwards, but a caller can hand over a
    /// stale reading — a queued frame, a value captured before a hop. One
    /// negative span would be attention handed back.
    @Test func aStaleReadingHandsNothingBack() {
        var w = ask(watched: 5)
        w.watch(from: 100)

        #expect(w.watched(at: 90) == 5)           // not 5 − 10
        w.lookAway(at: 90, wallClock: noon)
        #expect(w.watched == 5)
    }

    @Test func fractionIsClampedToTheStroke() {
        var w = ask()
        w.watch(from: 0)

        #expect(w.fraction(at: 10) == 1)
        #expect(w.fraction(at: 10_000) == 1)      // never past the end of the ink
    }

    @Test func aZeroLengthWaitIsOverRatherThanUndrawable() {
        let w = ask(length: 0)

        // 0/0 has no answer; the honest one is "finished".
        #expect(w.fraction(at: 0) == 1)
        #expect(w.isOver(at: 0))
    }

    @Test func theWaitIsOverAtExactlyItsLengthAndNotAFrameLater() {
        var w = ask()
        w.watch(from: 0)

        #expect(w.isOver(at: 9.999) == false)
        #expect(w.isOver(at: 10))
    }
}

@Suite struct WaitStaleness {

    @Test func aWaitSomeoneIsWatchingIsNeverStale() {
        var w = ask()
        w.watch(from: 0)

        // Even against a wall clock a year on: someone is looking at it now.
        #expect(w.isStale(at: noon.addingTimeInterval(31_536_000)) == false)
    }

    @Test func aParkedWaitGoesStaleOnTheWallClockAndNotTheReading() {
        var w = ask()
        w.watch(from: 0)
        w.lookAway(at: 3, wallClock: noon)

        #expect(w.isStale(at: noon.addingTimeInterval(60)) == false)
        #expect(w.isStale(at: noon.addingTimeInterval(Wait.staleAfter)) == false)
        #expect(w.isStale(at: noon.addingTimeInterval(Wait.staleAfter + 1)))
    }

    /// The trap this window exists to close: an abandoned wait that resumes
    /// under her thumb when she comes back for something else entirely.
    @Test func theWindowIsShortEnoughThatComingBackLaterIsAFreshVisit() {
        #expect(Wait.staleAfter == 120)
    }

    @Test func aWaitThatWasNeverWatchedAtAllIsNotYetStale() {
        // Nothing has paused it, so there is no moment to measure from. The
        // surface raises it and the first frame starts it.
        let w = ask()
        #expect(w.isStale(at: noon.addingTimeInterval(31_536_000)) == false)
    }

    /// A wait born while Silk is in the background, and the reason `raiseWait`
    /// parks one instead of watching it.
    ///
    /// `handle` is async and suspends twice — the model parse, then the 480 ms
    /// beat — before the wait exists. Swipe home inside that window and the
    /// wait is created with nobody present. A watching span opened there would
    /// run for the whole time she is away, because the monotonic clock counts
    /// through process suspension: she returns an hour later, `watched` already
    /// exceeds `length`, and the door opens on zero seconds watched. Parking it
    /// instead — watched, then immediately looked away from — banks nothing and
    /// stamps `pausedAt`, so the window governs it from birth.
    @Test func aWaitBornParkedBanksNothingAndIsGovernedByTheWindow() {
        var w = ask()
        // Exactly what `raiseWait` does when it finds itself in the background.
        w.watch(from: 100)
        w.lookAway(at: 100, wallClock: noon)

        #expect(w.watched == 0)
        #expect(w.isWatching == false)
        // The hour away buys nothing at all…
        #expect(w.watched(at: 100 + 3600) == 0)
        #expect(w.isOver(at: 100 + 3600) == false)
        // …and the ask does not survive it.
        #expect(w.isStale(at: noon.addingTimeInterval(Wait.staleAfter + 1)))
    }

    /// The failure the line above prevents, written down so the fix cannot be
    /// quietly reverted: left watching, the same wait is finished by absence.
    @Test func aWaitLeftWatchingWhileAwayWouldFinishItselfOnAbsenceAlone() {
        var w = ask()
        w.watch(from: 100)          // and never looked away from

        #expect(w.isOver(at: 100 + 3600))
        #expect(w.isStale(at: noon.addingTimeInterval(31_536_000)) == false)
    }
}

@Suite struct WaitPrice {

    /// The modal ask, and the one number in this file that came from a trial
    /// rather than from taste.
    @Test func twentyMinutesCostsTheResearchedSixSeconds() {
        #expect(Wait.length(forMinutes: 20) == 6.0)
    }

    /// No floor, on purpose: a clamped bottom is a fixed toll wearing a slope's
    /// clothes, and amendment A exists to refuse exactly that.
    @Test func thePriceHasNoFloorBecauseAFloorIsAToll() {
        #expect(Wait.length(forMinutes: 1) == 0.3)
        #expect(Wait.length(forMinutes: 2) == 0.6)
        #expect(Wait.length(forMinutes: 5) == 1.5)
        // Strictly increasing all the way down — nowhere is it the same price
        // twice, which is the property a toll has and this must not.
        for m in 1..<66 {
            #expect(Wait.length(forMinutes: m) < Wait.length(forMinutes: m + 1))
        }
    }

    /// Linear is the shape with nothing to game: splitting an ask in two costs
    /// exactly what asking once costs.
    @Test func splittingAnAskCostsWhatAskingOnceCosts() {
        let once = Wait.length(forMinutes: 30)
        let split = Wait.length(forMinutes: 10) + Wait.length(forMinutes: 20)
        #expect(abs(once - split) < 1e-9)
    }

    @Test func theCeilingBoundsTheAbsurdAskAndNothingBelowIt() {
        #expect(Wait.length(forMinutes: 66) < Wait.ceiling)
        #expect(Wait.length(forMinutes: 67) == Wait.ceiling)
        #expect(Wait.length(forMinutes: 300) == Wait.ceiling)
        // The default budget spent whole still costs less than the ceiling, so
        // the ceiling never binds on an ordinary day.
        #expect(Wait.length(forMinutes: 40) == 12.0)
    }

    @Test func aNonsenseMinuteCountCostsNothingRatherThanNegativeTime() {
        #expect(Wait.length(forMinutes: 0) == 0)
        #expect(Wait.length(forMinutes: -5) == 0)
    }

    /// Below the veil's own rise there is no wait to draw, and the door simply
    /// opens as it always did.
    @Test func aWaitShorterThanTheVeilsRiseIsNotDrawnAtAll() {
        #expect(Wait.isWorthDrawing(Wait.length(forMinutes: 1)) == false)   // 0.3s
        #expect(Wait.isWorthDrawing(Wait.length(forMinutes: 2)))            // 0.6s
        #expect(Wait.tooShortToDraw == 0.4)                                 // Silk.Motion.overlay
    }
}

/// The trap the wait's second validation fell into, pinned here so the app
/// cannot wander back into it.
///
/// `AppModel.landWait` re-validates when the ink lands, because a wait is time
/// and the balance may have moved under it. The obvious way to do that — take
/// the `.grant` verdict's door and minutes and build a fresh `.spend` — is
/// wrong, and silently so: the verdict carries the **clamped** minutes, the
/// Validator runs a number-provenance check against the utterance, and a
/// clamped number is by definition one she did not say. The app then answered
/// every over-ask with "Didn't get that." *after* making her watch the wait
/// for it. Two UI walks caught it; these three pin it without a simulator.
@Suite struct WaitRevalidationProvenance {

    private static func policy(budget: Int, door: Door) -> PolicyState {
        PolicyState(budgetMinutes: budget,
                    downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                    doors: [door])
    }

    /// Noon, well clear of the down-hours edge.
    private static let noon = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 12))!

    @Test func rebuildingTheCommandFromTheClampedVerdictLosesProvenance() {
        let door = Door(name: "Reddit")
        let state = Self.policy(budget: 40, door: door)
        let said = "give me sixty minutes of reddit"

        // First pass: sixty asked, forty granted.
        let first = Validator.validate(.command(.spend(door: door, minutes: 60)),
                                       utterance: said, state: state,
                                       ledger: GrantLedger(), now: Self.noon)
        guard case .grant(_, let granted, _) = first else {
            Issue.record("expected a clamped grant, got \(first)")
            return
        }
        #expect(granted == 40)

        // The tempting second pass, and why it may never be written: 40 is not
        // a word she said, so provenance rejects it and the app says
        // "Didn't get that." to a grant it had already approved.
        let rebuilt = Validator.validate(.command(.spend(door: door, minutes: granted)),
                                         utterance: said, state: state,
                                         ledger: GrantLedger(), now: Self.noon)
        #expect(rebuilt == .silence)
    }

    @Test func revalidatingTheOriginalOutcomeGrantsAgainAndReClamps() {
        let door = Door(name: "Reddit")
        let state = Self.policy(budget: 40, door: door)
        let said = "give me sixty minutes of reddit"
        let outcome = ParseOutcome.command(.spend(door: door, minutes: 60))

        // Same outcome, twice, against an untouched ledger: same answer.
        let first = Validator.validate(outcome, utterance: said, state: state,
                                       ledger: GrantLedger(), now: Self.noon)
        let second = Validator.validate(outcome, utterance: said, state: state,
                                        ledger: GrantLedger(), now: Self.noon)
        #expect(first == second)
        guard case .grant(_, let granted, _) = second else {
            Issue.record("the second pass did not grant: \(second)")
            return
        }
        #expect(granted == 40)
    }

    /// And the point of re-validating at all: a pool drawn down while she
    /// watched re-clamps rather than paying out the number the first pass
    /// computed.
    @Test func aBalanceThatMovedDuringTheWaitReClampsTheGrant() {
        let door = Door(name: "Reddit")
        let state = Self.policy(budget: 40, door: door)
        let said = "give me sixty minutes of reddit"
        let outcome = ParseOutcome.command(.spend(door: door, minutes: 60))

        // A Shortcut spent 25 on another door while the ink was being watched.
        let other = Door(name: "TikTok")
        var wider = state
        wider.doors.append(other)
        var ledger = GrantLedger()
        ledger.record(Grant(door: other, minutes: 25, issuedAt: Self.noon,
                            expiresAt: Self.noon.addingTimeInterval(25 * 60)))

        let verdict = Validator.validate(outcome, utterance: said, state: wider,
                                         ledger: ledger, now: Self.noon)
        guard case .grant(_, let granted, _) = verdict else {
            Issue.record("expected a re-clamped grant, got \(verdict)")
            return
        }
        #expect(granted == 15)   // 40 − 25, not the 40 the first pass found
    }

    /// §8.1 of the design doc, the thing it names as most likely to hurt: she
    /// can pay the wait and be refused at the end of it. Written down there and
    /// asserted nowhere until now.
    @Test func downHoursThatBeganDuringTheWaitRefuseTheAskShePaidFor() {
        let door = Door(name: "Reddit")
        let state = Self.policy(budget: 40, door: door)
        let said = "give me twenty minutes of reddit"
        let outcome = ParseOutcome.command(.spend(door: door, minutes: 20))
        let cal = Calendar(identifier: .gregorian)

        // 21:30, the aperture open and room to spend inside it. Deliberately
        // not 21:59:57: a twenty-minute ask that close to the edge is already
        // truncated by it, so the two passes would differ for a second reason
        // and the test would prove nothing about the edge itself.
        let before = cal.date(from: DateComponents(year: 2026, month: 8, day: 8,
                                                   hour: 21, minute: 30))!
        guard case .grant = Validator.validate(outcome, utterance: said, state: state,
                                               ledger: GrantLedger(), now: before) else {
            Issue.record("the ask should have been granted before the edge")
            return
        }

        // 22:00:03 — the ink lands on the other side of it.
        let after = cal.date(from: DateComponents(year: 2026, month: 8, day: 8,
                                                  hour: 22, minute: 0, second: 3))!
        let verdict = Validator.validate(outcome, utterance: said, state: state,
                                         ledger: GrantLedger(), now: after)
        #expect(verdict == .refuseDownHours(until: TimeOfDay(hour: 7)))
    }

    /// The clamp reaching zero must become a refusal, not a grant of nothing.
    /// The only re-clamp case tested above lands on 15; a door opened for zero
    /// minutes would be a wall that came down and went straight back up.
    @Test func aPoolSpentToNothingDuringTheWaitRefusesRatherThanGrantingZero() {
        let door = Door(name: "Reddit")
        let other = Door(name: "TikTok")
        var state = Self.policy(budget: 40, door: door)
        state.doors.append(other)
        let said = "give me twenty minutes of reddit"
        let outcome = ParseOutcome.command(.spend(door: door, minutes: 20))

        // A Shortcut spent the whole pool elsewhere while she watched.
        var ledger = GrantLedger()
        ledger.record(Grant(door: other, minutes: 40, issuedAt: Self.noon,
                            expiresAt: Self.noon.addingTimeInterval(40 * 60)))

        #expect(Validator.validate(outcome, utterance: said, state: state,
                                   ledger: ledger, now: Self.noon) == .refuseNothingLeft)
    }
}

@Suite struct WaitUnderArbitraryInterleavings {

    /// The invariant that has to hold whatever order the scene phases arrive
    /// in: watched time is monotonic, never exceeds the real attended time, and
    /// equals it exactly. Seeded, so a failure is reproducible.
    @Test func watchedTimeEqualsAttendedTimeForAnyInterleaving() {
        var rng = SeededRNG(seed: 0xA11CE)

        for _ in 0..<2000 {
            var w = ask(length: 1000)
            var reading: TimeInterval = 0
            var attended: TimeInterval = 0
            var watching = false
            var previous: TimeInterval = 0

            for _ in 0..<40 {
                let step = Double(rng.next() % 500) / 10.0        // 0…50s
                reading += step
                if watching { attended += step }

                // The reading is asked mid-flight too, and must never regress.
                let seen = w.watched(at: reading)
                #expect(seen >= previous)
                previous = seen

                if rng.next() % 2 == 0 {
                    if watching {
                        w.lookAway(at: reading, wallClock: noon)
                    } else {
                        w.watch(from: reading)
                    }
                    watching.toggle()
                }
            }
            if watching { w.lookAway(at: reading, wallClock: noon) }
            #expect(abs(w.watched - attended) < 1e-9)
        }
    }

    /// The same sweep, asked the other question: at no point during any
    /// interleaving is the wait over while nobody is watching it.
    @Test func noInterleavingEverFinishesTheWaitWhileParked() {
        var rng = SeededRNG(seed: 0xBEEF)

        for _ in 0..<2000 {
            var w = ask(length: 12)
            var reading: TimeInterval = 0
            var watching = false

            for _ in 0..<40 {
                reading += Double(rng.next() % 60) / 10.0
                if !watching {
                    #expect(w.isOver(at: reading) == w.isOver(at: reading + 10_000))
                }
                if rng.next() % 3 == 0 {
                    if watching {
                        w.lookAway(at: reading, wallClock: noon)
                    } else {
                        w.watch(from: reading)
                    }
                    watching.toggle()
                }
            }
        }
    }
}

/// A tiny reproducible generator, in the spirit of the R1 fuzzer: a seeded run
/// that fails is a run that can be re-run.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The price, met at the two seams it actually arrives through: the clamp that
/// decides how many minutes are being bought, and the tables the product lets a
/// user choose from.
///
/// `AppModel.raiseWait` prices off the minutes she will be GIVEN and not the
/// ones she said, which makes `Validator`'s clamp part of the price. The clamp
/// is tested above and `Wait.length` is tested above; the seam between them was
/// tested nowhere, and it is where a wrong number would actually be charged.
@Suite struct WaitPriceAsTheAppActuallyReachesIt {

    private static let cal = Calendar(identifier: .gregorian)
    private static let midday = cal.date(from: DateComponents(year: 2026, month: 8, day: 8,
                                                              hour: 12))!

    private static func policy(budget: Int, door: Door, cap: Int? = nil) -> PolicyState {
        PolicyState(budgetMinutes: budget,
                    downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                    doors: [door],
                    doorCaps: cap.map { [door.id: $0] } ?? [:])
    }

    /// Three terms decide the number, and the third one is the door's own
    /// ceiling. Sixty asked against a pool of forty and a ceiling of fifteen
    /// buys fifteen — so the wait costs 4.5 seconds, not the 18 the sentence
    /// would price at and not the 12 the pool alone would.
    @Test func theDoorsCeilingPricesTheWaitAndNotTheNumberSheSaid() {
        let door = Door(name: "Reddit")
        let state = Self.policy(budget: 40, door: door, cap: 15)

        let verdict = Validator.validate(.command(.spend(door: door, minutes: 60)),
                                         utterance: "give me sixty minutes of reddit",
                                         state: state, ledger: GrantLedger(), now: Self.midday)
        guard case .grant(_, let granted, _) = verdict else {
            Issue.record("expected a capped grant, got \(verdict)")
            return
        }
        #expect(granted == 15)

        #expect(Wait.length(forMinutes: granted) == 4.5)
        #expect(Wait.length(forMinutes: granted) < Wait.length(forMinutes: 40))   // the pool
        #expect(Wait.length(forMinutes: granted) < Wait.length(forMinutes: 60))   // the sentence
    }

    /// And the end of that slope, which is a real state and not a curiosity: a
    /// ceiling with one minute left under it grants one minute, one minute
    /// prices at 0.3 s, and 0.3 s is under the veil's own rise — so `raiseWait`
    /// answers false and the door opens with no wait at all, off a sentence
    /// asking for sixty.
    @Test func aCeilingWithOneMinuteLeftUnderItOpensWithNoWaitAtAll() {
        let door = Door(name: "Reddit")
        let state = Self.policy(budget: 40, door: door, cap: 20)

        // Nineteen of the twenty already drawn this morning, and EXPIRED: a
        // live grant would restate instead, which is a different verdict and
        // would prove nothing about the price.
        var ledger = GrantLedger()
        let morning = Self.midday.addingTimeInterval(-2 * 3600)
        ledger.record(Grant(door: door, minutes: 19, issuedAt: morning,
                            expiresAt: morning.addingTimeInterval(19 * 60)))

        let verdict = Validator.validate(.command(.spend(door: door, minutes: 60)),
                                         utterance: "give me sixty minutes of reddit",
                                         state: state, ledger: ledger, now: Self.midday)
        guard case .grant(_, let granted, _) = verdict else {
            Issue.record("expected the last minute under the ceiling, got \(verdict)")
            return
        }
        #expect(granted == 1)
        #expect(Wait.length(forMinutes: granted) == 0.3)
        #expect(Wait.isWorthDrawing(Wait.length(forMinutes: granted)) == false)
    }

    /// Every seat the cap wheel offers is on the slope, and none of them is at
    /// the ceiling. This is the property amendment A is about — never the same
    /// cost twice — asserted against the only table the product actually offers,
    /// rather than against the abstract curve.
    ///
    /// It is also the guard on the table: a 90-minute seat would price at 27,
    /// clamp to 20, and sit at the flat top beside anything else above 66 — two
    /// ceilings that cost the same wait, which is the toll the slope exists to
    /// refuse. That change breaks this test rather than shipping quietly.
    @Test func everySeatTheCapWheelOffersIsOnTheSlopeAndNoneAtTheCeiling() {
        for (lower, higher) in zip(Caps.wheelTable, Caps.wheelTable.dropFirst()) {
            #expect(Wait.length(forMinutes: lower) < Wait.length(forMinutes: higher))
        }
        for seat in Caps.wheelTable {
            #expect(Wait.length(forMinutes: seat) < Wait.ceiling)
            #expect(Wait.isWorthDrawing(Wait.length(forMinutes: seat)))
        }
        #expect(Wait.length(forMinutes: Caps.wheelTable.last ?? 0) == 18)
    }

    /// The draw threshold at its own boundary, which only the `-silkWait` seam
    /// can land on: the comparison is `>=`, so a wait priced at exactly the
    /// veil's rise is drawn. No minute count reaches it — 0.3 × m is never 0.4 —
    /// which is why the price table above cannot state it.
    @Test func aWaitPricedAtExactlyTheVeilsRiseIsStillDrawn() {
        #expect(Wait.isWorthDrawing(Wait.tooShortToDraw))
        #expect(Wait.isWorthDrawing(Wait.tooShortToDraw.nextDown) == false)
    }
}

/// Staleness, at the three edges the suite above it does not reach: a window
/// that is not the default, a wall clock that went backwards, and the question
/// of which park the window is measured from.
@Suite struct WaitStalenessAtTheEdgesOfItsWindow {

    private func parked(at wallClock: Date = noon) -> Wait {
        var w = ask()
        w.watch(from: 0)
        w.lookAway(at: 3, wallClock: wallClock)
        return w
    }

    /// `-silkStale <seconds>` pins the window so a walk can prove the drop path
    /// without standing still for two minutes, and `AppModel.waitStaleAfter`
    /// hands whatever it finds straight to `isStale(at:after:)`. Every test
    /// above takes the default, so the parameter itself — and the strictness of
    /// its comparison — went unchecked on the seam the walks actually run on.
    @Test func aPinnedWindowIsHonouredAndItsComparisonIsStrict() {
        let w = parked()

        #expect(w.isStale(at: noon.addingTimeInterval(0.5), after: 0.5) == false)
        #expect(w.isStale(at: noon.addingTimeInterval(0.75), after: 0.5))
        // The default is not consulted when a window is given: the same instant
        // is nowhere near stale against two minutes.
        #expect(w.isStale(at: noon.addingTimeInterval(0.75)) == false)
    }

    /// `-silkWait 0` turns the feature off; `-silkStale 0` does not turn the
    /// window off, it shuts it. `waitStaleAfter` clamps with `max(0, pinned)`,
    /// so zero is reachable, and the strict comparison is the whole reason the
    /// instant of parking is not itself already too late.
    @Test func aWindowOfZeroDropsTheAskOnTheNextInstantAndNotOnTheParkItself() {
        let w = parked()

        #expect(w.isStale(at: noon, after: 0) == false)
        #expect(w.isStale(at: noon.addingTimeInterval(0.001), after: 0))
    }

    /// The accrual clock cannot go backwards; this one can. Staleness is wall
    /// time by design, and wall time moves — Settings, an NTP correction, the
    /// autumn hour that happens twice.
    ///
    /// The direction it fails in is the safe one, and worth writing down rather
    /// than discovering: a clock behind the park cannot age the ask, so an
    /// abandoned wait outlives its window until the clock catches up. Nothing is
    /// debited while it stands and it dies with the process, so the cost is a
    /// veil that lowers late — never a grant that should not have been made.
    @Test func aWallClockThatWentBackwardsCannotAgeTheAsk() {
        let w = parked()

        #expect(w.isStale(at: noon.addingTimeInterval(-3600)) == false)
        #expect(w.isStale(at: noon.addingTimeInterval(-1), after: 0) == false)
        // And it is stale again the moment the clock is past the window.
        #expect(w.isStale(at: noon.addingTimeInterval(Wait.staleAfter + 1)))
    }

    /// The window measures the LAST park, not the first, because `watch` clears
    /// `pausedAt`. Two ninety-second absences with a glance between them put the
    /// ask three minutes from its birth and still not stale — which is §7's rule
    /// ("back within 2 min resumes from exactly where it stopped") applied per
    /// departure, and the widest the trap it closes can really open.
    @Test func theWindowRunsFromTheLastParkAndNotTheFirst() {
        var w = ask()
        w.watch(from: 0)
        w.lookAway(at: 1, wallClock: noon)                          // parked at noon
        #expect(w.isStale(at: noon.addingTimeInterval(90)) == false)

        w.watch(from: 100)                                          // a glance back…
        w.lookAway(at: 101, wallClock: noon.addingTimeInterval(91)) // …and away again

        // 181 seconds since the first park; 90 since this one.
        #expect(w.isStale(at: noon.addingTimeInterval(181)) == false)
        // Measured from the second park, it dies at the same two minutes.
        #expect(w.isStale(at: noon.addingTimeInterval(91 + Wait.staleAfter + 1)))
    }
}

/// The surface draws `fraction` and the model lands on `isOver`, and nothing
/// asserted that the two ever agree. They have to, exactly: a whole mark sitting
/// with nothing happening is the one failure this screen may not have, and a
/// door opening under an unfinished stroke is the other.
@Suite struct WaitTheInkIsWholeExactlyWhenItLands {

    @Test func theyStillAgreeAcrossAPauseAndAResume() {
        var w = ask()
        w.watch(from: 0)
        w.lookAway(at: 3.25, wallClock: noon)

        #expect(abs(w.fraction(at: 9_999) - 0.325) < 1e-12)
        #expect(w.isOver(at: 9_999) == false)

        w.watch(from: 100)
        for reading in stride(from: 100.0, through: 108.0, by: 0.25) {
            #expect(w.isOver(at: reading) == (w.fraction(at: reading) == 1))
        }
        #expect(w.isOver(at: 106.5) == false)           // 3.25 banked + 6.5 = 9.75
        #expect(w.fraction(at: 106.75) == 1)            // 3.25 banked + 6.75 = 10
        #expect(w.isOver(at: 106.75))
    }
}

/// `Wait` is a struct, and two places in `AppModel` depend on it staying one:
/// `pauseWait` and `resumeWait` both take the wait OUT of `waiting`, mutate the
/// copy, and put it back. Under a reference type the mutation would land before
/// the assignment, `Waiting` would compare equal to itself across a pause, and
/// the observation that redraws the mark would never fire — a wait that freezes
/// on screen and lands anyway. None of that is visible from a walk; all of it
/// follows from the two facts below.
@Suite struct WaitIsAValueAndItsChangesAreVisible {

    @Test func twoWaitsThatDifferOnlyInTheirWatchingAreNotEqual() {
        // Synthesized `Equatable` over the stored properties needs no test.
        // What does is that `since` participates: a wait that has
        // just been resumed is not the wait that was parked, and the veil's
        // animation is driven off exactly that difference.
        var resumed = ask(watched: 3)
        resumed.watch(from: 0)
        #expect(resumed != ask(watched: 3))
    }

    @Test func aWaitCannotBeBornOwingTimeItCannotOwe() {
        // Both clamps live in the initialiser and nothing in the app can reach
        // them today — the price floors at zero and the `-silkWait` seam clamps
        // its own input — which is exactly why removing one would go unnoticed.
        let w = Wait(doorID: door, minutes: 20, length: -5, watched: -30)

        #expect(w.length == 0)
        #expect(w.watched == 0)
        #expect(w.fraction(at: 0) == 1)                 // zero length: finished, not undrawable
    }
}
