import Foundation

/// The model (or the grammar) proposes; this disposes. Every command from any
/// parser — deterministic or LLM — passes through here before anything touches
/// the wall. Measured result of this architecture: 18/18 on the adversarial
/// eval, both prompt injections killed by arithmetic. (docs/market/open-language.md)
public enum Verdict: Equatable, Sendable {
    /// A grant, fully specified: door, minutes actually granted, re-lock time.
    case grant(door: Door, minutes: Int, relockAt: Date)
    /// A rule change, with its polarity already computed by state diff.
    case ruleChange(proposed: PolicyState, polarity: Polarity)
    /// A close, with the instant it lifts already resolved — a stated hour's
    /// next occurrence, or the day boundary. The sentence states the deadline:
    /// "TikTok closed until 9:00."
    case close(door: Door, until: Date)
    /// Every door at once, same lift. Carries the doors so the caller can rest
    /// each one; the sentence confirms plurally: "Everything closed until 7:00."
    case closeAll(doors: [Door], until: Date)
    case status(remaining: Int)
    /// The window read back, for the app to speak as "Down hours run 10:00 PM
    /// to 7:00 AM." — see `DownHours.runText`.
    case downHours(DownHours)
    /// Refusals. Each carries only what the sentence needs. The wording lives in
    /// the app layer — see `AppModel.apply`.
    case refuseNothingLeft                      // "0 left today."
    case refuseDownHours(until: TimeOfDay)      // "Down hours. Opens 7:00 AM."
    case refuseSayHowManyMinutes                // "How long?"
    /// Zero parses, two parses, failed provenance: Silk says nothing new.
    case silence
}

public extension Verdict {
    /// Whether this verdict only ever narrows what is permitted. Tightening is
    /// instant from anywhere, including down hours, so the caller can let these
    /// through a gate that stops everything else.
    var isTighten: Bool {
        switch self {
        case .close, .closeAll:
            return true
        case .ruleChange(_, let polarity):
            return polarity == .tighten
        default:
            return false
        }
    }
}

public enum Validator {

    /// `utterance` is required for the provenance check: any minutes granted
    /// must be traceable to words the user actually said. A model that invents
    /// "40" out of the budget dies here, not in the prompt.
    public static func validate(
        _ outcome: ParseOutcome,
        utterance: String,
        state: PolicyState,
        ledger: GrantLedger,
        now: Date,
        calendar: Calendar = .current
    ) -> Verdict {
        guard case .command(let command) = outcome else { return .silence }

        let dayStart = DayBoundary.dayStart(now: now, downHours: state.downHours, calendar: calendar)
        let remaining = ledger.remainingMinutes(budget: state.budgetMinutes, dayStart: dayStart)
        let nowTime = timeOfDay(now, calendar: calendar)

        switch command {
        case .status:
            return .status(remaining: remaining)

        case .downHoursQuery:
            // A read, not a write: hand back the window for the caller to speak.
            return .downHours(state.downHours)

        case .placeBoundAsk:
            // Understandable, not executable: a condition can start a grant;
            // only a number can end one.
            return .refuseSayHowManyMinutes

        case .closeDoorToday(let door, let until):
            // Tightening. Always allowed, always instant.
            return .close(door: door, until: restLift(until: until, now: now,
                                                      dayStart: dayStart, calendar: calendar))

        case .closeAllToday(let until):
            // The same tighten across the whole door list. Expanded here, not
            // in the parser, so "everything" always means the doors as they
            // stand when the sentence lands.
            return .closeAll(doors: state.doors,
                             until: restLift(until: until, now: now,
                                             dayStart: dayStart, calendar: calendar))

        case .spend(let door, let minutes):
            // Edges never yield.
            if state.downHours.contains(nowTime) {
                return .refuseDownHours(until: state.downHours.end)
            }
            if remaining <= 0 { return .refuseNothingLeft }

            // P3 — number provenance. The minutes must be words she said.
            guard NumberParser.allNumbers(in: utterance).contains(minutes) else {
                return .silence
            }
            // P1/P2 — sanity on the pair.
            guard minutes > 0, state.doors.contains(where: { $0.id == door.id }) else {
                return .silence
            }
            // A closed door stays closed — for the day, or until its stated hour.
            if ledger.isClosed(door.id, at: now, dayStart: dayStart) {
                return .refuseNothingLeft
            }
            // P4 — the budget binds, and the bind is a clamp. This point used
            // to refuse an over-ask with the balance ("stating the number is
            // not negotiating"); the handoff superseded that: "Requested
            // durations clamp to the minutes actually remaining"
            // (docs/design/handoff/README.md:248-249, and the prototype's
            // Math.min at Silk Mockup.dc.html:323). The readback then states
            // the clamped number, so she still hears what she actually got.
            let asked = min(minutes, remaining)

            // A grant cannot cross into down hours: re-lock is
            // min(now + minutes, downStart), and we debit what was granted.
            let requestedEnd = now.addingTimeInterval(TimeInterval(asked * 60))
            let edge = nextDownHoursStart(after: now, downHours: state.downHours, calendar: calendar)
            let relock = min(requestedEnd, edge ?? requestedEnd)
            let granted = max(0, Int(relock.timeIntervalSince(now) / 60))
            guard granted > 0 else { return .refuseDownHours(until: state.downHours.end) }
            return .grant(door: door, minutes: granted, relockAt: relock)

        case .setBudget, .setDownHoursStart, .setDownHoursEnd, .addDoor, .removeDoor:
            guard let proposed = PolarityEngine.proposedState(applying: command, to: state) else {
                return .silence
            }
            let polarity = PolarityEngine.classify(current: state, proposed: proposed)
            return .ruleChange(proposed: proposed, polarity: polarity)
        }
    }

    // MARK: - Clock helpers

    /// When a close lifts. No stated hour → the day boundary, as ever. A stated
    /// hour → its next occurrence, capped at the day boundary: "closed today"
    /// is the outer promise, and a stated hour can only shorten it. The parser
    /// already read bare hours as evenings, so 9 is 9 PM tonight; a 9 PM that
    /// has already passed rounds up to the boundary rather than reaching into
    /// tomorrow.
    static func restLift(until: TimeOfDay?, now: Date, dayStart: Date, calendar: Calendar) -> Date {
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)
        guard let t = until else { return dayEnd }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = t.hour
        comps.minute = t.minute
        guard let today = calendar.date(from: comps) else { return dayEnd }
        let next = today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? dayEnd)
        return min(next, dayEnd)
    }

    public static func timeOfDay(_ date: Date, calendar: Calendar) -> TimeOfDay {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    static func nextDownHoursStart(after now: Date, downHours: DownHours, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = downHours.start.hour
        comps.minute = downHours.start.minute
        guard let todayStart = calendar.date(from: comps) else { return nil }
        if todayStart > now { return todayStart }
        return calendar.date(byAdding: .day, value: 1, to: todayStart)
    }
}
