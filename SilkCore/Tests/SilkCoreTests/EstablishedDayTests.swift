import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures
//
// The mid-day boundary move. "Down hours end at 9am" said at 8:00 is a longer
// night, a tighten, and lands instantly — and `DayBoundary.dayStart` recomputes
// from live policy on every read, so at 9:01 the day the user was standing in
// suddenly claims to have started at 9:00. Every grant issued between the two
// hours fell out of the spend windows (the pool and every exhausted cap
// refilled the same calendar day) and a hand close stopped binding. The seam
// that ends it is `GrantLedger.effectiveDayStart` over the `dayBegan` stamp the
// boundary sweeps maintain; everything below pins it through verdicts.

private let tightenedNight = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 9))

/// August 2026 — deep inside daylight time, so no DST edge rides along.
private func establishedAt(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
}

private func state(_ downHours: DownHours, budget: Int = 40,
                   caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: downHours,
                doors: [tiktok, instagram], doorCaps: caps)
}

private func validate(_ text: String, state: PolicyState, ledger: GrantLedger,
                      at now: Date) -> Verdict {
    Validator.validate(DeterministicParser.parse(text, state: state), utterance: text,
                       state: state, ledger: ledger, now: now, calendar: cal)
}

// MARK: - The day keeps the start it opened with

@Suite struct EstablishedDayTests {

    /// The move itself is a tighten and lands instantly — the premise the rest
    /// of the suite stands on.
    @Test func theMoveItselfLandsInstantlyAsATighten() {
        guard case .ruleChange(let proposed, let polarity) =
                validate("down hours end at 9am", state: state(night),
                         ledger: GrantLedger(), at: establishedAt(5, 8)) else {
            Issue.record("the boundary move must parse and validate")
            return
        }
        #expect(polarity == .tighten)
        #expect(proposed.downHours == tightenedNight)
    }

    /// TikTok's ceiling, spent at 7:30, stays spent at 9:30 — the live
    /// boundary's claim that a fresh day began at 9:00 does not refill it.
    @Test func capStaysExhaustedWhenTheBoundaryMovesMidDay() {
        let old = state(night, caps: [tiktok.id: 10])
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        guard case .grant(let door, let minutes, let relock) =
                validate("give me 10 minutes of tiktok", state: old,
                         ledger: ledger, at: establishedAt(5, 7, 30)) else {
            Issue.record("the morning ask must grant")
            return
        }
        #expect(minutes == 10)
        ledger.record(Grant(door: door, minutes: minutes,
                            issuedAt: establishedAt(5, 7, 30), expiresAt: relock))

        let moved = state(tightenedNight, caps: [tiktok.id: 10])
        #expect(validate("give me 10 minutes of tiktok", state: moved,
                         ledger: ledger, at: establishedAt(5, 9, 30))
                == .refuseDoorClosed(door: tiktok, until: establishedAt(6, 7)),
                "a tighten refilled the ceiling it had no business touching")
    }

    /// The shared pool, drained before the move, stays drained after it.
    @Test func poolStaysSpentWhenTheBoundaryMovesMidDay() {
        let old = state(night)
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        guard case .grant(let door, let minutes, let relock) =
                validate("give me 40 minutes of tiktok", state: old,
                         ledger: ledger, at: establishedAt(5, 7, 30)) else {
            Issue.record("the morning ask must grant")
            return
        }
        #expect(minutes == 40)
        ledger.record(Grant(door: door, minutes: minutes,
                            issuedAt: establishedAt(5, 7, 30), expiresAt: relock))

        let moved = state(tightenedNight)
        #expect(validate("give me 10 minutes of instagram", state: moved,
                         ledger: ledger, at: establishedAt(5, 9, 30))
                == .refuseNothingLeft,
                "a tighten refilled the pool it had no business touching")
    }

    /// A door closed by hand at 7:45 is still closed at 9:30, and the refusal
    /// still quotes the established day's end — not a lift the move invented.
    @Test func handCloseStaysBindingWhenTheBoundaryMovesMidDay() {
        let old = state(night)
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        guard case .close(let door, let until) =
                validate("close instagram", state: old, ledger: ledger,
                         at: establishedAt(5, 7, 45)) else {
            Issue.record("the close must land")
            return
        }
        #expect(until == establishedAt(6, 7), "a plain close runs to the established day's end")
        ledger.closeDoor(door, at: establishedAt(5, 7, 45))

        let moved = state(tightenedNight)
        #expect(validate("give me 10 minutes of instagram", state: moved,
                         ledger: ledger, at: establishedAt(5, 9, 30))
                == .refuseDoorClosed(door: instagram, until: establishedAt(6, 7)),
                "the boundary move lifted a close made by hand")
    }

    /// The tighten does take effect — tomorrow. The morning it buys holds
    /// until nine, and the next real day starts at the NEW hour with the
    /// ceiling honestly refilled.
    @Test func theNextRealDayStartsAtTheNewHour() {
        let moved = state(tightenedNight, caps: [tiktok.id: 10])
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        ledger.record(Grant(door: tiktok, minutes: 10,
                            issuedAt: establishedAt(5, 7, 30),
                            expiresAt: establishedAt(5, 7, 40)))

        #expect(validate("give me 10 minutes of tiktok", state: moved,
                         ledger: ledger, at: establishedAt(6, 8, 30))
                == .refuseDownHours(until: TimeOfDay(hour: 9)),
                "the lengthened night holds its own morning")
        guard case .grant(_, let minutes, _) =
                validate("give me 10 minutes of tiktok", state: moved,
                         ledger: ledger, at: establishedAt(6, 9, 30)) else {
            Issue.record("the new day must refill the ceiling")
            return
        }
        #expect(minutes == 10)
    }

    /// An honest midnight rollover never waits for a sweep: the stamp goes
    /// stale the instant the established day ends, and the live boundary
    /// refills the pool exactly as it always has.
    @Test func anOrdinaryRolloverRefillsWithoutASweep() {
        let old = state(night)
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        ledger.record(Grant(door: tiktok, minutes: 40,
                            issuedAt: establishedAt(5, 10), expiresAt: establishedAt(5, 10, 40)))

        guard case .grant(_, let minutes, _) =
                validate("give me 10 minutes of tiktok", state: old,
                         ledger: ledger, at: establishedAt(6, 7, 30)) else {
            Issue.record("yesterday's spend must not reach into today")
            return
        }
        #expect(minutes == 10)
    }

    /// A grant minted under a transiently-forward clock still spends only the
    /// day it claims — the established window keeps the far edge that clips it.
    @Test func aPhantomGrantStillSpendsOnlyTheDayItClaims() {
        let moved = state(tightenedNight, caps: [tiktok.id: 10])
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        ledger.record(Grant(door: tiktok, minutes: 10,
                            issuedAt: establishedAt(8, 10), expiresAt: establishedAt(8, 10, 10)))

        guard case .grant(_, let minutes, _) =
                validate("give me 10 minutes of tiktok", state: moved,
                         ledger: ledger, at: establishedAt(5, 9, 30)) else {
            Issue.record("a phantom three days out must not spend the standing day")
            return
        }
        #expect(minutes == 10)
    }
}

// MARK: - The stamp's own discipline

@Suite struct EstablishDayStampTests {

    @Test func theStampAdvancesOnlyAcrossARealTurn() {
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        // A boundary that moved mid-day does not move the stamp…
        ledger.establishDay(startingAt: establishedAt(5, 9), calendar: cal)
        #expect(ledger.dayBegan == establishedAt(5, 7))
        // …and the next real turn does, at the NEW hour.
        ledger.establishDay(startingAt: establishedAt(6, 9), calendar: cal)
        #expect(ledger.dayBegan == establishedAt(6, 9))
    }

    @Test func aFabricatedFutureStampHealsItself() {
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(20, 7), calendar: cal)   // clock was forward
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)    // the corrected sweep
        #expect(ledger.dayBegan == establishedAt(5, 7))
    }

    @Test func anUnstampedLedgerReadsTheLiveBoundary() {
        let ledger = GrantLedger()
        #expect(ledger.effectiveDayStart(now: establishedAt(5, 12), downHours: night, calendar: cal)
                == DayBoundary.dayStart(now: establishedAt(5, 12), downHours: night, calendar: cal))
    }

    @Test func theStampHoldsItsOwnDayAndYieldsPastIt() {
        var ledger = GrantLedger()
        ledger.establishDay(startingAt: establishedAt(5, 7), calendar: cal)
        #expect(ledger.effectiveDayStart(now: establishedAt(5, 9, 30), downHours: tightenedNight,
                                         calendar: cal)
                == establishedAt(5, 7), "the standing day keeps the start it opened with")
        #expect(ledger.effectiveDayStart(now: establishedAt(6, 9, 30), downHours: tightenedNight,
                                         calendar: cal)
                == establishedAt(6, 9), "the next real day starts at the new hour")
    }
}
