import Foundation

/// The day record and the walk that produces it.
///
/// Pure — no FamilyControls, no `SharedStore` — so the whole mechanic is
/// testable from `swift test` the way `GrantLedger` is. Everything the wall
/// knows and Core cannot see arrives as the `wallStanding` argument.
///
/// Why records and not a running total: an `Int` incremented from two
/// processes silently drops increments, and Silk writes from the app and from
/// `SpendIntent`. Records are idempotent by `dayStart`, so a lost write can
/// lose a day but can never corrupt one.
///
/// See `docs/design/mirror-continuity.md` §2–§3.

// MARK: - The record

/// One closed Silk day, summarised once and never revised.
public struct DayRecord: Codable, Hashable, Sendable {
    /// Identity — the Silk day this summarises. Day starts when down hours
    /// end, not at midnight (`DayBoundary.dayStart`).
    public let dayStart: Date
    /// The union, in minutes, of every grant interval clipped to this day.
    public let grantedMinutes: Int
    /// Distinct reaches inside the day. `recordAttempt` already dedupes at
    /// 60 s, so this is per reach, not per shield render.
    public let reaches: Int
    /// Those reaches falling inside the down-hours window.
    public let lateReaches: Int
    /// The wall stood and Silk could see it. Decided at write time and never
    /// revised — an unobserved day credits nothing, charges nothing, and
    /// draws a ring.
    public let observed: Bool

    public init(dayStart: Date, grantedMinutes: Int, reaches: Int,
                lateReaches: Int, observed: Bool) {
        self.dayStart = dayStart
        self.grantedMinutes = grantedMinutes
        self.reaches = reaches
        self.lateReaches = lateReaches
        self.observed = observed
    }

    /// The day's contribution. Frozen arithmetic over frozen fields: a record
    /// written once can never be recomputed into a different number, which is
    /// what makes the hero monotone rather than merely "usually rising".
    public var fraction: Double {
        guard observed else { return 0 }
        let cost = Double(grantedMinutes + reaches + lateReaches)
        return max(0, 1 - cost / DayLog.allowance)
    }
}

// MARK: - The log

public enum DayLog {
    /// The day's allowance, in points, declared before the day starts rather
    /// than granted after it goes wrong. A granted minute costs one; a reach
    /// costs one; a reach inside down hours costs one more — the coefficients
    /// the shipped score already uses. 180 is the one number here that is not
    /// derived from anything; see mirror-continuity §8.5. Provisional until
    /// calibrated against a real device day.
    public static let allowance: Double = 180

    /// The cap `recordAttempt` enforces on the attempts blob. Mirrored here
    /// because §3.5's observability rule turns on the blob being *at* it.
    public static let attemptsCap = 2000

    /// A Silk day shorter or longer than this is a boundary that moved under
    /// the user — a timezone change, not a day. It draws a ring rather than a
    /// fill, because `observed` has a span term even though `fraction` does
    /// not (§3.3).
    public static let sameSpan = (min: 20.0 * 3600, max: 28.0 * 3600)

    /// The largest backfill a single walk will emit. A 90-day absence is
    /// expected (§3.7); this exists so a boundary that has moved absurdly far
    /// cannot spin. It matches the record cap, so a walk can never produce
    /// more records than the store keeps.
    public static let maxWalk = 2000

    // MARK: Summarising one day

    /// Summarise one closed Silk day.
    ///
    /// `attempts` must be the **whole** blob, not a pre-filtered slice: §3.5
    /// decides observability partly from whether the blob is at its cap, and
    /// a slice cannot answer that. Filtering to the day happens here.
    ///
    /// `wallStanding` is the caller's verdict on the two facts Core cannot
    /// see — `policy.wallEnabled` and `WallController.standing == .up`. It is
    /// ANDed with the two this function *can* decide (span, attempts cap), so
    /// a caller cannot accidentally promote a day Core knows is unobservable.
    public static func summarise(dayStart: Date,
                                 downHours: DownHours,
                                 grants: [Grant],
                                 attempts: [Date],
                                 wallStanding: Bool,
                                 calendar: Calendar = .current) -> DayRecord {
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)

        let inDay = attempts.filter { $0 >= dayStart && $0 < dayEnd }
        let late = inDay.count { attempt in
            let c = calendar.dateComponents([.hour, .minute], from: attempt)
            return downHours.contains(TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0))
        }

        // The span term. A boundary that moved under the user produces a day
        // that is not a day; `fraction` would still be arithmetically fine,
        // which is exactly why the guard has to live on `observed`.
        let span = dayEnd.timeIntervalSince(dayStart)
        let sane = span >= sameSpan.min && span <= sameSpan.max

        // The blob is at its cap and this day starts before the oldest thing
        // in it, so the reach count would be a floor, not a count. A
        // fabricated fraction is worse than a ring.
        let truncated = attempts.count >= attemptsCap
            && (attempts.first.map { dayStart < $0 } ?? false)

        return DayRecord(dayStart: dayStart,
                         grantedMinutes: grantedMinutes(grants, from: dayStart, to: dayEnd),
                         reaches: inDay.count,
                         lateReaches: late,
                         observed: wallStanding && sane && !truncated)
    }

    /// The union, in minutes, of every grant interval `[issuedAt, expiresAt)`
    /// clipped to the day.
    ///
    /// **Union, not sum.** Two doors open at once is one minute the wall was
    /// down, not two — summing would charge a multi-door grant twice and make
    /// the cost depend on how the same span was sliced.
    ///
    /// Rounded to nearest rather than floored: a grant crossing a boundary is
    /// split in two, and flooring both halves loses up to a minute per
    /// crossing in a direction that always flatters the user.
    static func grantedMinutes(_ grants: [Grant], from dayStart: Date, to dayEnd: Date) -> Int {
        let clipped: [(start: Date, end: Date)] = grants.compactMap { g in
            let s = max(g.issuedAt, dayStart)
            let e = min(g.expiresAt, dayEnd)
            return s < e ? (s, e) : nil
        }.sorted { $0.start < $1.start }

        var total: TimeInterval = 0
        var open: (start: Date, end: Date)?
        for interval in clipped {
            guard var current = open else { open = interval; continue }
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)   // overlap — extend
                open = current
            } else {
                total += current.end.timeIntervalSince(current.start)
                open = interval
            }
        }
        if let last = open { total += last.end.timeIntervalSince(last.start) }

        return Int((total / 60).rounded())
    }

    // MARK: The walk

    /// Every closed Silk day that has no record yet, oldest first.
    ///
    /// **No cursor.** `lastRecordedDayStart` is deliberately not stored: a
    /// cursor that advances past a write which did not land loses that day
    /// permanently, whereas this set-difference walk re-emits it on the next
    /// pass. That self-healing is what lets the compaction gate fail safe.
    ///
    /// `currentDayStart` is excluded — today is not closed and is never in
    /// the hero.
    ///
    /// Uses `DayBoundary.nextDayStart`, which adds a *calendar* day rather
    /// than 86 400 s, so a 23- or 25-hour Silk day is walked exactly once
    /// (pinned by `DSTNightTests`).
    ///
    /// **Bootstrapping.** With no records at all there is no anchor to walk
    /// from — §3.6 deletes `firstRun`, so nothing stamps the install. This
    /// emits the single day immediately before `currentDayStart` and lets the
    /// chain continue from there. On a real first run that day was not
    /// observed (the wall is not up during onboarding), so it writes a ring
    /// and the hero reads 0 on day 1, which is what §2.6 specifies. This is
    /// the one place the implementation had to decide something the document
    /// does not state.
    public static func missingBoundaries(recorded: Set<Date>,
                                         upTo currentDayStart: Date,
                                         calendar: Calendar = .current) -> [Date] {
        // Anchored on the OLDEST record, not the newest. Anchoring on the
        // newest would skip any gap behind it — which is a stored cursor
        // wearing a different hat, and loses exactly the day this walk exists
        // to recover.
        guard let anchor = recorded.min() else {
            let previous = calendar.date(byAdding: .day, value: -1, to: currentDayStart)
            return previous.map { [$0] } ?? []
        }
        guard anchor < currentDayStart else { return [] }

        var out: [Date] = []
        var cursor = DayBoundary.nextDayStart(after: anchor, calendar: calendar)
        while cursor < currentDayStart && out.count < maxWalk {
            if !recorded.contains(cursor) { out.append(cursor) }
            let next = DayBoundary.nextDayStart(after: cursor, calendar: calendar)
            guard next > cursor else { break }   // a boundary that cannot advance
            cursor = next
        }
        return out
    }

    /// Fold new records into the stored set, oldest first.
    ///
    /// **An existing record always wins.** `observed` is decided at write
    /// time and never revised, so a re-walk — which happens whenever a write
    /// fails to land and the set-difference walk re-emits the day — must not
    /// be able to change a verdict already recorded. Without this the hero
    /// stops being monotone: the same day could summarise differently on a
    /// later pass, when the attempts blob has moved on.
    ///
    /// Capped like every other array in the store, dropping oldest first.
    public static func merge(existing: [DayRecord], adding fresh: [DayRecord]) -> [DayRecord] {
        var byDay: [Date: DayRecord] = [:]
        for record in existing { byDay[record.dayStart] = record }
        for record in fresh where byDay[record.dayStart] == nil {
            byDay[record.dayStart] = record
        }
        var out = byDay.values.sorted { $0.dayStart < $1.dayStart }
        if out.count > recordCap { out.removeFirst(out.count - recordCap) }
        return out
    }

    /// How many closed days the store keeps — 2000, about 5.5 years, matching
    /// the convention every other array in `SharedStore` follows.
    public static let recordCap = 2000

    /// The hero: whole days held, over closed observed days only.
    public static func daysHeld(_ records: [DayRecord]) -> Int {
        Int(records.reduce(0.0) { $0 + $1.fraction })
    }
}
