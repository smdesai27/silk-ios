import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private func dayStart(_ now: Date) -> Date {
    DayBoundary.dayStart(now: now, downHours: night, calendar: cal)
}

private func grant(_ door: Door, from: Date, to: Date) -> Grant {
    Grant(door: door, minutes: Int(to.timeIntervalSince(from) / 60), issuedAt: from, expiresAt: to)
}

// MARK: - open: the grant, and the instant it stops being one

@Suite struct DoorOpenStateTests {
    @Test func activeGrantMakesTheDoorOpen() {
        let now = at(7, 29, 16, 22)
        let expiry = at(7, 29, 16, 52)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: now, to: expiry))

        #expect(ledger.activeGrant(for: instagram, at: now)?.expiresAt == expiry)
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal)
                == .open(until: expiry))
    }

    @Test func expiryIsExclusive() {
        // Fail-closed: at the expiry instant the grant is already gone. A door
        // may hang shut a moment early, never open a moment late.
        let issued = at(7, 29, 16, 22)
        let expiry = at(7, 29, 16, 52)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: issued, to: expiry))

        let justBefore = expiry.addingTimeInterval(-1)
        #expect(ledger.state(of: instagram, at: justBefore, dayStart: dayStart(justBefore), cap: nil, calendar: cal)
                == .open(until: expiry))
        #expect(ledger.activeGrant(for: instagram, at: expiry) == nil)
        #expect(ledger.state(of: instagram, at: expiry, dayStart: dayStart(expiry), cap: nil, calendar: cal) == .live)
    }

    @Test func overlappingGrantsReportTheLastExpiry() {
        // Two grants on one door: the row must say when the door actually shuts.
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 10)))
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 25)))
        #expect(ledger.activeGrant(for: instagram, at: now)?.expiresAt == at(7, 29, 15, 25))
    }

    @Test func undoingTheLaterGrantLeavesTheEarlierOneHoldingTheDoor() {
        // The rule `AppModel.restateRelockLayers` reads, and the reason it
        // takes a door instead of an instant. A second ask EXTENDS a running
        // door rather than replacing it, so taking the newer grant back is not
        // the same as closing the door: the earlier one is still live, the wall
        // still holds the door open, and the re-lock layers — keyed by door,
        // not by grant — have to be re-stated to what remains rather than
        // cleared. Cleared, the door had nothing left to shut it.
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 10)))
        let later = grant(instagram, from: now, to: at(7, 29, 15, 25))
        ledger.record(later)

        ledger.removeGrant(id: later.id)

        #expect(ledger.activeGrant(for: instagram, at: now)?.expiresAt == at(7, 29, 15, 10))
        #expect(ledger.openDoors(at: now, dayStart: dayStart(now)) == [instagram.id])
    }

    @Test func anotherDoorsGrantIsNotThisDoorsGrant() {
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 20)))
        #expect(ledger.activeGrant(for: youtube, at: now) == nil)
        #expect(ledger.state(of: youtube, at: now, dayStart: dayStart(now), cap: nil, calendar: cal) == .live)
    }
}

// MARK: - rest: a door shut for the day lifts at the next boundary, never midnight

@Suite struct DoorShutStateTests {
    @Test func closedTodayLiftsAtTheNextDayStart() {
        // A plain close carries no stated hour into the state: the row shows
        // just the name, and the lift is the day boundary by construction.
        let closedAt = at(7, 29, 14)
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt)
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal)
                == .rest(until: nil))
        #expect(ledger.state(of: instagram, at: at(7, 30, 8), dayStart: dayStart(at(7, 30, 8)), cap: nil, calendar: cal)
                == .live)
    }

    @Test func acrossMidnightTheRuleStillLiftsAtSevenAM() {
        // 23:30 belongs to the day that began at 07:00 the same morning, so the
        // rule lifts at 07:00 tomorrow — not at midnight, ninety minutes away.
        let closedAt = at(7, 29, 21)
        let lateNight = at(7, 29, 23, 30)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt)
        #expect(ledger.state(of: instagram, at: lateNight, dayStart: dayStart(lateNight), cap: nil, calendar: cal)
                == .rest(until: nil))

        // 03:00 is still that same Silk day: same close, same rest.
        let afterMidnight = at(7, 30, 3)
        #expect(dayStart(afterMidnight) == at(7, 29, 7))
        #expect(ledger.state(of: instagram, at: afterMidnight, dayStart: dayStart(afterMidnight), cap: nil, calendar: cal)
                == .rest(until: nil))
    }

    @Test func aStatedHourCloseLiftsAtThatHourNotTheBoundary() {
        // "block instagram until 9" at 15:00 — the row reads "· till 9:00",
        // and at 9 the door is back in play, hours before the day boundary.
        let closedAt = at(7, 29, 15)
        let lift = at(7, 29, 21)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt, until: lift)
        #expect(ledger.state(of: instagram, at: at(7, 29, 16), dayStart: dayStart(at(7, 29, 16)), cap: nil, calendar: cal)
                == .rest(until: lift))
        #expect(DoorState.rest(until: lift).displayTime(calendar: cal) == "· till 9:00")
        #expect(ledger.state(of: instagram, at: at(7, 29, 21, 5), dayStart: dayStart(at(7, 29, 21, 5)), cap: nil, calendar: cal)
                == .live)
    }

    @Test func yesterdaysCloseIsSpent() {
        let closedAt = at(7, 28, 20)
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt)
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal) == .live)
    }

    @Test func theNextDayStartIsACalendarDayNotEightySixFourHundredSeconds() {
        // Spring forward, 2026-03-08: 07:00 to 07:00 is 23 hours. Adding seconds
        // would lift the rule at 06:00 and open the door an hour early.
        let start = at(3, 7, 7)
        let next = DayBoundary.nextDayStart(after: start, calendar: cal)
        #expect(cal.component(.day, from: next) == 8)
        #expect(cal.component(.hour, from: next) == 7)
        #expect(next.timeIntervalSince(start) == 23 * 3600)
    }
}

// MARK: - what each state renders

@Suite struct DoorDisplayTests {
    @Test func inPlaySaysNothing() {
        // A door behind the wall but askable has no time to state. Silk has one
        // shared budget, so there is no per-door window to name.
        let now = at(7, 29, 15)
        #expect(GrantLedger().state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal) == .live)
        #expect(DoorState.live.displayTime(calendar: cal) == nil)
    }

    @Test func aGrantAnswersInTheDeadlineItExpiresAt() {
        // "· till 4:52" — the duration was spoken once, in the reply; the row
        // holds the deadline forever after. Deadlines, not countdowns; nothing
        // ticks.
        #expect(DoorState.open(until: at(7, 29, 16, 52)).displayTime(calendar: cal) == "· till 4:52")
        #expect(DoorState.open(until: at(7, 29, 18, 7)).displayTime(calendar: cal) == "· till 6:07")
    }

    @Test func aShutDoorStatesItsStatedHourAndOnlyThat() {
        // "· till 9:00" — lowercase, following the separator
        // (Silk Mockup.dc.html:330). A plain close says nothing: the resting
        // costume is the whole message (README.md:90-91).
        #expect(DoorState.rest(until: at(7, 29, 21)).displayTime(calendar: cal) == "· till 9:00")
        #expect(DoorState.rest(until: nil).displayTime(calendar: cal) == nil)
    }
}

// MARK: - The meridiem-bearing formatter

@Suite struct MeridiemTests {
    @Test func noonAndMidnight() {
        #expect(TimeOfDay(hour: 12).displayWithMeridiem == "12:00\u{00A0}PM")
        #expect(TimeOfDay(hour: 0).displayWithMeridiem == "12:00\u{00A0}AM")
        #expect(TimeOfDay(hour: 12, minute: 30).displayWithMeridiem == "12:30\u{00A0}PM")
        #expect(TimeOfDay(hour: 0, minute: 5).displayWithMeridiem == "12:05\u{00A0}AM")
    }

    @Test func singleDigitHours() {
        // No leading zero on the hour, and 9:30 in the morning is not the evening.
        #expect(TimeOfDay(hour: 7).displayWithMeridiem == "7:00\u{00A0}AM")
        #expect(TimeOfDay(hour: 9, minute: 30).displayWithMeridiem == "9:30\u{00A0}AM")
        #expect(TimeOfDay(hour: 21, minute: 30).displayWithMeridiem == "9:30\u{00A0}PM")
        #expect(TimeOfDay(hour: 22).displayWithMeridiem == "10:00\u{00A0}PM")
    }

    @Test func displayItselfIsUntouched() {
        // The row and the closed-door sentence carry the context themselves;
        // a meridiem there would be noise. The intent's down-hours refusal
        // does not — see `TimeOfDayMeridiemTests`.
        #expect(TimeOfDay(hour: 7).display == "7:00")
        #expect(TimeOfDay(hour: 22).display == "10:00")
    }

    @Test func apertureWindow() {
        #expect(night.apertureText == "☾\u{00A0} 10:00\u{00A0}PM \u{2013} 7:00\u{00A0}AM")
    }
}

// MARK: - the cap only decides WHICH state, and never adds a fourth

/// Proposal (F) — `.live(remaining:)` and a "· 20 min" on the row — is rejected
/// outright, and these are what hold it out. The row's serif slot is a deadline
/// slot ("Silk answers in deadlines, not countdowns"), a remaining cap is a
/// countdown driven by the user's own hand, and `.live` is the boldest costume
/// on Now — the last thing a door that refuses every ask should be wearing.
/// So the cap picks the state and changes nothing else.
@Suite struct DoorCapStateTests {
    /// A grant already over by the time under test: it moves the door's spend
    /// without being the live grant the first branch would answer.
    private func spent(_ door: Door, _ minutes: Int, before now: Date) -> Grant {
        let end = now.addingTimeInterval(-600)
        return Grant(door: door, minutes: minutes,
                     issuedAt: end.addingTimeInterval(Double(-minutes) * 60), expiresAt: end)
    }

    @Test func aCapExhaustedDoorRests() {
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(spent(instagram, 20, before: now))
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: 20, calendar: cal)
                == .rest(until: nil))
    }

    /// A running grant outranks every rule, cap included: the wall really is
    /// open, and the row must not claim otherwise.
    @Test func aCapExhaustedDoorWithALiveGrantIsStillOpen() {
        let now = at(7, 29, 15)
        let expiry = at(7, 29, 15, 10)
        var ledger = GrantLedger()
        ledger.record(spent(instagram, 20, before: now))
        ledger.record(grant(instagram, from: now.addingTimeInterval(-300), to: expiry))
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: 20, calendar: cal)
                == .open(until: expiry))
    }

    /// The reason the cap branch sits BEFORE `isClosed`. A door closed until
    /// 3:00 and also capped out has no lift today, and promising 3:00 would be
    /// a three-hour lie.
    @Test func aCapExhaustedAndClosedDoorStatesNoLift() {
        let now = at(7, 29, 12)
        let lift = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(spent(instagram, 20, before: now))
        ledger.closeDoor(instagram, at: at(7, 29, 11), until: lift)
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: 20, calendar: cal)
                == .rest(until: nil))
        // Uncapped, the same ledger states the hour it lifts — so it really is
        // the cap speaking, and not the close losing its hour.
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal)
                == .rest(until: lift))
    }

    /// `cap: nil` reproduces every state the enum had before caps existed.
    @Test func anUncappedDoorIsUnaffected() {
        let now = at(7, 29, 15)
        let expiry = at(7, 29, 15, 20)
        var ledger = GrantLedger()
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal) == .live)
        ledger.record(spent(instagram, 200, before: now))
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal) == .live,
                "no ceiling is no ceiling, however much the door has drawn")
        ledger.record(grant(instagram, from: now.addingTimeInterval(-60), to: expiry))
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal)
                == .open(until: expiry))
        var closed = GrantLedger()
        closed.closeDoor(instagram, at: at(7, 29, 14))
        #expect(closed.state(of: instagram, at: now, dayStart: dayStart(now), cap: nil, calendar: cal)
                == .rest(until: nil))
    }

    @Test func aCapNotYetSpentLeavesTheDoorInPlay() {
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(spent(instagram, 5, before: now))
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: 20, calendar: cal) == .live)
    }

    /// Nothing new reaches the serif slot. `.live` still renders nil, and a
    /// cap-exhausted door renders the plain rest — the costume is the message.
    @Test func displayTimeIsUnchangedForEveryState() {
        let now = at(7, 29, 15)
        #expect(DoorState.live.displayTime(calendar: cal) == nil)
        #expect(DoorState.rest(until: nil).displayTime(calendar: cal) == nil)
        #expect(DoorState.rest(until: at(7, 29, 21)).displayTime(calendar: cal) == "· till 9:00")
        #expect(DoorState.open(until: at(7, 29, 15, 20)).displayTime(calendar: cal) == "· till 3:20")
        var ledger = GrantLedger()
        ledger.record(spent(instagram, 20, before: now))
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), cap: 20, calendar: cal)
                .displayTime(calendar: cal) == nil)
    }
}
