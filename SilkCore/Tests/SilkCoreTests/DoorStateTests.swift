import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private let instagram = Door(name: "Instagram")
private let youtube = Door(name: "YouTube")

private let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

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
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), calendar: cal)
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
        #expect(ledger.state(of: instagram, at: justBefore, dayStart: dayStart(justBefore), calendar: cal)
                == .open(until: expiry))
        #expect(ledger.activeGrant(for: instagram, at: expiry) == nil)
        #expect(ledger.state(of: instagram, at: expiry, dayStart: dayStart(expiry), calendar: cal) == .live)
    }

    @Test func overlappingGrantsReportTheLastExpiry() {
        // Two grants on one door: the row must say when the door actually shuts.
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 10)))
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 25)))
        #expect(ledger.activeGrant(for: instagram, at: now)?.expiresAt == at(7, 29, 15, 25))
    }

    @Test func anotherDoorsGrantIsNotThisDoorsGrant() {
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.record(grant(instagram, from: now, to: at(7, 29, 15, 20)))
        #expect(ledger.activeGrant(for: youtube, at: now) == nil)
        #expect(ledger.state(of: youtube, at: now, dayStart: dayStart(now), calendar: cal) == .live)
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
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), calendar: cal)
                == .rest(until: nil))
        #expect(ledger.state(of: instagram, at: at(7, 30, 8), dayStart: dayStart(at(7, 30, 8)), calendar: cal)
                == .live)
    }

    @Test func acrossMidnightTheRuleStillLiftsAtSevenAM() {
        // 23:30 belongs to the day that began at 07:00 the same morning, so the
        // rule lifts at 07:00 tomorrow — not at midnight, ninety minutes away.
        let closedAt = at(7, 29, 21)
        let lateNight = at(7, 29, 23, 30)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt)
        #expect(ledger.state(of: instagram, at: lateNight, dayStart: dayStart(lateNight), calendar: cal)
                == .rest(until: nil))

        // 03:00 is still that same Silk day: same close, same rest.
        let afterMidnight = at(7, 30, 3)
        #expect(dayStart(afterMidnight) == at(7, 29, 7))
        #expect(ledger.state(of: instagram, at: afterMidnight, dayStart: dayStart(afterMidnight), calendar: cal)
                == .rest(until: nil))
    }

    @Test func aStatedHourCloseLiftsAtThatHourNotTheBoundary() {
        // "block instagram until 9" at 15:00 — the row reads "· till 9:00",
        // and at 9 the door is back in play, hours before the day boundary.
        // (docs/design/handoff/README.md:243)
        let closedAt = at(7, 29, 15)
        let lift = at(7, 29, 21)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt, until: lift)
        #expect(ledger.state(of: instagram, at: at(7, 29, 16), dayStart: dayStart(at(7, 29, 16)), calendar: cal)
                == .rest(until: lift))
        #expect(DoorState.rest(until: lift).displayTime(now: at(7, 29, 16), calendar: cal) == "· till 9:00")
        #expect(ledger.state(of: instagram, at: at(7, 29, 21, 5), dayStart: dayStart(at(7, 29, 21, 5)), calendar: cal)
                == .live)
    }

    @Test func yesterdaysCloseIsSpent() {
        let closedAt = at(7, 28, 20)
        let now = at(7, 29, 15)
        var ledger = GrantLedger()
        ledger.closeDoor(instagram, at: closedAt)
        #expect(ledger.state(of: instagram, at: now, dayStart: dayStart(now), calendar: cal) == .live)
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
        #expect(GrantLedger().state(of: instagram, at: now, dayStart: dayStart(now), calendar: cal) == .live)
        #expect(DoorState.live.displayTime(now: now, calendar: cal) == nil)
    }

    @Test func aGrantAnswersInTheDeadlineItExpiresAt() {
        // "· till 4:52" — the duration was spoken once, in the reply; the row
        // holds the deadline forever after. Deadlines, not countdowns; nothing
        // ticks. (docs/design/canon.md, Screens/Interactive)
        let now = at(7, 29, 16, 37)
        #expect(DoorState.open(until: at(7, 29, 16, 52)).displayTime(now: now, calendar: cal) == "· till 4:52")
        #expect(DoorState.open(until: at(7, 29, 18, 7)).displayTime(now: now, calendar: cal) == "· till 6:07")
    }

    @Test func aShutDoorStatesItsStatedHourAndOnlyThat() {
        // "· till 9:00" — lowercase, following the separator
        // (Silk Mockup.dc.html:330). A plain close says nothing: the resting
        // costume is the whole message (README.md:90-91).
        let now = at(7, 29, 15)
        #expect(DoorState.rest(until: at(7, 29, 21)).displayTime(now: now, calendar: cal) == "· till 9:00")
        #expect(DoorState.rest(until: nil).displayTime(now: now, calendar: cal) == nil)
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
        // AppModel.swift:102 and SpendIntent.swift:38 speak sentences that carry
        // the context themselves; a meridiem there would be noise.
        #expect(TimeOfDay(hour: 7).display == "7:00")
        #expect(TimeOfDay(hour: 22).display == "10:00")
    }

    @Test func apertureWindow() {
        #expect(night.apertureText == "☾\u{00A0} 10:00\u{00A0}PM \u{2013} 7:00\u{00A0}AM")
    }
}
