import XCTest

/// Walks the whole product on the simulator: onboarding end to end, the first
/// grant through the bar, and the surfaces that shipped after it — the
/// wall-down row, the thread's Undo, the status ask, the Settings wheels.
/// This is the file that answers "does it work in the simulator" with
/// something better than a guess.
///
/// It is also a file that has to survive a machine it does not own, and two
/// failures on code known to pass set its shape. A local run lost a chip tap
/// during setup and then spent five seconds waiting for a sheet nothing had
/// asked for; a CI run on a branch whose diff contains no Swift at all failed
/// on the app's teardown kill. Neither was a product bug and neither is fixed
/// by a bigger number, so the taps here prove they landed and the app is put
/// down deliberately rather than left to be killed. Where a number did grow,
/// the comment beside it names the slow thing it is waiting on.
final class OnboardingUITests: XCTestCase {

    // MARK: - How long the walk waits

    // Four waits with reasons rather than one number repeated. `timeout: 5`
    // everywhere was generous for a label already on screen and short for a
    // cold process's first frame, and it read as a considered value in both
    // places when it was only ever considered in one.

    /// Something the current screen already owns: a row, a label, a chip, a
    /// state that has just changed. The shortest of the four, because a miss
    /// here is a real absence and there is nothing slow standing between the
    /// tap and it — but not as short as it looks, because a single element
    /// query against a busy runner can itself cost a second or two, and a wait
    /// has to be able to afford several of them before it calls something gone.
    private static let appear: TimeInterval = 12

    /// A sheet or an overlay arriving on a gesture. Longer because a sheet's
    /// own 0.4s curve is the smallest part of what it waits on: a simulator
    /// xcodebuild has just booted is still serving the app's first launch, the
    /// accessibility server's first tree, and Screen Time's daemons waking, and
    /// the presentation queues behind all of it.
    private static let overlay: TimeInterval = 20

    /// The first thing a freshly launched process draws. A cold launch on a
    /// loaded runner is the slowest operation in the suite by a wide margin,
    /// and it is the one place a long wait costs nothing when things are well.
    ///
    /// 30 was measured on this hardware and was still too tight on GitHub's:
    /// the first launch of a run there, against a simulator booted seconds
    /// earlier on a shared host, missed it and took the suite red on `main`
    /// with the fix for the swallowed tap already in. Ninety is not a guess at
    /// how slow a runner can be so much as an admission that we do not know —
    /// and it is free, because `waitForExistence` returns the instant the
    /// element appears. A generous ceiling here lengthens only genuine
    /// failures, which are the runs nobody is waiting on anyway.
    private static let launch: TimeInterval = 90

    /// A reply in the thread. The bar answers behind a deliberate ~480ms beat
    /// and the parse that precedes it, so this is the beat plus room.
    private static let answer: TimeInterval = 15

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// XCTest kills every app a test launched when the method returns, and that
    /// implicit kill is where CI died: "Failed to terminate
    /// com.silkapp.silk:5985", on a branch carrying no Swift at all. The
    /// timing is not a mystery. A test ends the instant its last assertion
    /// passes, which is routinely the instant the app is still finishing what
    /// the assertion only saw the front of — a grant re-applies the wall and
    /// arms two DeviceActivity schedules, all of it XPC to Screen Time's
    /// daemons, and a process waiting on a daemon answers a kill late. On a
    /// loaded runner, late enough.
    ///
    /// Putting the app down here does two things the implicit kill cannot. It
    /// backgrounds first, so the app is suspended with nothing in flight by the
    /// time the kill lands, and it waits for the process to actually reach
    /// notRunning rather than assuming it did. By the time XCTest's own
    /// teardown runs there is nothing left running for it to fail against.
    ///
    /// `assumeIsolated` rather than a `@MainActor` override: XCTest calls
    /// teardown on the main thread for a synchronous test case, but the base
    /// declaration is not isolated, so an override cannot claim to be. The two
    /// helpers it reaches are static for the same reason — a non-Sendable test
    /// case cannot be handed across the hop, and neither of them wants one.
    override func tearDown() {
        MainActor.assumeIsolated {
            OnboardingUITests.stop(XCUIApplication())
        }
    }

    /// Launch arguments every walk shares: wiped state, and the night window
    /// parked six hours ahead of the wall clock. A fixed window is a trap that
    /// springs whenever the suite runs near it — a 3:28 AM run against a 4 AM
    /// window watched its "sixty minutes" clamp to 31 at the approaching edge
    /// — and no fixed assertion survives that. Six hours ahead, no grant these
    /// tests make can reach the edge, and every walk runs in day behavior.
    private static let launchArguments: [String] = {
        let hour = Calendar.current.component(.hour, from: .now)
        let start = (hour + 6) % 24
        return ["-silkReset", "YES", "-silkDownStart", "\(start)", "-silkDownEnd", "\((start + 1) % 24)",
                // Every grant now stands behind a wait priced off the minutes
                // asked for, which would put a 40-minute clamp test twelve
                // seconds from its own assertion and price a dozen walks off a
                // product curve none of them are about. Pinned short and
                // deliberately not to zero, so the veil is real wherever it
                // appears rather than switched off for the convenience of the
                // suite.
                //
                // How much that actually covers, counted rather than assumed: a
                // veil rises on a *grant*, and of the nine sentences the walks
                // above line 1387 type, four are grants (:425, :531, :911,
                // :1051). So four older walks raise and land a veil incidentally
                // — worth having, because it means a regression in the rise
                // breaks tests that are not about the wait. The **pause** is
                // walked only by the two departure tests below; the sole other
                // `press(.home)` in this file is in `stop(_:)`'s teardown. An
                // earlier version of this comment claimed the overlay "rises,
                // pauses and lands in every walk below", which overstated the
                // net by five times.
                "-silkWait", "0.6"]
    }()

    /// The Screen Time consent alert is SpringBoard's, not ours, and on iOS 26
    /// the simulator really presents it — left standing it swallows the next
    /// tap. Continue only leads deeper, to an "Allow with Passcode" sheet no
    /// passcode-less simulator can finish, so the one deterministic path is to
    /// decline — which the app deliberately doesn't gate on there (the request
    /// is fire-and-forget on the simulator).
    ///
    /// Tapping decline is not the same as the alert being gone: SpringBoard
    /// dismisses on its own curve and the app underneath takes no touches until
    /// it has, so the walk waits the alert out instead of racing its exit. The
    /// answer is remembered per simulator, so most runs find nothing here and
    /// the report of that is what the retry path uses to decide it is looking
    /// at a different problem.
    @MainActor
    @discardableResult
    private static func dismissScreenTimeConsent(timeout: TimeInterval = 4) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // "Don't Allow", curly quote and all — matched loosely so the copy
        // owning the apostrophe stays Apple's problem.
        let decline = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        guard decline.waitForExistence(timeout: timeout) else { return false }
        decline.tap()
        _ = decline.waitForNonExistence(timeout: Self.appear)
        return true
    }

    // MARK: - Waiting, and tapping only when a tap can land

    /// The one place a predicate becomes a wait. `waitForExistence` is the only
    /// wait XCTest hands out and existence is the weakest thing worth knowing
    /// about an element, so everything below asks a sharper question through
    /// here.
    ///
    /// The loop is not belt and braces. A predicate expectation over an
    /// XCUIElement answers by running a fresh accessibility query, and on a
    /// loaded runner that query can fail outright rather than come back false —
    /// at which point the waiter stops early and reports exactly what it would
    /// report for an element that was never there. That is how a Done button
    /// which was on screen and enabled came back as "never became tappable" two
    /// seconds into an eight-second wait, on a machine where an ordinary
    /// `waitForExistence(timeout: 8)` was meanwhile taking fifteen minutes. A
    /// question that went unanswered is not a no, so it is asked again until
    /// the deadline has genuinely passed.
    @MainActor
    private func wait(for element: XCUIElement, _ predicate: String,
                      _ arguments: [Any] = [], timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: predicate, argumentArray: arguments),
                object: element)
            let left = max(deadline.timeIntervalSinceNow, 1)
            if XCTWaiter().wait(for: [expectation], timeout: left) == .completed { return true }
        } while Date.now < deadline
        return false
    }

    /// A state read that waits for the state to arrive. SwiftUI settles a
    /// change and the accessibility server publishes it on a beat of its own,
    /// so reading `isEnabled` or `label` on the line after the tap that changes
    /// them answers the previous question about as often as the current one
    /// under load. Waiting for the expected value cannot hide a wrong one: a
    /// value that never arrives still fails, only later.
    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: String, args: [Any] = [],
                        _ what: String, timeout: TimeInterval = OnboardingUITests.appear,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element, predicate, args, timeout: timeout),
                      what, file: file, line: line)
    }

    @MainActor
    private func expect(_ element: XCUIElement, label: String, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        expect(element, "label == %@", args: [label],
               "\(what) — read \"\(element.label)\"", file: file, line: line)
    }

    @MainActor
    private func expect(_ element: XCUIElement, labelContains fragment: String, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        expect(element, "label CONTAINS %@", args: [fragment],
               "\(what) — read \"\(element.label)\"", file: file, line: line)
    }

    /// A tap that waits until it can land. `exists` is answered from a snapshot
    /// of the accessibility tree and says nothing about whether a touch would
    /// reach the element: a row still sliding in under a page transition, or a
    /// chip under SpringBoard's alert, exists and is not hittable. A tap
    /// delivered then is not an error — it goes somewhere harmless and the walk
    /// carries on against a screen that never changed, which is how a missed
    /// tap surfaces five seconds later and two helpers away from where it
    /// actually happened.
    @MainActor
    private func tap(_ element: XCUIElement, _ what: String,
                     timeout: TimeInterval = OnboardingUITests.appear,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element, "exists == true AND isHittable == true", timeout: timeout),
                      "\(what) never became tappable", file: file, line: line)
        element.tap()
    }

    /// A tap that has to raise something, and proves it did — asking a second
    /// time when it did not.
    ///
    /// The tap that goes missing here is not hypothetical. Setup's permission
    /// step fires `requestAuthorization` and deliberately does not wait for it,
    /// so SpringBoard's consent alert arrives whenever its daemon gets to it,
    /// which on a loaded machine is after the few seconds anyone is willing to
    /// stand and wait for it — and it lands over the chips and eats the next
    /// touch. That is the local failure this file was opened for: a chip tap
    /// swallowed during setup, and then a five-second wait for a sheet nothing
    /// had asked for.
    ///
    /// Asking again is the same request rather than a different one, which is
    /// what makes it safe. `OnboardingView.toggleDoor` reads a second tap on a
    /// named-but-unbound chip as another try at binding, not a deselect, and
    /// every other trigger here — Other apps, a Settings row, Rebind, an add
    /// chip, a page dot — only sets state it already wanted. The second tap is
    /// made only when nothing arrived at all and the trigger is still standing
    /// there to be tapped, so a slow presentation is waited out rather than
    /// tapped through, and a trigger that has gone means the first tap landed.
    @MainActor
    private func tap(_ trigger: XCUIElement, _ what: String,
                     raising target: XCUIElement, _ raised: String,
                     timeout: TimeInterval = OnboardingUITests.overlay,
                     file: StaticString = #filePath, line: UInt = #line) {
        tap(trigger, what, file: file, line: line)
        if target.waitForExistence(timeout: timeout) { return }
        Self.dismissScreenTimeConsent(timeout: 0)
        if trigger.isHittable { trigger.tap() }
        XCTAssertTrue(target.waitForExistence(timeout: timeout),
                      "\(raised) did not rise on \(what)", file: file, line: line)
    }

    /// Puts the app down and waits until it is actually gone, rather than
    /// asking and moving on. Used between the relaunches a test makes and again
    /// in teardown, so the process is never killed while it is busy and never
    /// assumed dead while it is dying. A consent alert left standing outlives
    /// the process and would land over whatever launches next, so it goes
    /// first.
    @MainActor
    private static func stop(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        dismissScreenTimeConsent(timeout: 0)
        // Suspension is the ideal moment to kill — a suspended process holds
        // nothing open — but iOS takes its own time about getting there and
        // measurably will not inside eight seconds, so this asks and does not
        // insist. The state that actually matters arrives in the first beat
        // after the press: out of the foreground, the scene resigned, the UI
        // stopped, and whatever the last assertion caught mid-write given its
        // moment to finish.
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackgroundSuspended, timeout: 2)
        app.terminate()
        guard !app.wait(for: .notRunning, timeout: Self.appear) else { return }
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: Self.appear)
    }

    /// A fresh, deterministic launch: wiped state, parked night window.
    @MainActor
    private func launchFresh(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += Self.launchArguments + extra
        app.launch()
        return app
    }

    /// The setup walk, compressed. Every test past the walkthrough needs an
    /// onboarded app more than it needs to re-prove onboarding — the
    /// walkthrough test below owns the step-by-step assertions. Three steps
    /// now: permission → apps → limits, and the last OK lands on Now. The
    /// budget slider is left untouched, so the default 40 stands — every
    /// downstream balance assertion leans on it. Returns the bar, which is
    /// also the proof that Now arrived.
    @MainActor
    @discardableResult
    private func completeSetup(_ app: XCUIApplication, door: String = "Reddit") -> XCUIElement {
        let ok = app.buttons["silk.setup.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: Self.launch), "onboarding did not show")
        tap(ok, "OK", raising: app.staticTexts["Which apps should Silk block?"], "the apps step")
        Self.dismissScreenTimeConsent()
        let chip = app.buttons["chip.\(door)"]
        XCTAssertTrue(chip.waitForExistence(timeout: Self.appear), "the \(door) chip is missing")
        bindThroughPicker(app, app: door, from: chip, "the \(door) chip")
        tap(ok, "OK", raising: app.staticTexts["How many minutes a day?"], "the limits step")
        let bar = app.textFields["silk.bar"]
        tap(ok, "OK", raising: bar, "Now")
        return bar
    }

    /// Naming a door now raises Silk's picker sheet, and the sheet's Done is
    /// the gate — so binding is part of finishing the apps step, not something
    /// a simulator run can skip. Picks the one app and commits. The tap that
    /// raises the sheet is made in here rather than at the call site so that it
    /// can be re-made: this is the tap that was observed going missing.
    @MainActor
    private func bindThroughPicker(_ ui: XCUIApplication, app named: String,
                                   from trigger: XCUIElement, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let header = element(ui, "silk.picker.header")
        tap(trigger, what, raising: header, "the picker sheet", file: file, line: line)
        let row = ui.buttons["silk.picker.row.\(named)"]
        XCTAssertTrue(row.waitForExistence(timeout: Self.appear),
                      "\(named) was not in the list", file: file, line: line)
        tap(row, "the \(named) row", file: file, line: line)
        let done = ui.buttons["silk.picker.done"]
        expect(done, "isEnabled == true", "Done stayed dead on exactly one app",
               file: file, line: line)
        tap(done, "Done", file: file, line: line)
        XCTAssertTrue(header.waitForNonExistence(timeout: Self.overlay),
                      "the picker sheet did not come down", file: file, line: line)
    }

    /// Identifier lookup that does not guess the element's type: a combined
    /// Settings row reads as a button on some releases and a plain element on
    /// others, and the picker's layers are bare stacks.
    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Types a sentence at the bar. The tap has to take focus before a
    /// character can go anywhere, and the bar is the last thing to settle when
    /// a page or an overlay has just moved, so it waits to be tappable like
    /// every other tap here.
    @MainActor
    private func say(_ bar: XCUIElement, _ sentence: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        tap(bar, "the bar", file: file, line: line)
        // On a cold simulator the session's FIRST focus has been seen to take
        // and then drop: the stage dims and the bar rises five seconds after
        // the tap, holds for eight, and snaps back to its dock with no
        // keyboard just as the typing starts — "neither element nor any
        // descendant has keyboard focus". Six runs in eleven, first-in-lane
        // or right after a build, never on a warm simulator, and the app
        // itself has no path that resigns the field before a sentence
        // (`SilkApp`'s tap-out catcher and the wait's veil are the only two,
        // and neither can fire yet). The cause is not found; the recording
        // and hierarchy are in the 2026-09-02 scout notes. So the walk waits
        // for focus and, if it went, asks once more — a bar that will not
        // hold focus twice is still a failure, and every other assertion in
        // the suite is unchanged.
        if !waitForFocus(bar, timeout: 4) {
            tap(bar, "the bar, again", file: file, line: line)
            _ = waitForFocus(bar, timeout: 4)
        }
        bar.typeText(sentence)
    }

    /// Whether `element` has keyboard focus within `timeout`, polled the way
    /// XCTest itself checks before it types.
    @MainActor
    @discardableResult
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"),
                                  evaluatedWith: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }

    /// The backdrop is the picker's commit button, but the wheels fold into
    /// single adjustable elements and the backdrop's own element does not
    /// surface reliably — so tap through the overlay itself, low, under the
    /// wheels, where only the backdrop listens.
    ///
    /// The overlay fades in on its own curve and a coordinate tap is aimed at a
    /// frame, not an element, so a tap made mid-fade is aimed at the Settings
    /// row underneath. Settle on the wheel becoming tappable, not on the veil:
    /// `silk.picker` is a full-screen button whose centre sits under the wheels,
    /// and asking whether it is hittable can fail the test outright
    /// ("Activation point invalid") rather than return false. That is the
    /// failure `testACapSetOverARunningGrantDoesNotClaimTheDoorIsShut` hit
    /// after a drag, at the wait on this overlay.
    @MainActor
    private func tapPickerBackdrop(_ app: XCUIApplication) {
        let overlay = element(app, "silk.picker")
        settlePicker(app, overlay)
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
    }

    /// Steps a wheel by whole rows. The wheel folds into one adjustable
    /// element, so the drag goes through the overlay's frame: the single wheel
    /// sits centred, ~25pt below the overlay's middle (title + its 34pt seat
    /// above). A slow 52pt-per-row drag with a settling hold snaps exactly
    /// `rows` seats — positive drags the column down (earlier values).
    @MainActor
    private func dragWheel(_ app: XCUIApplication, rows: Int) {
        let overlay = element(app, "silk.picker")
        settlePicker(app, overlay)
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
        let end = start.withOffset(CGVector(dx: 0, dy: CGFloat(rows) * 52))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    /// Wait until the picker is a thing a coordinate can be aimed at. Never
    /// asks whether the veil itself is hittable — see `tapPickerBackdrop`.
    @MainActor
    private func settlePicker(_ app: XCUIApplication, _ overlay: XCUIElement) {
        _ = overlay.waitForExistence(timeout: Self.appear)
        let wheel = app.descendants(matching: .any)
            .matching(identifier: "silk.picker.wheel.0")
            .firstMatch
        // Short existence check first: if the identifier never surfaces, a
        // full `appear` wait would stall every drag and backdrop tap.
        if wheel.waitForExistence(timeout: 2),
           wait(for: wheel, "exists == true AND isHittable == true", timeout: Self.appear) {
            return
        }
        // Weakest settle that does not query the backdrop's hit point: a
        // full-screen frame has arrived. Polled rather than slept; returns
        // the instant the frame is large enough to aim at.
        let deadline = Date.now.addingTimeInterval(Self.appear)
        repeat {
            let frame = overlay.frame
            if overlay.exists && frame.width > 100 && frame.height > 100 { return }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        } while Date.now < deadline
    }

    @MainActor
    func testOnboardingWalkthroughAndFirstGrant() throws {
        let app = launchFresh()
        let ok = app.buttons["silk.setup.ok"]

        // Step 1 — permission
        XCTAssertTrue(app.staticTexts["Silk uses Screen Time to block the apps you choose."]
                        .waitForExistence(timeout: Self.launch),
                      "onboarding did not show")
        expect(ok, "isEnabled == true", "OK was dead on the permission step")
        // If the apps step never arrives, authorization gated the flow — which
        // on the simulator it must never do; the request is fire-and-forget
        // there precisely so that it cannot.
        tap(ok, "OK", raising: app.staticTexts["Which apps should Silk block?"], "the apps step")

        // Step 2 — apps
        Self.dismissScreenTimeConsent()
        // Each name raises its own sheet and is answered there before the next
        // one is named — one app at a time, which is the whole point of the
        // step. Naming and binding are no longer separable.
        let instagram = app.buttons["chip.Instagram"]
        XCTAssertTrue(instagram.waitForExistence(timeout: Self.appear))
        bindThroughPicker(app, app: "Instagram", from: instagram, "the Instagram chip")
        bindThroughPicker(app, app: "TikTok", from: app.buttons["chip.TikTok"], "the TikTok chip")
        // The quiet door to the extras sits below the chips — plural is
        // correct there, and its own sheet says so.
        XCTAssertTrue(app.buttons["silk.setup.other"].exists, "the Other apps button is missing")
        // Simulator: OK stays enabled regardless of selection.
        expect(ok, "isEnabled == true", "OK went dead on the apps step")

        // Step 3 — limits: the slider reads 40 until moved, and the wheels
        // sit under their caption.
        tap(ok, "OK", raising: app.staticTexts["How many minutes a day?"], "the limits step")
        XCTAssertTrue(app.sliders["silk.setup.budget"].exists,
                      "the budget slider is missing")
        XCTAssertTrue(app.staticTexts["Locked overnight"].exists,
                      "the overnight caption is missing above the wheels")

        // Now — setup complete after three steps, apps listed, the bar present
        let bar = app.textFields["silk.bar"]
        tap(ok, "OK", raising: bar, "Now")
        XCTAssertTrue(app.staticTexts["Instagram"].waitForExistence(timeout: Self.appear))
        XCTAssertTrue(app.staticTexts["TikTok"].waitForExistence(timeout: Self.appear))

        // The first grant, through the whole pipeline: parse → validate →
        // debit → read-back. 40 - 10 = 30 left.
        say(bar, "Instagram, ten\n")
        // The reply is a sentence now, not a time-statement: the current design
        // gives the bar a conversation, so "Instagram · 10 · till 5:12" became
        // "Instagram is open for 10 min."
        let readBack = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Instagram is open for 10")
        ).firstMatch
        XCTAssertTrue(readBack.waitForExistence(timeout: Self.answer), "grant read-back did not appear")
        XCTAssertTrue(app.staticTexts["30"].waitForExistence(timeout: Self.appear), "ensō did not debit to 30")
    }

    /// Every chip tap must say what the system picker never does: one app
    /// only, then Done. The simulator skips the sheet itself, but the line is
    /// the contract and it must land — on the first tap, again on later taps,
    /// and away on a deselect. The over-selection correction copy can't be
    /// reached here (the picker is non-functional on the simulator); the
    /// verdicts and both composed lines are unit-tested in SilkCore's
    /// DoorBindingTests, and this walk proves the slot they land in.
    @MainActor
    func testChipTapShowsOneAppGuidance() throws {
        let app = launchFresh()
        let ok = app.buttons["silk.setup.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: Self.launch), "onboarding did not show")
        tap(ok, "OK", raising: app.staticTexts["Which apps should Silk block?"], "the apps step")
        Self.dismissScreenTimeConsent()

        let header = element(app, "silk.picker.header")
        XCTAssertFalse(header.exists, "the picker sheet was up before any chip was tapped")

        let instagram = app.buttons["chip.Instagram"]
        XCTAssertTrue(instagram.waitForExistence(timeout: Self.appear))

        // The sheet rises on the tap — no reading beat to wait out — and its
        // header carries the door's name and the rule, above Apple's list
        // rather than underneath it.
        tap(instagram, "the Instagram chip", raising: header, "the picker sheet")
        expect(header, labelContains: "Instagram", "the sheet did not name the door")
        expect(header, labelContains: "Just Instagram", "the sheet did not state the one-app rule")

        // Done is the gate, and it starts shut: nothing is picked yet.
        let done = app.buttons["silk.picker.done"]
        XCTAssertTrue(done.exists, "the sheet offered no Done")
        expect(done, "isEnabled == false", "Done was live with nothing picked")
        let status = app.staticTexts["silk.picker.status"]
        expect(status, label: "Nothing picked yet", "the status line did not rest")

        // One app wakes it.
        tap(app.buttons["silk.picker.row.Instagram"], "the Instagram row")
        expect(done, "isEnabled == true", "Done stayed dead on exactly one app")

        // A second kills it again, and says why — the mistake the old flow
        // only caught after the list came down.
        tap(app.buttons["silk.picker.row.TikTok"], "the TikTok row")
        expect(done, "isEnabled == false", "Done stayed live on two apps")
        expect(status, label: "2 picked — tap one to remove.", "the sheet did not state the correction")

        // A category can never be a door, however many apps ride with it.
        tap(app.buttons["silk.picker.row.TikTok"], "the TikTok row")
        tap(app.buttons["silk.picker.row.Social"], "the Social row")
        expect(done, "isEnabled == false", "a category got past Done")
        expect(status, label: "A category can't be a door — pick one app.",
               "the sheet did not state the category rule")

        // Cancelling a name that never got an app takes the name with it:
        // setup will not carry a door with nothing behind it.
        tap(app.buttons["silk.picker.cancel"], "Cancel")
        XCTAssertTrue(header.waitForNonExistence(timeout: Self.overlay), "the sheet did not come down")
        expect(app.buttons["chip.Instagram"], "isSelected == false",
               "a cancelled binding left its name selected")
    }

    /// The extras are the one place plural is right, and the sheet says so
    /// instead of applying the door rule everywhere and looking arbitrary.
    @MainActor
    func testOtherAppsSheetAllowsMany() throws {
        let app = launchFresh()
        let ok = app.buttons["silk.setup.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: Self.launch), "onboarding did not show")
        tap(ok, "OK", raising: app.staticTexts["Which apps should Silk block?"], "the apps step")
        Self.dismissScreenTimeConsent()

        let header = element(app, "silk.picker.header")
        tap(app.buttons["silk.setup.other"], "Other apps", raising: header, "the extras sheet")
        expect(header, labelContains: "Other apps", "the extras sheet kept a door's title")

        let done = app.buttons["silk.picker.done"]
        expect(done, "isEnabled == false", "Done was live with nothing picked")
        tap(app.buttons["silk.picker.row.Facebook"], "the Facebook row")
        expect(done, "isEnabled == true", "one extra was refused")
        tap(app.buttons["silk.picker.row.Snapchat"], "the Snapchat row")
        expect(done, "isEnabled == true", "the extras refused a second app — plural is correct here")
        expect(app.staticTexts["silk.picker.status"], label: "2 apps",
               "the extras did not count what was picked")
    }

    @MainActor
    func testOverAskClampsToBalance() throws {
        let app = launchFresh()
        let bar = completeSetup(app)

        // Ask for more than the budget. The Validator clamps the over-ask to
        // the minutes actually remaining (handoff README.md:248-249, mirrored
        // in Validator.swift's `min(minutes, remaining)`): sixty against a
        // 40 budget grants 40, and the read-back states the clamped number —
        // a grant sentence, never a refusal. The reply lands in the thread
        // after the deliberate ~480ms beat, so the wait is generous.
        say(bar, "give me sixty minutes of reddit\n")
        let clamped = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 40")
        ).firstMatch
        XCTAssertTrue(clamped.waitForExistence(timeout: Self.answer), "clamped grant read-back did not appear")
        // The clamp is real, not just spoken: the whole balance was debited.
        XCTAssertTrue(app.staticTexts["0"].waitForExistence(timeout: Self.appear), "ensō did not debit to 0")
    }

    /// The wall's truth-telling row (docs/market/gaps.md #5). The standing is
    /// re-judged on an onboarded init or foreground, so the flag is asserted
    /// across a relaunch: setup happens under -silkReset, then the app comes
    /// back onboarded with — and without — the wall forced down.
    @MainActor
    func testWallDownRowShowsOnlyWhenForced() throws {
        let app = launchFresh()
        completeSetup(app)
        Self.stop(app)

        // Onboarded, no flag: the simulator's standing is always up, so the
        // row must stay away. No -silkReset here — it would wipe the walk
        // above. The parked window is not restated either: it was written into
        // the policy by setup, and only OnboardingView's own state reads the
        // argument.
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.textFields["silk.bar"].waitForExistence(timeout: Self.launch),
                      "did not land on Now when already onboarded")
        XCTAssertFalse(app.staticTexts["Blocking is off."].exists)
        XCTAssertFalse(app.buttons["silk.wall.raise"].exists)
        Self.stop(app)

        // -silkWallDown YES forces the standing down, and the row states it
        // with its one action — "Turn it on." — beside it.
        app.launchArguments = ["-silkWallDown", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Blocking is off."].waitForExistence(timeout: Self.launch),
                      "the blocking-off row did not show under -silkWallDown")
        XCTAssertTrue(app.buttons["silk.wall.raise"].waitForExistence(timeout: Self.appear),
                      "the blocking-off row carried no way to turn it back on")
    }

    /// A typed tighten lands instantly and carries the way back in the thread
    /// — the Undo pill, not a toast: toasts answer changes made elsewhere.
    @MainActor
    func testTypedTightenOffersUndoAndRestores() throws {
        let app = launchFresh()
        let bar = completeSetup(app)

        // "no more reddit today" is pure grammar — closer phrase, door, no
        // number — so DeterministicParser resolves it without the model and
        // the outcome cannot drift run to run.
        say(bar, "no more reddit today\n")
        let closed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit closed until")
        ).firstMatch
        XCTAssertTrue(closed.waitForExistence(timeout: Self.answer), "close read-back did not appear")

        let undoPill = app.buttons["silk.turn.undo"]
        XCTAssertTrue(undoPill.waitForExistence(timeout: Self.appear), "the tighten offered no way back")
        tap(undoPill, "the thread's Undo", raising: app.staticTexts["Put back."], "the Undo reply")

        // The restore is real, not just spoken: status names a closed door
        // when there is one, and after Undo it has none to name — the reply
        // is the bare balance, nothing appended.
        say(bar, "status\n")
        XCTAssertTrue(app.staticTexts["40 min left."].waitForExistence(timeout: Self.answer),
                      "status did not read a clean balance after Undo")
    }

    /// The status ask, straight through: a question changes nothing and is
    /// answered in the thread with the balance.
    @MainActor
    func testTypedStatusAskAnswersBalance() throws {
        let app = launchFresh()
        let bar = completeSetup(app)

        say(bar, "status\n")
        XCTAssertTrue(app.staticTexts["40 min left."].waitForExistence(timeout: Self.answer),
                      "status did not answer with the balance")
        // Nothing was spent by asking.
        XCTAssertTrue(app.staticTexts["40"].exists, "the ensō moved on a question")
    }

    /// The budget row raises the wheel; the backdrop takes it down. Commit and
    /// dismiss are the same gesture, so the overlay must fade out on the tap —
    /// there is no other exit to try.
    @MainActor
    func testSettingsBudgetPickerOpensAndBackdropDismisses() throws {
        let app = launchFresh()
        completeSetup(app)

        let budgetRow = element(app, "silk.settings.budget")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: budgetRow, "Settings")

        let picker = element(app, "silk.picker")
        tap(budgetRow, "the budget row", raising: picker, "the wheel")

        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay), "the wheel did not fade out")
    }

    /// A Settings tighten answers with a toast carrying Undo — the one
    /// undo-bearing toast in the product — and Undo puts the old rule back
    /// where the row can read it.
    @MainActor
    func testSettingsTightenToastCarriesUndo() throws {
        let app = launchFresh()
        completeSetup(app)

        let budgetRow = element(app, "silk.settings.budget")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: budgetRow, "Settings")
        tap(budgetRow, "the budget row", raising: element(app, "silk.picker"), "the wheel")

        // 40 → 15 is a tighten: it lands on the backdrop tap, and the receipt
        // states the balance the new rule leaves. The wheel opens centred on
        // 45 (nearest seat to 40), so 15 is two rows up the table.
        dragWheel(app, rows: 2)
        tapPickerBackdrop(app)

        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: Self.appear), "the tighten receipt did not toast")
        expect(toast, label: "15 left today.", "the receipt did not state the new balance")
        let undo = app.buttons["silk.toast.undo"]
        XCTAssertTrue(undo.exists, "the tighten toast carried no Undo")

        // The row already reads the new rule…
        expect(budgetRow, labelContains: "15 min", "the budget row did not take the tighten")

        // …and Undo restores the old one, row and all.
        tap(undo, "the toast's Undo")
        let restored = app.descendants(matching: .any)
            .matching(identifier: "silk.settings.budget")
            .matching(NSPredicate(format: "label CONTAINS %@", "40 min")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: Self.appear), "Undo did not restore the budget")
    }

    /// The editor's backdrop is the exit; like the wheel's, its element does
    /// not surface reliably, so tap through the overlay itself, low, where
    /// only the backdrop listens. Existence and a usable frame, not
    /// hittability: the veil is a full-screen button whose centre is covered,
    /// and querying `isHittable` on that shape can fail the test outright.
    @MainActor
    private func tapEditorBackdrop(_ app: XCUIApplication) {
        let overlay = element(app, "silk.settings.editor")
        _ = overlay.waitForExistence(timeout: Self.appear)
        let deadline = Date.now.addingTimeInterval(Self.appear)
        repeat {
            let frame = overlay.frame
            if overlay.exists && frame.width > 100 && frame.height > 100 { break }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        } while Date.now < deadline
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
    }

    /// A door row raises the door's detail card — Change app and Remove demoted
    /// under the door's own name — and Change app raises the same sheet setup
    /// uses. The simulator's family picker is non-functional, so the binding is
    /// skipped there; the sheet naming the door is the contract and it must land.
    /// The backdrop is the exit, exactly as the wheel's is.
    @MainActor
    func testSettingsDoorRowOpensEditorWithRebindGuidance() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")

        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        let rebind = app.buttons["silk.settings.rebind"]
        XCTAssertTrue(rebind.waitForExistence(timeout: Self.appear), "the card offered no Change app")
        XCTAssertTrue(app.buttons["silk.settings.remove"].exists, "the card offered no Remove")

        // Change app raises the same sheet setup uses — one idiom, not two.
        let header = element(app, "silk.picker.header")
        tap(rebind, "Rebind", raising: header, "the picker sheet")
        expect(header, labelContains: "Reddit", "the sheet did not name the door")
        expect(app.buttons["silk.picker.done"], "isEnabled == false",
               "Done was live before an app was picked")
        tap(app.buttons["silk.picker.cancel"], "Cancel")
        XCTAssertTrue(header.waitForNonExistence(timeout: Self.overlay), "the sheet did not come down")
    }

    /// The add row offers only what is genuinely free (Reddit, already a
    /// door, must not be offered twice), a chip tap makes the door and lands
    /// the one-app guidance, and Remove takes a door out with the undo toast
    /// carrying the whole way back.
    @MainActor
    func testSettingsAddAndRemoveDoorWithUndo() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit

        let addRow = element(app, "silk.settings.door.add")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: addRow, "the add row")

        let editor = element(app, "silk.settings.editor")
        tap(addRow, "the add row", raising: editor, "the add overlay")
        XCTAssertTrue(app.buttons["add.chip.Instagram"].waitForExistence(timeout: Self.appear),
                      "Instagram was not offered")
        XCTAssertFalse(app.buttons["add.chip.Reddit"].exists,
                       "Reddit is already a door and was offered again")

        // The chip tap makes the door and raises its binding sheet at once.
        // Cancelling takes the name back with it: an added door with no app
        // behind it is the half-state neither setup nor the editor will carry.
        let header = element(app, "silk.picker.header")
        tap(app.buttons["add.chip.Instagram"], "the Instagram add chip",
            raising: header, "the picker sheet")
        expect(header, labelContains: "Instagram", "the sheet did not name the new door")
        tap(app.buttons["silk.picker.cancel"], "Cancel")
        XCTAssertTrue(header.waitForNonExistence(timeout: Self.overlay), "the sheet did not come down")
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.overlay), "the add overlay did not fade out")
        let instagramRow = element(app, "silk.settings.door.Instagram")
        XCTAssertFalse(instagramRow.exists,
                       "a cancelled add left a door with no app behind it")

        // Again, answered this time: the door arrives only once it has its app.
        tap(addRow, "the add row", raising: editor, "the add overlay")
        bindThroughPicker(app, app: "Instagram",
                          from: app.buttons["add.chip.Instagram"], "the Instagram add chip")
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.overlay), "the add overlay did not fade out")
        XCTAssertTrue(instagramRow.waitForExistence(timeout: Self.appear),
                      "the added door has no Settings row")

        // Remove: instant, and the toast carries the way back.
        tap(instagramRow, "the Instagram row", raising: editor, "the door detail card")
        tap(app.buttons["silk.settings.remove"], "Remove")
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.overlay), "the editor outlived the removal")
        XCTAssertTrue(instagramRow.waitForNonExistence(timeout: Self.overlay), "the removed door kept its row")
        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: Self.appear), "the removal did not toast")
        expect(toast, label: "Instagram removed.", "the removal receipt did not name the door")
        let undo = app.buttons["silk.toast.undo"]
        XCTAssertTrue(undo.exists, "the removal toast carried no Undo")
        tap(undo, "the toast's Undo")
        XCTAssertTrue(instagramRow.waitForExistence(timeout: Self.appear), "Undo did not restore the door")
    }

    // MARK: - Per-app daily caps
    //
    // The Settings wheel is the only surface that sets a cap, so these walks are
    // the whole feature's front door: what the door's card states, what the wheel
    // writes, what the row and the card read back, and — in
    // `…ClampsTheGrantAtTheBar` — that the ceiling is real by the time the bar is
    // asked for minutes past it.

    /// **The card states before it offers.** A door row raises the door's own
    /// detail card, and the cap row is not merely present on it: it carries the
    /// ceiling actually in force, readable before anything is tapped, and it
    /// stands ABOVE the two actions that are demoted under the rule.
    ///
    /// This walk replaces `testSettingsDoorEditorOffersTheCapRow`, which pinned
    /// the opposite order — Change app, then Daily cap, then Remove — on an
    /// overlay that was the wheel picker's costume worn by three tappable serif
    /// rows. Both halves of the old assertion are deliberately inverted, so this
    /// cannot pass on that layout: the cap row now reads its VALUE as well as its
    /// word (it did not, and could not), and it now sits above Change app rather
    /// than below it.
    ///
    /// `element(…)` rather than `app.buttons[…]` for the cap row, for the reason
    /// the helper exists: the row folds its label and its value into one element
    /// with `children: .combine`, and a combined row reads as a button on some
    /// releases and a plain element on others. Its label is therefore "Daily cap"
    /// AND the value in one string, which is why the matches are `contains`.
    @MainActor
    func testSettingsDoorCardStatesTheCapAboveItsActions() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit, capped by nothing

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")

        let card = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: card, "the door detail card")

        let cap = element(app, "silk.settings.cap")
        XCTAssertTrue(cap.waitForExistence(timeout: Self.appear), "the card offered no Daily cap")
        expect(cap, labelContains: "Daily cap", "the cap row did not carry its own word")
        // The whole of the redesign, in one assertion: a fresh door has no
        // ceiling, and the card says so where you can read it — the wheel's own
        // first-seat word, composed through `Caps.settingsValue`.
        expect(cap, labelContains: "No cap", "the cap row did not read the ceiling in force")

        let rebind = app.buttons["silk.settings.rebind"]
        let remove = app.buttons["silk.settings.remove"]
        XCTAssertTrue(rebind.exists, "the card offered no Change app")
        XCTAssertTrue(remove.exists, "the card offered no Remove")
        // Wholly above, not merely higher: the rule divides what the card states
        // from what it offers, so the cap row's bottom edge clears Change app's
        // top edge with the hairline between them.
        XCTAssertLessThan(cap.frame.maxY, rebind.frame.minY,
                          "the cap row did not stand above the demoted actions")
        XCTAssertLessThan(rebind.frame.midY, remove.frame.midY,
                          "Remove sat above Change app")
    }

    /// The cap row hands the door to the wheel and takes the card down on the
    /// way. Both matter: the wheel's title is the only thing left saying which
    /// door is being capped, and a card left standing would draw its own .97
    /// veil over the wheel and eat every touch aimed at it.
    @MainActor
    func testSettingsCapRowOpensTheWheelWithTheDoorTitle() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")

        let picker = element(app, "silk.picker")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")

        // The title is asked for by identifier PREFIX and not by a bare name
        // match. `silk.picker` now rides the backdrop (as the editor's
        // identifier does) so children keep `silk.picker.title` / `.wheel.N`;
        // the prefix still matches both, and the label is what separates the
        // title from the Settings door row behind the veil, which also reads
        // "Reddit". Kept as a prefix rather than `silk.picker.title` alone so
        // a stamp regression cannot silently hollow this walk out.
        //
        // It must be the prefix match rather than a bare `staticTexts[…]` on the
        // name: the Settings door row behind the veil is still in the tree and
        // still reads "Reddit", so a query that does not pin the identifier
        // would pass with the wheel absent entirely.
        let named = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                        "silk.picker", "Reddit")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: Self.appear),
                      "the cap wheel did not name the door")
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.overlay),
                      "the door detail card outlived the cap tap and would cover the wheel")
    }

    /// A fresh door has no ceiling, and the row says so in the wheel's own
    /// first-seat word — the round-trip rule: the row must read back what the
    /// wheel would show. It is deliberately not the shared budget, which four
    /// rows printing "40 min" would have made read as an allowance table.
    @MainActor
    func testSettingsUncappedDoorRowReadsNoCap() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit, capped by nothing

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        expect(doorRow, labelContains: "No cap", "an uncapped door's row did not read the wheel's first seat")
    }

    /// The feature end to end, from the only surface that has it: set a ceiling
    /// on the wheel, watch the receipt and the row read it back, then ask the bar
    /// for more minutes than the ceiling allows and get the ceiling.
    @MainActor
    func testSettingsCapCommitTightensAndTheRowReadsItBack() throws {
        let app = launchFresh()
        let bar = completeSetup(app)   // one door: Reddit, budget 40

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        let picker = element(app, "silk.picker")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")

        // An uncapped door opens on "No cap", the first seat; "20 min" is four
        // seats down the table (5, 10, 15, 20).
        dragWheel(app, rows: -4)
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay), "the cap wheel did not fade out")

        // Adding a ceiling is a tighten: it lands now, and its receipt names the
        // door and the ceiling rather than the pool's number — which did not
        // move, and which a bare status already says.
        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: Self.appear), "the cap tighten did not toast")
        expect(toast, label: "Reddit 20 min \u{00B7} day.", "the receipt did not state the new ceiling")
        XCTAssertTrue(app.buttons["silk.toast.undo"].exists, "the cap tighten carried no Undo")
        expect(doorRow, labelContains: "20 min", "the door row did not read the new cap back")

        // And the ceiling is real. Sixty against a budget of 40 clamped to 40
        // before this feature existed; against a cap of 20 it clamps to 20, and
        // the pool is debited by what was actually granted.
        // Back to Now for the hero: the bar answers from any page, but the ensō
        // is only drawn on one. No `raising:` here — the pager keeps every page
        // in the tree, so a hero already matched would prove nothing about the
        // tap.
        tap(app.buttons["silk.dot.0"], "the Now dot")
        say(bar, "give me sixty minutes of reddit\n")
        let capped = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 20")
        ).firstMatch
        XCTAssertTrue(capped.waitForExistence(timeout: Self.answer),
                      "the grant was not clamped to the door's own ceiling")
        XCTAssertTrue(app.staticTexts["20"].waitForExistence(timeout: Self.appear),
                      "ensō did not debit the pool by the capped grant")
    }

    /// The other direction, which nothing walked before this: taking a ceiling
    /// off again. It is a LOOSENING (an absent cap reads as infinity), so rule 3
    /// parks it for tomorrow and the row correctly goes on showing the ceiling
    /// still in force — which is exactly the report. "I set a cap it works, but
    /// when I try to go back to no cap it doesn't work."
    ///
    /// Nothing about rule 3 changes here. What this pins is that the app now
    /// SAYS so: the reply names the door and the value it is holding for
    /// tomorrow, the affordance beside it is the key and not "Undo" — which
    /// would have withdrawn the ask while reading as undoing the waiting — and
    /// the card where the wheel was spun states the wait next to the ceiling it
    /// is waiting behind. Tapping the key closes the round trip in one gesture,
    /// at the point the gesture was made.
    ///
    /// It also measures the capsule. `Silk/Toast.swift` cannot wrap and cannot
    /// truncate, and this reply is the longest thing it can be asked to say
    /// *and* it now carries a second control — so the walk asserts the laid-out
    /// capsule is inside the glass rather than trusting an estimate.
    @MainActor
    func testClearingACapParksAndTheReplyNamesItAndOffersTheKey() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit, budget 40

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        let editor = element(app, "silk.settings.editor")
        let picker = element(app, "silk.picker")
        let capRow = element(app, "silk.settings.cap")

        // A ceiling first, so there is one to take off. This half is the tighten
        // walk's, in four lines: it lands, instantly, and the row reads it back.
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        tap(capRow, "Daily cap", raising: picker, "the cap wheel")
        dragWheel(app, rows: -4)          // No cap → 20 min
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay),
                      "the cap wheel did not fade out")
        expect(doorRow, labelContains: "20 min", "the cap did not land")

        // And now take it off. The wheel opens on the LIVE ceiling — deliberately,
        // because seating it on the pending would show a value that is not in
        // force — so four seats back up is the No-cap seat it started from.
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        tap(capRow, "Daily cap", raising: picker, "the cap wheel")
        dragWheel(app, rows: 4)           // 20 min → No cap
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay),
                      "the cap wheel did not fade out")

        // The reply names the door and the value. It used to be seventeen
        // characters of "Applies tomorrow." — byte-identical to what a budget
        // raise says, carrying no user data at all, over a screen that had
        // visibly not changed.
        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: Self.appear), "the loosening did not toast")
        expect(toast, label: "Tomorrow: Reddit no cap",
               "the parked receipt did not name the door and the value")

        // The affordance is the key, not Undo. Both halves matter: Undo here
        // withdrew the ask, which is not what anyone wants in that second and is
        // not what the word reads as.
        let apply = app.buttons["silk.toast.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: Self.appear),
                      "the parked receipt did not offer the key")
        XCTAssertFalse(app.buttons["silk.toast.undo"].exists,
                       "the parked receipt still offered Undo")

        // Measured, not estimated. The capsule is the two labels plus 18pt of
        // padding a side, and it may not wrap and may not truncate — so what it
        // has to fit inside is the screen.
        //
        // Two assertions, because the runner is not the narrowest device. The
        // first is the literal one: on whatever this is running on, nothing ran
        // off. The second is the one that matters — 375 is the narrowest glass
        // Silk supports, and a suite that only ever runs on a 402pt phone would
        // let a message grow past it unseen. Silk's fonts are fixed size, so
        // this width is the same number on every device.
        // Measured on this walk: 285.2pt for "Tomorrow: Reddit no cap" beside
        // "Apply now.", and the catalogue's longest name ("Instagram") adds 22pt
        // on top of that — 307pt of the 375, with 68 to spare.
        let capsule = toast.frame.union(apply.frame).insetBy(dx: -18, dy: 0)
        XCTAssertTrue(app.frame.insetBy(dx: -0.5, dy: -0.5).contains(capsule),
                      "the receipt ran off the glass — \(capsule.width)pt of \(app.frame.width)")
        XCTAssertLessThanOrEqual(capsule.width, 375,
                                 "the receipt would not fit the narrowest device Silk supports")

        // Rule 3 still holds, and that is the point: nothing landed. The row
        // behind the toast goes on stating the ceiling in force.
        expect(doorRow, labelContains: "20 min", "the loosening applied instantly")

        // And the card where the wheel was spun now says what it is waiting for,
        // beside what is still in force. This is what breaks the retry loop: the
        // wheel used to re-open on the live ceiling with the ask invisible on
        // every surface, so clearing it again produced the same reply over the
        // same unchanged screen.
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        expect(capRow, labelContains: "20 min", "the card stopped stating the ceiling in force")
        let pendingRow = element(app, "silk.settings.pending")
        XCTAssertTrue(pendingRow.waitForExistence(timeout: Self.appear),
                      "the card said nothing about the parked change")
        expect(pendingRow, labelContains: "no cap", "the card did not name what is waiting")

        // The key, spent from the receipt — the whole reason it is offered there.
        tap(apply, "Apply now. on the receipt")
        expect(capRow, labelContains: "No cap", "the key did not clear the ceiling")
        XCTAssertTrue(pendingRow.waitForNonExistence(timeout: Self.overlay),
                      "the card still offered a change that had already landed")

        // …and it is real behind the card too.
        tap(editor, "the backdrop")
        expect(doorRow, labelContains: "No cap", "the cleared ceiling did not reach the row")
    }

    /// A running grant outranks the ceiling the receipt just set — and the
    /// receipt has to know that, because it is the only thing this commit says.
    ///
    /// Thirty minutes of Reddit are granted, then Reddit is capped at 20: the
    /// ceiling is already overdrawn, but the door is open until the grant runs
    /// out, the wall is down, the Now row draws `· till`, and the bar would
    /// answer with the same deadline. The receipt used to say "Reddit closed
    /// until 7:00." in that second — four surfaces, one door, and the only one
    /// she is shown was the false one.
    ///
    /// `Caps.receipt`'s own ordering is pinned in the spine; this walk pins the
    /// wiring, which is the half a spine test cannot see.
    @MainActor
    func testACapSetOverARunningGrantDoesNotClaimTheDoorIsShut() throws {
        let app = launchFresh()
        let bar = completeSetup(app)   // one door: Reddit, budget 40

        say(bar, "give me thirty minutes of reddit\n")
        let granted = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 30")
        ).firstMatch
        XCTAssertTrue(granted.waitForExistence(timeout: Self.answer), "the grant did not land")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        let picker = element(app, "silk.picker")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")
        dragWheel(app, rows: -4)          // No cap → 20 min
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay), "the cap wheel did not fade out")

        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: Self.appear), "the cap tighten did not toast")
        expect(toast, label: "Reddit 20 min \u{00B7} day.",
               "the receipt did not name the ceiling it set")
        XCTAssertFalse((toast.label).contains("closed until"),
                       "the receipt said the door was shut while a grant was still running")
        expect(doorRow, labelContains: "20 min", "the door row did not read the new cap back")
    }

    /// A cap survives a relaunch, the Settings row reads it back, and re-opening
    /// its wheel to look costs nothing.
    ///
    /// Note what this walk does NOT prove, because the name it used to carry
    /// claimed it: 20 is an exact `Caps.wheelTable` seat, so an untouched commit
    /// here would round-trip to 20 and `settle`'s own `proposed != policy` guard
    /// would swallow it with no toast either way. The untouched-wheel rule is
    /// proved by `testBudgetWheelDismissedUntouchedKeepsAnOffGridValue`, where
    /// the value is off-grid and a commit would visibly move it, and by
    /// `CapWheelSeatTests` in the spine. Nothing off-grid is reachable on the
    /// cap wheel until the grammar lands (PR 2), so the cap analogue of the
    /// budget walk belongs to that PR.
    ///
    /// The app is put down and brought back so no earlier toast is left standing
    /// to confuse the absence being asserted — which is what pins the storage
    /// round trip.
    @MainActor
    func testSettingsCapSurvivesARelaunchAndReOpeningItsWheelCostsNothing() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        let picker = element(app, "silk.picker")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")
        dragWheel(app, rows: -4)
        tapPickerBackdrop(app)
        expect(doorRow, labelContains: "20 min", "the cap did not land")

        // No -silkReset: the walk above is what this relaunch is standing on.
        Self.stop(app)
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.textFields["silk.bar"].waitForExistence(timeout: Self.launch),
                      "did not land on Now when already onboarded")

        let row = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: row, "the Reddit row")
        expect(row, labelContains: "20 min", "the cap did not survive a relaunch")

        let editorAgain = element(app, "silk.settings.editor")
        tap(row, "the Reddit row", raising: editorAgain, "the door detail card")
        // The card's own round trip, and the quietest place in the suite to take
        // it: a stored ceiling, no wheel in flight, no toast left standing. The
        // card composes this string through `Caps.settingsValue(cap:)`, the same
        // call the row behind it makes, so what the card states here is what the
        // wheel is about to open on.
        let cap = element(app, "silk.settings.cap")
        expect(cap, labelContains: "20 min", "the card did not read the stored cap back")
        let wheel = element(app, "silk.picker")
        tap(cap, "Daily cap", raising: wheel, "the cap wheel")
        tapPickerBackdrop(app)
        XCTAssertTrue(wheel.waitForNonExistence(timeout: Self.overlay), "the cap wheel did not fade out")

        // A commit would have toasted — a tighten with Undo, or "Applies
        // tomorrow." — so the absence of any toast is the whole assertion. Three
        // seconds is the receipt's own arrival time over, not a guess.
        XCTAssertFalse(app.staticTexts["silk.toast"].waitForExistence(timeout: 3),
                       "a wheel put back where it started still wrote something")
        expect(row, labelContains: "20 min", "an untouched wheel moved the cap")
    }

    /// The untouched-wheel rule, on the value that can actually be caught by it
    /// today. A wheel opens an off-grid number on its NEAREST seat, so
    /// dismissing one that committed writes that seat: a budget of 35 opens on
    /// "30 min" and would be silently tightened to 30 by a screen that was only
    /// being read. Caps make an off-grid value ordinary — a cap wheel has eight
    /// seats — but the budget wheel has had this hole since it shipped.
    ///
    /// This is the half that can be walked. The other half — that the seat a
    /// wheel OPENS on stays reachable, which a first fix broke by comparing the
    /// committed indices against the opening ones — needs a spin away and back
    /// to the same seat, and two drags chained on one wheel do not land where
    /// they are aimed: the attempt landed on 45 and then on 15, never on the
    /// seat the wheel opened on, because the second drag starts before the first
    /// has settled. A walk tuned until it passes is not a pin, so it is not
    /// here. The direction that would actually hurt someone is this one, and
    /// it is covered: if `touched` were ever true on mount, this walk goes red.
    @MainActor
    func testBudgetWheelDismissedUntouchedKeepsAnOffGridValue() throws {
        let app = launchFresh()
        let bar = completeSetup(app)

        // 40 → 35 is a tighten, so it lands instantly and the receipt states the
        // balance it leaves. No wheel can express 35.
        say(bar, "set the budget to 35\n")
        XCTAssertTrue(app.staticTexts["35 left today."].waitForExistence(timeout: Self.answer),
                      "the off-grid budget did not land")

        // The thread's tap-out catcher covers the screen while the bar holds
        // focus, so a tap on the ground is the blur that takes the thread down
        // and gives the dots back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        let budgetRow = element(app, "silk.settings.budget")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: budgetRow, "Settings")
        expect(budgetRow, labelContains: "35 min", "the budget row did not read the off-grid value")

        let picker = element(app, "silk.picker")
        tap(budgetRow, "the budget row", raising: picker, "the wheel")
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay), "the wheel did not fade out")

        XCTAssertFalse(app.staticTexts["silk.toast"].waitForExistence(timeout: 3),
                       "dismissing an untouched wheel committed its nearest seat")
        expect(budgetRow, labelContains: "35 min", "an untouched wheel snapped the budget to a seat")
    }

    // MARK: - Where a wheel is actually resting
    //
    // Every cap walk above either taps a row or drags, which SETS the seat, or
    // reads a label. None of them asks the question the two walks below ask:
    // where does a wheel come to rest when it is merely handed a seat? The
    // answer was "offset 0, whatever it was handed", and no label in this file
    // could see it — the row, the card and the wheel's own accessibility value
    // are all composed from the selection, and the selection was never wrong.
    // Only the scroll was, and a scroll has no label. So this is measured.

    /// The laid-out geometry of every wheel on screen, left to right: the 128×312
    /// window, and the frame of the column of seats scrolling inside it.
    ///
    /// The rows themselves have no elements to ask, deliberately — `Wheel` folds
    /// into ONE adjustable element because the resting value is its whole
    /// VoiceOver reading. What the tree does carry is the scroll view and the
    /// single child that is its content, and that is enough: the child's frame is
    /// reported unclipped and is exactly `52 × count` tall, so seat *i* occupies
    /// `column.minY + 52i` for 52pt. The 52 is not this file's invention — it is
    /// `Wheel`'s own snap unit, the number 312 − 2×130 of content margin exists
    /// to leave exactly one of.
    @MainActor
    private func wheels(_ app: XCUIApplication) -> [(window: CGRect, column: CGRect)] {
        app.scrollViews.allElementsBoundByIndex
            .map { (window: $0.frame, column: $0.children(matching: .other).firstMatch.frame) }
            .sorted { $0.window.minX < $1.window.minX }
    }

    /// The honest assertion about an opening seat: the row carrying the stored
    /// value is the row lying between the hairlines.
    ///
    /// The reading line is the window's own centre. `selectionFrame` straddles it
    /// with two hairlines at ∓26.5, and the 130pt content margins leave exactly
    /// one 52pt seat in the middle of the 312pt window — so "centred in the
    /// window" and "inside the selection band" are the same sentence, and the
    /// window is the element that actually exists.
    @MainActor
    private func expect(_ app: XCUIApplication, wheel i: Int, restingOn seat: Int,
                        _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let all = wheels(app)
        guard i < all.count else {
            return XCTFail("\(what) — there is no wheel \(i) on screen (found \(all.count))",
                           file: file, line: line)
        }
        let (window, column) = all[i]
        let row = CGRect(x: column.minX, y: column.minY + 52 * CGFloat(seat),
                         width: column.width, height: 52)
        XCTAssertEqual(row.midY, window.midY, accuracy: 1,
                       String(format: "%@ — seat %d sits %.1fpt off the reading line; "
                              + "the wheel is resting on seat %.2f",
                              what, seat, row.midY - window.midY,
                              (window.midY - column.minY - 26) / 52),
                       file: file, line: line)
    }

    /// **A wheel opens resting on the seat it was given.**
    ///
    /// `.scrollPosition(id:anchor:)` moves a scroll view in response to a CHANGE
    /// in what it is bound to, and a value the binding was born holding is not
    /// one — so a wheel seeded with its selection laid out at offset 0 and
    /// stayed there. A door capped at 10 min opened with the selection frame over
    /// "No cap" and "10 min" two rows below it in full ink.
    ///
    /// Both pickers, because the fix has to be per wheel: down hours mounts two
    /// with independent selections, and a fix that seated "the wheel" would seat
    /// one of them and leave the other reading someone else's answer.
    @MainActor
    func testWheelsOpenRestingOnTheSeatTheyWereGiven() throws {
        // The window is pinned rather than parked six hours out, because here
        // the seats ARE the assertion and (hour + 6) puts them wherever the wall
        // clock happens to be — usually on seat 0, which is the one seat a wheel
        // that never scrolled gets right by accident. 9:00 PM is downStart seat
        // 2 and 8:00 AM is downEnd seat 6: different from each other, and
        // neither of them 0. Nothing in this walk makes a grant, so the parked
        // window every other walk launches with is protecting nothing here.
        let app = XCUIApplication()
        app.launchArguments += ["-silkReset", "YES", "-silkDownStart", "21", "-silkDownEnd", "8"]
        app.launch()
        completeSetup(app)

        let downRow = element(app, "silk.settings.down")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: downRow, "Settings")
        expect(downRow, labelContains: "9:00\u{00A0}PM", "the pinned night window did not take")

        let picker = element(app, "silk.picker")
        tap(downRow, "the down row", raising: picker, "the down wheels")
        expect(app, wheel: 0, restingOn: 2, "the start wheel did not open on 9:00 PM")
        expect(app, wheel: 1, restingOn: 6, "the end wheel did not open on 8:00 AM")
        // Asked twice. The wheel "opens already resting on it, no animation" —
        // a seat arriving on the 0.4s curve is not resting on anything, and two
        // reads of one frame are far enough apart to catch it still moving.
        expect(app, wheel: 0, restingOn: 2, "the start wheel was still travelling to its seat")
        expect(app, wheel: 1, restingOn: 6, "the end wheel was still travelling to its seat")
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay),
                      "the down wheels did not fade out")
        // A non-breaking space before the meridiem, not a plain one:
        // `displayWithMeridiem` sets it so "9:00 PM" can never wrap, and a
        // `CONTAINS` with an ordinary space matches nothing at all.
        expect(downRow, labelContains: "9:00\u{00A0}PM",
               "looking at the down wheels moved the window")

        // And now the reported case in its own numbers. A fresh door first: seat
        // 0 is the one a wheel gets right for free, so this half proves nothing
        // on its own — it is here to set the ceiling the half below reads back.
        let doorRow = element(app, "silk.settings.door.Reddit")
        XCTAssertTrue(doorRow.waitForExistence(timeout: Self.appear), "the Reddit row is missing")
        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")
        expect(app, wheel: 0, restingOn: 0, "an uncapped door's wheel did not open on No cap")
        dragWheel(app, rows: -2)          // No cap → 10 min
        tapPickerBackdrop(app)
        expect(doorRow, labelContains: "10 min", "the cap did not land")

        // Reopened on the ceiling in force. `Caps.wheelSeat(for: 10)` is 2 —
        // seat 0 is No cap, and 10 is the second minute in `Caps.wheelTable`;
        // `CapWheelSeatTests.tenMinutesIsTheSeatTheReportedCaseOpensOn` holds
        // that number in the spine so this walk is not the only place it lives.
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")
        expect(app, wheel: 0, restingOn: 2, "the cap wheel did not open on the ceiling in force")
        expect(app, wheel: 0, restingOn: 2, "the cap wheel was still travelling to its seat")
    }

    /// **And a bare look still costs nothing.** The companion to the walk above,
    /// and the reason it is safe to seat a wheel programmatically at all.
    ///
    /// `touched` is the whole of it: the overlay raises it from `onChange(of:
    /// selections)`, and `Wheel` writes a landing back into its selection — so a
    /// seating that nudged `selection`, even transiently, even to the value it
    /// already held by a different route, would make every wheel in the product
    /// commit on a bare look.
    ///
    /// That is invisible unless the wheel opens somewhere it cannot commit
    /// without moving something, so the ceiling here is OFF-GRID. 25 min is a
    /// value the bar can say and the wheel has no seat for; it opens on 20, the
    /// nearest (`CapWheelSeatTests.anOffGridCeilingOpensOnItsNearestSeat`), and a
    /// commit from an untouched wheel would silently tighten the door from 25 to
    /// 20 and toast about it.
    ///
    /// This is the cap analogue of `testBudgetWheelDismissedUntouchedKeepsAnOff
    /// GridValue`, which the seating bug had quietly hollowed out: with the wheel
    /// resting at seat 0 instead of on the nearest seat, that walk was proving
    /// the rule about a wheel that was not where it said it was.
    @MainActor
    func testCapWheelOpenedOnAnOffGridCeilingAndOnlyLookedAtKeepsIt() throws {
        let app = launchFresh()
        let bar = completeSetup(app)   // one door: Reddit, no ceiling

        // Raising a ceiling from infinity is a tighten, so it lands now.
        say(bar, "cap reddit at 25\n")
        let landed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit 25")).firstMatch
        XCTAssertTrue(landed.waitForExistence(timeout: Self.answer),
                      "the off-grid ceiling did not land")

        // Relaunched rather than waited out: what this walk asserts at the end is
        // the ABSENCE of a receipt, and a tighten's own receipt stands for a
        // minute carrying Undo. It also proves 25 survives storage, which is what
        // makes the seat below the stored value's rather than the sentence's.
        Self.stop(app)
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.textFields["silk.bar"].waitForExistence(timeout: Self.launch),
                      "did not land on Now when already onboarded")

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")
        expect(doorRow, labelContains: "25 min", "the off-grid ceiling did not survive a relaunch")

        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door detail card")
        let picker = element(app, "silk.picker")
        tap(element(app, "silk.settings.cap"), "Daily cap", raising: picker, "the cap wheel")
        expect(app, wheel: 0, restingOn: 4, "25 min did not open on its nearest seat, 20 min")

        // …and then nothing at all. No drag, no tap on a row, no adjustable step
        // — only the backdrop, which is the picker's one exit.
        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.overlay),
                      "the cap wheel did not fade out")
        XCTAssertFalse(app.staticTexts["silk.toast"].waitForExistence(timeout: 3),
                       "a wheel that was only looked at committed the seat it opened on")
        expect(doorRow, labelContains: "25 min",
               "a wheel that was only looked at tightened the ceiling to its nearest seat")
    }

    // MARK: - The wait (docs/design/wait.md)

    /// The shape of the whole feature, walked once: a granted ask does not
    /// open the app, it raises the wait; the ledger is not touched while the
    /// wait stands; and the ink landing is what lands the grant.
    ///
    /// The balance assertion in the middle is the load-bearing one. Under the
    /// other ordering — record the grant, then wait — the ensō would already
    /// read 30 here, and so would the wall: `Wall.reconcile` derives the open
    /// doors from the ledger, so a recorded grant IS an unshielded app, and
    /// the wait would be a screen you walk around by pressing Home.
    @MainActor
    func testTheWaitStandsBeforeTheGrantAndTheGrantLandsWhenItEnds() throws {
        let app = launchFresh(["-silkWait", "3"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")

        let wait = element(app, "silk.wait")
        XCTAssertTrue(wait.waitForExistence(timeout: Self.answer),
                      "the wait did not rise over a granted ask")
        // Nothing has been spent. The hero still reads the whole budget, and it
        // must keep reading it for as long as the veil is up — this is the
        // record-after ordering (docs/design/wait.md §5) caught in the act.
        //
        // A note for whoever reads this next, because two attempts were spent
        // on it: the veil IS hardened against VoiceOver — `.isModal` on the
        // overlay plus `.accessibilityHidden` on the stratum the blur scopes —
        // and **neither is observable from here**. XCUITest queries the raw
        // element tree and honours neither modality nor, through the
        // UIKit-backed pager, the hidden flag. So this walk cannot assert the
        // a11y fix, and an assertion that tried would only be testing XCUITest.
        // What it can prove about the veil is that touches do not pass through
        // it and the keyboard is down, which
        // `testASecondAskCannotLandBehindAStandingWait` does.
        XCTAssertTrue(app.staticTexts["40"].exists,
                      "the balance moved before the wait was paid")

        XCTAssertTrue(wait.waitForNonExistence(timeout: Self.answer),
                      "the wait never came down")
        let readBack = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 10")
        ).firstMatch
        XCTAssertTrue(readBack.waitForExistence(timeout: Self.answer),
                      "the wait ended without answering the turn it was holding")
        XCTAssertTrue(app.staticTexts["30"].waitForExistence(timeout: Self.appear),
                      "the grant did not land when the ink did")
    }

    /// The rule the feature exists for: the wait only passes while Silk is on
    /// screen. Leaving does not reset it and does not finish it — it stops.
    ///
    /// The proof is a wait longer than the trip: eight seconds of watching
    /// owed, then Silk is put down for roughly twelve. If the wait ran on a
    /// wall clock it would be long over and Reddit long open by the time she
    /// comes back; instead the veil is still standing, with the ink where she
    /// left it, and only then does it finish.
    @MainActor
    func testAWaitDoesNotPassWhileSilkIsOffScreen() throws {
        let app = launchFresh(["-silkWait", "8"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")
        let wait = element(app, "silk.wait")
        XCTAssertTrue(wait.waitForExistence(timeout: Self.answer),
                      "the wait did not rise over a granted ask")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.appear)
                        || app.wait(for: .runningBackgroundSuspended, timeout: Self.appear),
                      "Silk never left the foreground")
        // Longer than the whole wait, so a wall-clock timer would be done and
        // the app would be open behind us.
        Thread.sleep(forTimeInterval: 12)

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.launch),
                      "Silk did not come back")
        XCTAssertTrue(wait.waitForExistence(timeout: Self.appear),
                      "the wait finished while nobody was looking at it")

        // And from there it goes on from where it stopped rather than starting
        // over: what is left is the balance of eight seconds, not eight more.
        XCTAssertTrue(wait.waitForNonExistence(timeout: Self.answer),
                      "the wait did not resume when she came back")
        XCTAssertTrue(app.staticTexts["30"].waitForExistence(timeout: Self.answer),
                      "the resumed wait never landed its grant")
    }

    /// An ask too small to draw a wait is answered exactly as it was before
    /// this feature existed — the veil never rises, because a wait shorter
    /// than the veil's own fade is a flash and not a price.
    @MainActor
    func testAnAskTooSmallToDrawAWaitOpensAsItAlwaysDid() throws {
        // Under Wait.tooShortToDraw (0.4s), which is Silk.Motion.overlay.
        let app = launchFresh(["-silkWait", "0.2"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")
        let readBack = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 10")
        ).firstMatch
        XCTAssertTrue(readBack.waitForExistence(timeout: Self.answer),
                      "the grant read-back did not appear")
        XCTAssertFalse(element(app, "silk.wait").exists,
                       "a wait too short to draw was drawn anyway")
        XCTAssertTrue(app.staticTexts["30"].waitForExistence(timeout: Self.appear),
                      "the grant did not debit")
    }

    /// The keyboard is the one thing the veil cannot cover — it is its own
    /// window and draws over every overlay Silk owns. A wait raised under a
    /// live keyboard would put a full QWERTY on a screen designed as three
    /// elements and no words, and every touch in the bottom third would land
    /// in a text field nobody can see.
    @MainActor
    func testTheWaitTakesTheKeyboardDownWithIt() throws {
        let app = launchFresh(["-silkWait", "3"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")
        XCTAssertTrue(element(app, "silk.wait").waitForExistence(timeout: Self.answer),
                      "the wait did not rise over a granted ask")
        XCTAssertTrue(wait(for: app.keyboards.firstMatch, "exists == false", timeout: Self.overlay),
                      "the keyboard stayed up behind the wait")
    }

    /// Walk away and never come back: the ask goes, and it costs nothing.
    ///
    /// This is the assertion that pins **record-after**, which is the whole
    /// transaction argument in `docs/design/wait.md` §5. If the grant were
    /// recorded when the sentence landed — as it was before this feature — the
    /// minutes would be gone here, the wall would be down behind Reddit, and
    /// two DeviceActivity schedules would be armed for a door she never opened.
    /// Instead the state is byte-identical to the state before she typed.
    ///
    /// The last line is the one nothing else catches: the minute clock is
    /// cancelled for the duration of every wait, and only `clearWait` puts it
    /// back. A staleness drop that forgot to would freeze the whole app's clock
    /// silently and for good — the hero would stop turning over at midnight and
    /// no grant would ever expire on screen again. A status ask answering
    /// proves the model is still alive on the far side of the drop.
    @MainActor
    func testAnAbandonedWaitSpendsNothingAndPutsTheClockBack() throws {
        // A long wait she cannot finish by accident, and a staleness window
        // short enough to walk. Two minutes is the shipped value.
        let app = launchFresh(["-silkWait", "30", "-silkStale", "3"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")
        let wait = element(app, "silk.wait")
        XCTAssertTrue(wait.waitForExistence(timeout: Self.answer),
                      "the wait did not rise over a granted ask")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.appear)
                        || app.wait(for: .runningBackgroundSuspended, timeout: Self.appear),
                      "Silk never left the foreground")
        Thread.sleep(forTimeInterval: 6)          // past the pinned window

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.launch),
                      "Silk did not come back")

        // The veil is gone, and it took the ask with it.
        XCTAssertTrue(wait.waitForNonExistence(timeout: Self.overlay),
                      "a wait abandoned past its window was still standing")
        XCTAssertTrue(app.staticTexts["40"].waitForExistence(timeout: Self.appear),
                      "an abandoned wait spent minutes")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open")
        ).firstMatch.exists, "an abandoned wait opened the door anyway")
        // No orphaned "…" left standing where the answer would have gone.
        XCTAssertFalse(app.staticTexts["…"].exists,
                       "the dropped ask left the thread still thinking")

        // And the model is still running: the clock came back with the veil.
        //
        // The exact sentence, not `CONTAINS "40"`. The hero itself is a static
        // text reading "40" and it is already on screen and already asserted
        // three lines up — so a `CONTAINS` match was satisfied by the enso
        // before the bar had answered anything at all, and would have stayed
        // green with the thread stone dead. `testTypedStatusAskAnswersBalance`
        // matches the balance answer exactly; this is the same string, for the
        // same reason.
        say(bar, "how many left\n")
        XCTAssertTrue(app.staticTexts["40 min left."].waitForExistence(timeout: Self.answer),
                      "the bar went dead after a wait was dropped")
    }

    /// Two waits cannot be watched at once. The bar stays live while a slow
    /// model parse is in flight, so a second sentence can reach the grant path
    /// with a veil already standing — and before the guard, it silently
    /// replaced the first wait, stranding that turn at "…" for good and
    /// swapping the door name under a mark already being drawn.
    ///
    /// Driven here through the one seam a walk has: a wait long enough to still
    /// be standing, and a send attempted against it. The veil eats touches and
    /// the keyboard is down, so this proves the closed door rather than the
    /// guard behind it — which is the property that actually matters.
    @MainActor
    func testASecondAskCannotLandBehindAStandingWait() throws {
        let app = launchFresh(["-silkWait", "20"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")
        // Named `veil`, not `wait`: a local of that name shadows this class's
        // own `wait(for:_:timeout:)` helper, and the compiler reports it as
        // "cannot call value of non-function type 'XCUIElement'".
        let veil = element(app, "silk.wait")
        XCTAssertTrue(veil.waitForExistence(timeout: Self.answer),
                      "the wait did not rise over a granted ask")

        // The bar is unreachable while the veil stands — not merely covered.
        XCTAssertFalse(bar.isHittable,
                       "the bar was still reachable behind the wait")
        XCTAssertTrue(wait(for: app.keyboards.firstMatch, "exists == false", timeout: Self.overlay),
                      "the keyboard was up, so a second sentence could be typed")

        // A touch where the bar sits lands on the veil and changes nothing.
        veil.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(element(app, "silk.wait").exists,
                      "a tap through the veil dismissed the wait")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open")
        ).firstMatch.exists, "a tap through the veil landed the grant early")

        // And the tap did not quietly tear the conversation down behind the
        // veil. This is the falsifiable half: the catcher under the veil sets
        // `conversation.focused = false`, which clears the thread — and a
        // cleared thread means the turn the wait is holding no longer exists,
        // so `landWait`'s reply is addressed to an id that is gone and is
        // swallowed. Delete the veil's tap eater and the read-back below never
        // arrives, while every other assertion in this walk still passes.
        //
        // The timeout has to clear the pinned wait itself, not just the usual
        // beat: this walk holds the veil for twenty seconds on purpose so the
        // taps above land against a standing one, and `Self.answer` is fifteen.
        // Waiting less than the thing being waited for is a test that fails on
        // its own arithmetic — which is exactly what it did the first time.
        let restOfTheWait = Self.answer + 20
        XCTAssertTrue(veil.waitForNonExistence(timeout: restOfTheWait),
                      "the wait never came down")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 10")
        ).firstMatch.waitForExistence(timeout: Self.answer),
                      "a tap behind the veil took the thread, and the answer with it")
    }

    /// The way back survives the wait.
    ///
    /// `SilkTests` owns the arithmetic of this — that Undo after a wait puts
    /// the minutes back and closes the door. What it cannot own is the screen
    /// the veil leaves behind, and that screen is not the one
    /// `testTypedTightenOffersUndoAndRestores` taps its pill on: there the bar
    /// still holds focus and the keyboard is up. Here the wait took the
    /// keyboard down, `barFocused` is false, and the thread is still focused
    /// deliberately — so the stage is dimmed and the tap-out catcher is
    /// standing with nothing having dismissed it.
    ///
    /// A pill drawn one layer under that catcher would be un-tappable, and a
    /// near-miss on it tears the whole thread down instead. That is the failure
    /// this walk exists to catch, and it needs a real finger.
    @MainActor
    func testTheGrantAWaitLandedStillOffersTheWayBack() throws {
        let app = launchFresh(["-silkWait", "3"])
        let bar = completeSetup(app)

        say(bar, "reddit for ten\n")
        let veil = element(app, "silk.wait")
        XCTAssertTrue(veil.waitForExistence(timeout: Self.answer),
                      "the wait did not rise over a granted ask")
        XCTAssertTrue(veil.waitForNonExistence(timeout: Self.answer),
                      "the wait never came down")

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 10")
        ).firstMatch.waitForExistence(timeout: Self.answer),
                      "the wait ended without answering the turn it was holding")
        XCTAssertTrue(app.staticTexts["30"].waitForExistence(timeout: Self.appear),
                      "the grant did not land when the ink did")

        // The pill, on a turn asked before the veil and answered after it. The
        // 60 seconds start here — at the landing, not at the sentence — which
        // is what record-after buys undo.
        let undoPill = app.buttons["silk.turn.undo"]
        XCTAssertTrue(undoPill.waitForExistence(timeout: Self.appear),
                      "a grant landed by a wait offered no way back")
        tap(undoPill, "the thread's Undo",
            raising: app.staticTexts[SilkStringsMirror.putBack], "the Undo reply")

        XCTAssertTrue(app.staticTexts["40"].waitForExistence(timeout: Self.appear),
                      "Undo after a wait did not put the minutes back")
    }
}

/// The two sentences this file matches by value. The test bundle does not link
/// SilkCore, so they are written out rather than imported — and written out
/// once, here, rather than inline at the call site where a typo would read as
/// a product bug.
private enum SilkStringsMirror {
    static let putBack = "Put back."
}
