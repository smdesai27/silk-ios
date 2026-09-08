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

@Suite(.serialized) @MainActor struct WaitModelSmoke {

    /// The target itself: if this fails, nothing below means anything.
    ///
    /// The window is `nightWellClearOfNow()` and not the 10 PM–7 AM the product
    /// ships, which is what this fixture used to pin against the real wall
    /// clock. A suite that ran between ten and seven built a model already
    /// inside its own night — `isDownHours` true, the day boundary somewhere
    /// else than every sibling suite assumes — and the only reason nothing here
    /// failed is that nothing here says anything. It is the same trap
    /// `OnboardingUITests.launchArguments` documents, and it does not become
    /// safe by sitting in a smoke test.
    @Test func theAppTargetCanBeBuiltAndItsModelConstructed() {
        let (model, door) = freshModel(downHours: nightWellClearOfNow())

        #expect(model.onboarded)
        #expect(model.policy.doors.count == 1)
        #expect(model.policy.doors.first?.name == door.name)
        #expect(model.remainingMinutes == 40)
        #expect(model.waiting == nil)
    }

    /// The price seam the walks drive through `-silkWait`, read directly.
    @Test func theDebugSeamOverridesTheCurveAndTheCurveIsTheDefault() {
        defer { unpinTheSeams() }
        unpinTheSeams()
        #expect(AppModel.waitLength(forMinutes: 20) == Wait.length(forMinutes: 20))

        UserDefaults.standard.set("3.5", forKey: "silkWait")
        #expect(AppModel.waitLength(forMinutes: 20) == 3.5)
        UserDefaults.standard.set("0", forKey: "silkWait")
        #expect(AppModel.waitLength(forMinutes: 20) == 0)
    }

    @Test func theStalenessSeamOverridesTheWindowAndTheWindowIsTheDefault() {
        defer { unpinTheSeams() }
        unpinTheSeams()
        #expect(AppModel.waitStaleAfter == Wait.staleAfter)

        UserDefaults.standard.set("4", forKey: "silkStale")
        #expect(AppModel.waitStaleAfter == 4)
    }
}
