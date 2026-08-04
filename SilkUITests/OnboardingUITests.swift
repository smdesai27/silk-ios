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
    /// com.sanildesai.silk:5985", on a branch carrying no Swift at all. The
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
        return ["-silkReset", "YES", "-silkDownStart", "\(start)", "-silkDownEnd", "\((start + 1) % 24)"]
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
        bar.typeText(sentence)
    }

    /// The backdrop is the picker's commit button, but the wheels fold into
    /// single adjustable elements and the backdrop's own element does not
    /// surface reliably — so tap through the overlay itself, low, under the
    /// wheels, where only the backdrop listens.
    ///
    /// The overlay fades in on its own curve and a coordinate tap is aimed at a
    /// frame, not an element, so a tap made mid-fade is aimed at the Settings
    /// row underneath. The wait for hittability is a settle rather than a gate:
    /// the container may never report itself hittable, and the tap is made
    /// either way, exactly as it was before.
    @MainActor
    private func tapPickerBackdrop(_ app: XCUIApplication) {
        let overlay = element(app, "silk.picker")
        _ = wait(for: overlay, "exists == true AND isHittable == true", timeout: 1.5)
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
    }

    /// Steps a wheel by whole rows. The wheel folds into one adjustable
    /// element and its identifiers don't surface to XCUI, so the drag goes
    /// through the overlay's frame: the single wheel sits centred, ~25pt below
    /// the overlay's middle (title + its 34pt seat above). A slow 52pt-per-row
    /// drag with a settling hold snaps exactly `rows` seats — positive drags
    /// the column down (earlier values).
    @MainActor
    private func dragWheel(_ app: XCUIApplication, rows: Int) {
        let overlay = element(app, "silk.picker")
        _ = wait(for: overlay, "exists == true AND isHittable == true", timeout: 1.5)
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
        let end = start.withOffset(CGVector(dx: 0, dy: CGFloat(rows) * 52))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.4)
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
    /// only the backdrop listens.
    @MainActor
    private func tapEditorBackdrop(_ app: XCUIApplication) {
        let overlay = element(app, "silk.settings.editor")
        _ = wait(for: overlay, "exists == true AND isHittable == true", timeout: 1.5)
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
    }

    /// A door row raises the editor now — Rebind and Remove under the door's
    /// own name — and Rebind lands setup's one-app guidance in the editor's
    /// slot. The simulator's family picker is non-functional, so the sheet is
    /// skipped there; the line is the contract and it must land. The backdrop
    /// is the exit, exactly as the wheel's is.
    @MainActor
    func testSettingsDoorRowOpensEditorWithRebindGuidance() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit

        let doorRow = element(app, "silk.settings.door.Reddit")
        tap(app.buttons["silk.dot.2"], "the Settings dot", raising: doorRow, "the Reddit row")

        let editor = element(app, "silk.settings.editor")
        tap(doorRow, "the Reddit row", raising: editor, "the door editor")
        let rebind = app.buttons["silk.settings.rebind"]
        XCTAssertTrue(rebind.waitForExistence(timeout: Self.appear), "the editor offered no Rebind")
        XCTAssertTrue(app.buttons["silk.settings.remove"].exists, "the editor offered no Remove")

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
        tap(instagramRow, "the Instagram row", raising: editor, "the door editor")
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
}
