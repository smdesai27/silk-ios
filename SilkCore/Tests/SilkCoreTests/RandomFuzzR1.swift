import Foundation
import Testing
@testable import SilkCore

// Seeded, deterministic randomized fuzzer, round 1. 20,000 generated inputs —
// random unicode garbage plus mutations of the harvested corpus (character
// swaps, splices, repetitions, truncations) — driven through the full
// DeterministicParser → Validator pipeline against a rotating set of fixture
// states. Invariants only: no trap, a well-formed verdict, and never a grant
// past what the state's arithmetic allows. The seed is fixed, so a failure
// line ("FUZZR1-RAND chunk/iter …") reproduces exactly.

// MARK: - Fixtures

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

private let confusingDoors = [
    Door(name: "Instagram"),
    Door(name: "Insta"),
    Door(name: "TikTok"),
    Door(name: "X"),
]

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

private func afternoon() -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 15))!
}

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 29) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
}

private func spentEarlier(_ door: Door, _ minutes: Int) -> Grant {
    let end = afternoon().addingTimeInterval(-600)
    return Grant(door: door, minutes: minutes,
                 issuedAt: end.addingTimeInterval(Double(-minutes) * 60), expiresAt: end)
}

/// The rotation of (state, ledger, clock) the fuzz inputs run against.
private func fuzzFixtures() -> [(PolicyState, GrantLedger, Date)] {
    var spentLedger = GrantLedger()
    spentLedger.record(spentEarlier(tiktok, 10))

    var liveLedger = GrantLedger()
    let issued = at(14, 50)
    liveLedger.record(Grant(door: instagram, minutes: 25, issuedAt: issued,
                            expiresAt: issued.addingTimeInterval(25 * 60)))

    var closedLedger = GrantLedger()
    closedLedger.closeDoor(tiktok, at: afternoon().addingTimeInterval(-600))

    let capped = makeState(caps: [tiktok.id: 10, instagram.id: 10])
    let confusing = PolicyState(budgetMinutes: 40,
                                downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
                                doors: confusingDoors,
                                doorCaps: [confusingDoors[0].id: 10])
    return [
        (makeState(), GrantLedger(), afternoon()),
        (capped, GrantLedger(), afternoon()),
        (capped, spentLedger, afternoon()),
        (makeState(), liveLedger, afternoon()),
        (makeState(), closedLedger, afternoon()),
        (makeState(), GrantLedger(), at(23, 0)),   // inside down hours
        (makeState(), GrantLedger(), at(21, 50)),  // 10 min before the night edge
        (makeState(budget: 0), GrantLedger(), afternoon()),
        (confusing, GrantLedger(), afternoon()),
    ]
}

// MARK: - Deterministic PRNG

/// SplitMix64 — tiny, seedable, platform-stable. `SystemRandomNumberGenerator`
/// would make every failure unreproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
}

// MARK: - Input generation

/// Scalar pools for garbage: ASCII, whitespace/controls, Latin-1, combining
/// marks, Arabic, CJK, emoji, zero-width/bidi controls. All ranges avoid the
/// surrogate block, so every pick is a valid Unicode.Scalar.
private let scalarPools: [[ClosedRange<UInt32>]] = [
    [0x20...0x7E],
    [0x09...0x0D, 0x20...0x20, 0x85...0x85, 0x2028...0x2029, 0xA0...0xA0],
    [0xA1...0xFF],
    [0x300...0x36F],
    [0x600...0x6FF],
    [0x4E00...0x4FFF],
    [0x1F300...0x1F64F],
    [0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064],
    [0x00...0x1F],
]

private func randomGarbage(_ rng: inout SplitMix64) -> String {
    let length = rng.below(81)
    var s = ""
    s.reserveCapacity(length)
    for _ in 0..<length {
        let pool = scalarPools[rng.below(scalarPools.count)]
        let range = pool[rng.below(pool.count)]
        let value = range.lowerBound + UInt32(rng.below(Int(range.upperBound - range.lowerBound) + 1))
        if let scalar = Unicode.Scalar(value) { s.unicodeScalars.append(scalar) }
    }
    return s
}

/// Valid-utterance seeds: the whole harvested corpus. Mutating real sentences
/// walks the parser's edges far better than pure noise.
private let seeds: [String] = ParserCorpus.all

private func mutate(_ rng: inout SplitMix64) -> String {
    var chars = Array(seeds[rng.below(seeds.count)])
    let mutations = 1 + rng.below(3)
    for _ in 0..<mutations where !chars.isEmpty {
        switch rng.below(6) {
        case 0: // transpose two adjacent characters
            if chars.count >= 2 {
                let i = rng.below(chars.count - 1)
                chars.swapAt(i, i + 1)
            }
        case 1: // delete one character
            chars.remove(at: rng.below(chars.count))
        case 2: // insert a random ASCII or garbage character
            let pool = scalarPools[rng.below(scalarPools.count)]
            let range = pool[rng.below(pool.count)]
            let value = range.lowerBound + UInt32(rng.below(Int(range.upperBound - range.lowerBound) + 1))
            if let scalar = Unicode.Scalar(value) {
                chars.insert(Character(scalar), at: rng.below(chars.count + 1))
            }
        case 3: // duplicate a slice in place
            let start = rng.below(chars.count)
            let end = min(chars.count, start + 1 + rng.below(8))
            chars.insert(contentsOf: chars[start..<end], at: end)
        case 4: // truncate
            chars.removeLast(rng.below(chars.count))
        default: // flip the case of one character
            let i = rng.below(chars.count)
            let flipped = String(chars[i])
            chars.replaceSubrange(i...i, with: flipped == flipped.lowercased()
                ? flipped.uppercased() : flipped.lowercased())
        }
    }
    return String(chars)
}

private func splice(_ rng: inout SplitMix64) -> String {
    let a = seeds[rng.below(seeds.count)]
    let b = seeds[rng.below(seeds.count)]
    let cutA = a.index(a.startIndex, offsetBy: rng.below(a.count + 1))
    let cutB = b.index(b.startIndex, offsetBy: rng.below(b.count + 1))
    return String(a[..<cutA]) + String(b[cutB...])
}

private func repetition(_ rng: inout SplitMix64) -> String {
    let unit = seeds[rng.below(seeds.count)]
    guard !unit.isEmpty else { return unit }
    let times = 2 + rng.below(6)
    let joiner = [" ", ", ", ". ", "\n", ""][rng.below(5)]
    var s = ""
    for _ in 0..<times where s.count < 400 {
        s += (s.isEmpty ? "" : joiner) + unit
    }
    return s
}

private func makeInput(_ rng: inout SplitMix64, _ i: Int) -> String {
    switch i % 4 {
    case 0: return randomGarbage(&rng)
    case 1, 2: return mutate(&rng)
    default: return rng.below(2) == 0 ? splice(&rng) : repetition(&rng)
    }
}

// MARK: - Invariant

private func sanitize(_ s: String, limit: Int = 90) -> String {
    let printable = s.unicodeScalars.prefix(limit).map { sc -> String in
        (0x20...0x7E).contains(Int(sc.value)) ? String(Character(sc)) : "\\u{\(String(sc.value, radix: 16))}"
    }.joined()
    return s.unicodeScalars.count > limit ? printable + "…(\(s.count) chars)" : printable
}

/// Runs one input through the pipeline and checks the invariants. Returns a
/// reason string on violation, nil when everything held.
private func violation(utterance: String, state: PolicyState,
                       ledger: GrantLedger, now: Date) -> String? {
    let outcome = DeterministicParser.parse(utterance, state: state)
    let verdict = Validator.validate(outcome, utterance: utterance, state: state,
                                     ledger: ledger, now: now, calendar: cal)
    let dayStart = DayBoundary.dayStart(now: now, downHours: state.downHours, calendar: cal)

    switch verdict {
    case .grant(let door, let minutes, let relockAt):
        guard state.doors.contains(where: { $0.id == door.id }) else {
            return "grant on a door the state does not have (\(door.name))"
        }
        guard minutes > 0 else { return "non-positive grant (\(minutes))" }
        let pool = ledger.remainingMinutes(budget: state.budgetMinutes, dayStart: dayStart)
        guard minutes <= pool else { return "grant \(minutes) exceeds pool \(pool)" }
        if let cap = state.doorCaps[door.id] {
            let capLeft = ledger.remainingMinutes(cap: cap, doorID: door.id, dayStart: dayStart)
            guard minutes <= capLeft else {
                return "grant \(minutes) exceeds cap remaining \(capLeft) on \(door.name)"
            }
        }
        guard relockAt > now else { return "relock \(relockAt) not after now" }
        guard !state.downHours.contains(Validator.timeOfDay(now, calendar: cal)) else {
            return "grant minted inside down hours"
        }
        // The minted minutes must equal the open interval they buy.
        let interval = Int(relockAt.timeIntervalSince(now) / 60)
        guard interval == minutes else {
            return "grant of \(minutes) buys \(interval) open minutes"
        }
    case .closeAll(let doors, let until):
        guard doors == state.doors else { return "closeAll doors differ from the state's" }
        guard until > now else { return "closeAll lifts in the past" }
    case .close(_, let until):
        guard until > now else { return "close lifts in the past" }
    case .restated(_, let until):
        guard until > now else { return "restated a deadline already past" }
    case .status(let remaining):
        guard remaining >= 0 else { return "negative status \(remaining)" }
    case .ruleChange(let proposed, _):
        guard proposed.doors.count <= state.doors.count + 1 else {
            return "rule change invented \(proposed.doors.count - state.doors.count) doors"
        }
        guard proposed.budgetMinutes >= 0 else { return "negative proposed budget" }
    case .downHours, .refuseNothingLeft, .refuseDownHours, .refuseWriteItOut,
         .refuseSayAmOrPm, .refuseDoorNeedsApp, .refuseDoorClosed, .silence:
        break  // refusals and silence are always well-formed
    }
    return nil
}

// MARK: - The fuzz test

@Suite("Random fuzz R1")
struct RandomFuzzR1 {

    static let iterationsPerChunk = 5000
    static let chunks: [UInt64] = [0, 1, 2, 3]  // 4 × 5000 = 20,000 inputs

    @Test(arguments: chunks)
    func fuzz(_ chunk: UInt64) {
        // Fixed seed, derived per chunk — every run generates the same inputs.
        var rng = SplitMix64(seed: 0xF00D_2026_0805_51C4 &+ chunk &* 0x9E37_79B9)
        let fixtures = fuzzFixtures()
        let start = Date()
        var failures: [String] = []

        for i in 0..<Self.iterationsPerChunk {
            let input = makeInput(&rng, i)
            let (state, ledger, now) = fixtures[rng.below(fixtures.count)]
            if let why = violation(utterance: input, state: state, ledger: ledger, now: now) {
                failures.append("FUZZR1-RAND \(chunk)/\(i): \(why) | utterance=\(sanitize(input))")
                if failures.count >= 20 { break }  // enough to diagnose; stay readable
            }
        }

        for f in failures { Issue.record("\(f)") }
        #expect(failures.isEmpty)

        // No-hang guard: 5000 inputs through the full pipeline must stay fast.
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 120, "fuzz chunk \(chunk) took \(elapsed)s")
    }
}
