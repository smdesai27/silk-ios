import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures
//
// Six call sites dropped the injected calendar at the day window's far edge —
// `Validator.validate`'s pool and ceiling reads, both legs of
// `askableMinutes`, `state(of:)`'s cap branch, and `Caps.receipt` (which then
// USED the passed calendar two lines later: one function, two calendars). The
// far edge is `DayBoundary.nextDayStart`, a *calendar* day ahead, so the drop
// is invisible until the injected calendar and the machine's disagree on how
// long a day is — which is exactly what a DST night is for.
//
// The pin is a pair: New York's fall-back day (31 Oct 2026 07:00 EDT →
// 1 Nov 07:00 EST, 25 hours) against a frozen UTC−4 twin (24 hours, no
// fall-back ever). The two calendars agree on the same absolute day START and
// disagree on where it ENDS, and a grant seeded between the two edges is
// inside one day and outside the other. Whatever zone the machine itself
// runs in, its one `Calendar.current` answer cannot satisfy both halves of
// any test below — so the suite is hermetic: it fails unless the INJECTED
// calendar governs the far edge.

private var newYork: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private var frozenEDT: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
    return c
}

/// A zero-length night — down hours that block nothing. The approach to the
/// far edge is always the last stretch before down hours end, so any real
/// night would refuse the ask before the windowing this suite pins could run.
private let noNight = DownHours(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 7))

/// 31 Oct 2026 07:00 EDT — the same instant in both calendars, because EDT is
/// UTC−4 until that night's fall-back.
private let dayStart: Date =
    newYork.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7))!

/// Inside the 25-hour New York day, past the frozen twin's 24-hour edge —
/// reachable only by a phantom, which is exactly what makes the far edge
/// observable at all: nothing honest is ever issued past `now`.
private let betweenTheEdges = dayStart.addingTimeInterval((24 * 60 + 40) * 60)
/// Where the asks land: ten minutes short of the frozen edge and seventy
/// short of New York's, so BOTH calendars still derive the same `dayStart`
/// for `now` inside `validate` and only the far edge divides them.
private let now = dayStart.addingTimeInterval((23 * 60 + 50) * 60)

private func state(budget: Int, caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: noNight,
                doors: [tiktok], doorCaps: caps)
}

/// A grant seeded between the two far edges — 24 h 40 m after the day began.
private func edgeLedger(minutes: Int) -> GrantLedger {
    var l = GrantLedger()
    l.record(Grant(door: tiktok, minutes: minutes, issuedAt: betweenTheEdges,
                   expiresAt: betweenTheEdges.addingTimeInterval(TimeInterval(minutes * 60))))
    return l
}

private func validate(_ text: String, state: PolicyState, ledger: GrantLedger,
                      calendar: Calendar) -> Verdict {
    Validator.validate(DeterministicParser.parse(text, state: state), utterance: text,
                       state: state, ledger: ledger, now: now, calendar: calendar)
}

// MARK: - The pin

@Suite struct CalendarFarEdgeTests {

    /// The two calendars really do disagree by exactly the repeated hour, and
    /// agree on the start — the geometry every other test here leans on.
    @Test func theFallBackDayIsTwentyFiveHoursLong() {
        #expect(DayBoundary.nextDayStart(after: dayStart, calendar: newYork)
                == dayStart.addingTimeInterval(25 * 3600))
        #expect(DayBoundary.nextDayStart(after: dayStart, calendar: frozenEDT)
                == dayStart.addingTimeInterval(24 * 3600))
        #expect(DayBoundary.dayStart(now: now, downHours: noNight, calendar: newYork)
                == dayStart)
        #expect(DayBoundary.dayStart(now: now, downHours: noNight, calendar: frozenEDT)
                == dayStart)
    }

    /// The pool's window (validate's own remaining read).
    @Test func validateWindowsThePoolOnTheInjectedCalendar() {
        let s = state(budget: 30)
        let ledger = edgeLedger(minutes: 30)
        #expect(validate("give me 5 minutes of tiktok", state: s, ledger: ledger,
                         calendar: newYork)
                == .refuseNothingLeft,
                "inside the 25-hour day the pool is spent")
        guard case .grant(_, let minutes, _) =
                validate("give me 5 minutes of tiktok", state: s, ledger: ledger,
                         calendar: frozenEDT) else {
            Issue.record("past the frozen edge the pool is whole again")
            return
        }
        #expect(minutes == 5)
    }

    /// The ceiling's window (validate's doorRemaining read).
    @Test func validateWindowsTheCeilingOnTheInjectedCalendar() {
        let s = state(budget: 40, caps: [tiktok.id: 10])
        let ledger = edgeLedger(minutes: 10)
        #expect(validate("give me 5 minutes of tiktok", state: s, ledger: ledger,
                         calendar: newYork)
                == .refuseDoorClosed(door: tiktok,
                                     until: DayBoundary.nextDayStart(after: dayStart,
                                                                     calendar: newYork)),
                "inside the 25-hour day the ceiling is spent")
        guard case .grant(_, let minutes, _) =
                validate("give me 5 minutes of tiktok", state: s, ledger: ledger,
                         calendar: frozenEDT) else {
            Issue.record("past the frozen edge the ceiling is whole again")
            return
        }
        #expect(minutes == 5)
    }

    /// Both of `askableMinutes`' ledger reads.
    @Test func askableMinutesWindowsOnTheInjectedCalendar() {
        let s = state(budget: 30, caps: [tiktok.id: 20])
        let ledger = edgeLedger(minutes: 20)
        #expect(Validator.askableMinutes(door: tiktok, state: s, ledger: ledger,
                                         now: now, dayStart: dayStart, calendar: newYork)
                == 0, "pool 10, ceiling 0 — the wall promises nothing")
        // Under the frozen calendar the ceiling is whole, and the zero-length
        // night's own edge (07:00, ten minutes out) is what clamps.
        #expect(Validator.askableMinutes(door: tiktok, state: s, ledger: ledger,
                                         now: now, dayStart: dayStart, calendar: frozenEDT)
                == 10)
    }

    /// The row's cap branch in `state(of:)`.
    @Test func theRowWindowsOnTheInjectedCalendar() {
        let ledger = edgeLedger(minutes: 20)
        #expect(ledger.state(of: tiktok, at: now, dayStart: dayStart, cap: 20,
                             calendar: newYork)
                == .rest(until: nil), "the ceiling is spent — the resting costume")
        #expect(ledger.state(of: tiktok, at: now, dayStart: dayStart, cap: 20,
                             calendar: frozenEDT)
                == .live)
    }

    /// The receipt — the function that already used its calendar two lines
    /// below the read that dropped it.
    @Test func theReceiptWindowsOnTheInjectedCalendar() {
        let previous = state(budget: 40)
        let proposed = state(budget: 40, caps: [tiktok.id: 20])
        let ledger = edgeLedger(minutes: 20)
        #expect(Caps.receipt(for: proposed, movedFrom: previous, ledger: ledger,
                             now: now, dayStart: dayStart, calendar: newYork)
                == "TikTok \(SilkStrings.closedUntil) 7:00.",
                "the new ceiling has already bitten inside the 25-hour day")
        #expect(Caps.receipt(for: proposed, movedFrom: previous, ledger: ledger,
                             now: now, dayStart: dayStart, calendar: frozenEDT)
                == "TikTok 20 \(SilkStrings.minutes) \u{00B7} \(SilkStrings.perDay).")
    }
}
