import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// Fixture helpers shared by more than one file in this target. Each used to be
// copy-pasted per-file; consolidated here so a fix (or a drift, like the copy
// that only cleared "silkWait") cannot land in one copy and not the others.

/// A down-hours window that opens six hours out from `now` — clear of the
/// moment the suite runs, so nothing below is refused by the night or clamped
/// by its edge.
func nightWellClearOfNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay + 6 * 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 7 * 60))
}

/// A down-hours window the current minute sits inside — the night, wherever
/// the suite happens to run.
func nightContainingNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay - 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 60))
}

/// A down-hours window containing no minute of any day, whose edge sits half a
/// day out whatever the clock says when the suite runs.
func noWindowTonight(at reference: Date = .now) -> DownHours {
    let hour = (Calendar.current.component(.hour, from: reference) + 12) % 24
    let nowhere = TimeOfDay(hour: hour, minute: 30)
    return DownHours(start: nowhere, end: nowhere)
}

// MARK: - The seams

/// Puts every debug seam in the app back where a fresh process leaves it.
///
/// **Eight keys, and the count is the point.** This used to clear two — the pinned
/// wait and the pinned staleness window — while six others were reset by hand
/// in whichever suite happened to remember. A seam left pinned is not a failure
/// in the suite that pinned it: it is a failure somewhere later, in a test that
/// never mentions the thing that broke it, which is the most expensive shape a
/// test defect has. So the list lives here, once, and every suite spends the
/// same `defer`.
///
/// `@MainActor` because three of the eight are: `WallController.testForceArmed`
/// inherits its class's isolation, `SpendIntent.testForceWallUp` and
/// `LaunchCatalog.testOpenCount` are declared on the main actor outright. Which
/// is why the list is split in two. A `deinit` is nonisolated even on a
/// `@MainActor` class, so a suite that must tear down there — one that arms a
/// seam and has to disarm it after a FAILING case as well as a passing one —
/// can reach `unpinTheProcessSeams()` and nothing more.
@MainActor
func unpinTheSeams() {
    unpinTheProcessSeams()
    // The wall, forced to answer that it armed. Nil is the honest simulator
    // rollback; `true` left standing makes a later suite's grant stand where
    // the product would have taken it back.
    WallController.testForceArmed = nil
    // The intent's other two: the wall-standing read the day sweep takes, and
    // the count that says Siri unshields and does not launch (finding 4).
    SpendIntent.testForceWallUp = nil
    LaunchCatalog.testOpenCount = 0
}

/// The five a nonisolated context can reach — the two `UserDefaults` pins and
/// the three `nonisolated(unsafe)` statics. A strict subset of
/// `unpinTheSeams()`, which calls it, so there is exactly one list per
/// isolation domain and no copy to drift.
func unpinTheProcessSeams() {
    // The two pins the walks and the suites drive the wait by.
    UserDefaults.standard.removeObject(forKey: "silkWait")
    UserDefaults.standard.removeObject(forKey: "silkStale")
    // The widener, silenced. Left standing it silences Apple Intelligence for
    // every later suite in the process — the one seam here that can turn a
    // green run into a differently-green one.
    SilkModelParser.testForceSilent = false
    // What Siri last said, and the grant-leg race hook.
    SpendIntent.lastDialog = ""
    SpendIntent.beforeGrantSave = nil
}

// MARK: - The model, from nothing

/// A wiped App Group, an onboarded `AppModel`, and the first of its doors.
///
/// Seven files wrote this fixture and no two wrote it the same way: one pinned
/// `DownHours(22, 07)` against the real wall clock, one pinned `-silkWait 0`
/// and never unpinned it, three guarded the foreground and four did not. The
/// differences that were deliberate are parameters below; the rest were drift.
///
/// - Parameters:
///   - budget: the day's minutes.
///   - doors: the roster. The first is returned, because that is the one every
///     caller types at.
///   - downHours: the night. `noWindowTonight()` by default — no minute of any
///     day is inside it, so nothing a test says can be refused by the hour it
///     happens to run at. Pass `nightWellClearOfNow()` for a real window that
///     is simply not now, and `nightContainingNow()` to be inside one.
///   - silkWait: the wait's price, pinned before the model is built. Nil leaves
///     whatever the caller already pinned standing — several suites pin it
///     themselves on the line above.
///   - requiringForeground: assert the host app is not backgrounded. `raiseWait`
///     parks a wait created in the background (the C1 fix), so a runner that
///     started tests before the scene activated would fail every wait case at
///     once with unrelated-looking messages. Named once, here, by the suites
///     whose waits are all born watching.
@MainActor
func freshModel(budget: Int = 40,
                doors: [Door] = [Door(name: "Instagram")],
                downHours: DownHours = noWindowTonight(),
                silkWait: String? = nil,
                requiringForeground: Bool = false) -> (AppModel, Door) {
    SharedStore.wipeAll()
    // The intent's seams travel with the store, not with the suite: a forced
    // wall or a stale dialog left by whatever ran last is exactly as global as
    // the App Group this just wiped.
    SpendIntent.lastDialog = ""
    SpendIntent.beforeGrantSave = nil
    SpendIntent.testForceWallUp = nil
    WallController.testForceArmed = nil
    if let silkWait { UserDefaults.standard.set(silkWait, forKey: "silkWait") }
    let model = AppModel()
    model.completeSetup(doors: doors,
                        doorSelections: [:],
                        wallSelection: .init(),
                        budget: budget,
                        downHours: downHours)
    if requiringForeground {
        #expect(UIApplication.shared.applicationState != .background,
                "the host app is not foreground — every wait below will be born parked")
    }
    return (model, doors[0])
}

/// A wiped App Group with a policy in it and no `AppModel` anywhere — the
/// fixture the intent suites need.
///
/// Deliberately no model: a model starts its minute clock, and a clock that
/// syncs the ledger and reconciles the wall on its own schedule is a second
/// writer standing inside a test whose entire subject is which write happened
/// when.
@MainActor
@discardableResult
func freshPolicy(budget: Int = 40,
                 downHours: DownHours = nightWellClearOfNow(),
                 doors: [Door] = [Door(name: "Instagram")],
                 caps: [UUID: Int] = [:]) -> Door {
    SharedStore.wipeAll()
    SpendIntent.lastDialog = ""
    SpendIntent.beforeGrantSave = nil
    SpendIntent.testForceWallUp = nil
    WallController.testForceArmed = nil
    SharedStore.save(policy: PolicyState(budgetMinutes: budget,
                                         downHours: downHours,
                                         doors: doors,
                                         doorCaps: caps))
    return doors[0]
}

// MARK: - Preconditions and polling

/// A grammar precondition: asserts the deterministic parser still claims
/// `sentence` (i.e. does not answer with silence) against `model`'s policy,
/// so a test that types it is measuring the grammar and not the on-device
/// widener.
///
/// `throws`, and it is a `#require` rather than an `#expect`, deliberately: a
/// lost grammar claim must abort the case. Carrying on would hand the sentence
/// to Apple Intelligence — which the simulator has — and every assertion after
/// it would be a property of the machine dressed up as a property of the
/// product.
@MainActor
func claimed(_ sentence: String, _ model: AppModel) throws {
    try #require(DeterministicParser.parse(sentence, state: model.policy) != .silence,
                 "the grammar stopped claiming \"\(sentence)\" — this test now measures the widener")
}

/// Polls `reached` until it returns true or `seconds` elapse, returning
/// whether it was reached in time — waits for a state instead of a fixed
/// duration.
@MainActor
func settle(within seconds: Double = 3.0,
           until reached: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !reached() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
