import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// The night, at the bar. What Silk refuses between the hours, what it still
// accepts, and the one clause the balance answer grows when a rule is standing.
//
// `SpendIntentTests` owns the same three facts from Siri's side and pins the
// dialogs. Nothing owned them from the *bar's* side, which is the surface the
// user actually types into and the one where the refusal is composed twice:
// `handle`'s own down-hours gate (the `isDownHours, verdict.deferredByDownHours`
// gate in `AppModel.handle`) and `apply`'s
// `.refuseDownHours` arm compose the same sentence from the same field, and a
// change to either that missed the other would ship a night that answers
// differently depending on which gate caught the sentence.
//
// **Every sentence below is one the deterministic grammar claims outright**,
// and each test says so before it drives `handle`. The simulator carries Apple
// Intelligence, so a sentence the grammar falls silent on reaches the on-device
// widener and may come back with a real verdict — which would make any
// assertion here a property of the machine. The precondition is what keeps
// these deterministic: if the grammar ever stops claiming one of these, the
// test fails on the premise rather than quietly measuring the weather.
//
// The premise is a `#require` — `try claimed(_:_:)` — and the word is
// load-bearing. It used to be an `#expect`, which reports and carries on: a
// grammar that had stopped claiming "no more instagram today" would have
// recorded one failure and then gone on to drive `handle` anyway, measuring the
// widener under every assertion below it. A premise that fails must END the
// case, or the case goes on to measure something else.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group.

// MARK: -

@Suite(.serialized) @MainActor struct TheBarDuringDownHours {

    /// **The edge does not yield.** A door asked for inside the window is
    /// refused, the refusal names the hour the wall opens, and the pool is
    /// exactly where it was.
    ///
    /// The wait is pinned OFF rather than left at the product curve, and that
    /// is deliberate: with `-silkWait 0` a grant that slipped past this gate
    /// would land instantly and show up in the balance below. Left at the
    /// curve, the same regression would sit behind a veil and every assertion
    /// here would still be green.
    @Test func aDoorAskedForInsideTheWindowIsRefusedWithTheOpeningHour() async throws {
        defer { unpinTheSeams() }
        let night = nightContainingNow()
        let (model, _) = freshModel(budget: 40, downHours: night, silkWait: "0")
        let sentence = "give me 10 minutes of instagram"
        try claimed(sentence, model)
        try #require(model.isDownHours, "the fixture window does not contain the current minute")

        await model.handle(sentence)

        #expect(model.conversation.turns.last?.reply
                == "\(SilkStrings.downHoursOpens) \(night.end.displayWithMeridiem).",
                "the night answered: \(model.conversation.turns.last?.reply ?? "nil")")
        #expect(model.remainingMinutes == 40, "the night debited the pool")
        #expect(model.ledger.grants.isEmpty, "a grant was recorded inside down hours")
        #expect(model.waiting == nil, "a veil rose over an ask the night had already refused")
        #expect(model.conversation.turns.last?.undo == nil,
                "a refusal that moved nothing offered a way back")
    }

    /// And the standing exception, which is the other half of the rule:
    /// **tightening is instant from anywhere.** A close said at two in the
    /// morning lands at two in the morning — refusing it would be the edge
    /// yielding in the wrong direction.
    @Test func aCloseStillLandsInsideTheWindow() async throws {
        defer { unpinTheSeams() }
        let night = nightContainingNow()
        let (model, door) = freshModel(budget: 40, downHours: night)
        let sentence = "no more instagram today"
        try claimed(sentence, model)
        try #require(model.isDownHours, "the fixture window does not contain the current minute")

        await model.handle(sentence)

        #expect(model.ledger.isClosed(door.id, at: .now, dayStart: model.dayStart),
                "a tighten was deferred to the morning")
        let reply = model.conversation.turns.last?.reply
        #expect(reply?.hasPrefix(SilkStrings.downHoursOpens) != true,
                "the close was answered with the opening hour instead of its receipt — read \"\(reply ?? "nil")\"")
        #expect(reply?.contains(door.name) == true,
                "the close's receipt did not name the door — read \"\(reply ?? "nil")\"")
        #expect(model.conversation.turns.last?.undo != nil,
                "the tighten that landed offered no way back")
    }
}

// MARK: - The balance answer names the rule in force

@Suite(.serialized) @MainActor struct TheStatusLineNamesAStandingClose {

    /// "40 min left. Instagram closed until 7:00." — the design's second
    /// clause, said about the only per-door rule Silk has.
    ///
    /// The expected tail is not recomputed here; it is the close's OWN
    /// receipt, captured a moment earlier. `SilkStrings.closedUntil` is the one
    /// composition both sentences go through, and holding them byte-identical
    /// is the property — a status tail that drifted from the receipt would be
    /// two different sentences about the same fact.
    @Test func theBalanceAnswerAppendsTheClauseForAHandClosedDoor() async throws {
        defer { unpinTheSeams() }
        let (model, door) = freshModel(budget: 40, downHours: nightWellClearOfNow())
        let close = "no more instagram today"
        let ask = "how much is left"
        try claimed(close, model)
        try claimed(ask, model)

        await model.handle(close)
        let receipt = try #require(model.conversation.turns.last?.reply)
        try #require(model.ledger.isClosed(door.id, at: .now, dayStart: model.dayStart),
                     "the close did not land, so there is no rule for the status line to name")

        await model.handle(ask)

        #expect(model.conversation.turns.last?.reply
                == "40 \(SilkStrings.minLeft) \(receipt)",
                "the balance answer did not name the standing close — read \"\(model.conversation.turns.last?.reply ?? "nil")\"")
    }

    /// With nothing standing, the balance answer is the balance and nothing
    /// else — so the clause above is a fact about the close, not a suffix the
    /// status line always carries.
    @Test func theBalanceAnswerIsBareWithNoRuleStanding() async throws {
        defer { unpinTheSeams() }
        let (model, _) = freshModel(budget: 40, downHours: nightWellClearOfNow())
        let ask = "how much is left"
        try claimed(ask, model)

        await model.handle(ask)

        #expect(model.conversation.turns.last?.reply == "40 \(SilkStrings.minLeft)",
                "the bare balance grew a clause — read \"\(model.conversation.turns.last?.reply ?? "nil")\"")
    }
}
