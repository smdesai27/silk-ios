import Testing
import Foundation
@testable import Silk
@testable import SilkCore

// The wait's state machine, checked without a simulator walk.
//
// `SilkCore`'s WaitTests own the clock and the price; these own the part that
// lives in the app — raise, pause, resume, land, drop — and the seams between
// it and the ledger. A walk can reach some of this in thirty seconds a case;
// here it costs milliseconds, and the branches with no pixel (a stale drop, a
// second ask arriving behind a standing veil) can be reached at all.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group. That
// makes state global to the process, which is why every test starts from
// `freshModel()`.

@MainActor
private func freshModel(budget: Int = 40) -> (AppModel, Door) {
    SharedStore.wipeAll()
    let model = AppModel()
    let door = Door(name: "Instagram")
    model.completeSetup(doors: [door],
                        doorSelections: [:],
                        wallSelection: .init(),
                        budget: budget,
                        downHours: DownHours(start: TimeOfDay(hour: 22),
                                             end: TimeOfDay(hour: 7)))
    return (model, door)
}

@Suite(.serialized) @MainActor struct WaitModelSmoke {

    /// The target itself: if this fails, nothing below means anything.
    @Test func theAppTargetCanBeBuiltAndItsModelConstructed() {
        let (model, door) = freshModel()

        #expect(model.onboarded)
        #expect(model.policy.doors.count == 1)
        #expect(model.policy.doors.first?.name == door.name)
        #expect(model.remainingMinutes == 40)
        #expect(model.waiting == nil)
    }

    /// The price seam the walks drive through `-silkWait`, read directly.
    @Test func theDebugSeamOverridesTheCurveAndTheCurveIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: "silkWait")
        #expect(AppModel.waitLength(forMinutes: 20) == Wait.length(forMinutes: 20))

        UserDefaults.standard.set("3.5", forKey: "silkWait")
        #expect(AppModel.waitLength(forMinutes: 20) == 3.5)
        UserDefaults.standard.set("0", forKey: "silkWait")
        #expect(AppModel.waitLength(forMinutes: 20) == 0)
        UserDefaults.standard.removeObject(forKey: "silkWait")
    }

    @Test func theStalenessSeamOverridesTheWindowAndTheWindowIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: "silkStale")
        #expect(AppModel.waitStaleAfter == Wait.staleAfter)

        UserDefaults.standard.set("4", forKey: "silkStale")
        #expect(AppModel.waitStaleAfter == 4)
        UserDefaults.standard.removeObject(forKey: "silkStale")
    }
}
