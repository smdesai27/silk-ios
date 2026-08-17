import Foundation

/// The clock arithmetic behind a grant's re-lock schedules, kept out of the
/// wall so it can be checked without a device. DeviceActivity moves both ends
/// of a schedule — it refuses intervals under fifteen minutes, and it reads
/// only hours and minutes, so an end lands on its own minute mark. A schedule
/// that fires even a second before the ledger's expiry wakes the wall while the
/// grant is still live, reconciles to nothing, and was the last thing that
/// would have closed the door — so every move here is late, never early.
///
/// Which is why both ends are stated ON a minute mark rather than handed over
/// with seconds the schedule will drop. An ask lands at an arbitrary instant,
/// so a grant's expiry is `now + n·60` and carries whatever second the sentence
/// was said on; truncating that expiry to build the schedule fires the primary
/// up to 59 seconds EARLY, on the one clock the grant is still live by. Rounding
/// up costs under a minute and buys the property the whole layer exists for:
/// the first schedule to fire is the first one that can actually close the door.
public struct RelockWindow: Equatable, Sendable {
    /// Where the primary schedule ends: the first minute mark at or after the
    /// expiry — or at or after the floor below it, when the grant is shorter
    /// than a schedule is allowed to be.
    public let primaryEnd: Date
    /// The staggered second schedule, two minutes behind the primary — a
    /// backstop for the wake that never comes (a dead daemon, a killed
    /// extension), not a second chance at arithmetic the primary got wrong.
    public let backupEnd: Date
    /// True when the floor moved the primary. The ledger still holds the real
    /// expiry, so a clamped grant only ever closes late.
    public let clamped: Bool
    /// The usage threshold, in whole minutes, rounded up: a threshold under the
    /// minutes granted would police a grant it undercuts. It keeps the TRUE
    /// remaining minutes even when the floor clamps the schedules, which is what
    /// makes it the only layer near expiry on a short grant.
    public let thresholdMinutes: Int

    /// Fifteen minutes is DeviceActivitySchedule's documented minimum; the
    /// thirty seconds are margin against clock skew between arming and the
    /// daemon reading the interval.
    public static let scheduleFloor: TimeInterval = 15 * 60 + 30

    public init(now: Date, relockAt: Date) {
        let remaining = relockAt.timeIntervalSince(now)
        clamped = remaining < Self.scheduleFloor
        let target = clamped ? now.addingTimeInterval(Self.scheduleFloor) : relockAt
        primaryEnd = Self.minuteMark(atOrAfter: target)
        // Off the rounded primary, so the stagger is a whole two minutes of
        // real daylight rather than whatever was left of one after truncation.
        backupEnd = primaryEnd.addingTimeInterval(120)
        thresholdMinutes = max(1, Int(ceil(remaining / 60)))
    }

    /// The first minute mark at or after `date` — the instant a schedule ending
    /// there actually fires, once DeviceActivity has read the hours and minutes
    /// off it and dropped the rest.
    ///
    /// Arithmetic, and deliberately no `Calendar`: a minute mark needs none. The
    /// reference date is minute-aligned and every zone's offset is a whole
    /// number of minutes, so the grid `Calendar.dateComponents` truncates to and
    /// the grid this rounds up to are the same grid — in any zone, across any
    /// DST edge, with no calendar to inject into a type whose whole point is
    /// being checkable without a device.
    static func minuteMark(atOrAfter date: Date) -> Date {
        // Exact: `truncatingRemainder` is, and so is the one addition below at
        // these magnitudes — so a date already on the mark is returned
        // unmoved rather than nudged a minute into the future for nothing.
        let into = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)
        guard into != 0 else { return date }
        // A negative remainder means a date before the reference — the mark is
        // still `date - into`, which is `into` seconds ahead.
        return date.addingTimeInterval(into > 0 ? 60 - into : -into)
    }
}
