import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures
//
// The two DST nights, America/New_York 2026: spring forward Mar 8 (2:00 → 3:00,
// a 23-hour night) and fall back Nov 1 (2:00 → 1:00, a 25-hour night). The
// decided semantics (docs/market/gaps.md, "DST and travel"): grant expiries are
// ABSOLUTE instants; down hours are LOCAL WALL-CLOCK. Every test here is one of
// those two rules meeting a night that is not 24 hours long.

private let instagram = Door(name: "Instagram")

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

/// The same window ending 7:00, but starting 4:00 AM — the straddle tests need
/// an ask that is legal at 1:50 AM while the night edge still lies across the
/// transition. The stock 22:00 start would refuse before the clamp could run.
private let smallHours = DownHours(start: TimeOfDay(hour: 4), end: TimeOfDay(hour: 7))

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// Wall clocks inside the transition hours are skipped (spring) or repeated
/// (fall), so `at` cannot name those instants unambiguously. The fixtures
/// anchor at an unambiguous time and add real seconds — the one representation
/// DST cannot bend.
private func seconds(after anchor: Date, _ s: TimeInterval) -> Date {
    anchor.addingTimeInterval(s)
}

private func makeState(budget: Int = 40, downHours: DownHours = night) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: downHours, doors: [instagram])
}

/// The parser is not under test here; the command goes straight to the
/// Validator, with an utterance that carries the number so provenance passes.
private func spend(_ minutes: Int, state: PolicyState, at now: Date) -> Verdict {
    Validator.validate(.command(.spend(door: instagram, minutes: minutes)),
                       utterance: "instagram \(minutes)", state: state,
                       ledger: GrantLedger(), now: now, calendar: cal)
}

// MARK: - The day boundary on the two transition mornings

@Suite struct DSTDayBoundaryTests {
    @Test func bothTransitionMorningsStartAtWallClockSeven() {
        // Down hours are wall-clock by decision: the day starts when the clock
        // face says 7:00, on both mornings, whatever the night did.
        let springStart = DayBoundary.dayStart(now: at(3, 8, 8), downHours: night, calendar: cal)
        let fallStart = DayBoundary.dayStart(now: at(11, 1, 8), downHours: night, calendar: cal)
        #expect(springStart == at(3, 8, 7))
        #expect(fallStart == at(11, 1, 7))
        #expect(cal.component(.hour, from: springStart) == 7)
        #expect(cal.component(.hour, from: fallStart) == 7)
    }

    @Test func theTwoDaysDifferByTwoHoursInAbsoluteTerms() {
        // Boundary to boundary: 23 real hours across spring forward, 25 across
        // fall back. `nextDayStart` adds a calendar day, not 86 400 seconds,
        // which is exactly what makes both come out at wall-clock 7:00.
        #expect(at(3, 8, 7).timeIntervalSince(at(3, 7, 7)) == 23 * 3600)
        #expect(at(11, 1, 7).timeIntervalSince(at(10, 31, 7)) == 25 * 3600)
        #expect(DayBoundary.nextDayStart(after: at(3, 7, 7), calendar: cal) == at(3, 8, 7))
        #expect(DayBoundary.nextDayStart(after: at(10, 31, 7), calendar: cal) == at(11, 1, 7))
    }

    @Test func theSmallHoursOfBothNightsBelongToThePreviousSilkDay() {
        // 1:30 EST on spring-forward night is yesterday's Silk day; on
        // fall-back night 1:30 happens twice, and BOTH instants resolve to the
        // Oct 31 boundary — the budget does not refill mid-repeat.
        let springSmall = seconds(after: at(3, 8, 1), 30 * 60)          // 1:30 EST
        let firstOneThirty = seconds(after: at(11, 1, 0), 90 * 60)      // 1:30 EDT
        let secondOneThirty = seconds(after: firstOneThirty, 3600)      // 1:30 EST
        #expect(DayBoundary.dayStart(now: springSmall, downHours: night, calendar: cal) == at(3, 7, 7))
        #expect(DayBoundary.dayStart(now: firstOneThirty, downHours: night, calendar: cal) == at(10, 31, 7))
        #expect(DayBoundary.dayStart(now: secondOneThirty, downHours: night, calendar: cal) == at(10, 31, 7))
    }
}

// MARK: - The night-edge clamp on the two transition evenings

@Suite struct DSTNightEdgeClampTests {
    @Test func springForwardEveClampLandsOnWallClockTen() {
        // Mar 7, 21:50, ask 30: re-lock at wall-clock 22:00, ten real minutes
        // debited. The 23-hour night ahead changes neither number.
        let now = at(3, 7, 21, 50)
        guard case .grant(_, let minutes, let relock) = spend(30, state: makeState(), at: now) else {
            Issue.record("expected clamped grant")
            return
        }
        #expect(minutes == 10)
        #expect(relock == at(3, 7, 22))
        #expect(relock.timeIntervalSince(now) == 10 * 60)
    }

    @Test func fallBackEveClampLandsOnWallClockTen() {
        // Oct 31, 21:50, ask 30: same clamp, same ten minutes, 25-hour night
        // notwithstanding. The debit is what she can actually spend.
        let now = at(10, 31, 21, 50)
        guard case .grant(_, let minutes, let relock) = spend(30, state: makeState(), at: now) else {
            Issue.record("expected clamped grant")
            return
        }
        #expect(minutes == 10)
        #expect(relock == at(10, 31, 22))
        #expect(relock.timeIntervalSince(now) == 10 * 60)
    }

    @Test func clampAcrossSpringForwardDebitsTheRealIntervalNotTheWallDifference() {
        // 1:50 EST, ask 200 against the 4:00 AM edge. The wall clock says the
        // gap is 130 minutes; the night skips an hour, so it is really 70.
        // Debiting the wall difference would charge her for the missing hour.
        let now = seconds(after: at(3, 8, 1), 50 * 60)   // 1:50 EST
        guard case .grant(_, let minutes, let relock) =
                spend(200, state: makeState(budget: 240, downHours: smallHours), at: now) else {
            Issue.record("expected clamped grant")
            return
        }
        #expect(relock == at(3, 8, 4))
        #expect(minutes == 70)
        #expect(relock.timeIntervalSince(now) == 70 * 60)
    }

    @Test func clampAcrossFallBackDebitsTheRealIntervalNotTheWallDifference() {
        // The mirror: 1:50 EDT, ask 200 against the 4:00 AM edge. The wall
        // says 130 minutes; the hour repeats, so the door is really open 190
        // — and 190 is what the budget must record as spent.
        let now = seconds(after: at(11, 1, 0), 110 * 60)   // 1:50 EDT, first pass
        guard case .grant(_, let minutes, let relock) =
                spend(200, state: makeState(budget: 240, downHours: smallHours), at: now) else {
            Issue.record("expected clamped grant")
            return
        }
        #expect(relock == at(11, 1, 4))
        #expect(minutes == 190)
        #expect(relock.timeIntervalSince(now) == 190 * 60)
    }
}

// MARK: - A grant straddling the transition itself

@Suite struct DSTStraddlingGrantTests {
    @Test func aGrantAcrossSpringForwardRunsExactlyTheAskedMinutes() {
        // Asked at 1:50 EST for 20: the expiry is absolute, so the door shuts
        // 20 real minutes later even though the wall reads 3:10 — an hour and
        // twenty later by the clock face.
        let now = seconds(after: at(3, 8, 1), 50 * 60)   // 1:50 EST
        guard case .grant(_, let minutes, let relock) =
                spend(20, state: makeState(downHours: smallHours), at: now) else {
            Issue.record("expected grant")
            return
        }
        #expect(minutes == 20)
        #expect(relock.timeIntervalSince(now) == 20 * 60)
        let c = cal.dateComponents([.hour, .minute], from: relock)
        #expect(c.hour == 3 && c.minute == 10)

        var ledger = GrantLedger()
        ledger.record(Grant(door: instagram, minutes: minutes, issuedAt: now, expiresAt: relock))
        #expect(ledger.openDoors(at: seconds(after: now, 19 * 60), dayStart: at(3, 7, 7)) == [instagram.id])
        #expect(ledger.openDoors(at: relock, dayStart: at(3, 7, 7)).isEmpty)
    }

    @Test func aGrantAcrossFallBackRunsExactlyTheAskedMinutes() {
        // Asked at the first 1:50 (EDT) for 20: the door shuts 20 real minutes
        // later, at the second 1:10 (EST). The wall clock reads EARLIER than
        // the ask; the absolute expiry does not care, and neither does the wall
        // — open through minute 19, gone at the instant.
        let now = seconds(after: at(11, 1, 0), 110 * 60)   // 1:50 EDT, first pass
        guard case .grant(_, let minutes, let relock) =
                spend(20, state: makeState(downHours: smallHours), at: now) else {
            Issue.record("expected grant")
            return
        }
        #expect(minutes == 20)
        #expect(relock.timeIntervalSince(now) == 20 * 60)
        let c = cal.dateComponents([.hour, .minute], from: relock)
        #expect(c.hour == 1 && c.minute == 10)   // the hour repeats; the expiry does not

        var ledger = GrantLedger()
        ledger.record(Grant(door: instagram, minutes: minutes, issuedAt: now, expiresAt: relock))
        #expect(ledger.openDoors(at: seconds(after: now, 19 * 60), dayStart: at(10, 31, 7)) == [instagram.id])
        #expect(ledger.openDoors(at: relock, dayStart: at(10, 31, 7)).isEmpty)
    }
}

// MARK: - Containment at the skipped and repeated wall-clock hours

@Suite struct DSTContainmentTests {
    @Test func twoThirtyNeverHappensOnSpringForwardNightAndTheWindowNeverOpens() {
        // No instant on Mar 8 reads 2:30. The window holds across the gap: the
        // last EST instant reads 1:59 and refuses, the first EDT instant reads
        // 3:00 and refuses, and TimeOfDay(2:30) itself sits inside the window
        // — so a clock that somehow reported it would refuse too.
        let lastEST = seconds(after: at(3, 8, 1), 3599)    // 1:59:59 EST
        let firstEDT = seconds(after: at(3, 8, 1), 3600)   // 3:00:00 EDT
        #expect(Validator.timeOfDay(lastEST, calendar: cal) == TimeOfDay(hour: 1, minute: 59))
        #expect(Validator.timeOfDay(firstEDT, calendar: cal) == TimeOfDay(hour: 3))
        #expect(night.contains(TimeOfDay(hour: 2, minute: 30)))
        #expect(spend(10, state: makeState(), at: lastEST) == .refuseDownHours(until: TimeOfDay(hour: 7)))
        #expect(spend(10, state: makeState(), at: firstEDT) == .refuseDownHours(until: TimeOfDay(hour: 7)))
    }

    @Test func oneThirtyHappensTwiceOnFallBackNightAndIsDownBothTimes() {
        // Wall-clock semantics, taken whole: both instants that read 1:30 fall
        // inside the window, so the repeated hour is down twice over and the
        // night runs 25 absolute hours. That is the decision, not a defect.
        let first = seconds(after: at(11, 1, 0), 90 * 60)   // 1:30 EDT
        let second = seconds(after: first, 3600)            // 1:30 EST
        #expect(second.timeIntervalSince(first) == 3600)
        #expect(Validator.timeOfDay(first, calendar: cal) == TimeOfDay(hour: 1, minute: 30))
        #expect(Validator.timeOfDay(second, calendar: cal) == TimeOfDay(hour: 1, minute: 30))
        #expect(night.contains(TimeOfDay(hour: 1, minute: 30)))
        #expect(spend(10, state: makeState(), at: first) == .refuseDownHours(until: TimeOfDay(hour: 7)))
        #expect(spend(10, state: makeState(), at: second) == .refuseDownHours(until: TimeOfDay(hour: 7)))
    }
}
