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

    public func spentMinutes(dayStart: Date) -> Int {
        grants.filter { $0.issuedAt >= dayStart }.reduce(0) { $0 + $1.minutes }
    }

    public func remainingMinutes(budget: Int, dayStart: Date) -> Int {
        max(0, budget - spentMinutes(dayStart: dayStart))
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
    public mutating func compact(dayStart: Date) {
        grants.removeAll { $0.expiresAt < dayStart }
        closedToday = closedToday.filter { $0.value >= dayStart }
        closedUntil = closedUntil.filter { closedToday[$0.key] != nil }
    }
}
