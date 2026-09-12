import Foundation
import Testing
@testable import SilkCore

// MARK: - Fixtures

private func relockClock(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29,
                                  hour: hour, minute: minute, second: second))!
}

/// What the wall can actually ask for: a DeviceActivitySchedule carries hours
/// and minutes, so the end it fires on is the minute mark below the Date the
/// window computed. Every claim about "after expiry" has to survive this.
private func asScheduled(_ d: Date) -> Date {
    cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: d))!
}

/// The instant the door actually re-shields, given only the schedules.
///
/// A schedule end that lands before the ledger's expiry wakes the monitor while
/// `Grant.isActive` is still true, so its `Wall.reconcile` closes nothing — the
/// wake is spent and the door stays open. So the close is the FIRST scheduled
/// end at or after expiry, and every earlier one is a wasted wake. nil means
/// nothing armed here would ever have closed the door.
private func scheduledClose(_ w: RelockWindow, expiry: Date) -> Date? {
    [asScheduled(w.primaryEnd), asScheduled(w.backupEnd)]
        .filter { $0 >= expiry }
        .min()
}

@Suite struct RelockWindowTests {
    @Test func aGrantLongerThanTheFloorSchedulesAtItsOwnExpiry() {
        let w = RelockWindow(now: relockClock(14, 3), relockAt: relockClock(14, 33))

        #expect(w.clamped == false)
        #expect(w.primaryEnd == relockClock(14, 33))
        #expect(w.backupEnd == relockClock(14, 35))
        #expect(w.thresholdMinutes == 30)
    }

    @Test func aGrantShorterThanTheFloorSchedulesLateNeverEarly() {
        let now = relockClock(14, 3)
        let relockAt = relockClock(14, 8)
        let w = RelockWindow(now: now, relockAt: relockAt)

        #expect(w.clamped)
        // The floor lands at 14:18:30, and a schedule cannot say the thirty —
        // so the end is the mark above it. Later than the floor, never below.
        #expect(w.primaryEnd == relockClock(14, 19))
        #expect(w.primaryEnd >= now.addingTimeInterval(RelockWindow.scheduleFloor))
        #expect(w.primaryEnd > relockAt)
        // The threshold keeps the five minutes actually granted: it is spent
        // usage, not wall clock, and nothing forces it up to the floor.
        #expect(w.thresholdMinutes == 5)
    }

    @Test func theEndsAreStatedOnTheMinuteTheScheduleWillFireOn() {
        // A grant asked at 14:03:47 expires at 14:33:47, and a schedule carries
        // no seconds to say the forty-seven with. Handed the expiry raw it would
        // end at 14:33 — before the ledger stops calling the grant live, so its
        // reconcile finds nothing to close and the wake is spent for nothing.
        // Stated at 14:34 it closes the door thirteen seconds late, which is
        // the direction this file exists to keep every move in.
        let relockAt = relockClock(14, 33, 47)
        let w = RelockWindow(now: relockClock(14, 3, 47), relockAt: relockAt)

        #expect(w.primaryEnd == relockClock(14, 34))
        #expect(w.backupEnd == relockClock(14, 36))
        // Stated on the mark, the schedule's own truncation is a no-op — which
        // is the property `WallController.arm` leans on when it reads
        // `[.hour, .minute]` off these two dates.
        #expect(asScheduled(w.primaryEnd) == w.primaryEnd)
        #expect(asScheduled(w.backupEnd) == w.backupEnd)
        #expect(asScheduled(w.primaryEnd) > relockAt)
    }

    @Test func theThresholdRoundsUpSoItNeverUndercutsTheMinutesGranted() {
        let w = RelockWindow(now: relockClock(14, 3), relockAt: relockClock(14, 23, 1))

        #expect(w.thresholdMinutes == 21)
    }

    @Test func aGrantWithNothingLeftOnItStillArmsAMinuteOfThreshold() {
        // The Validator truncates a grant at the night edge, and a spend a
        // second before that edge can arrive here with no time on it. A
        // threshold of zero arms nothing at all.
        let now = relockClock(21, 59, 59)
        let w = RelockWindow(now: now, relockAt: now)

        #expect(w.clamped)
        #expect(w.thresholdMinutes == 1)
        #expect(w.primaryEnd > now)
    }
}

// MARK: - How late the door actually closes

/// The window's arithmetic can be right in every clause above and still leave a
/// door open a minute past its expiry, because none of those tests asks the one
/// question the user asks: *when does it actually shut?* That answer is not a
/// property of either end on its own — it is the first end that lands on the
/// far side of expiry, read through the truncation the wall performs. These are
/// the bounds the device re-lock protocol states as its pass standard.
@Suite struct RelockLatency {

    /// The whole bug, in one loop. An ask lands on an arbitrary instant, so
    /// `relockAt` is `now + n·60` and carries `now`'s seconds — while the
    /// schedule policing it carries only hours and minutes. Sixty asks, one per
    /// second of the minute: every one of them must close within a minute of
    /// the expiry the ledger holds.
    @Test func aDoorClosesWithinAMinuteOfExpiryWhicheverSecondItWasAskedOn() {
        for second in 0..<60 {
            let now = relockClock(14, 3, second)
            let relockAt = now.addingTimeInterval(30 * 60)
            let w = RelockWindow(now: now, relockAt: relockAt)

            guard let closed = scheduledClose(w, expiry: relockAt) else {
                Issue.record("asked at :\(second) — no schedule lands at or after expiry")
                continue
            }
            let late = closed.timeIntervalSince(relockAt)
            #expect(late < 60, "asked at :\(second) — door closed \(Int(late))s late")
        }
    }

    /// And it must be the PRIMARY that closes it. The stagger exists for the
    /// wake that never comes — a dead daemon, a killed extension — and a design
    /// that spends it on ordinary truncation has no backstop left: the first
    /// schedule is a wasted wake on every single grant, and the layer meant to
    /// cover a failure is instead carrying the happy path.
    @Test func thePrimaryScheduleIsTheOneThatCloses() {
        for second in 0..<60 {
            let now = relockClock(9, 17, second)
            let relockAt = now.addingTimeInterval(45 * 60)
            let w = RelockWindow(now: now, relockAt: relockAt)

            #expect(asScheduled(w.primaryEnd) >= relockAt,
                    "asked at :\(second) — primary fires before expiry and closes nothing")
            #expect(asScheduled(w.backupEnd) > asScheduled(w.primaryEnd),
                    "asked at :\(second) — the stagger collapsed onto the primary")
        }
    }

    /// A grant clamped by the schedule floor cannot close on time from a
    /// schedule — that is what the clamp means, and the ledger keeps the true
    /// expiry so the lateness is harmless. What it may not do is close EARLY,
    /// and the threshold must still police the minutes actually granted: for a
    /// short grant that event is the only layer near expiry at all.
    @Test func aClampedGrantIsLateFromTheSchedulesAndOnTimeFromTheThreshold() {
        for second in 0..<60 {
            let now = relockClock(14, 3, second)
            let relockAt = now.addingTimeInterval(2 * 60)
            let w = RelockWindow(now: now, relockAt: relockAt)

            #expect(w.clamped)
            #expect(w.thresholdMinutes == 2)
            #expect(asScheduled(w.primaryEnd) > relockAt,
                    "asked at :\(second) — a clamped schedule closed early")
        }
    }

    /// Rounding an end up can only lengthen an interval — but the fifteen-minute
    /// minimum is what makes a schedule arm at all, and a schedule that throws
    /// arms nothing and re-locks never. Asserted across the sub-minute phases
    /// and the lengths that straddle the floor, because the arithmetic that
    /// guarantees it is exactly the arithmetic under change.
    @Test func everyScheduledIntervalClearsTheFifteenMinuteMinimum() {
        for second in 0..<60 {
            for minutes in [1, 2, 5, 14, 15, 16, 17, 30, 120] {
                let now = relockClock(14, 3, second)
                let w = RelockWindow(now: now,
                                     relockAt: now.addingTimeInterval(Double(minutes) * 60))
                let start = asScheduled(now)
                #expect(asScheduled(w.primaryEnd).timeIntervalSince(start) >= 15 * 60,
                        "\(minutes)m asked at :\(second) — primary interval under the minimum")
                #expect(asScheduled(w.backupEnd).timeIntervalSince(start) >= 15 * 60,
                        "\(minutes)m asked at :\(second) — backup interval under the minimum")
            }
        }
    }
}
