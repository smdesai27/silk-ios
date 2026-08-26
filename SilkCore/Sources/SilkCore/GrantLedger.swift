import Foundation

/// One grant: prepaid minutes on one door, with an absolute expiry.
/// Silk debits at grant time, not by measuring usage — that is why it needs no
/// Apple usage data, and why closing the app early refunds nothing.
public struct Grant: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let doorID: UUID
    public let doorName: String
    public let minutes: Int          // what was debited
    public let issuedAt: Date
    public let expiresAt: Date       // absolute instant; DST-proof

    public init(id: UUID = UUID(), door: Door, minutes: Int, issuedAt: Date, expiresAt: Date) {
        self.id = id
        self.doorID = door.id
        self.doorName = door.name
        self.minutes = minutes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at now: Date) -> Bool {
        now >= issuedAt && now < expiresAt
    }
}

/// The day-boundary rule: the day starts when down hours END, not at midnight.
/// The budget refills when the aperture closes — 7:00 AM, not 12:00 AM.
/// (docs/market/gaps.md #7)
public enum DayBoundary {
    /// The instant the current "Silk day" began.
    public static func dayStart(now: Date, downHours: DownHours, calendar: Calendar = .current) -> Date {
        let end = downHours.end
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = end.hour
        comps.minute = end.minute
        guard let todayBoundary = calendar.date(from: comps) else { return now }
        if now >= todayBoundary { return todayBoundary }
        return calendar.date(byAdding: .day, value: -1, to: todayBoundary) ?? todayBoundary
    }
}

/// The ledger: every grant, every closed door, every attempt — Silk's own
/// arithmetic on Silk's own record. Pure logic; storage is injected so the
/// same code runs in the app, the tests, and (read-only) the shield extension.
public struct GrantLedger: Codable, Sendable, Equatable {
    public private(set) var grants: [Grant]
    public private(set) var closedToday: [UUID: Date]   // doorID → closed-at (until day end)
    /// doorID → when the close lifts, where a stated hour shortened it
    /// ("block tiktok until 9"). Absent means the day boundary, as ever.
    public private(set) var closedUntil: [UUID: Date]

    public init(grants: [Grant] = [], closedToday: [UUID: Date] = [:],
                closedUntil: [UUID: Date] = [:]) {
        self.grants = grants
        self.closedToday = closedToday
        self.closedUntil = closedUntil
    }

    /// `closedUntil` postdates the first persisted ledgers, so it decodes as
    /// optional; synthesized `encode(to:)` still writes all three keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grants = try c.decode([Grant].self, forKey: .grants)
        closedToday = try c.decode([UUID: Date].self, forKey: .closedToday)
        closedUntil = try c.decodeIfPresent([UUID: Date].self, forKey: .closedUntil) ?? [:]
    }

    // MARK: - Spending

    public mutating func record(_ grant: Grant) {
        grants.append(grant)
    }

    /// Surgical rollback: remove exactly one grant, by its identity, and touch
    /// nothing else. The caller is a writer whose grant failed downstream of
    /// its own save — SpendIntent, when the re-lock schedule will not arm —
    /// and whose failure path sits across a suspension point. Doctrine: it
    /// must NOT put back its pre-save snapshot wholesale, because a ledger
    /// write that landed during the await (the user's bar-side close, another
    /// process's grant) would be erased with it — a tighten silently lost.
    /// Instead it reloads the ledger that stands NOW, removes the one row it
    /// added, and saves. An id absent from the ledger removes nothing, so the
    /// rollback is idempotent; a close that meanwhile truncated the grant kept
    /// its id, so the refund still finds it.
    public mutating func removeGrant(id: UUID) {
        grants.removeAll { $0.id == id }
    }

    public mutating func closeDoor(_ door: Door, at now: Date, until: Date? = nil) {
        closedToday[door.id] = now
        // A stated hour shortens the close; nil is the full day, and clears
        // any earlier stated hour — the newer sentence wins whole.
        closedUntil[door.id] = until
        // Closing also ends any live grant on that door, with no refund.
        grants = grants.map { g in
            guard g.doorID == door.id, g.isActive(at: now) else { return g }
            return Grant(id: g.id, door: door, minutes: g.minutes, issuedAt: g.issuedAt, expiresAt: now)
        }
    }

    // MARK: - Reading the day

    /// The day's spend is the day's grants: issued at or after `dayStart` AND
    /// before the next boundary. The window's far edge is not pedantry — a
    /// grant minted while the device clock was transiently forward carries a
    /// future `issuedAt`, and under the old open-ended filter it satisfied
    /// `issuedAt >= dayStart` on EVERY subsequent real day, re-debiting the
    /// same minutes from the budget daily until real time caught up with it.
    /// Clipped to the day, a phantom grant charges only the day it claims to
    /// belong to, exactly as `DayLog.grantedMinutes` already clips.
    public func spentMinutes(dayStart: Date, calendar: Calendar = .current) -> Int {
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)
        return grants.filter { $0.issuedAt >= dayStart && $0.issuedAt < dayEnd }
            .reduce(0) { $0 + $1.minutes }
    }

    public func remainingMinutes(budget: Int, dayStart: Date, calendar: Calendar = .current) -> Int {
        max(0, budget - spentMinutes(dayStart: dayStart, calendar: calendar))
    }

    /// What one door has drawn from the pool today. Derived from `grants`, like
    /// the shared spend, so restoring a ledger value restores every door's
    /// remaining for free — which is why the grant and close undo paths need no
    /// cap clause at all. Windowed to the day for the same reason the shared
    /// spend is.
    public func spentMinutes(doorID: UUID, dayStart: Date, calendar: Calendar = .current) -> Int {
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)
        return grants.filter { $0.doorID == doorID && $0.issuedAt >= dayStart && $0.issuedAt < dayEnd }
            .reduce(0) { $0 + $1.minutes }
    }

    /// What is left under one door's own ceiling. `cap` is non-optional on
    /// purpose: an uncapped door has no ceiling to have a remainder under, and
    /// the caller says so by not calling. The uncapped form is
    /// `policy.doorCaps[door.id].map { ledger.remainingMinutes(cap: $0, …) }`,
    /// which yields `Int?` where nil means "no ceiling" and never 0.
    ///
    /// Floors at zero exactly as the shared form does, so a cap lowered below
    /// what the door has already spent reads 0 at once and does not cut short a
    /// running grant — the same precedent a budget cut already sets, and the
    /// same reason closing an app early refunds nothing.
    public func remainingMinutes(cap: Int, doorID: UUID, dayStart: Date,
                                 calendar: Calendar = .current) -> Int {
        max(0, cap - spentMinutes(doorID: doorID, dayStart: dayStart, calendar: calendar))
    }

    /// Whether a close currently binds this door: recorded this Silk day, and
    /// its stated hour (if any) not yet reached. The one predicate the wall,
    /// the row, and the Validator all read, so a close means the same thing
    /// everywhere.
    public func isClosed(_ doorID: UUID, at now: Date, dayStart: Date) -> Bool {
        guard let closedAt = closedToday[doorID], closedAt >= dayStart else { return false }
        if let lift = closedUntil[doorID], now >= lift { return false }
        return true
    }

    /// Doors that should be OPEN right now. Everything else is walled.
    /// This is the fail-closed heart: an expired grant is simply absent, so a
    /// dead extension or a missed callback can only ever leave a door SHUT
    /// slightly long, never open. ("Late, never never.")
    public func openDoors(at now: Date, dayStart: Date) -> Set<UUID> {
        var open = Set<UUID>()
        for g in grants where g.isActive(at: now) {
            open.insert(g.doorID)
        }
        for doorID in closedToday.keys where isClosed(doorID, at: now, dayStart: dayStart) {
            open.remove(doorID)
        }
        return open
    }

    /// The next instant the wall must change (a grant expiring) or a row must
    /// (a stated-hour close lifting). The scheduler arms redundant timers
    /// against this; every wake reconciles against it.
    public func nextTransition(after now: Date) -> Date? {
        (grants.map(\.expiresAt) + Array(closedUntil.values)).filter { $0 > now }.min()
    }

    /// Drop everything before the previous day; history beyond the Mirror week
    /// lives in its own store, not the hot ledger.
    ///
    /// A grant issued at or past the day's END goes with the history: it was
    /// minted under a clock that has since been corrected, and it belongs to a
    /// day that has not happened. Kept, its expiry stays forever ahead of every
    /// sweep — the row is immortal — and when the fake window finally arrives,
    /// months on, it goes active and drops the wall for a spend nobody
    /// remembers making. Nothing legitimate is in that region: every honest
    /// grant is issued at some `now` inside the day being swept.
    public mutating func compact(dayStart: Date, calendar: Calendar = .current) {
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)
        grants.removeAll { $0.expiresAt < dayStart || $0.issuedAt >= dayEnd }
        closedToday = closedToday.filter { $0.value >= dayStart }
        closedUntil = closedUntil.filter { closedToday[$0.key] != nil }
    }
}
