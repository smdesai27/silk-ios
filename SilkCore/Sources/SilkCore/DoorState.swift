import Foundation

/// What a door is doing right now, as the row must draw it. Three states and no
/// fourth: a door is a threshold, so the row reports state and never offers a
/// control.
///
/// The names are the design's, and they mean what the design means by them —
/// which is the opposite of the obvious reading, and was got backwards once:
///
///   - `.live` is the door **in play**: askable, drawing on today's budget. The
///     design draws it boldest (name at ink-84 / weight 500, filled dot).
///   - `.rest` is the door **not in play**: shut for the day. The design dims it
///     (ink-44 / weight 400, hollow ring) and lets it carry the time it lifts.
///   - `.open` is a running grant, and it is the only one that gets the leaf.
///
/// Drawing a door she just closed in the `.live` costume put the strongest signal
/// on Now against the one thing she cannot use.
public enum DoorState: Equatable, Sendable {
    case open(until: Date)   // a grant is running; the deadline it expires at
    case live                // in play today — askable within the shared budget
    /// Shut for the day. `until` is the stated hour that shortened the close
    /// ("block tiktok until 9") — nil when the close simply runs to the day
    /// boundary. The distinction is visible: a rule-bound rest states its
    /// deadline, a plain rest says only the name — so the
    /// nil must survive into the state rather than being papered over with
    /// the boundary date it happens to equal.
    case rest(until: Date?)
}

// MARK: - Projecting the ledger

extension GrantLedger {

    /// The grant holding `door` open at `now`. `openDoors` answers the same
    /// question for the wall but returns a `Set<UUID>` and throws the expiry
    /// away; the row needs the instant. Deliberately the same predicate —
    /// `Grant.isActive` — so the wall and the row read a grant the same way.
    ///
    /// Overlapping grants resolve to the last to expire: that is when the door
    /// actually shuts, and it is what `openDoors` already implies.
    public func activeGrant(for door: Door, at now: Date) -> Grant? {
        grants
            .filter { $0.doorID == door.id && $0.isActive(at: now) }
            .max { $0.expiresAt < $1.expiresAt }
    }

    /// Resolve one row. Order is the point: a running grant outranks a rule,
    /// because a grant is something she asked for and a rule is something she
    /// set — and asking is the newer fact.
    ///
    /// `dayStart` is the CURRENT day's boundary from `DayBoundary.dayStart`; a
    /// rule runs to the NEXT one. Rules carry no deadline of their own, so
    /// there is nothing to read off the `Door`.
    ///
    /// `cap` is the door's own ceiling, or nil when it has none. No default
    /// value: a caller that forgot it would draw a cap-exhausted door in the
    /// in-play costume, which is the one mistake this enum's header exists to
    /// prevent. Every call site states the cap, and the compiler makes sure.
    public func state(of door: Door, at now: Date, dayStart: Date,
                      cap: Int?, calendar: Calendar = .current) -> DoorState {
        if let grant = activeGrant(for: door, at: now) {
            return .open(until: grant.expiresAt)
        }
        // A door that has drawn its whole ceiling is out of play for the day,
        // and it says so in the resting costume rather than in a number on the
        // row: the row's serif slot is a deadline slot, and a remaining cap is a
        // countdown the user drives herself.
        //
        // Before the `isClosed` branch, so a door that is both closed until an
        // hour AND capped out reports no lift: there is no hour today that
        // changes it, and stating the close's own would promise a door that
        // will refuse anyway. `nil` is what the case documents — the close that
        // simply runs to the day boundary.
        if let cap, remainingMinutes(cap: cap, doorID: door.id, dayStart: dayStart,
                                     calendar: calendar) <= 0 {
            return .rest(until: nil)
        }
        // `closedToday` is never pruned on read; a record from an earlier day is
        // spent, and a stated-hour close that has lifted is over — both exactly
        // as `openDoors` treats them, through the same `isClosed`. Only a
        // stated hour rides into the state: `closedUntil` holds nothing for a
        // plain close, and that nothing is what the row renders.
        if isClosed(door.id, at: now, dayStart: dayStart) {
            return .rest(until: closedUntil[door.id])
        }
        // Behind the wall but askable. Silk has one shared budget rather than a
        // per-door allowance, and a cap is a ceiling on that one pool rather
        // than a window — so there is still nothing to name here. The design's
        // `· 5:00` is a deadline, and an unspent cap has none.
        return .live
    }

    /// The one per-door rule the status sentence names after the balance —
    /// "40 min left. TikTok closed until 7:00." — as the door and the instant it
    /// lifts (nil meaning the day boundary, exactly as `.rest` carries it).
    ///
    /// A door closed BY HAND is preferred over one that has merely spent its
    /// ceiling, and it is looked for across all the doors before any rest is
    /// named: taking the first `.rest` in door order would let a capped-out
    /// TikTok sorting first swallow the Instagram close she made a second ago,
    /// which is exactly the fact this clause exists to state.
    ///
    /// Both searches require the door to be at rest, in one pass, so the
    /// preference cannot strand the fallback. Testing `isClosed` on its own and
    /// re-deriving the state afterwards reads the same and is not: a door that
    /// satisfies `isClosed` but is not `.rest` would take the preference, fail
    /// the state match, and drop the fallback with it — the clause whose job is
    /// to name the rule in force would then name nothing.
    public func ruleInForce(for policy: PolicyState, at now: Date, dayStart: Date,
                            calendar: Calendar = .current) -> (door: Door, lifts: Date?)? {
        var resting: (door: Door, lifts: Date?)?
        for door in policy.doors {
            guard case .rest(let until) = state(of: door, at: now, dayStart: dayStart,
                                                cap: policy.doorCaps[door.id],
                                                calendar: calendar) else { continue }
            if isClosed(door.id, at: now, dayStart: dayStart) { return (door, until) }
            if resting == nil { resting = (door, until) }
        }
        return resting
    }
}

extension DayBoundary {

    /// The instant the next Silk day begins — when down hours end, not midnight.
    /// Taking it from `dayStart` rather than from the wall clock is what makes a
    /// window that crosses midnight fall out for free: `dayStart` is already the
    /// correct absolute instant, on whichever calendar day that landed. Adding a
    /// calendar day rather than 86 400 seconds keeps 7:00 AM at 7:00 AM across a
    /// DST shift.
    public static func nextDayStart(after dayStart: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    }
}

// MARK: - What the row renders

extension DoorState {

    /// The row's serif slot, or nil when there is nothing to say. The separator
    /// belongs to the string — "· 5:00" is one serif span, not a name plus a
    /// time (Interactive.html:276). The gap before it does not: the mockup opens
    /// that span with an &nbsp; only because CSS gives `.silk-door__time` no
    /// margin (_ds_bundle.css:236), and in SwiftUI that gap is the row's
    /// spacing. A resting door leaves the slot empty so the baseline stays put.
    ///
    /// Meridiem-less on purpose. The row is read in the moment, and there is
    /// only one 4:52 she could mean.
    ///
    /// **No `now`.** It used to take one and never read it — nothing ticks, so
    /// every branch below is a pure function of the state itself. The cost of
    /// the parameter was not the argument: Now's door rows called it with
    /// `model.now`, which made the app's hottest list observe the minute clock
    /// a second time, on top of the read `state(of:)` already makes. A deadline
    /// that does not move must not be able to ask to be redrawn.
    public func displayTime(calendar: Calendar = .current) -> String? {
        switch self {
        case .open(let until):
            // A grant answers in the deadline it expires at: "· till 4:52".
            // The prototype's row shows "· 0:15", but
            // the canon is explicit that a grant states its duration once, in
            // the reply, and the door shows "· till 4:52" forever after —
            // deadlines, not countdowns; nothing ticks. The canon wins.
            return "· \(SilkStrings.till.lowercased()) \(Self.clock(until, calendar))"
        case .rest(let until):
            // A stated-hour close states when it lifts: "· till 9:00", as the
            // handoff mockup does. A plain close has nothing to add —
            // the resting costume is the whole message.
            guard let until else { return nil }
            return "· \(SilkStrings.till.lowercased()) \(Self.clock(until, calendar))"
        case .live:
            // In play, and nothing to say about it. The slot stays present but
            // empty so the baseline never shifts between states.
            return nil
        }
    }

    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        Validator.timeOfDay(date, calendar: calendar).display
    }
}

// MARK: - The meridiem-bearing forms

extension TimeOfDay {

    /// "10:00 PM", "7:00 AM". `display` stays meridiem-less because it lives
    /// inside sentences that already carry the context ("Till 7:00."). This form
    /// is for the two labels that stand alone with no sentence to lean on: the
    /// aperture and the night hero, where 7:00 must not be read as the evening.
    /// Non-breaking space before the meridiem, as the mockup sets it — "7:00 AM"
    /// must never wrap.
    public var displayWithMeridiem: String {
        "\(display)\u{00A0}\(hour < 12 ? "AM" : "PM")"
    }
}

extension DownHours {

    /// The aperture's one line: "☾  10:00 PM – 7:00 AM" (Interactive.html:273).
    /// The glyph is part of the string because the aperture is a single centred
    /// label, not an icon beside text, and the gap after it is nbsp + space
    /// exactly as the mockup sets it. En dash, never a hyphen — this is a range.
    public var apertureText: String {
        "☾\u{00A0} \(start.displayWithMeridiem) \u{2013} \(end.displayWithMeridiem)"
    }

    /// The bar's answer to a bare "down hours" / "bedtime" / "quiet":
    /// "Down hours run 10:00 PM to 7:00 AM." Both ends carry the meridiem
    /// because the sentence spans the night — a bare "10:00 to 7:00" reads as
    /// a nine-hour morning.
    public var runText: String {
        SilkStrings.downHoursRun(from: start.displayWithMeridiem, to: end.displayWithMeridiem)
    }
}
