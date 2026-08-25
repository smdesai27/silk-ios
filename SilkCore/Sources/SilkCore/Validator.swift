import Foundation

/// The model (or the grammar) proposes; this disposes. Every command from any
/// parser — deterministic or LLM — passes through here before anything touches
/// the wall. Measured result of this architecture: 18/18 on the adversarial
/// eval, both prompt injections killed by arithmetic. (docs/market/open-language.md)
public enum Verdict: Equatable, Sendable {
    /// A grant, fully specified: door, minutes actually granted, re-lock time.
    case grant(door: Door, minutes: Int, relockAt: Date)
    /// The ask is already covered by a grant still running. Nothing is debited
    /// and the existing deadline is restated. Without it, a second ask on a
    /// door near its ceiling clamps to a handful of minutes that buy no extra
    /// open time at all — the door is already open past them — while debiting
    /// both currencies and pushing the cap to exhausted. `SpendIntent` has had
    /// this guard since it shipped ("a double debit would be catastrophic for
    /// the single-currency promise", SpendIntent.swift:22-25); the bar never
    /// needed it because the shared pool is large, and a cap makes the door's
    /// own remaining systematically smaller than the time left on its own grant.
    case restated(door: Door, until: Date)
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
    /// The time as the sentence gave it, so the question can quote it back
    /// whole: "7:30am or 7:30pm?" Carrying only the hour would offer two times
    /// and neither of them the one asked for.
    case refuseSayAmOrPm(at: TimeOfDay)         // "11am or 11pm?"
    /// A door asked for in a sentence. A door is a name and an app, and only
    /// Apple's picker can say which app — a sentence carries the name and
    /// nothing else, and a door made from a name alone parses, launches,
    /// spends the budget, and can never be excepted from the wall.
    case refuseDoorNeedsApp                     // "Add it in Settings."
    /// A door that cannot open right now, named — because a bare "0 left today."
    /// is a lie whenever the pool still has minutes in it, which is the ordinary
    /// case once a door can run out on its own. `until` is the instant it lifts:
    /// a stated hour, or the day boundary. The sentence states it, exactly as
    /// `.close` does: "TikTok closed until 7:00."
    ///
    /// This case takes over the `isClosed` refusal too. A door closed by hand
    /// with 40 shared minutes left had been answering "0 left today." since
    /// before caps existed, and shipping a second, honest refusal beside it
    /// would document the bug rather than fix it.
    case refuseDoorClosed(door: Door, until: Date)
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

    /// Whether the night holds this back. Down hours answer everything with the
    /// hour they end, and a tighten is the standing exception to that — but the
    /// hour is a promise to come back for a different answer, and a door asked
    /// for at the bar is refused at seven exactly as it is at eleven. Quoting
    /// the hour there sends her back in the morning for nothing.
    var deferredByDownHours: Bool {
        switch self {
        case .refuseDoorNeedsApp, .refuseSayAmOrPm:
            // The am/pm question joins it for the same reason, and needs the
            // exemption more: "let me stay up till 11" is a sentence said at
            // eleven at night. Deferring it answers a question about tonight
            // with the hour the wall opens, and the ask is lost.
            return false
        default:
            return !isTighten
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
            // The door's own ceiling, and then the clamp — both computed before
            // any of the three branches below, because two of them need the
            // number she can actually be GIVEN rather than the one she said.
            let doorRemaining = state.doorCaps[door.id].map {
                ledger.remainingMinutes(cap: $0, doorID: door.id, dayStart: dayStart)
            }
            // P4 — the budget binds, and the bind is a clamp. This point used
            // to refuse an over-ask with the balance ("stating the number is
            // not negotiating"); the handoff superseded that: "Requested
            // durations clamp to the minutes actually remaining"
            // (docs/design/handoff/README.md:248-249, and the prototype's
            // Math.min at Silk Mockup.dc.html:323). The readback then states
            // the clamped number, so she still hears what she actually got.
            //
            // Three terms now: the pool binds, and so does the door's own
            // ceiling.
            let asked = min(minutes, remaining, doorRemaining ?? Int.max)

            // Already open, and the ask cannot reach past it. The comparison is
            // against `asked` and NOT against the ask as spoken, because
            // shrinking is exactly what makes a second ask fail to buy time:
            // forty minutes asked with five left under the ceiling clamps to
            // five, and five minutes from now expires BEFORE the grant already
            // running. Granting that debits both currencies, buys not one extra
            // second of open door, and finishes the ceiling for the day — the
            // harm `.restated` was added to prevent. Comparing the unshrunk
            // number is the one comparison that cannot catch it.
            //
            // Ahead of both refusals, and that ordering is the point. A door
            // whose ceiling is spent clamps to zero, so a live grant restates
            // here instead of being told it is closed — which it is not: the
            // wall is down, `openDoors` holds it, and `state(of:)` draws the row
            // `· till 10:30` in the same second. A running grant outranks every
            // rule, cap included, on the row and at the bar alike.
            //
            // It cannot jump the close below either: `closeDoor` truncates every
            // live grant on the door it shuts, so a closed door has no active
            // grant to restate and reaches the `isClosed` branch as it always
            // did. That is the same fact the old ordering leaned on when it put
            // the close first, which is why moving it is safe.
            if let live = ledger.activeGrant(for: door, at: now) {
                let alreadyOpen = max(0, Int(live.expiresAt.timeIntervalSince(now) / 60))
                if asked <= alreadyOpen { return .restated(door: door, until: live.expiresAt) }
            }
            // The door's own ceiling, spent. Named, because "0 left today."
            // beside a hero reading 30 is the lie this verdict exists to kill.
            //
            // Before the `isClosed` branch, for the reason `state(of:)` puts it
            // there: a door that is both closed until 9:00 and capped out has no
            // hour today that helps, and answering 9:00 sends her back at nine
            // for a second refusal. The row promises no lift for exactly this
            // state, and the bar must not promise one either.
            if let r = doorRemaining, r <= 0 {
                return .refuseDoorClosed(door: door,
                                         until: DayBoundary.nextDayStart(after: dayStart,
                                                                         calendar: calendar))
            }
            // A closed door stays closed — for the day, or until its stated
            // hour — and the refusal names the door and the hour. It used to
            // say "0 left today." with the pool untouched beside it, which is
            // false whenever the pool has minutes in it.
            if ledger.isClosed(door.id, at: now, dayStart: dayStart) {
                return .refuseDoorClosed(
                    door: door,
                    until: ledger.closedUntil[door.id]
                        ?? DayBoundary.nextDayStart(after: dayStart, calendar: calendar))
            }
            // Past the ceiling branch `doorRemaining` is at least 1 and the pool
            // is at least 1, so `asked` is at least 1 and the clamp above can
            // never have minted a zero grant.

            // A grant cannot cross into down hours: re-lock is
            // min(now + minutes, downStart), and we debit what was granted.
            // After the cap clamp, and only ever reducing — so the debit still
            // equals what was granted and the edge can never overdraw a ceiling.
            let requestedEnd = now.addingTimeInterval(TimeInterval(asked * 60))
            let edge = nextDownHoursStart(after: now, downHours: state.downHours, calendar: calendar)
            let relock = min(requestedEnd, edge ?? requestedEnd)
            let granted = max(0, Int(relock.timeIntervalSince(now) / 60))
            guard granted > 0 else { return .refuseDownHours(until: state.downHours.end) }
            return .grant(door: door, minutes: granted, relockAt: relock)

        case .addDoor:
            // Understandable, not executable — the same shape as a place-bound
            // ask. The name is all a sentence can carry, and the app behind it
            // comes from Apple's picker, which cannot be raised at the day
            // boundary where a loosening matures; the door would arrive as a
            // name alone, which parses and launches and can never be excepted
            // from the wall. Refused here rather than in the app layer because
            // this is the one point every parser passes, so the model's widened
            // paraphrases meet the same answer the grammar does — and Settings,
            // where the cap and the launch catalogue are checked, stays the
            // only place a door is made.
            return .refuseDoorNeedsApp

        case .setDownHoursEnd(let end):
            // An hour with no am/pm on it, landing on the edge that reads bare
            // hours as mornings. "till 7" is the night's own end and costs
            // nothing; "till 11" reads as 11 AM, four more hours of lockdown,
            // and lands instantly because a longer night is a tightening — when
            // "let me stay up till 11" plainly means 11 PM and the opposite
            // direction. Silk does not pick between them.
            //
            // The test is the direction, not the hour: only a reading that
            // LENGTHENS the night is refused, because that is the one a wrong
            // guess cannot be waited out or taken back. Where it shortens the
            // night or leaves it alone the guess is free, so "till 7" and
            // "til 6:30" are never questioned.
            //
            // Here rather than in the grammar for the reason `addDoor` gives
            // above: this is the one point every parser passes, so the model's
            // widened paraphrases meet the same answer the deterministic
            // reading does. A guess this expensive must not have a way around.
            //
            // P3 FIRST, AND THAT ORDER IS THE FIX. The am/pm question below is
            // keyed to `statedTime(in: utterance)`, so on a sentence carrying no
            // clock at all it found nothing, asked nothing, and fell straight
            // through to `ruleChange` — which is to say it protected only the
            // case where the user DID state the hour, exactly the case that
            // needed it least. "do something about my mornings" states no time,
            // is silent in the grammar, and reaches a widener whose `hour` is
            // only range-checked; a 10:00 end against a 22:00 start is three
            // more hours of lockdown every night, it reads as a tighten, and a
            // tighten lands instantly. The guard now REQUIRES a stated hour and
            // requires it to be the one the command carries — the same reading
            // rule 2 took, with the same `assumeEvening: false` this edge uses,
            // so it stays dead code on the grammar path.
            // MEMBERSHIP, not identity with the first clock. "lock me out from
            // 10pm to 7am" states two hours and a widened end of 07:00 is a
            // correct reading of it; asking only for the first silenced every
            // two-ended window sentence the widener can read.
            guard NumberParser.statedTimes(in: utterance, assumeEvening: false).contains(end),
                  let stated = NumberParser.statedTime(in: utterance, assumeEvening: false)
            else { return .silence }
            if !stated.meridiemWasStated,
               DownHours(start: state.downHours.start, end: end).length > state.downHours.length {
                return .refuseSayAmOrPm(at: end)
            }
            return ruleChange(command, state)

        case .setDoorCap(let door, let minutes):
            // The door must be one of ours, from any parser — the same sanity
            // the spend arm applies to its pair.
            guard state.doors.contains(where: { $0.id == door.id }) else { return .silence }
            if let m = minutes {
                // Zero is not a ceiling, it is a permanent close by rule: no day
                // boundary refills it, `isClosed` knows nothing about it, and it
                // would draw as an ordinary rest that visibly fails to lift in
                // the morning. Silk already has `closeDoorToday` for closing a
                // door, and it has a costume and a lift. Refused here, at the
                // one point every parser and every surface passes, so no later
                // wheel or sentence can reach it.
                guard m > 0 else { return .silence }
                // P3 — provenance, exactly as the spend arm applies it. It is
                // dead code on the grammar path (the number can only have come
                // from `NumberParser.singleNumber`), and it is not dead on the
                // premise this file is built on: "every command from any
                // parser". setDoorCap is the first door-scoped rule change, so a
                // hallucinated (door, minutes) pair writes into a keyed map with
                // no hero number anywhere on screen to contradict it, and under
                // the clamp above a fabricated LOW cap silently shortens every
                // future grant on that door with no sentence to point at.
                guard NumberParser.allNumbers(in: utterance).contains(m) else { return .silence }
            }
            // `minutes: nil` needs no provenance — there is no number to trace —
            // and no refusal: the grammar is its only producer, and the outcome
            // is a loosening that parks, shows on Now, and can be undone.
            return ruleChange(command, state)

        case .setBudget(let minutes):
            // P3 — provenance, exactly as the spend and setDoorCap arms apply
            // it, and it belonged here from the day the widener learned the
            // verb. Dead code on the grammar path: rule 3's number can only
            // have come from `NumberParser.allNumbers`. Live on the premise
            // this file rests on — "every command from any parser" — and the
            // pool is the one field where the model has both the verb and the
            // number handed to it: `ModelAction` carries `setBudget`, and the
            // widener's own instructions state the current budget, so any
            // NUMBERLESS paraphrase ("halve my budget", "my daily limit is way
            // too high, fix it") is silenced by the grammar, reaches the model,
            // and can come back with any Int at all. No adversary is required
            // for that; an adversary makes it worse, and the eval recorded both
            // halves — an injection landing on setBudget, and minutes invented
            // "out of the budget I'd mentioned in the prompt"
            // (docs/market/open-language.md).
            //
            // The direction that hurts is the tighten: a raise parks as a
            // pending, is named on Now and can be undone, while a cut lands
            // instantly with "N left today." as its only receipt.
            //
            // Provenance only, and deliberately not a `> 0` guard beside it:
            // "0 a day" compiles to `setBudget(0)` on the grammar path today,
            // and whether the pool may be zeroed is a product question, not a
            // provenance one. `setDoorCap`'s zero refusal rests on a ceiling of
            // zero being a permanent close by rule, which the pool is not.
            guard NumberParser.allNumbers(in: utterance).contains(minutes) else { return .silence }
            return ruleChange(command, state)

        case .setDownHoursStart(let start):
            // P3 FOR THE CLOCK. The night's start had no guard of any kind, and
            // it is a pure tighten when it moves earlier — so it skips the
            // down-hours defer gate and lands instantly, out of a sentence with
            // no hour in it. "block me earlier in the evenings" names no time,
            // falls silent in the grammar (rule 2 needs a readable clock), and
            // reaches a widener whose `hour` is only range-checked.
            //
            // Equality against the READING, not against the digits: rule 2
            // resolves a bare hour with `assumeEvening: true` on this edge, so
            // "down hours start at ten" is 22:00 and the number 22 appears
            // nowhere in the sentence. Asking `allNumbers` for 22 would silence
            // the canonical sentence; asking `statedTime` the same question the
            // grammar asked, with the same assumption, makes this dead code on
            // the grammar path by construction.
            guard NumberParser.statedTimes(in: utterance, assumeEvening: true).contains(start)
            else { return .silence }
            return ruleChange(command, state)

        case .removeDoor:
            return ruleChange(command, state)
        }
    }

    private static func ruleChange(_ command: Command, _ state: PolicyState) -> Verdict {
        guard let proposed = PolarityEngine.proposedState(applying: command, to: state) else {
            return .silence
        }
        return .ruleChange(proposed: proposed,
                           polarity: PolarityEngine.classify(current: state, proposed: proposed))
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

    /// What Silk would actually GIVE this door right now, if she asked for
    /// everything — the number the wall's subtitle promises.
    ///
    /// It lives here, beside the `.spend` arm, because the wall and the bar
    /// answering the same question with different arithmetic is the exact lie
    /// the subtitle was rewritten to end. Every clamp the arm applies before it
    /// mints a grant is reproduced, in the arm's own order:
    ///
    ///  - down hours, and the **edge**. The edge is the one the shield used to
    ///    miss: at 21:50 against a 22:00 window, a door with 40 in the pool and
    ///    no ceiling can still only be given 10, because `relock` is
    ///    `min(now + asked, nextDownHoursStart)`. The wall promised four times
    ///    what the bar would mint, on the surface she hits first.
    ///  - a close recorded by hand, which refuses outright.
    ///  - the pool, and the door's own ceiling.
    ///
    /// A running grant is deliberately *not* consulted: this answers "what could
    /// I be given", and a door with a live grant is not behind a wall to ask
    /// from. `SilkCoreTests` pins the parity — for every fixture, asking for this
    /// number grants exactly it.
    public static func askableMinutes(door: Door, state: PolicyState, ledger: GrantLedger,
                                      now: Date, dayStart: Date,
                                      calendar: Calendar = .current) -> Int {
        if state.downHours.contains(timeOfDay(now, calendar: calendar)) { return 0 }
        if ledger.isClosed(door.id, at: now, dayStart: dayStart) { return 0 }
        let ceiling = state.doorCaps[door.id].map {
            ledger.remainingMinutes(cap: $0, doorID: door.id, dayStart: dayStart)
        }
        var askable = min(ledger.remainingMinutes(budget: state.budgetMinutes, dayStart: dayStart),
                          ceiling ?? Int.max)
        if let edge = nextDownHoursStart(after: now, downHours: state.downHours, calendar: calendar) {
            askable = min(askable, Int(edge.timeIntervalSince(now) / 60))
        }
        return max(0, askable)
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
