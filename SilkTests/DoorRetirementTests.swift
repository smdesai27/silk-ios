import Testing
import Foundation
import UIKit
import FamilyControls
@testable import Silk
@testable import SilkCore

// A door leaving, and the one thing that must leave with it.
//
// `Wall.reconcile` unions every stored selection with **no policy filter** —
// that is the whole hazard. A selection left behind under a door that no longer
// exists goes on shielding its app with no row on Now, no grant path at the
// bar and no entry in Settings; there is no gesture anywhere in the product
// that can reach it, and before `retireOrphanedSelections` only a wipe cleared
// it. The sweep lives inside `commit`, so it runs on every write that goes
// through there, whatever moved the doors.
//
// The seat matters for the same class of reason. A door dropped by sentence
// comes back on Undo, and it has to come back WHERE IT WAS: Now draws the
// roster in policy order, so a door restored onto the end has visibly moved
// house for a gesture that was supposed to undo something.
//
// Sentences are grammar-claimed and asserted so before they are typed — the
// simulator has Apple Intelligence, and per spec §5.7 the widener can produce
// neither a cap nor a deletion, so a removal that fell through to it would
// answer with silence and this file would be testing the weather.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group.

// MARK: - Fixtures

private func nightWellClearOfNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay + 6 * 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 7 * 60))
}

@MainActor
private func freshModel(doors: [Door], budget: Int = 40) -> AppModel {
    SharedStore.wipeAll()
    UserDefaults.standard.set("0", forKey: "silkWait")
    let model = AppModel()
    model.completeSetup(doors: doors, doorSelections: [:], wallSelection: .init(),
                        budget: budget, downHours: nightWellClearOfNow())
    return model
}

private func unpinTheSeams() {
    UserDefaults.standard.removeObject(forKey: "silkWait")
}

@MainActor
private func claimed(_ sentence: String, _ model: AppModel) {
    #expect(DeterministicParser.parse(sentence, state: model.policy) != .silence,
            "the grammar stopped claiming \"\(sentence)\" — this test now measures the widener")
}

// MARK: -

@Suite(.serialized) @MainActor struct ADoorlessSelectionIsRetired {

    /// A selection keyed by a UUID no door answers to — the shape a crashed
    /// removal, a restored backup or a build that predates the sweep leaves
    /// behind. The next commit of any kind must take it out, and must not touch
    /// the live door's beside it.
    ///
    /// The commit here is a budget tighten: nothing about it concerns doors,
    /// which is the point. The sweep belongs to `commit`, not to the removal
    /// paths, so the orphan cannot survive by arriving through a door nobody
    /// thought to sweep.
    @Test func aSelectionUnderADoorlessIdIsPrunedOnTheNextCommit() async {
        defer { unpinTheSeams() }
        let door = Door(name: "Instagram")
        let model = freshModel(doors: [door])
        let orphan = UUID()
        SharedStore.save(doorSelections: [door.id: FamilyActivitySelection(),
                                          orphan: FamilyActivitySelection()])
        #expect(SharedStore.loadDoorSelections().count == 2, "the fixture did not store two")

        let sentence = "budget of 20"
        claimed(sentence, model)
        await model.handle(sentence)
        #expect(model.policy.budgetMinutes == 20, "the tighten did not land, so no commit ran")

        let after = SharedStore.loadDoorSelections()
        #expect(after[orphan] == nil,
                "a selection under a doorless id survived a commit — it shields an app with no row, no grant path and no way to remove it")
        #expect(after[door.id] != nil, "the sweep took the live door's selection with it")
    }
}

// MARK: - A door dropped by sentence, and the way back to its seat

@Suite(.serialized) @MainActor struct ADoorDroppedAtTheBarComesBack {

    /// "remove tiktok" from the middle of three. The door goes, its selection
    /// goes with it, and Undo puts both back — the door at index 1, where it
    /// was, and not on the end.
    ///
    /// Three doors rather than two, because a seat is only observable when
    /// there is somewhere else the door could have landed.
    @Test func removingTheMiddleDoorAndPuttingItBackKeepsItsSeat() async {
        defer { unpinTheSeams() }
        let instagram = Door(name: "Instagram")
        let tiktok = Door(name: "TikTok")
        let youtube = Door(name: "YouTube")
        let model = freshModel(doors: [instagram, tiktok, youtube])
        SharedStore.save(doorSelections: [instagram.id: FamilyActivitySelection(),
                                          tiktok.id: FamilyActivitySelection(),
                                          youtube.id: FamilyActivitySelection()])

        let sentence = "remove tiktok"
        claimed(sentence, model)

        await model.handle(sentence)

        #expect(model.policy.doors.map(\.name) == ["Instagram", "YouTube"],
                "\"\(sentence)\" left the roster as \(model.policy.doors.map(\.name))")
        #expect(SharedStore.loadDoorSelections()[tiktok.id] == nil,
                "the dropped door's app is still on the wall with no row to reach it")
        let turn = model.conversation.turns.last!
        #expect(turn.undo != nil, "a door was deleted with no way back")

        model.conversation.undo(turn.id)

        #expect(model.policy.doors.map(\.name) == ["Instagram", "TikTok", "YouTube"],
                "the door came back to \(model.policy.doors.map(\.name)) instead of its seat")
        #expect(SharedStore.loadDoorSelections()[tiktok.id] != nil,
                "the door came back as a name alone — it parses and launches and can never be excepted from the wall")
        #expect(model.conversation.turns.last?.reply == SilkStrings.putBack,
                "the landed restore earned no receipt")
    }
}
