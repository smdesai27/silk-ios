import Foundation
@testable import SilkCore

// THE FIXTURES THIS SUITE ACTUALLY SHARES, IN ONE FILE.
//
// Twenty-six test files opened with the same twenty lines. Four doors declared
// sixty-six times, the night window thirteen, the New York calendar twenty-two,
// and `makeState` in five byte-identical copies — every one of them `private`,
// so the compiler could not see that they were the same thing and nobody
// grepping for "the fixture" could find which one a test was reading.
//
// The cost is not the duplication. It is that the copies DRIFT, silently and in
// the one direction that matters: a fixture is what a test's assertion is
// measured against, so two files that believe they share a fixture and do not
// are two files whose failures mean different things. The census that produced
// this file found three door orders in the wild for what was described in every
// case as "the four doors", and rule 10 hands a doorless fragment THE FIRST
// DOOR — so the order is not decoration, it is an input.
//
// WHAT DOES NOT LIVE HERE. A fixture that differs on purpose stays in its own
// file and is RENAMED to say so — `capsAt`, `durationState`, `widenerState`,
// `spendShapeState`, `dstState`, `establishedAt`, `relockAt`. That is not
// politeness: a top-level `let` here and a file-private `let` of the same name
// there is an invalid redeclaration, not a shadow, so the compiler makes the
// choice explicit whether or not anybody wants it to. A file that keeps its own
// clock has to say which clock it is, in the name, at every call site.

// MARK: - The doors
//
// ONE instance each, module-wide. `Door` carries a fresh `UUID` per
// initialization and identity is by id, so a per-file copy of "Instagram" was
// not the same door as another file's — which is invisible while a test only
// reads `door.name`, and load-bearing the moment one reads `doorCaps[door.id]`.

let instagram = Door(name: "Instagram")
let tiktok = Door(name: "TikTok")
let reddit = Door(name: "Reddit")
let youtube = Door(name: "YouTube")

// MARK: - The clocks

/// The night window every fixture but the DST and far-edge suites runs under:
/// 22:00 to 07:00, so the Silk day begins at seven in the morning.
let night = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))

/// America/New_York, gregorian. Chosen so both 2026 DST nights are reachable
/// and so a UTC-offset assumption cannot hide in a passing test.
var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

/// A fixed afternoon: 2026-07-29 15:00 local — outside the night window, so a
/// verdict that is held back is held back by the sentence and never by the
/// hour. A `func` and not a `let` because that is the spelling twenty call
/// sites already used.
func afternoon() -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 15))!
}

/// A 2026 instant, month and day first. The shape seven of the day-boundary
/// suites already wrote, kept positional so their call sites read unchanged.
///
/// The name is `at` and nothing else's is, because five different `at(…)`
/// signatures were in the suite and three of them took an hour first: `at(6,
/// 10, 7)` meant June 10th 07:00 in one file and 6:10 AM on the 7th in
/// another. Nothing catches that — both compile, both return a Date, and the
/// test goes green against the wrong day. Every other shape is renamed for the
/// clock it actually reads (`capsAt`, `establishedAt`, `julyAt`, `relockAt`).
func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day,
                                  hour: hour, minute: minute))!
}

/// July 2026, hour first, defaulting to the 29th — the clock the stress and
/// fuzz suites keep, where every row is an hour on `afternoon()`'s own day.
func julyAt(_ hour: Int, _ minute: Int = 0, day: Int = 29) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: day,
                                  hour: hour, minute: minute))!
}

// MARK: - The states

/// The four doors, the night, and forty minutes. The default door ORDER is
/// `[instagram, tiktok, reddit, youtube]`, and it is part of the fixture rather
/// than an accident of typing: rule 10 answers a doorless fragment with the
/// FIRST door, so every "10 minutes" row in the suite is pinned to Instagram by
/// this line.
func makeState(budget: Int = 40,
               caps: [UUID: Int] = [:],
               doors: [Door] = [instagram, tiktok, reddit, youtube]) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: night, doors: doors, doorCaps: caps)
}

/// The same four with two of them already carrying a ceiling.
///
/// Capped STRUCTURALLY, and the reason is worth keeping: against an uncapped
/// state every `setDoorCap` raises a ceiling from infinity, which is a tighten
/// — so a loosening test run against `makeState()` is inert for the whole cap
/// feature and would report green for any cap rule whatsoever, including one
/// that read "unlimited tiktok" as an instruction to remove a ceiling.
func makeCappedState(budget: Int = 40) -> PolicyState {
    makeState(budget: budget, caps: [tiktok.id: 10, instagram.id: 10])
}

/// Doors whose spoken forms collide with each other — the third state the
/// fuzz corpora's NO_CRASH_ONLY rows run against.
let confusingDoors = [
    Door(name: "Instagram"),
    Door(name: "Insta"),
    Door(name: "TikTok"),
    Door(name: "X"),
]

func makeConfusingState() -> PolicyState {
    PolicyState(budgetMinutes: 40, downHours: night, doors: confusingDoors,
                doorCaps: [confusingDoors[0].id: 10])
}

// MARK: - The shorthands

func parse(_ utterance: String, _ state: PolicyState = makeState()) -> ParseOutcome {
    DeterministicParser.parse(utterance, state: state)
}

/// A failure message that cannot itself be the failure. Fuzz inputs carry
/// control characters, RTL overrides and megabyte pastes, and a raw one in an
/// `Issue.record` corrupts the terminal it is read in or buries the row that
/// matters — so the input is escaped and clipped before it is quoted.
func sanitize(_ s: String, limit: Int = 90) -> String {
    let printable = s.unicodeScalars.prefix(limit).map { sc -> String in
        (0x20...0x7E).contains(Int(sc.value)) ? String(Character(sc)) : "\\u{\(String(sc.value, radix: 16))}"
    }.joined()
    return s.unicodeScalars.count > limit ? printable + "…(\(s.count) chars)" : printable
}
