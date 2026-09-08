import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// **An undo applies whole or not at all.**
//
// Every ledger undo closure snapshots the ledger wholesale (AppModel.swift:21-31),
// so an offer may only restore its snapshot while the live ledger still descends
// from it. Two offers can stand at once — the pill's window runs to five minutes
// — and without the per-mutation generation the older one puts back a pre-both
// ledger and erases the newer turn whole: a grant the user was answered for
// vanishes, or a close she made a moment ago quietly lifts.
//
// `TurnLifecycleTests.anOlderBudgetPillCannotUndoANewerTighten` pins that shape
// for the POLICY's offers. The LEDGER's — the close, the close-all and the grant
// — had no test of it at all, and they are the two writers that can interleave
// across processes: `restore(_:ifStill:)` syncs before it checks, so an external
// grant landing under a standing pill expires the offer rather than being
// erased by it. The generation is the whole mechanism and this file is its only
// assertion.
//
// Both orders are here on purpose. Close-then-grant and grant-then-close reach
// two DIFFERENT closures — `.close`'s goes through `restore(_:ifStill:)`, the
// grant's is built inline in `apply` so it can restate the re-lock layers — and
// each has its own copy of the generation check.
//
// Every sentence is one the deterministic grammar claims, asserted before it is
// typed: the simulator carries Apple Intelligence, and a sentence the grammar
// falls silent on reaches the widener, where the verdict is a property of the
// machine rather than of the code.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group.

// MARK: - Fixtures

/// Two doors, and the wait pinned off. A grant's price is seconds of watching
/// and `landWait` re-runs the whole verdict on the far side of them; this file
/// is about what the ledger holds afterwards, not about the wait, so the veil
/// is turned off and the grant lands on `handle`'s own pass.
@MainActor
private func twoDoorModel(budget: Int = 40) -> (AppModel, Door, Door) {
    let instagram = Door(name: "Instagram")
    let youtube = Door(name: "YouTube")
    let (model, _) = freshModel(budget: budget, doors: [instagram, youtube],
                                downHours: nightWellClearOfNow(), silkWait: "0")
    return (model, instagram, youtube)
}

// MARK: - An older ledger pill may not undo a newer one

@Suite(.serialized) @MainActor struct TheLedgerUndoOfferExpiresUnderALaterMutation {

    /// Shut Instagram, then open YouTube, then tap the CLOSE's pill. The close's
    /// snapshot predates the grant, so putting it back would delete a grant the
    /// user has already been answered for and already spent minutes on. The
    /// offer expires instead, silently and completely: nothing moves, the pill
    /// goes, and the reply keeps stating what actually happened.
    @Test func anOlderClosePillCannotUndoANewerGrant() async throws {
        defer { unpinTheSeams() }
        let (model, instagram, youtube) = twoDoorModel(budget: 40)
        let close = "no more instagram today"
        let grant = "give me 10 minutes of youtube"
        try claimed(close, model)
        try claimed(grant, model)

        await model.handle(close)
        let closeTurn = model.conversation.turns.last!
        #expect(model.ledger.isClosed(instagram.id, at: .now, dayStart: model.dayStart),
                "the close did not land")
        #expect(closeTurn.undo != nil, "the close offered no way back")

        await model.handle(grant)
        #expect(model.ledger.grants.contains { $0.doorID == youtube.id },
                "the grant did not land, so there is no later mutation to expire the pill")
        #expect(model.remainingMinutes == 30, "the grant debited \(40 - model.remainingMinutes)")

        // Tap the OLDER pill.
        model.conversation.undo(closeTurn.id)

        #expect(model.ledger.grants.contains { $0.doorID == youtube.id },
                "an expired close pill erased the grant that came after it")
        #expect(model.remainingMinutes == 30,
                "an expired close pill refunded minutes that were spent")
        #expect(model.ledger.isClosed(instagram.id, at: .now, dayStart: model.dayStart),
                "an expired offer lifted the close anyway — half an undo is worse than none")
        let settled = model.conversation.turns.first { $0.id == closeTurn.id }
        #expect(settled?.undo == nil, "the expired pill is still standing")
        #expect(settled?.undone == false, "a turn that was not put back is marked undone")
        #expect(settled?.reply?.contains(SilkStrings.putBack) != true,
                "an undo that never landed wrote a receipt anyway — read \"\(settled?.reply ?? "nil")\"")
    }

    /// And the other order, which reaches the other closure. Open YouTube, then
    /// shut Instagram, then tap the GRANT's pill: the grant's snapshot predates
    /// the close, and restoring it would lift a tighten she made a second ago —
    /// which is the one direction canon never allows a mistake in.
    @Test func anOlderGrantPillCannotUndoANewerClose() async throws {
        defer { unpinTheSeams() }
        let (model, instagram, youtube) = twoDoorModel(budget: 40)
        let grant = "give me 10 minutes of youtube"
        let close = "no more instagram today"
        try claimed(grant, model)
        try claimed(close, model)

        await model.handle(grant)
        let grantTurn = model.conversation.turns.last!
        #expect(model.ledger.grants.contains { $0.doorID == youtube.id }, "the grant did not land")
        #expect(grantTurn.undo != nil, "the grant offered no way back")

        await model.handle(close)
        #expect(model.ledger.isClosed(instagram.id, at: .now, dayStart: model.dayStart),
                "the close did not land, so there is no later mutation to expire the pill")

        // Tap the OLDER pill.
        model.conversation.undo(grantTurn.id)

        #expect(model.ledger.isClosed(instagram.id, at: .now, dayStart: model.dayStart),
                "an expired grant pill lifted the close that came after it")
        #expect(model.ledger.grants.contains { $0.doorID == youtube.id },
                "an expired offer took the grant back anyway — half an undo is worse than none")
        #expect(model.remainingMinutes == 30, "an expired offer refunded the grant's minutes")
        let settled = model.conversation.turns.first { $0.id == grantTurn.id }
        #expect(settled?.undo == nil, "the expired pill is still standing")
        #expect(settled?.undone == false, "a turn that was not put back is marked undone")
        #expect(settled?.reply?.contains(SilkStrings.putBack) != true,
                "an undo that never landed wrote a receipt anyway — read \"\(settled?.reply ?? "nil")\"")
    }
}

// MARK: - Everything, and the one way back from it

@Suite(.serialized) @MainActor struct TheCloseAllIsOneTurnAndOneUndo {

    /// "block everything" is the same tighten multiplied — every door, one
    /// lift, one sentence — and the whole of it comes back on one tap. A
    /// per-door receipt or a per-door pill would be a different product; the
    /// count assertions are what hold that.
    @Test func blockEverythingShutsEveryDoorAndComesBackWhole() async throws {
        defer { unpinTheSeams() }
        let (model, instagram, youtube) = twoDoorModel(budget: 40)
        let sentence = "block everything"
        try claimed(sentence, model)

        await model.handle(sentence)

        #expect(model.ledger.isClosed(instagram.id, at: .now, dayStart: model.dayStart),
                "\"\(sentence)\" left Instagram open")
        #expect(model.ledger.isClosed(youtube.id, at: .now, dayStart: model.dayStart),
                "\"\(sentence)\" left YouTube open")
        #expect(model.conversation.turns.count == 1,
                "the close-all wrote \(model.conversation.turns.count) turns instead of one")
        let turn = model.conversation.turns.last!
        #expect(turn.reply?.hasPrefix(SilkStrings.everything) == true,
                "the close-all's receipt named a door instead of everything — read \"\(turn.reply ?? "nil")\"")
        #expect(turn.undo != nil, "the close-all offered no way back")

        model.conversation.undo(turn.id)

        #expect(model.ledger.isClosed(instagram.id, at: .now, dayStart: model.dayStart) == false,
                "the undo reopened only part of what one sentence shut")
        #expect(model.ledger.isClosed(youtube.id, at: .now, dayStart: model.dayStart) == false,
                "the undo reopened only part of what one sentence shut")
        #expect(model.conversation.turns.last?.reply == SilkStrings.putBack,
                "the landed restore earned no receipt")
        #expect(model.conversation.turns.last?.undone == true)
    }
}
