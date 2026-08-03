import Foundation

/// The clock arithmetic behind a grant's re-lock schedules, kept out of the
/// wall so it can be checked without a device. DeviceActivity moves both ends
/// of a schedule — it refuses intervals under fifteen minutes, and it reads
/// only hours and minutes, so an end lands on its own minute mark. A schedule
/// that fires even a second before the ledger's expiry wakes the wall while the
/// grant is still live, reconciles to nothing, and was the last thing that
/// would have closed the door — so every move here is late, never early.
public struct RelockWindow: Equatable, Sendable {
    /// Where the primary schedule ends: the expiry itself, or the floor below
    /// when the grant is shorter than a schedule is allowed to be.
    public let primaryEnd: Date
    /// The staggered second schedule. Two minutes clears the minute the
    /// primary's end is truncated to, which is why this one — not the primary —
    /// is the schedule guaranteed to land after expiry.
    public let backupEnd: Date
    /// True when the floor moved the primary. The ledger still holds the real
    /// expiry, so a clamped grant only ever closes late.
    public let clamped: Bool
    /// The usage threshold, in whole minutes, rounded up: a threshold under the
    /// minutes granted would police a grant it undercuts.
    public let thresholdMinutes: Int

    /// Fifteen minutes is DeviceActivitySchedule's documented minimum; the
    /// thirty seconds are margin against clock skew between arming and the
    /// daemon reading the interval.
    public static let scheduleFloor: TimeInterval = 15 * 60 + 30

    public init(now: Date, relockAt: Date) {
        let remaining = relockAt.timeIntervalSince(now)
        clamped = remaining < Self.scheduleFloor
        primaryEnd = clamped ? now.addingTimeInterval(Self.scheduleFloor) : relockAt
        backupEnd = primaryEnd.addingTimeInterval(120)
        thresholdMinutes = max(1, Int(ceil(remaining / 60)))
    }
}
