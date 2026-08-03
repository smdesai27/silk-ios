import Foundation

/// A minute-of-day, 0..<1440. Down hours are wall-clock local by decision
/// (docs/market/gaps.md #10); grants expire at absolute instants.
public struct TimeOfDay: Hashable, Codable, Sendable, Comparable {
    public let minutes: Int  // since midnight

    public init(hour: Int, minute: Int = 0) {
        self.minutes = ((hour * 60 + minute) % 1440 + 1440) % 1440
    }

    public init(minutesSinceMidnight: Int) {
        self.minutes = ((minutesSinceMidnight % 1440) + 1440) % 1440
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutes < rhs.minutes }

    /// "5:00", "10:30" — 12-hour, no am/pm; the surrounding sentence carries context.
    public var display: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", h12, minute)
    }
}

/// A door: a named app the user may ask for. The name is simultaneously the
/// voice vocabulary, the launch mapping, and the web-domain block.
public struct Door: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String          // display name, user-chosen from the catalogue
    public var aliases: [String]     // learned shorthand (the alias table)

    public init(id: UUID = UUID(), name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }

    /// All spoken forms, lowercased, for matching.
    public var spokenForms: [String] { ([name] + aliases).map { $0.lowercased() } }
}

/// The night window. May cross midnight (22:00 → 7:00).
public struct DownHours: Hashable, Codable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    /// Whether `t` falls inside the window.
    public func contains(_ t: TimeOfDay) -> Bool {
        if start.minutes <= end.minutes {
            return t.minutes >= start.minutes && t.minutes < end.minutes
        }
        // crosses midnight
        return t.minutes >= start.minutes || t.minutes < end.minutes
    }

    /// Window length in minutes.
    public var length: Int {
        ((end.minutes - start.minutes) % 1440 + 1440) % 1440
    }

    /// Whether this window blocks every minute `other` blocks. A window is an
    /// arc on a 24-hour circle, so what it costs the user is the set of those
    /// minutes and not the count of them, which is why polarity asks this and
    /// not `length`. A zero-length window blocks nothing and so is covered by
    /// every window, including another zero-length one elsewhere, which makes
    /// mutual coverage mean "blocks the same minutes", not "is the same window".
    public func covers(_ other: DownHours) -> Bool {
        if other.length == 0 { return true }
        let offset = TimeOfDay(minutesSinceMidnight: other.start.minutes - start.minutes)
        return offset.minutes + other.length <= length
    }
}

/// The whole of Silk's policy. Small on purpose: if it doesn't fit here,
/// Silk doesn't do it.
public struct PolicyState: Hashable, Codable, Sendable {
    public var budgetMinutes: Int          // one daily allowance for all distraction
    public var downHours: DownHours        // one night window
    public var doors: [Door]               // 3–6 named doors
    public var wallEnabled: Bool           // the categories behind the wall (tokens live outside Core)

    public init(budgetMinutes: Int, downHours: DownHours, doors: [Door], wallEnabled: Bool = true) {
        self.budgetMinutes = budgetMinutes
        self.downHours = downHours
        self.doors = doors
        self.wallEnabled = wallEnabled
    }

    public func door(named utteranceToken: String) -> Door? {
        let t = utteranceToken.lowercased()
        return doors.first { $0.spokenForms.contains(t) }
    }
}
