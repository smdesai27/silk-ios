import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// Rule 4 on the bar's own spend path: **a door does not open unless its
// re-lock armed.**
//
// `SpendIntent` has always taken a grant back when `WallController.arm`
// refused it. The bar's landing did not: it committed the ledger — which is
// the unshielding — then called `arm` and dropped the answer on the floor. A
// `startMonitoring` that threw (authorization revoked underneath a live app is
// the likeliest way) left the door open with no schedule, no threshold and no
// shield to render, until Silk was next opened by hand or the daily heartbeat
// fired. That is the fail-open the rule forbids, and this file is what says it
// stays closed.
//
// The seam is `WallController.testForceArmed = false`: the simulator has no
// wall of its own, so `arm` answers "armed" there by default and the refusal
// leg is reached only on demand. Hosted by the app for the reason
// `WaitTransactionTests` gives, and `.serialized` for the same.

@Suite(.serialized) @MainActor struct RelockArmFailureTests {

    private static let waitSeconds = 0.8
    private static let ask = "give me twenty minutes of instagram"

    /// A refused arm lands as a refusal, not as a grant: nothing debited,
    /// nothing unshielded, nothing launched, and no way back offered because
    /// nothing was done.
    @Test func aRefusedArmTakesTheGrantBackAndOpensNothing() async throws {
        defer { unpinTheSeams() }

        let (model, door) = freshModel(downHours: nightWellClearOfNow(),
                                       silkWait: "\(Self.waitSeconds)",
                                       requiringForeground: true)
        let untouched = SharedStore.loadLedger()
        WallController.testForceArmed = false
        LaunchCatalog.testOpenCount = 0

        try claimed(Self.ask, model)
        await model.handle(Self.ask)

        let waiting = try #require(model.waiting, "no wait was raised over a granted ask")
        #expect(waiting.door.id == door.id)

        let landed = await settle { model.waiting == nil }
        #expect(landed, "the ink never landed")

        // The ledger, in memory and in the store the shield reads, is exactly
        // what it was before the ask: the grant was recorded and then
        // withdrawn on the same landing.
        #expect(model.ledger.grants.isEmpty)
        #expect(SharedStore.loadLedger().grants.isEmpty)
        #expect(SharedStore.loadLedger() == untouched)
        #expect(model.remainingMinutes == 40)
        #expect(!model.ledger.openDoors(at: .now, dayStart: model.dayStart)
            .contains(door.id))

        // The app did not open — a door with no layer behind it is not handed
        // the phone.
        #expect(LaunchCatalog.testOpenCount == 0)

        // Answered in the turn it was holding, with the silence an unreadable
        // sentence gets and no undo pill: there is nothing to put back.
        #expect(model.conversation.turns.count == 1)
        let answered = try #require(model.conversation.turns.last)
        #expect(answered.id == waiting.turn)
        #expect(answered.reply == SilkStrings.didntGetThat)
        #expect(answered.undo == nil)
    }

    /// The harder case: the door already holds a live grant, and a larger ask
    /// lands beside it (the bar, unlike the intent, lets it). The failed arm
    /// has disarmed BOTH of the door's schedule names, so taking back the new
    /// grant alone would leave the earlier one running with no layer behind it
    /// — the fail-open in a second coat. The earlier grant has to end.
    @Test func aRefusedArmOverALiveGrantEndsThatGrantToo() async throws {
        defer { unpinTheSeams() }

        let (model, door) = freshModel(budget: 60,
                                       downHours: nightWellClearOfNow(),
                                       silkWait: "\(Self.waitSeconds)",
                                       requiringForeground: true)
        // First, a grant that lands: ten minutes, armed.
        WallController.testForceArmed = true
        let first = "give me ten minutes of instagram"
        try claimed(first, model)
        await model.handle(first)
        var landed = await settle { model.waiting == nil }
        #expect(landed, "the first ink never landed")
        #expect(model.ledger.grants.count == 1)
        #expect(model.remainingMinutes == 50)

        // Then a larger ask over it, and this time the wall refuses.
        WallController.testForceArmed = false
        LaunchCatalog.testOpenCount = 0
        let second = "give me twenty minutes of instagram"
        try claimed(second, model)
        await model.handle(second)
        landed = await settle { model.waiting == nil }
        #expect(landed, "the second ink never landed")

        // The new grant is gone, and the earlier one is ended rather than left
        // open behind a wall with no schedule: the door is shut, nothing
        // launched, and the balance is what the first grant left.
        let now = Date.now
        #expect(!model.ledger.grants.contains { $0.minutes == 20 })
        #expect(model.ledger.activeGrant(for: door, at: now) == nil)
        #expect(!model.ledger.openDoors(at: now, dayStart: model.dayStart)
            .contains(door.id))
        #expect(!SharedStore.loadLedger().openDoors(at: now, dayStart: model.dayStart)
            .contains(door.id))
        #expect(LaunchCatalog.testOpenCount == 0)
        #expect(model.remainingMinutes == 50)
        // Ended, not closed: no close of the landing's own is on the books,
        // so nothing of another writer's close could have been overwritten.
        #expect(model.ledger.closedToday.isEmpty)
        #expect(model.ledger.closedUntil.isEmpty)
        let answered = try #require(model.conversation.turns.last)
        #expect(answered.reply == SilkStrings.didntGetThat)
        #expect(answered.undo == nil)
    }

    /// The control: the same ask with the arm allowed lands the grant, so the
    /// test above is measuring the arm's answer and not some other refusal.
    @Test func anArmedGrantStillLands() async throws {
        defer { unpinTheSeams() }

        let (model, door) = freshModel(downHours: nightWellClearOfNow(),
                                       silkWait: "\(Self.waitSeconds)",
                                       requiringForeground: true)
        WallController.testForceArmed = true

        try claimed(Self.ask, model)
        await model.handle(Self.ask)
        let landed = await settle { model.waiting == nil }
        #expect(landed, "the ink never landed")

        #expect(model.ledger.grants.count == 1)
        #expect(model.remainingMinutes == 20)
        #expect(model.ledger.openDoors(at: .now, dayStart: model.dayStart)
            .contains(door.id))
    }
}
