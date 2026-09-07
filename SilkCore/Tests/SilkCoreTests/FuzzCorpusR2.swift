import Foundation
import Testing
@testable import SilkCore

// Fuzz-corpus runner, round 2 (round-3 corpora: breakfixes + statetorture).
// Every row of FuzzCorpusR2Data.swift is driven through the real pipeline —
// DeterministicParser.parse → Validator.validate — with its stated state and
// clock precondition, and the outcome is compared against the expectation
// mini-grammar. Rows whose spec cannot be interpreted are skipped loudly
// (FUZZR2-SKIP on stdout), never guessed at.
//
// The interpreter below is a faithful copy of FuzzCorpusR1.swift's — the R1
// helpers are all file-private there and the R1 files are frozen, so the
// machinery is duplicated verbatim rather than modified. FuzzCorpusRow itself
// is reused from FuzzCorpusR1Data.swift.

// MARK: - Fixtures (the canonical shapes from SilkCoreTests/StressTests)

private let instagram = Door(name: "Instagram")
private let tiktok = Door(name: "TikTok")
private let reddit = Door(name: "Reddit")
private let youtube = Door(name: "YouTube")

private func makeState(budget: Int = 40, caps: [UUID: Int] = [:]) -> PolicyState {
    PolicyState(budgetMinutes: budget,
                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                doors: [instagram, tiktok, reddit, youtube],
                doorCaps: caps)
}

private func makeCappedState(budget: Int = 40) -> PolicyState {
    makeState(budget: budget, caps: [tiktok.id: 10, instagram.id: 10])
}

/// Doors whose spoken forms collide with each other and with the plain
/// fixtures' aliases — the third state NO_CRASH_ONLY rows run against.
private let confusingDoors = [
    Door(name: "Instagram"),
    Door(name: "Insta"),
    Door(name: "TikTok"),
    Door(name: "X"),
]

private func makeConfusingState() -> PolicyState {
    PolicyState(budgetMinutes: 40,
                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                doors: confusingDoors,
                doorCaps: [confusingDoors[0].id: 10])
}

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

/// Fixed 2026-07-29 15:00 America/New_York.
private func afternoon() -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 15))!
}

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 29) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
}

/// An already-expired grant issued today: moves shared + per-door spend,
/// never restates. Anchored just before the row's effective clock.
private func spentEarlier(_ door: Door, _ minutes: Int, before now: Date) -> Grant {
    let end = now.addingTimeInterval(-600)
    return Grant(door: door, minutes: minutes,
                 issuedAt: end.addingTimeInterval(Double(-minutes) * 60), expiresAt: end)
}

// MARK: - Spec mini-grammar interpreter

private struct SpecError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

private func fixtureDoor(_ name: String) throws -> Door {
    switch name.lowercased() {
    case "instagram": return instagram
    case "tiktok": return tiktok
    case "reddit": return reddit
    case "youtube": return youtube
    default: throw SpecError(reason: "unknown fixture door '\(name)'")
    }
}

private func specInt(_ s: String) throws -> Int {
    guard let n = Int(s) else { throw SpecError(reason: "not an int '\(s)'") }
    return n
}

private func specTime(_ s: String) throws -> TimeOfDay {
    let parts = s.split(separator: ":")
    guard (1...2).contains(parts.count), let h = Int(parts[0]) else {
        throw SpecError(reason: "not a time '\(s)'")
    }
    let m = parts.count == 2 ? try specInt(String(parts[1])) : 0
    return TimeOfDay(hour: h, minute: m)
}

/// "{tiktok:10,instagram:10}" → [(door, 10), (door, 10)]
private func doorIntMap(_ s: String) throws -> [(Door, Int)] {
    guard s.hasPrefix("{"), s.hasSuffix("}") else { throw SpecError(reason: "bad map '\(s)'") }
    return try s.dropFirst().dropLast().split(separator: ",").map { entry in
        let kv = entry.split(separator: ":", maxSplits: 1)
        guard kv.count == 2 else { throw SpecError(reason: "bad map entry '\(entry)'") }
        return (try fixtureDoor(String(kv[0])), try specInt(String(kv[1])))
    }
}

/// "{instagram}" or "{instagram@18:00}" → [(door, liftTime?)]
private func closedList(_ s: String) throws -> [(Door, TimeOfDay?)] {
    guard s.hasPrefix("{"), s.hasSuffix("}") else { throw SpecError(reason: "bad closed '\(s)'") }
    return try s.dropFirst().dropLast().split(separator: ",").map { entry in
        let parts = entry.split(separator: "@", maxSplits: 1)
        let door = try fixtureDoor(String(parts[0]))
        let t = parts.count == 2 ? try specTime(String(parts[1])) : nil
        return (door, t)
    }
}

/// "{tiktok:30@14:50}" → [(door, minutes, issuedAt time)]
private func liveList(_ s: String) throws -> [(Door, Int, TimeOfDay)] {
    guard s.hasPrefix("{"), s.hasSuffix("}") else { throw SpecError(reason: "bad live '\(s)'") }
    return try s.dropFirst().dropLast().split(separator: ",").map { entry in
        let byAt = entry.split(separator: "@", maxSplits: 1)
        guard byAt.count == 2 else { throw SpecError(reason: "bad live entry '\(entry)'") }
        let kv = byAt[0].split(separator: ":", maxSplits: 1)
        guard kv.count == 2 else { throw SpecError(reason: "bad live entry '\(entry)'") }
        return (try fixtureDoor(String(kv[0])), try specInt(String(kv[1])), try specTime(String(byAt[1])))
    }
}

private struct BuiltCase {
    var state: PolicyState
    var ledger: GrantLedger
    var now: Date
    /// True when the row stated any explicit precondition (state or clock).
    var explicit: Bool
}

/// Splits the row's expect + state fields into the expectation head and the
/// built (state, ledger, now) the row runs under.
private func build(_ row: FuzzCorpusRow) throws -> (head: String, built: BuiltCase) {
    var fragments: [String] = []
    let expectParts = row.expect.components(separatedBy: ";")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let head = expectParts[0]
    fragments += expectParts.dropFirst()
    if let s = row.stateSpec {
        fragments += s.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var budget = 40
    var caps: [UUID: Int] = [:]
    var spent: [(Door, Int)] = []
    var closed: [(Door, TimeOfDay?)] = []
    var live: [(Door, Int, TimeOfDay)] = []
    var now = afternoon()
    var explicit = false

    for frag in fragments where !frag.isEmpty {
        explicit = true
        if frag.hasPrefix("now=") {
            // "now=23:00" (an optional "/DAY" suffix is allowed by the grammar
            // but unused by these corpora — day defaults to the fixture day).
            let body = String(frag.dropFirst(4)).components(separatedBy: "/")
            let t = try specTime(body[0])
            guard body.count == 1 else { throw SpecError(reason: "day-qualified now '\(frag)'") }
            now = at(t.hour, t.minute)
        } else if frag.hasPrefix("state:") {
            for tok in frag.dropFirst(6).split(separator: " ") {
                let kv = tok.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { throw SpecError(reason: "bad state token '\(tok)'") }
                switch String(kv[0]) {
                case "budget": budget = try specInt(String(kv[1]))
                case "caps": for (d, n) in try doorIntMap(String(kv[1])) { caps[d.id] = n }
                case "spent": spent += try doorIntMap(String(kv[1]))
                case "closed": closed += try closedList(String(kv[1]))
                case "live": live += try liveList(String(kv[1]))
                default: throw SpecError(reason: "unknown state key '\(kv[0])'")
                }
            }
        } else {
            throw SpecError(reason: "unknown fragment '\(frag)'")
        }
    }

    let state = makeState(budget: budget, caps: caps)
    var ledger = GrantLedger()
    for (d, n) in spent { ledger.record(spentEarlier(d, n, before: now)) }
    for (d, n, t) in live {
        let issued = at(t.hour, t.minute)
        ledger.record(Grant(door: d, minutes: n, issuedAt: issued,
                            expiresAt: issued.addingTimeInterval(Double(n) * 60)))
    }
    for (d, t) in closed {
        ledger.closeDoor(d, at: now.addingTimeInterval(-600), until: t.map { at($0.hour, $0.minute) })
    }
    return (head, BuiltCase(state: state, ledger: ledger, now: now, explicit: explicit))
}

// MARK: - Rendering (for failure messages)

private func fmt(_ t: TimeOfDay) -> String { String(format: "%d:%02d", t.hour, t.minute) }

private func fmt(_ d: Date) -> String {
    let c = cal.dateComponents([.month, .day, .hour, .minute], from: d)
    return String(format: "%02d-%02d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
}

private func render(_ o: ParseOutcome) -> String {
    switch o {
    case .silence: return "UNPARSED-to-widener"
    case .writeItOut(let d, let m):
        return "WRITE_IT_OUT door=\(d.name) minutes=\(m.map(String.init) ?? "none")"
    case .command(let c):
        switch c {
        case .spend(let d, let m): return "SPEND(\(d.name), \(m))"
        case .closeDoorToday(let d, let u): return "CLOSE(\(d.name), until: \(u.map(fmt) ?? "nil"))"
        case .closeAllToday(let u): return "CLOSE_ALL(until: \(u.map(fmt) ?? "nil"))"
        case .setBudget(let m): return "SET_BUDGET(\(m))"
        case .setDownHoursStart(let t): return "SET_DOWN_START(\(fmt(t)))"
        case .setDownHoursEnd(let t): return "SET_DOWN_END(\(fmt(t)))"
        case .addDoor(let n): return "ADD_DOOR(\(n))"
        case .removeDoor(let d): return "REMOVE_DOOR(\(d.name))"
        case .setDoorCap(let d, let m): return "SET_CAP(\(d.name), \(m.map(String.init) ?? "none"))"
        case .status: return "STATUS"
        case .downHoursQuery: return "DOWN_HOURS_QUERY"
        }
    }
}

private func render(_ v: Verdict) -> String {
    switch v {
    case .grant(let d, let m, let r): return "GRANT(\(d.name), \(m), relock \(fmt(r)))"
    case .restated(let d, let u): return "RESTATED(\(d.name), until \(fmt(u)))"
    case .ruleChange(let p, let pol):
        let caps = p.doors.compactMap { d in p.doorCaps[d.id].map { "\(d.name):\($0)" } }
            .sorted().joined(separator: ",")
        return "RULE_CHANGE(\(pol), budget \(p.budgetMinutes), "
            + "down \(fmt(p.downHours.start))-\(fmt(p.downHours.end)), "
            + "doors [\(p.doors.map(\.name).joined(separator: ","))], caps {\(caps)})"
    case .close(let d, let u): return "CLOSE(\(d.name), until \(fmt(u)))"
    case .closeAll(let ds, let u):
        return "CLOSE_ALL([\(ds.map(\.name).joined(separator: ","))], until \(fmt(u)))"
    case .status(let r): return "STATUS(remaining \(r))"
    case .downHours(let w): return "DOWN_HOURS(\(fmt(w.start))-\(fmt(w.end)))"
    case .refuseNothingLeft: return "REFUSE_NOTHING_LEFT"
    case .refuseDownHours(let u): return "REFUSE_DOWN_HOURS(until \(fmt(u)))"
    case .refuseWriteItOut(let d, let m):
        return "WRITE_IT_OUT door=\(d.name) minutes=\(m.map(String.init) ?? "none")"
    case .refuseSayAmOrPm(let t): return "REFUSE_AM_OR_PM(at \(fmt(t)))"
    case .refuseDoorNeedsApp: return "REFUSE_DOOR_NEEDS_APP"
    case .refuseDoorClosed(let d, let u): return "REFUSE_DOOR_CLOSED(\(d.name), until \(fmt(u)))"
    case .silence: return "SILENCE"
    }
}

private func sanitize(_ s: String, limit: Int = 90) -> String {
    let printable = s.unicodeScalars.prefix(limit).map { sc -> String in
        (0x20...0x7E).contains(Int(sc.value)) ? String(Character(sc)) : "\\u{\(String(sc.value, radix: 16))}"
    }.joined()
    return s.unicodeScalars.count > limit ? printable + "…(\(s.count) chars)" : printable
}

// MARK: - Head evaluation

/// Key=value tokens of a spec head, after the leading kind word.
private func headTokens(_ spec: String) -> (kind: String, kv: [String: String], positional: [String]) {
    let tokens = spec.split(separator: " ").map(String.init)
    var kv: [String: String] = [:]
    var positional: [String] = []
    for t in tokens.dropFirst() {
        if let eq = t.firstIndex(of: "=") {
            kv[String(t[t.startIndex..<eq])] = String(t[t.index(after: eq)...])
        } else {
            positional.append(t)
        }
    }
    return (tokens.first ?? "", kv, positional)
}

private func req(_ kv: [String: String], _ key: String) throws -> String {
    guard let v = kv[key] else { throw SpecError(reason: "missing \(key)=") }
    return v
}

/// PARSE-level expectation → the exact ParseOutcome it names.
private func expectedOutcome(_ head: String) throws -> ParseOutcome {
    let spec = String(head.dropFirst("PARSE".count)).trimmingCharacters(in: .whitespaces)
    if spec == "UNPARSED-to-widener" { return .silence }
    let (kind, kv, positional) = headTokens(spec)
    switch kind {
    case "SPEND":
        return .command(.spend(door: try fixtureDoor(req(kv, "door")),
                               minutes: try specInt(req(kv, "minutes"))))
    case "WRITE_IT_OUT":
        // `minutes=none` is the shape `render` prints for a sentence that
        // named a door and no duration, so a re-pinned row round-trips.
        let spelled = kv["minutes"] ?? "none"
        return .writeItOut(door: try fixtureDoor(req(kv, "door")),
                           minutes: spelled == "none" ? nil : try specInt(spelled))
    case "CLOSE":
        return .command(.closeDoorToday(door: try fixtureDoor(req(kv, "door")),
                                        until: try kv["until"].map(specTime)))
    case "CLOSE_ALL":
        return .command(.closeAllToday(until: try kv["until"].map(specTime)))
    case "SET_BUDGET":
        return .command(.setBudget(minutes: try specInt(req(kv, "minutes"))))
    case "SET_DOWN_START":
        guard let t = positional.first else { throw SpecError(reason: "SET_DOWN_START needs a time") }
        return .command(.setDownHoursStart(try specTime(t)))
    case "SET_DOWN_END":
        guard let t = positional.first else { throw SpecError(reason: "SET_DOWN_END needs a time") }
        return .command(.setDownHoursEnd(try specTime(t)))
    case "ADD_DOOR":
        return .command(.addDoor(name: try req(kv, "name")))
    case "REMOVE_DOOR":
        return .command(.removeDoor(door: try fixtureDoor(req(kv, "door"))))
    case "SET_CAP":
        return .command(.setDoorCap(door: try fixtureDoor(req(kv, "door")),
                                    minutes: try specInt(req(kv, "minutes"))))
    case "CLEAR_CAP":
        return .command(.setDoorCap(door: try fixtureDoor(req(kv, "door")), minutes: nil))
    case "STATUS":
        return .command(.status)
    case "DOWN_HOURS_QUERY":
        return .command(.downHoursQuery)
    default:
        throw SpecError(reason: "unknown PARSE kind '\(kind)'")
    }
}

/// VERDICT-level expectation. Returns nil on match, otherwise
/// "expected=… actual=…" for the failure report.
private func verdictMismatch(_ row: FuzzCorpusRow, head: String, built: BuiltCase) throws -> String? {
    let outcome = DeterministicParser.parse(row.utterance, state: built.state)
    let actual = Validator.validate(outcome, utterance: row.utterance, state: built.state,
                                    ledger: built.ledger, now: built.now, calendar: cal)
    let spec = String(head.dropFirst("VERDICT".count)).trimmingCharacters(in: .whitespaces)
    let (kind, kv, positional) = headTokens(spec)

    let dayStart = DayBoundary.dayStart(now: built.now, downHours: built.state.downHours, calendar: cal)
    let boundary = DayBoundary.nextDayStart(after: dayStart, calendar: cal)

    // "day-boundary", or a stated hour's next occurrence capped at the boundary.
    func resolveUntil(_ s: String) throws -> Date {
        if s == "day-boundary" { return boundary }
        let t = try specTime(s)
        var candidate = at(t.hour, t.minute)
        if candidate <= built.now {
            guard let bumped = cal.date(byAdding: .day, value: 1, to: candidate) else {
                throw SpecError(reason: "date arithmetic failed for '\(s)'")
            }
            candidate = bumped
        }
        return min(candidate, boundary)
    }

    func fail(_ expected: String) -> String {
        "expected=\(expected) actual=\(render(actual))"
    }

    switch kind {
    case "GRANT":
        let ed = try fixtureDoor(req(kv, "door"))
        let em = try specInt(req(kv, "minutes"))
        guard case .grant(let d, let m, let relock) = actual else {
            return fail("GRANT(\(ed.name), \(em))")
        }
        guard d.id == ed.id, m == em else { return fail("GRANT(\(ed.name), \(em))") }
        if let r = kv["relock"] {
            let expectedRelock: Date
            if r.hasPrefix("+"), r.hasSuffix("m") {
                expectedRelock = built.now.addingTimeInterval(Double(try specInt(String(r.dropFirst().dropLast()))) * 60)
            } else {
                let t = try specTime(r)
                expectedRelock = at(t.hour, t.minute)
            }
            guard relock == expectedRelock else {
                return fail("GRANT(\(ed.name), \(em), relock \(fmt(expectedRelock)))")
            }
        }
        return nil

    case "RESTATED":
        let t = try specTime(req(kv, "until"))
        let expected = Verdict.restated(door: try fixtureDoor(req(kv, "door")),
                                        until: at(t.hour, t.minute))
        return actual == expected ? nil : fail(render(expected))

    case "RULE_CHANGE":
        let polarity: Polarity
        switch try req(kv, "polarity") {
        case "tighten": polarity = .tighten
        case "loosen": polarity = .loosen
        case "unchanged": polarity = .unchanged
        default: throw SpecError(reason: "unknown polarity")
        }
        guard case .ruleChange(let proposed, let actualPolarity) = actual else {
            return fail("RULE_CHANGE(\(spec))")
        }
        guard actualPolarity == polarity else { return fail("RULE_CHANGE(\(spec))") }
        for (key, value) in kv where key != "polarity" {
            switch key {
            case "budget":
                guard proposed.budgetMinutes == (try specInt(value)) else {
                    return fail("RULE_CHANGE(\(spec))")
                }
            case "downStart":
                guard proposed.downHours.start == (try specTime(value)) else {
                    return fail("RULE_CHANGE(\(spec))")
                }
            case "downEnd":
                guard proposed.downHours.end == (try specTime(value)) else {
                    return fail("RULE_CHANGE(\(spec))")
                }
            case "doors-":
                let d = try fixtureDoor(value)
                guard !proposed.doors.contains(where: { $0.id == d.id }) else {
                    return fail("RULE_CHANGE(\(spec))")
                }
            default:
                guard key.hasPrefix("cap["), key.hasSuffix("]") else {
                    throw SpecError(reason: "unknown RULE_CHANGE key '\(key)'")
                }
                let d = try fixtureDoor(String(key.dropFirst(4).dropLast()))
                let expectedCap: Int? = value == "none" ? nil : try specInt(value)
                guard proposed.doorCaps[d.id] == expectedCap else {
                    return fail("RULE_CHANGE(\(spec))")
                }
            }
        }
        return nil

    case "CLOSE":
        let expected = Verdict.close(door: try fixtureDoor(req(kv, "door")),
                                     until: try resolveUntil(req(kv, "until")))
        return actual == expected ? nil : fail(render(expected))

    case "CLOSE_ALL":
        let expected = Verdict.closeAll(doors: built.state.doors,
                                        until: try resolveUntil(req(kv, "until")))
        return actual == expected ? nil : fail(render(expected))

    case "STATUS":
        let expected = Verdict.status(remaining: try specInt(req(kv, "remaining")))
        return actual == expected ? nil : fail(render(expected))

    case "DOWN_HOURS":
        guard let range = positional.first else { throw SpecError(reason: "DOWN_HOURS needs T-T") }
        let ends = range.split(separator: "-")
        guard ends.count == 2 else { throw SpecError(reason: "bad DOWN_HOURS '\(range)'") }
        let expected = Verdict.downHours(DownHours(start: try specTime(String(ends[0])),
                                                   end: try specTime(String(ends[1]))))
        return actual == expected ? nil : fail(render(expected))

    case "REFUSE_NOTHING_LEFT":
        return actual == .refuseNothingLeft ? nil : fail("REFUSE_NOTHING_LEFT")

    case "REFUSE_DOWN_HOURS":
        let expected = Verdict.refuseDownHours(until: try specTime(req(kv, "until")))
        return actual == expected ? nil : fail(render(expected))

    case "WRITE_IT_OUT":
        let spelled = kv["minutes"] ?? "none"
        let expected = Verdict.refuseWriteItOut(
            door: try fixtureDoor(req(kv, "door")),
            minutes: spelled == "none" ? nil : try specInt(spelled))
        return actual == expected ? nil : fail(render(expected))

    case "REFUSE_AM_OR_PM":
        let expected = Verdict.refuseSayAmOrPm(at: try specTime(req(kv, "at")))
        return actual == expected ? nil : fail(render(expected))

    case "REFUSE_DOOR_NEEDS_APP":
        return actual == .refuseDoorNeedsApp ? nil : fail("REFUSE_DOOR_NEEDS_APP")

    case "REFUSE_DOOR_CLOSED":
        let expected = Verdict.refuseDoorClosed(door: try fixtureDoor(req(kv, "door")),
                                                until: try resolveUntil(req(kv, "until")))
        return actual == expected ? nil : fail(render(expected))

    case "SILENCE":
        return actual == .silence ? nil : fail("SILENCE")

    default:
        throw SpecError(reason: "unknown VERDICT kind '\(kind)'")
    }
}

// MARK: - Invariant heads

/// NEVER_LOOSEN: on the plain AND the capped state (and any explicitly stated
/// one), the pipeline must yield neither a grant nor a loosening rule change.
private func neverLoosenViolation(_ row: FuzzCorpusRow, built: BuiltCase) -> String? {
    var configs: [(String, PolicyState, GrantLedger, Date)] = [
        ("plain", makeState(), GrantLedger(), afternoon()),
        ("capped", makeCappedState(), GrantLedger(), afternoon()),
    ]
    if built.explicit { configs.append(("stated", built.state, built.ledger, built.now)) }
    for (label, state, ledger, now) in configs {
        let v = Validator.validate(DeterministicParser.parse(row.utterance, state: state),
                                   utterance: row.utterance, state: state,
                                   ledger: ledger, now: now, calendar: cal)
        if case .grant = v {
            return "expected=no-grant-no-loosen actual=\(render(v)) on \(label) state"
        }
        if case .ruleChange(_, .loosen) = v {
            return "expected=no-grant-no-loosen actual=\(render(v)) on \(label) state"
        }
    }
    return nil
}

/// NO_CRASH_ONLY: parse+validate on the plain, capped and confusing-doors
/// states (plus any explicitly stated one). Any outcome is legal as long as
/// nothing traps and a grant stays inside the arithmetic the state allows.
private func noCrashViolation(_ row: FuzzCorpusRow, built: BuiltCase) -> String? {
    var configs: [(String, PolicyState, GrantLedger, Date)] = [
        ("plain", makeState(), GrantLedger(), built.now),
        ("capped", makeCappedState(), GrantLedger(), built.now),
        ("confusing", makeConfusingState(), GrantLedger(), built.now),
    ]
    if built.explicit { configs.append(("stated", built.state, built.ledger, built.now)) }
    for (label, state, ledger, now) in configs {
        let v = Validator.validate(DeterministicParser.parse(row.utterance, state: state),
                                   utterance: row.utterance, state: state,
                                   ledger: ledger, now: now, calendar: cal)
        if case .grant(let d, let m, let relock) = v {
            let dayStart = DayBoundary.dayStart(now: now, downHours: state.downHours, calendar: cal)
            let pool = ledger.remainingMinutes(budget: state.budgetMinutes, dayStart: dayStart)
            if m <= 0 { return "expected=positive-grant actual=\(render(v)) on \(label)" }
            if m > pool { return "expected=grant≤pool(\(pool)) actual=\(render(v)) on \(label)" }
            if let cap = state.doorCaps[d.id] {
                let capLeft = ledger.remainingMinutes(cap: cap, doorID: d.id, dayStart: dayStart)
                if m > capLeft { return "expected=grant≤cap(\(capLeft)) actual=\(render(v)) on \(label)" }
            }
            if relock <= now { return "expected=future-relock actual=\(render(v)) on \(label)" }
        }
    }
    return nil
}

// MARK: - The runner

/// Shared row driver for the R2 and R3 suites. `tag` prefixes the skip/fail
/// markers (FUZZR2-SKIP / FUZZR3-FAIL etc.) so grep stays per-suite.
private func runRow(_ row: FuzzCorpusRow, tag: String) {
    let mismatch: String?
    do {
        let (head, built) = try build(row)
        if head.hasPrefix("PARSE") {
            let expected = try expectedOutcome(head)
            let actual = DeterministicParser.parse(row.utterance, state: built.state)
            mismatch = actual == expected
                ? nil : "expected=\(render(expected)) actual=\(render(actual))"
        } else if head.hasPrefix("VERDICT") {
            mismatch = try verdictMismatch(row, head: head, built: built)
        } else if head == "NEVER_LOOSEN" {
            mismatch = neverLoosenViolation(row, built: built)
        } else if head == "NO_CRASH_ONLY" {
            mismatch = noCrashViolation(row, built: built)
        } else {
            throw SpecError(reason: "unknown head '\(head)'")
        }
    } catch let error as SpecError {
        // Not mechanizable — skipped, never guessed. Grep <tag>-SKIP.
        print("\(tag)-SKIP \(row.source)#\(row.index): \(error.reason)")
        return
    } catch {
        print("\(tag)-SKIP \(row.source)#\(row.index): \(error)")
        return
    }
    if let mismatch {
        Issue.record("\(tag)-FAIL \(row.source)#\(row.index) | utterance=\(sanitize(row.utterance)) | \(mismatch)")
    }
}

@Suite("Fuzz corpus R2")
struct FuzzCorpusR2 {

    @Test(arguments: FuzzCorpusR2Data.rows)
    func row(_ row: FuzzCorpusRow) {
        runRow(row, tag: "FUZZR2")
    }
}

// Round-3 conversation corpus (corpus-r3-conversation.json): run-ons,
// self-corrections, sign-offs, questions, negations, reported speech.
// Same spec mini-grammar, same interpreter, separate suite and grep tag.
@Suite("Fuzz corpus R3")
struct FuzzCorpusR3 {

    @Test(arguments: FuzzCorpusR3Data.rows)
    func row(_ row: FuzzCorpusRow) {
        runRow(row, tag: "FUZZR3")
    }
}
