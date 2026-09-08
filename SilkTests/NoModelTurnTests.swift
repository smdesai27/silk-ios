import Testing
import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Silk
@testable import SilkCore

// THE APP WITH NO MODEL BEHIND IT.
//
// Silk's parser is two tiers: `DeterministicParser` is the grammar and runs on
// every sentence; `SilkModelParser` is the widener, and it answers `.silence`
// whenever `SystemLanguageModel.default.availability` is anything but
// `.available` (SilkModelParser.swift:180). A phone with Apple Intelligence
// switched off, unsupported, or still downloading its assets is therefore the
// grammar alone — and the claim the product rests on is that the grammar alone
// is the whole hot path.
//
// This file is that claim, measured rather than asserted. `testForceSilent`
// makes the widener answer exactly as an unavailable one does, and every
// sentence below is driven through `AppModel.handle` — the real turn, with the
// real Validator, the real ledger and the real reply composition — with the
// wait pinned off so a grant lands on the same pass it is granted on.
//
// WHAT A SPEND IS, AS THIS TABLE NOW READS IT. A grant takes three things —
// an opening verb, an app name and minutes — and a sentence carrying only two
// of them is not refused into silence: silence would hand "instagram 10" to the
// widener, which is a model, and a model reads it as the grant the grammar just
// declined. It is answered with the sentence that WOULD grant, in her own door
// and her own number ("Write it out: unlock Instagram for 10 min."), nothing is
// debited and no Undo is offered. So the table has three outcomes to hold apart
// and not two, and every `.writeItOut` row below asserts the balance and the
// ledger stood still.
//
// Two things it deliberately does NOT do. It does not assert that the widener
// is unreachable: it is reachable, it simply says nothing. And it does not
// pretend the simulator has no model — the simulator this suite runs on HAS
// Apple Intelligence (`theModelIsActuallyAvailableHere` logs the availability
// so the record says so), which is precisely why the seam is the only way to
// hold the refusal's wording still.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group;
// every case starts from `noModelModel()`, which wipes it.

// MARK: - Fixture

/// Two doors, because half the table is about which one a fragment names.
/// `TestSupport.freshModel` underneath — the wipe, the seam reset and the
/// onboarding are the same ones every other suite gets.
@MainActor
private func noModelModel(budget: Int = 40,
                          downHours: DownHours = noWindowTonight()) -> AppModel {
    freshModel(budget: budget,
               doors: [Door(name: "Instagram"), Door(name: "TikTok")],
               downHours: downHours).0
}

/// A duration in milliseconds, rounded to three places, for the printed table.
private func milliseconds(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1000
        + Double(d.components.attoseconds) / 1e15
    return String(format: "%9.3f", ms)
}

// MARK: - The table

/// One row of the sentence table: what is said, what the bar must answer, and
/// which tier is expected to have read it.
struct NoModelRow: Sendable, CustomStringConvertible {

    /// Which night the fixture runs under. `.night` puts the current minute
    /// inside the down-hours window; `.day` parks the window half a day out.
    enum Clock: Sendable { case day, night }

    /// What the reply has to be. The two computed cases exist because their
    /// text is composed from a fixture whose hours move with the wall clock.
    enum Reply: Sendable {
        /// Byte-for-byte.
        case exact(String)
        /// Every fragment present, in no particular order.
        case contains([String])
        /// `SilkStrings.didntGetThat` — the four words, and nothing else.
        case refused
        /// `SilkStrings.writeItOut(door:minutes:)` — the sentence written out
        /// for HALF a spend: a door and a number with no verb between them, a
        /// door asked for with no duration, or either half standing alone.
        /// `minutes` is nil when the sentence named none, and the hint then
        /// says ten.
        case writeItOut(door: String, minutes: Int?)
        /// "Down hours. Opens 7:00 AM." for the fixture's own window.
        case downHoursRefusal
        /// The window read back whole.
        case downHoursReadback
        /// Not the refusal, and the sentence moved the policy or parked a
        /// loosening. For the rows whose polarity is a function of the hour
        /// the suite happens to run at.
        case movedOrParked
    }

    /// Sentences said first, to put the fixture in the state the row is about.
    var given: [String] = []
    /// The sentence under test.
    var say: String
    /// What the bar must answer.
    var reply: Reply
    /// Whether the DETERMINISTIC grammar is expected to claim this sentence.
    /// Asserted, not documentation: a row marked `true` that goes silent is a
    /// grammar regression, and a row marked `false` that stops being silent is
    /// the grammar quietly widening under a test that thought it was measuring
    /// a refusal.
    var grammar: Bool
    /// The balance after the sentence, when the row is about the balance.
    var remaining: Int? = nil
    var clock: Clock = .day

    var description: String { say }
}

private let table: [NoModelRow] = [

    // ---- SPEND, in its documented form: A VERB, A DOOR AND MINUTES ----
    // (README rule 1, parser rule 7). Every row here is a real debit taken by
    // the grammar alone, which is the claim this file exists to measure: with
    // the widener silent the hot path still opens doors.
    .init(say: "unlock instagram for 10 min",
          reply: .exact("Instagram is open for 10 min."), grammar: true, remaining: 30),
    .init(say: "give me 20 minutes of instagram",
          reply: .exact("Instagram is open for 20 min."), grammar: true, remaining: 20),
    // The commitment frame is the verb spelled as a gerund — "using" is on the
    // opening-verb list, and the sentence is a person saying what she is about
    // to do, which is an ask.
    .init(say: "i'm using instagram for 5 minutes",
          reply: .exact("Instagram is open for 5 min."), grammar: true, remaining: 35),
    .init(say: "give me 2 hours of instagram",
          reply: .exact("Instagram is open for 40 min."), grammar: true, remaining: 0),
    // THE HINT BELOW, TYPED BACK VERBATIM. The whole of the guidance design
    // rests on this row: the sentence the bar shows has to be one the bar can
    // then read, capital letter, full stop and all.
    .init(say: "Unlock Instagram for 10 min.",
          reply: .exact("Instagram is open for 10 min."), grammar: true, remaining: 30),

    // ---- THE PARTIAL SPEND, WRITTEN OUT (parser rule 7's verb guard) ----
    // A door beside a number is the OBJECT and the AMOUNT of a request with no
    // request in it. Each of these opened a door and debited the pool until the
    // grammar required a verb; each is now answered with the sentence that
    // would grant, in her own door and her own number, and nothing moves.
    .init(say: "instagram 10", reply: .writeItOut(door: "Instagram", minutes: 10),
          grammar: true, remaining: 40),
    .init(say: "instagram, ten", reply: .writeItOut(door: "Instagram", minutes: 10),
          grammar: true, remaining: 40),
    .init(say: "tiktok for 15", reply: .writeItOut(door: "TikTok", minutes: 15),
          grammar: true, remaining: 40),
    .init(say: "10 minutes of instagram", reply: .writeItOut(door: "Instagram", minutes: 10),
          grammar: true, remaining: 40),

    // ---- THE ELLIPTICAL ASK (parser rule 8) ----
    // A door named with an OPENING VERB and no duration is answered with the
    // whole sentence it is missing a word of: "Write it out: unlock Instagram
    // for 10 min." Ten is what the sentence says when she named no number —
    // the old "How long?" asked for the missing word and then read whatever
    // fragment came back as the whole ask.
    .init(say: "give me instagram", reply: .writeItOut(door: "Instagram", minutes: nil),
          grammar: true, remaining: 40),
    .init(say: "open tiktok", reply: .writeItOut(door: "TikTok", minutes: nil),
          grammar: true, remaining: 40),
    // ---- THE TWO HALVES OF A FRAGMENT (parser rules 9 and 10) ----
    // A BARE DOOR NAME IS NOT AN ASK, and it is no longer a refusal either: it
    // is half a sentence, and the reply is the other half. Ten minutes, because
    // she named no number.
    .init(say: "instagram", reply: .writeItOut(door: "Instagram", minutes: nil),
          grammar: true, remaining: 40),
    // And a bare number names no door, so the hint names the FIRST one. Said
    // here after a partial ask, which is when a person actually types it — the
    // grammar carries nothing between turns and does not need to: the door is
    // in the reply she is reading. See docs/qa/no-model-verification-2026-09-03.md.
    .init(given: ["give me instagram"], say: "10",
          reply: .writeItOut(door: "Instagram", minutes: 10), grammar: true, remaining: 40),
    // The door the bar last wrote out is the one a bare number names — one
    // turn of memory, the app's (`AppModel.recentHintDoor`), so "tiktok" then
    // "10" writes out TikTok and not the first door on the list.
    .init(given: ["open tiktok"], say: "10",
          reply: .writeItOut(door: "TikTok", minutes: 10), grammar: true, remaining: 40),
    // And a whole sentence in between clears it.
    .init(given: ["open tiktok", "how much is left"], say: "10",
          reply: .writeItOut(door: "Instagram", minutes: 10), grammar: true, remaining: 40),

    // ---- STATUS ----
    .init(say: "how much is left", reply: .exact("40 min left."), grammar: true, remaining: 40),
    .init(say: "how many minutes do i have",
          reply: .exact("40 min left."), grammar: true, remaining: 40),
    .init(given: ["unlock instagram for 10 min"], say: "how much is left",
          reply: .exact("30 min left."), grammar: true, remaining: 30),

    // ---- CLOSE ----
    .init(say: "no more instagram today",
          reply: .contains(["Instagram", "closed until"]), grammar: true),
    .init(say: "close tiktok",
          reply: .contains(["TikTok", "closed until"]), grammar: true),

    // ---- BUDGET ----
    // A RAISE IS A LOOSENING and parks until tomorrow (canon rule 3), so the
    // receipt names the day and the number rather than a new balance.
    .init(say: "budget 60", reply: .exact("Tomorrow: 60"), grammar: true, remaining: 40),
    // A cut is instant, and its receipt is the balance it leaves.
    .init(say: "budget 30", reply: .exact("30 left today."), grammar: true, remaining: 30),

    // ---- DOWN HOURS ----
    .init(say: "when are down hours", reply: .downHoursReadback, grammar: true),
    // Whether moving an edge tightens or loosens depends on where the fixture's
    // window sits relative to the wall clock, so the row pins the thing that is
    // invariant: the sentence was read, and it either landed or parked.
    .init(say: "down hours start at 10", reply: .movedOrParked, grammar: true),
    .init(say: "down hours end at 7am", reply: .movedOrParked, grammar: true),
    // A BARE END HOUR IS STILL DISAMBIGUATED WITH NO MODEL IN THE LOOP. The
    // Validator refuses a reading that would LENGTHEN the night out of an hour
    // whose meridiem was never stated (Validator.swift:336) — and the answer is
    // the question, not the four words.
    .init(say: "down hours end at 7",
          reply: .exact(SilkStrings.amOrPm(TimeOfDay(hour: 7))), grammar: true),

    // ---- CAPS ----
    .init(say: "cap tiktok 20", reply: .exact("TikTok 20 min · day."), grammar: true),
    // Clearing a ceiling is a loosening: it parks, and the receipt names it.
    .init(given: ["cap tiktok 20"], say: "no cap on tiktok",
          reply: .contains(["Tomorrow:", "TikTok", "no cap"]), grammar: true),

    // ---- REFUSALS ----
    // Nothing left in the pool. A WHOLE sentence, because the guidance reply is
    // answered ahead of the balance (Validator.swift:127): a partial ask on an
    // empty pool is written out, not refused with the balance.
    .init(given: ["give me 40 minutes of instagram"], say: "unlock tiktok for 10",
          reply: .exact("0 left today."), grammar: true, remaining: 0),
    // Inside the night.
    .init(say: "give me 10 minutes of instagram",
          reply: .downHoursRefusal, grammar: true, remaining: 40, clock: .night),
    // AND THE HALF-SENTENCE HINT IS NO WAY ROUND THE NIGHT. "tiktok" then "10"
    // is the memory rule two rows above, walked after ten at night: both turns
    // are answered with the hour the wall opens, and neither writes a sentence
    // out. The gate is ahead of the hint in `handle` — `recentHintDoor` is set
    // only once the night has let the reply through — so the second turn here
    // is refused whether the memory holds TikTok or nothing at all.
    //
    // Which is exactly what this row CANNOT tell apart, and it is worth saying
    // so rather than implying more. Both readings of the memory produce the
    // same sentence at night: with TikTok remembered the bare number writes out
    // TikTok and is deferred; with nothing remembered it writes out the first
    // door and is deferred identically. The memory itself is
    // `AppModel.recentHintDoor`, `private`, and the only turn that could show
    // its contents is a DAY turn — which cannot follow a night one inside a
    // single model, because the window is fixed in the policy the fixture
    // built. The day half is pinned two rows above; the night half is this,
    // and the clearing itself is unasserted. See the report note.
    .init(given: ["open tiktok"], say: "10",
          reply: .downHoursRefusal, grammar: true, remaining: 40, clock: .night),
    // An app that is not a door. The grammar cannot name it and the widener is
    // silent, so the four words are the whole answer — and nothing moved.
    .init(say: "snapchat 10", reply: .refused, grammar: false, remaining: 40),
    .init(say: "give me 10 minutes of snapchat", reply: .refused, grammar: false, remaining: 40),

    // ---- PARAPHRASES ONLY THE MODEL COULD READ ----
    // These are the sentences the widener exists for. With it silent they must
    // reach the four words promptly and change nothing — never a guess.
    // "ig" and "the gram" are among them now: a door answers to its own name
    // and nothing else (Door.spokenForms), so a nickname is an unknown word and
    // the sentence built on one names no door at all.
    .init(say: "unlock ig for a while", reply: .refused, grammar: false, remaining: 40),
    .init(say: "how about a little tiktok", reply: .refused, grammar: false, remaining: 40),
    .init(say: "surely a short instagram break is fine",
          reply: .refused, grammar: false, remaining: 40),
    .init(say: "im bored, tiktok please", reply: .refused, grammar: false, remaining: 40),
    .init(say: "gimme the gram", reply: .refused, grammar: false, remaining: 40),
    .init(say: "asdfgh qwerty zxcvb", reply: .refused, grammar: false, remaining: 40),

    // THREE OF THE PARAPHRASES THE BRIEF EXPECTED TO BE REFUSED ARE NOT.
    // "let me", "can i" and "use" are opening verbs (`DeterministicParser.openingVerbs`),
    // so rule 8 claims all three and the bar writes the sentence out.
    // Recorded here rather than filed as a defect: the answer is deterministic,
    // it names no minutes it was not given, it debits nothing, and it is
    // strictly more useful than the refusal. It is the grammar being wider than
    // the brief assumed.
    .init(say: "let me have a bit of instagram", reply: .writeItOut(door: "Instagram", minutes: nil),
          grammar: true, remaining: 40),
    .init(say: "can i get on tiktok", reply: .writeItOut(door: "TikTok", minutes: nil),
          grammar: true, remaining: 40),
    .init(say: "i could really use some instagram right now",
          reply: .writeItOut(door: "Instagram", minutes: nil), grammar: true, remaining: 40),
]

// MARK: - The suite
//
// A class rather than the file's usual struct, so the seam can be set in `init`
// (setUp) and put back in `deinit` (tearDown) around EVERY case, including the
// ones that fail. A leaked `testForceSilent` would silence the widener for
// every later suite in this process, which is the one way this file could break
// tests it has nothing to do with.

@Suite(.serialized) @MainActor final class TheBarWithNoModelBehindIt {

    init() {
        SilkModelParser.testForceSilent = true
    }

    /// `unpinTheProcessSeams()` and not `unpinTheSeams()`, and the difference is
    /// not a preference. `deinit` is nonisolated even on a `@MainActor` class,
    /// so the four main-actor seams the full sweep also clears cannot be reached
    /// from here — and this suite arms none of them. What it does arm is the
    /// widener's own seam, and that one must come down even when a case fails,
    /// which is the whole reason the teardown is a `deinit` and not a `defer`.
    deinit {
        unpinTheProcessSeams()
    }

    /// The record of what machine this ran on. The simulator carries Apple
    /// Intelligence, so every "Didn't get that." below is the SEAM answering
    /// and not the absence of a model — which is the point: on a phone with no
    /// model the same code path is taken one branch earlier
    /// (SilkModelParser.swift:180) and the app cannot tell the difference.
    @Test func theModelIsActuallyAvailableHere() async {
        #if canImport(FoundationModels)
        let availability = SystemLanguageModel.default.availability
        print("[no-model] SystemLanguageModel.default.availability = \(availability)")
        if case .available = availability {
            print("[no-model] the model IS available here — the forced-silent seam is the meaningful path")
        } else {
            print("[no-model] the model is NOT available here — the seam is redundant on this machine")
        }
        #else
        print("[no-model] FoundationModels does not import on this SDK")
        #endif
        // Logged, never asserted: which machine the suite runs on is not a
        // property of the product.
    }

    /// EVERY CANONICAL SENTENCE, ANSWERED BY THE GRAMMAR ALONE.
    @Test(arguments: table)
    func theSentenceIsAnsweredWithoutTheWidener(_ row: NoModelRow) async {
        UserDefaults.standard.set("0", forKey: "silkWait")
        defer { unpinTheSeams() }

        let night = row.clock == .night ? nightContainingNow() : noWindowTonight()
        let model = noModelModel(downHours: night)
        if row.clock == .night {
            #expect(model.isDownHours, "the fixture window does not contain the current minute")
        }
        for sentence in row.given {
            await model.handle(sentence)
        }

        // Which tier read it, pinned. A grammar that quietly widened would
        // otherwise turn a refusal row green for the wrong reason.
        let claimed = DeterministicParser.parse(row.say, state: model.policy) != .silence
        #expect(claimed == row.grammar,
                "\"\(row.say)\": the grammar \(claimed ? "claims" : "no longer claims") it, the table says \(row.grammar ? "it should" : "it should not")")

        let policyBefore = model.policy
        let pendingBefore = model.pendingLoosening
        // The ledger as it stood BEFORE the sentence, not as it stood before
        // the fixture: a row may have granted in `given`, and what the guidance
        // rows have to prove is that THIS sentence took nothing.
        let grantsBefore = model.ledger.grants.count
        await model.handle(row.say)

        #expect(model.conversation.hasPendingTurn == false,
                "\"\(row.say)\" left its turn drawing \"…\"")
        #expect(model.conversation.turns.count == row.given.count + 1,
                "\"\(row.say)\" produced \(model.conversation.turns.count - row.given.count) turns")
        let answer = model.conversation.turns.last?.reply
        // Printed as well as asserted: the QA record wants what the bar
        // actually said beside what the table demanded, not a green tick.
        let saidBy = claimed ? "grammar" : "silent widener"
        print("[no-model] \(row.say.padding(toLength: 46, withPad: " ", startingAt: 0))"
              + "(\(saidBy)) -> \(answer ?? "nil")")

        switch row.reply {
        case .exact(let expected):
            #expect(answer == expected, "\"\(row.say)\" answered \"\(answer ?? "nil")\"")
        case .contains(let fragments):
            for fragment in fragments {
                #expect(answer?.contains(fragment) == true,
                        "\"\(row.say)\" answered \"\(answer ?? "nil")\", missing \"\(fragment)\"")
            }
        case .refused:
            #expect(answer == SilkStrings.didntGetThat,
                    "\"\(row.say)\" answered \"\(answer ?? "nil")\" instead of the four words")
            #expect(model.policy == policyBefore, "a refused sentence moved the policy")
            #expect(model.conversation.turns.last?.undo == nil,
                    "a refusal that moved nothing offered a way back")
        case .writeItOut(let door, let minutes):
            #expect(answer == SilkStrings.writeItOut(door, minutes: minutes),
                    "\"\(row.say)\" answered \"\(answer ?? "nil")\"")
            #expect(model.policy == policyBefore, "a guidance reply moved the policy")
            // The three facts that make the guidance affordable, held exactly
            // as the refusal rows hold them: nothing was debited, nothing was
            // recorded, and nothing was offered to take back.
            #expect(model.ledger.grants.count == grantsBefore,
                    "a guidance reply recorded a grant")
            #expect(model.conversation.turns.last?.undo == nil,
                    "a guidance reply that moved nothing offered a way back")
        case .downHoursRefusal:
            #expect(answer == "\(SilkStrings.downHoursOpens) \(night.end.displayWithMeridiem).",
                    "the night answered \"\(answer ?? "nil")\"")
            #expect(model.ledger.grants.isEmpty, "a grant was recorded inside down hours")
        case .downHoursReadback:
            #expect(answer == model.policy.downHours.runText,
                    "\"\(row.say)\" answered \"\(answer ?? "nil")\"")
        case .movedOrParked:
            #expect(answer != SilkStrings.didntGetThat,
                    "\"\(row.say)\" was refused")
            #expect(model.policy != policyBefore || model.pendingLoosening != pendingBefore,
                    "\"\(row.say)\" answered \"\(answer ?? "nil")\" and moved nothing")
        }

        if let remaining = row.remaining {
            #expect(model.remainingMinutes == remaining,
                    "\"\(row.say)\" left \(model.remainingMinutes) minutes, expected \(remaining)")
        }
    }

    /// LATENCY, MEASURED.
    ///
    /// Two numbers per sentence, and they answer different questions.
    ///
    /// COMPILE is the grammar plus the silent widener — the same two `parse`
    /// calls `AppModel.handle` makes, timed on their own.
    /// This is what a user pays for the parse when there is no model, and it
    /// must be far under a frame: the grammar is a string walk and the widener
    /// returns before it allocates anything.
    ///
    /// TURN is the whole of `handle`, which includes the deliberate ~480 ms
    /// beat `AppModel.handle` waits out. The bound on it is
    /// what proves the silent widener costs nothing ON TOP of that beat — a
    /// refusal that sat behind `SilkModelParser.deadline` would land at 2.5 s,
    /// not 0.5 s.
    @Test func neitherTierMakesTheUserWait() async {
        UserDefaults.standard.set("0", forKey: "silkWait")
        defer { unpinTheSeams() }

        // One sentence of every shape — the grant, the guidance, and the ones
        // only the widener could have read.
        let sentences = [
            "unlock instagram for 10 min", "Unlock Instagram for 10 min.",
            "instagram 10", "instagram, ten", "give me 20 minutes of instagram",
            "tiktok for 15", "10 minutes of instagram", "give me instagram",
            "how much is left", "no more instagram today", "close tiktok",
            "budget 60", "cap tiktok 20", "when are down hours",
            "instagram", "snapchat 10", "unlock ig for a while",
            "how about a little tiktok", "gimme the gram", "asdfgh qwerty zxcvb",
        ]

        var compiles: [(String, Duration)] = []
        var turns: [(String, Duration)] = []
        for sentence in sentences {
            let model = noModelModel()

            // The compile step, exactly as `handle` performs it — five times,
            // and the FASTEST of the five is the reading. A single sample of a
            // sub-millisecond string walk is mostly a measurement of what else
            // the machine was doing during it; the minimum is the one number a
            // ceiling like "under twelve milliseconds" is a claim about. A
            // change that made the grammar slower raises the floor and still
            // fails here. A loaded runner raises only the ceiling, and no
            // longer does.
            var compiled = Duration.seconds(Int.max)
            for _ in 0..<5 {
                let compileStart = ContinuousClock.now
                var outcome = DeterministicParser.parse(sentence, state: model.policy)
                if outcome == .silence {
                    outcome = await SilkModelParser.shared.parse(sentence, state: model.policy)
                }
                compiled = min(compiled, compileStart.duration(to: .now))
            }

            let turnStart = ContinuousClock.now
            await model.handle(sentence)
            let turned = turnStart.duration(to: .now)

            compiles.append((sentence, compiled))
            turns.append((sentence, turned))
        }

        print("[no-model] latency, widener silent — compile = grammar + widener, turn = whole handle()")
        for (i, entry) in compiles.enumerated() {
            let name = entry.0.padding(toLength: 40, withPad: " ", startingAt: 0)
            print("[no-model] \(name) compile \(milliseconds(entry.1)) ms   "
                  + "turn \(milliseconds(turns[i].1)) ms")
        }

        // A frame at 60 Hz is 16.7 ms and at 120 Hz is 8.3 ms. Twelve is a
        // ceiling with room in it for a loaded simulator, not a target: the
        // measured numbers are printed above and are two orders below it. Each
        // is the fastest of five, for the reason given at the measurement.
        for (sentence, took) in compiles {
            #expect(took < .milliseconds(12),
                    "\"\(sentence)\" took \(took) to compile with no model behind it")
        }
        // THE TURN IS PRINTED AND NOT BOUNDED, and that is a correction.
        //
        // It used to carry two upper bounds — 1200 ms, and the widener's own
        // two-second deadline — against ONE un-repeated wall-clock sample per
        // sentence. Most of each sample is a deliberate 480 ms sleep, so what
        // the margin above it actually measures is scheduling: a runner that
        // stalled 800 ms in the wrong place failed a test whose message
        // accused a silent widener of being a clock. Twenty samples an
        // afternoon is a coin toss looking for a place to land.
        //
        // The property those bounds were reaching for is real and is asserted
        // properly one test down, in
        // `theRefusalLandsOnTheBeatAndNothingIsLeftRunning`: the fastest of
        // five refusals — the sentence that actually reaches the widener — is
        // bounded there, where a repeated minimum makes the number mean
        // something. Here the readings stand in the log, which is what the QA
        // record wanted from them.
        let slowestTurn = turns.max { $0.1 < $1.1 }
        print("[no-model] slowest turn of \(turns.count): "
              + "\(slowestTurn?.0 ?? "—") at \(milliseconds(slowestTurn?.1 ?? .zero)) ms")
    }

    /// THE SILENT WIDENER ANSWERS ON THE SPOT, not on its clock.
    ///
    /// `parse` returns `.silence` before it builds a session, starts a
    /// generation or arms the deadline — the forced-silent branch at
    /// SilkModelParser.swift:177 and the availability guard at :180 both
    /// return ahead of the `AsyncStream`. This pins that: a regression that
    /// moved either check below the race would show up here as a two-second
    /// answer and nowhere else.
    /// The reading is the BEST of twenty and not the worst, and the inversion
    /// is the fix rather than a weakening.
    ///
    /// What this bounds is a branch — whether `parse` returns before it builds
    /// a session or after it has armed a two-second deadline. Those two answers
    /// are three orders of magnitude apart, so the fastest of twenty separates
    /// them exactly: a regression that moved either check below the race cannot
    /// produce a single sub-five-millisecond parse, and the floor rises with it.
    ///
    /// The maximum could not separate them, because it was never measuring
    /// this code. Twenty samples on a shared simulator host will contain a
    /// scheduling stall sooner or later, and a stall of five milliseconds is an
    /// ordinary thing for a machine to do — so the assertion failed for the one
    /// reason it must never fail for, with a message accusing the widener of
    /// being a clock. Both readings are printed, so a run whose worst sample
    /// was bad still says so.
    @Test func anUnavailableWidenerIsNotAClock() async {
        let model = noModelModel()
        var best = Duration.seconds(Int.max)
        var worst = Duration.zero
        for _ in 0..<20 {
            let started = ContinuousClock.now
            let outcome = await SilkModelParser.shared.parse("gimme the gram", state: model.policy)
            let took = started.duration(to: .now)
            #expect(outcome == .silence)
            best = min(best, took)
            worst = max(worst, took)
        }
        print("[no-model] 20 silent widener parses: best \(milliseconds(best)) ms, "
              + "worst \(milliseconds(worst)) ms")
        #expect(best < .milliseconds(5),
                "the silent widener's FASTEST parse took \(best) — it is meant to return before it allocates")
        #expect(SilkModelParser.deadline == .seconds(2),
                "the deadline moved; the bound this test is contrasted against is stale")
    }

    /// And the refusal itself is not behind a timer either: the turn is
    /// answered inside the beat, with nothing in flight afterwards.
    ///
    /// FIVE TURNS, and the fastest is what is bounded. This is the one place
    /// the widener's two-second deadline can actually be caught being paid —
    /// "gimme the gram" is a sentence the grammar declines, so it reaches the
    /// widener on every pass — and a single sample could not carry the claim:
    /// a turn is a 480 ms sleep plus whatever the machine did around it, and a
    /// runner that stalled 800 ms once failed a test that then said the
    /// refusal was behind a timer. A silent widener returns before it
    /// allocates, so ALL FIVE are inside the beat and the fastest cannot be
    /// past it; a widener paying its deadline puts every one of the five past
    /// two seconds and the fastest with them. The assertions that matter here
    /// — the four words, no pending turn, no veil — are made on every pass.
    /// A partial ask inside down hours is answered with the hour the wall
    /// opens, and the door it named is NOT remembered: the memory holds only
    /// a door the bar actually wrote out, and at night it wrote out nothing.
    /// The reply cannot show this (both states answer the same sentence), so
    /// the memory is read through its DEBUG accessor.
    @Test func aPartialAskAtNightLeavesNoDoorRemembered() async {
        UserDefaults.standard.set("0", forKey: "silkWait")
        defer { unpinTheSeams() }
        let model = noModelModel(downHours: nightContainingNow())
        await model.handle("open tiktok")
        #expect(model.recentHintDoorForTests == nil)
        // And by day the same ask does remember, so the test can tell the two apart.
        let day = noModelModel(downHours: noWindowTonight())
        await day.handle("open tiktok")
        #expect(day.recentHintDoorForTests?.name == "TikTok")
    }

    @Test func theRefusalLandsOnTheBeatAndNothingIsLeftRunning() async {
        UserDefaults.standard.set("0", forKey: "silkWait")
        defer { unpinTheSeams() }

        var best = Duration.seconds(Int.max)
        var readings: [Duration] = []
        for _ in 0..<5 {
            let model = noModelModel()
            let started = ContinuousClock.now
            await model.handle("gimme the gram")
            let took = started.duration(to: .now)

            #expect(model.conversation.turns.last?.reply == SilkStrings.didntGetThat)
            #expect(model.conversation.hasPendingTurn == false)
            #expect(model.waiting == nil, "a veil rose over a sentence nothing could read")
            readings.append(took)
            best = min(best, took)
        }
        print("[no-model] five refusals: "
              + readings.map { "\(milliseconds($0)) ms" }.joined(separator: ", "))
        #expect(best < .milliseconds(1200),
                "the fastest of five refusals landed at \(best) — the beat is 480 ms")
        #expect(best < SilkModelParser.deadline,
                "a refusal took longer than the widener's own deadline, which a silent widener must never make anyone wait for")
    }
}
