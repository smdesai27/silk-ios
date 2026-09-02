import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// The wait's state machine at model level: the branches that decide whether a
// veil rises at all, what a departure costs, and what happens to an ask that is
// no longer wanted.
//
// `SilkCore`'s WaitTests own the `Wait` value type — its clock, its price, its
// idempotence — and the UI walks own the pixels. What is left, and what lives
// here, is `AppModel`'s wiring between them: which verdicts reach `raiseWait`,
// which do not, and where each ending path leaves the ledger and the thread.
// Three of these cases have no pixel to walk (a `.restated` ask that never
// draws anything, a second sentence dropped behind a standing veil, a staleness
// drop that would otherwise cost two real minutes of standing still) and one is
// only reachable here at all.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group. That
// makes state global to the process, which is why every test starts from
// `freshModel()`.

// MARK: - Fixtures

/// A down-hours window that contains no minute of any day, and whose edge is
/// half a day away whatever the clock says when the suite runs.
///
/// Every test below drives a real grant through `handle`, and the shipped
/// 22–7 window would answer all of them with "Opens at 7 AM" whenever the
/// suite is run at night — the hours this project is most often built in. A
/// zero-length window contains nothing (`DownHours.contains`, start == end
/// makes the half-open test vacuous), so `isDownHours` is false at every hour.
///
/// The start still matters even so: `Validator` clamps a grant at the next
/// occurrence of it (`nextDownHoursStart`, which does not care that the window
/// is empty), so a window pinned at midnight would silently shorten a
/// ten-minute ask made at 23:55 to five. Anchoring it twelve hours from now
/// puts that edge at least eleven and a half hours out, always.
private func noWindowTonight(at reference: Date = .now) -> DownHours {
    let hour = (Calendar.current.component(.hour, from: reference) + 12) % 24
    let nowhere = TimeOfDay(hour: hour, minute: 30)
    return DownHours(start: nowhere, end: nowhere)
}

@MainActor
private func freshModel(budget: Int = 40,
                        downHours: DownHours = noWindowTonight()) -> (AppModel, Door) {
    SharedStore.wipeAll()
    let model = AppModel()
    let door = Door(name: "Instagram")
    model.completeSetup(doors: [door],
                        doorSelections: [:],
                        wallSelection: .init(),
                        budget: budget,
                        downHours: downHours)
    // Every wait below is born watching, and that is only true while the host
    // app is foreground. `raiseWait` parks a wait created in the background
    // (the C1 fix), so a runner that started tests before the scene activated
    // would fail nine cases at once with nine unrelated-looking messages.
    // Named here instead, once.
    #expect(UIApplication.shared.applicationState != .background,
            "the host app is not foreground — every wait below will be born parked")
    return (model, door)
}

/// Both debug seams, off. `defer`red at the top of every test that touches
/// them: a pinned wait or a pinned staleness window left behind would follow
/// the process into whatever runs next.
private func unpinTheSeams() {
    UserDefaults.standard.removeObject(forKey: "silkWait")
    UserDefaults.standard.removeObject(forKey: "silkStale")
}

@Suite(.serialized) @MainActor struct WaitLifecycle {

    // MARK: - (f) No wait to draw: the grant lands in the same pass

    /// Under `Wait.tooShortToDraw` the veil never rises and the ask is answered
    /// exactly as it was before this feature existed.
    ///
    /// The load-bearing assertion is the balance, and it is load-bearing
    /// because of *when* it is read: `handle` has already returned. Under the
    /// wait ordering nothing is debited until the ink lands, so a threshold
    /// that let 0.2 s through would leave 40 here and answer minutes later.
    /// `-silkWait 0` — the kill switch `docs/design/wait.md` §8 recommends
    /// shipping behind — takes this same branch and needs no case of its own:
    /// `waitLength` clamps at zero, the only consumer is
    /// `guard Wait.isWorthDrawing(length)`, and 0 and 0.2 are indistinguishable
    /// to every line below it. `WaitModelSmoke` pins the seam's arithmetic.
    @Test func anAskPricedUnderTheDrawThresholdLandsWithoutAVeil() async {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("0.2", forKey: "silkWait")   // < Wait.tooShortToDraw
        let (model, _) = freshModel()

        await model.handle("instagram for ten")

        #expect(model.waiting == nil, "a wait shorter than its own fade was drawn anyway")
        #expect(model.remainingMinutes == 30, "the grant did not land in the same pass")
        #expect(model.ledger.grants.count == 1)
        let turn = model.conversation.turns.last
        #expect(turn?.reply?.contains(SilkStrings.isOpenFor) == true,
                "the ask was not answered with the grant read-back")
        #expect(turn?.undo != nil,
                "the un-waited grant stopped offering the way back it always offered")
    }

    // MARK: - (e) A door already open is not made to pay again

    /// `.restated` raises no wait — "the door is already open, she can reach it
    /// from the home screen, so a wait there gates nothing" (wait.md §5).
    ///
    /// The wait is pinned at thirty seconds for the second ask, which is the
    /// whole point of the case: if `.restated` fell through to `raiseWait` the
    /// veil would still be standing on the line after it, and the assertion
    /// fails immediately rather than in a timing window.
    @Test func aRestatedAskRaisesNoWaitAndDebitsNothing() async {
        defer { unpinTheSeams() }
        let (model, _) = freshModel()

        // The opening grant, with no ceremony, so the door is genuinely open
        // behind the second sentence.
        UserDefaults.standard.set("0", forKey: "silkWait")
        await model.handle("instagram for ten")
        #expect(model.remainingMinutes == 30, "the opening grant did not land")

        // Five minutes asked against nine still running: covered, so restated.
        UserDefaults.standard.set("30", forKey: "silkWait")
        await model.handle("instagram for five")

        #expect(model.waiting == nil, "an ask already covered was made to watch a wait")
        #expect(model.remainingMinutes == 30, "a restated ask debited the pool a second time")
        #expect(model.ledger.grants.count == 1, "a restated ask recorded a second grant")
        #expect(model.conversation.turns.count == 2)

        let reply = model.conversation.turns.last?.reply
        #expect(reply?.contains(SilkStrings.till.lowercased()) == true,
                "the second ask was not answered with the deadline it already had")
        #expect(reply?.contains(SilkStrings.isOpenFor) == false,
                "the second ask was granted again instead of restated")
        #expect(model.conversation.turns.last?.undo == nil,
                "a restated ask offered a way back to a thing that never moved")

        // The other half of the rule — "and it still opens the app" — is
        // `LaunchCatalog.open`, which is `UIApplication.open` and leaves no
        // model-level trace. It belongs to the walk, deliberately un-asserted
        // here rather than faked.
    }

    // MARK: - (h) Leaving pauses; returning goes on from there

    /// The rule the feature exists for, at model level: the ink stops where it
    /// stopped, nothing accrues while nobody is watching, and coming back does
    /// not start it over.
    ///
    /// The two assertions that carry it are the equalities. `watched` after the
    /// park must equal `watched` four hundred milliseconds later — a wall-clock
    /// wait fails there — and `watched` after the resume must equal the same
    /// number, because a resume that reset would pass every inequality above it.
    ///
    /// **Thirty seconds, not three.** The price is only ever a ceiling here:
    /// the test sleeps 300 + 400 + 300 ms and asserts about a wait that is
    /// still standing, so anything comfortably past a second would do — but at
    /// three seconds the margin was one stall wide. A loaded runner pausing a
    /// beat between the `handle` and the first sleep, or between the resume and
    /// the last, lands the wait mid-test: the veil comes down, the grant is
    /// taken, and the failure reads as "the ink moved while nobody was looking
    /// at it" — a sentence about the feature, pointing at the machine. Thirty
    /// cannot be reached by any stall that leaves the rest of the suite green,
    /// and no assertion below wants a landing.
    @Test func leavingBanksTheWatchingAndComingBackGoesOnFromThere() async throws {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("30", forKey: "silkWait")
        let (model, _) = freshModel()

        await model.handle("instagram for ten")
        #expect(model.waiting != nil, "the wait did not rise over a granted ask")
        #expect(model.waiting?.wait.isWatching == true,
                "the wait was born parked — the host app was not foreground when it rose")

        try await Task.sleep(for: .milliseconds(300))
        model.pauseWait()

        let banked = try #require(model.waiting?.wait.watched)
        #expect(banked >= 0.2, "the span she watched before leaving was not banked")
        #expect(banked < 1.5, "the pause landed far later than it was asked for — the runner stalled")
        #expect(model.waiting?.wait.isWatching == false, "the departure did not stop the ink")

        // Away. Nothing accrues, nothing lands, nothing is spent.
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.waiting?.wait.watched(at: Monotonic.reading) == banked,
                "the ink moved while nobody was looking at it")
        #expect(model.waiting != nil, "the wait landed with nobody watching it")
        #expect(model.remainingMinutes == 40, "a parked wait spent minutes")
        #expect(model.ledger.grants.isEmpty)

        // Back. It goes on from exactly where it stopped.
        model.resumeWait()
        #expect(model.waiting?.wait.watched == banked,
                "coming back reset the wait instead of resuming it")
        #expect(model.waiting?.wait.isWatching == true, "the ink did not start again")

        try await Task.sleep(for: .milliseconds(300))
        let resumed = try #require(model.waiting?.wait.watched(at: Monotonic.reading))
        #expect(resumed > banked + 0.2, "the resumed wait did not accrue")
        #expect(resumed < 1.5, "the resumed reading came far later than it was asked for — the runner stalled")

        // Disarm: a landing left sleeping would fire into whatever runs next,
        // and `SharedStore` is process-global.
        model.pauseWait()
    }

    // MARK: - (c) A wait found past its window

    /// Come back late and the ask is gone: the veil lowers, the turn goes with
    /// it, and the balance is byte-identical to the balance before she typed.
    ///
    /// `conversation.focused` is raised first because the drop has to lower it.
    /// Dropping the turn alone left the worst screen in the feature — a blurred
    /// five-percent page with an empty thread over it — and nothing else in the
    /// app can turn that dim off once the wait has suppressed the blur.
    @Test func aWaitFoundPastItsWindowDropsTheAskAndSpendsNothing() async throws {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("30", forKey: "silkWait")    // unfinishable by accident
        UserDefaults.standard.set("0.2", forKey: "silkStale")
        let (model, _) = freshModel()
        model.conversation.focused = true

        await model.handle("instagram for ten")
        let turn = try #require(model.waiting?.turn)
        #expect(model.conversation.turns.contains(where: { $0.id == turn }),
                "the ask the wait is holding is not in the thread")

        model.pauseWait()                                       // she left
        try await Task.sleep(for: .milliseconds(400))           // past the pinned window
        model.resumeWait()                                      // and came back later

        #expect(model.waiting == nil, "a wait past its window resumed under her thumb")
        #expect(model.remainingMinutes == 40, "an abandoned wait spent minutes")
        #expect(model.ledger.grants.isEmpty, "an abandoned wait recorded a grant")
        #expect(model.conversation.turns.isEmpty,
                "the dropped ask was left in the thread, still thinking")
        #expect(model.conversation.focused == false,
                "the stage was left dim over an empty thread")
    }

    /// The window is a window, and not a rule that every return drops the ask.
    /// Without this the test above passes against a `resumeWait` that drops
    /// unconditionally — which would make the pause unusable and the feature
    /// pointless.
    @Test func aWaitFoundInsideItsWindowResumesInsteadOfDropping() async throws {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("30", forKey: "silkWait")
        UserDefaults.standard.set("5", forKey: "silkStale")
        let (model, _) = freshModel()
        model.conversation.focused = true

        await model.handle("instagram for ten")
        let turn = try #require(model.waiting?.turn)

        model.pauseWait()
        try await Task.sleep(for: .milliseconds(300))           // well inside the window
        model.resumeWait()

        #expect(model.waiting?.turn == turn, "a wait inside its window was dropped")
        #expect(model.waiting?.wait.isWatching == true, "the returned wait did not start again")
        #expect(model.conversation.turns.count == 1, "the ask was dropped inside the window")
        #expect(model.conversation.focused == true,
                "the stage was lifted out from under a standing wait")

        model.pauseWait()
    }

    // MARK: - (d) Two waits cannot be watched at once

    /// `handle` is async and the bar stays live through a slow model parse, so
    /// a second sentence can reach the grant path with a veil already standing.
    /// It is dropped, and the first wait is untouched.
    ///
    /// Both halves matter and the walk can only reach the first. Overwriting
    /// would strand the first turn at "…" for good and swap the door name under
    /// a mark already being drawn; falling through to `apply` would be worse
    /// still — a grant debited and a door opened behind a veil, with nobody
    /// watching the wait that was supposed to pay for it. The balance below is
    /// what catches that second failure.
    @Test func aSecondAskArrivingBehindAStandingWaitIsDroppedNotLanded() async throws {
        defer { unpinTheSeams() }
        UserDefaults.standard.set("30", forKey: "silkWait")
        let (model, door) = freshModel()

        await model.handle("instagram for ten")
        let first = try #require(model.waiting, "the wait did not rise over a granted ask")
        #expect(first.wait.minutes == 10)

        await model.handle("instagram for five")

        // The standing wait is the first one still: same turn, same door, same
        // minutes, same price.
        #expect(model.waiting?.turn == first.turn, "the second ask took the veil from the first")
        #expect(model.waiting?.door == door, "the door under the mark was swapped")
        #expect(model.waiting?.wait.minutes == 10, "the minutes under the mark were swapped")
        #expect(model.waiting?.wait.length == first.wait.length, "the price was re-priced mid-wait")

        // The second turn is gone — not answered, and not left at "…".
        #expect(model.conversation.turns.count == 1, "the dropped ask stayed in the thread")
        #expect(model.conversation.turns.first?.id == first.turn,
                "the turn left standing is not the one the wait is holding")

        // And nothing landed behind the veil.
        #expect(model.remainingMinutes == 40, "a grant was debited behind a standing wait")
        #expect(model.ledger.grants.isEmpty, "a grant was recorded behind a standing wait")

        model.pauseWait()
    }

    // MARK: - (g) The minute clock, and why there is no test for it here
    //
    // `raiseWait` stands the minute clock down (`clock?.cancel()`,
    // AppModel.swift:639) and `clearWait` is the only thing that puts it back
    // (`startClock()`, AppModel.swift:716). Every path that ends a wait — the
    // landing, the down-hours refusal on the far side of it, the deleted door,
    // the staleness drop — funnels through `clearWait`, so "the clock came
    // back" is exactly one call and it is worth an assertion. A drop that
    // forgot it would freeze the whole app's clock silently and for good.
    //
    // There is no honest one to write from here, and the obstacle is timing
    // rather than access. `startClock`'s only externally visible effect is the
    // tick body — `now = .now`, a ledger sync, a reconcile, two day-turn
    // sweeps — and the first tick fires at `secondsUntilNextWake()`, which is
    // `max(1, min(next minute boundary, ledger.nextTransition))`: between one
    // and sixty seconds out, and not steerable from a test. `clock` and
    // `secondsUntilNextWake` are private, `ledger` is `private(set)`, and the
    // soonest transition the app can be talked into minting through `handle` is
    // a one-minute grant. A test could only sample `model.now` and hope, which
    // passes on a coin flip and fails no bug.
    //
    // Asserting `waiting == nil` instead would be this case's tautology:
    // `clearWait` is the sole writer of `waiting = nil` *and* the sole caller
    // of `startClock`, so that assertion restates the branch it is meant to
    // check and would keep passing if `startClock()` were deleted from it.
    //
    // The minimal change that makes it testable is one word — drop `private`
    // from
    //
    //     @ObservationIgnored private var clock: Task<Void, Never>?   // :102
    //
    // after which the honest pair is observable synchronously, and neither half
    // restates the other:
    //
    //     #expect(model.clock?.isCancelled == true)     // while the veil stands
    //     #expect(model.clock?.isCancelled == false)    // after every ending path
    //
    // `raiseWait` cancels the task without nilling it and `startClock` replaces
    // it, so the flag separates the two states exactly. Until that word goes,
    // the case belongs to `OnboardingUITests`'
    // `testAnAbandonedWaitSpendsNothingAndPutsTheClockBack`, which reaches it
    // from outside by asking the bar a question after the drop.
}
