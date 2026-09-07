import XCTest

/// The App Store capture walk. Not a test of anything — every assertion here
/// exists only to prove the screen is the one the shot is meant to be of, so
/// that a capture never quietly ships the wrong state.
///
/// One test per image, each landing a full-resolution `XCUIScreen.main`
/// screenshot as a `.keepAlways` PNG attachment named `shot-NN`. The finals
/// are composed outside the simulator (`scripts/compose-screenshots.swift`);
/// this file only produces the raw device captures.
///
/// The helpers below are copied from `OnboardingUITests` rather than shared —
/// they are private there, and a capture walk should not be able to change the
/// walk that proves the product works.
//  Re-running the whole set, end to end. Nothing here is inferred from the
//  conversation that first produced the images; this is the recipe.
//
//    W=$(git rev-parse --show-toplevel)
//    U=$(xcrun simctl create "Silk Shots 6.9" \
//          com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max \
//          com.apple.CoreSimulator.SimRuntime.iOS-26-5)
//    xcrun simctl boot "$U"
//    BAR="--batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3"
//
//  The status bar renders HH:mm, whatever it is handed: "4:52" comes back
//  "04:52", which is four in the morning over a page saying "Good afternoon."
//  So the day shots take the wall clock and the night shot takes 23:20, and
//  the override is re-set immediately before each run rather than once.
//
//    xcrun simctl status_bar "$U" override --time "23:20" $BAR
//    TEST_RUNNER_SILK_SHOTS=1 xcodebuild test -project "$W/Silk.xcodeproj" \
//      -scheme Silk -destination "platform=iOS Simulator,id=$U" \
//      -only-testing:SilkUITests/ScreenshotWalk/testShot01NightShield \
//      -derivedDataPath "$W/DerivedData/shots" -resultBundlePath /tmp/shots-night.xcresult
//
//    xcrun simctl status_bar "$U" override --time "$(date '+%H:%M')" $BAR
//    TEST_RUNNER_SILK_SHOTS=1 xcodebuild test -project "$W/Silk.xcodeproj" \
//      -scheme Silk -destination "platform=iOS Simulator,id=$U" \
//      -only-testing:SilkUITests/ScreenshotWalk/testShot02NowDay \
//      -only-testing:SilkUITests/ScreenshotWalk/testShot03Grant \
//      -only-testing:SilkUITests/ScreenshotWalk/testShot04Mirror \
//      -derivedDataPath "$W/DerivedData/shots" -resultBundlePath /tmp/shots-day.xcresult
//
//    xcrun simctl status_bar "$U" clear
//
//  The seams the walk launches through. All `#if DEBUG`, all read straight off
//  the argument domain in `AppModel.init`, and none of them compiled into a
//  Release build:
//
//    -silkReset YES     wipe the App Group store and re-onboard
//    -silkWait 0        turn the wait off (every shot here is a settled screen)
//    -silkNight YES     pin the night face (shot 01)
//    -silkSeedDays 7    seat seven closed days ending yesterday, with plausible
//                       varied scores, and back-date the install to eight days
//                       ago so the hedgerow has that much growth (shot 04).
//                       Reachable ONLY from inside the -silkReset wipe, so it
//                       can never write over a store anyone is keeping.
//
//  The attachments out, named. `export attachments` writes UUID filenames and a
//  manifest mapping each to the name this file gave it ("shot-01_0_<uuid>.png"):
//
//  A fresh output directory per bundle. Exporting a second bundle over a
//  non-empty one leaves the FIRST manifest in place and silently re-copies its
//  attachments, which reads as the day shots having gone missing.
//
//    for K in night day; do
//      rm -rf "/tmp/att-$K"
//      xcrun xcresulttool export attachments \
//        --path "/tmp/shots-$K.xcresult" --output-path "/tmp/att-$K"
//      python3 - "$W" "/tmp/att-$K" <<'EOF'
//    import json, shutil, os, sys
//    raw, att = os.path.join(sys.argv[1], "docs/market/screenshots/raw"), sys.argv[2]
//    for t in json.load(open(os.path.join(att, "manifest.json"))):
//        for a in t["attachments"]:
//            n = a["suggestedHumanReadableName"]
//            if n.startswith("shot-"):
//                shutil.copy(os.path.join(att, a["exportedFileName"]),
//                            os.path.join(raw, n.split("_")[0] + ".png"))
//    EOF
//    done
//
//  And the finals:
//
//    swift "$W/scripts/compose-screenshots.swift" \
//      "$W/docs/market/screenshots/raw" "$W/docs/market/screenshots/6.9"
//
final class ScreenshotWalk: XCTestCase {

    // MARK: - How long the walk waits (see OnboardingUITests for the reasoning)

    private static let appear: TimeInterval = 12
    private static let overlay: TimeInterval = 20
    private static let launch: TimeInterval = 90
    private static let answer: TimeInterval = 15

    /// Not a test, and it must not run like one. `scripts/ci.sh ui` runs the
    /// whole bundle, and this walk drags a system slider by knob position and
    /// corrects against the read-back until it lands — a legitimate technique
    /// for a capture harness, and not a thing a red CI light should ever be
    /// allowed to mean. So the walk is opt-in and skips loudly otherwise.
    ///
    /// `xcodebuild` forwards its own `TEST_RUNNER_`-prefixed variables to the
    /// runner process with the prefix stripped, which is why the gate reads
    /// `SILK_SHOTS` and the command line sets `TEST_RUNNER_SILK_SHOTS`.
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SILK_SHOTS"] == "1",
                          "screenshot walk: run with TEST_RUNNER_SILK_SHOTS=1")
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ScreenshotWalk.stop(XCUIApplication())
        }
    }

    /// Wiped state, and the wait switched off. The wait's veil is a real part
    /// of the product and deliberately not in these frames: every shot here is
    /// of a settled screen, and a veil mid-rise is neither the before nor the
    /// after. The night window is left at its 10 PM–7 AM default, unparked, so
    /// the shield's night face states the hour the marketing copy quotes and
    /// Settings reads the window a real install would show. Every capture runs
    /// mid-afternoon, nowhere near the edge.
    private static let launchArguments: [String] = [
        "-silkReset", "YES", "-silkWait", "0"
    ]

    // MARK: - The shots

    /// 01 — the wall, night face. The whole conversation with a spent day.
    @MainActor
    func testShot01NightShield() throws {
        let app = launchFresh(["-silkNight", "YES"])
        completeSetup(app)

        // Down hours outrank every door state: the wall answers with the hour
        // it opens, and the door's name rides under it.
        let instagram = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Instagram")).firstMatch
        XCTAssertTrue(instagram.waitForExistence(timeout: Self.appear), "the Instagram row is missing")
        let title = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "7:00")).firstMatch
        tap(instagram, "the Instagram door row", raising: title, "the shield")

        settle(1.2)
        capture("shot-01")
    }

    /// 02 — Now, day. A bigger budget with 40 of it left.
    @MainActor
    func testShot02NowDay() throws {
        let app = launchFresh()
        let bar = completeSetup(app, budget: 60)

        // Twenty spent leaves forty, and the ensō is four-sixths drawn — the
        // ring has something to say, which it does not at a full budget.
        say(bar, "unlock TikTok for 20 min\n")
        let readBack = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "TikTok is open for 20")).firstMatch
        XCTAssertTrue(readBack.waitForExistence(timeout: Self.answer), "the grant did not land")

        blur(app)
        XCTAssertTrue(readBack.waitForNonExistence(timeout: Self.overlay), "the thread did not clear")
        XCTAssertTrue(app.staticTexts["40"].waitForExistence(timeout: Self.appear),
                      "the ensō did not debit to 40")

        settle(1.2)
        capture("shot-02")
    }

    /// 03 — the artifact a sentence produced: Instagram open, and the hour it
    /// shuts again standing in the row.
    @MainActor
    func testShot03Grant() throws {
        let app = launchFresh()
        let bar = completeSetup(app, budget: 60)

        say(bar, "unlock Instagram for 10 min\n")
        let readBack = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Instagram is open for 10")).firstMatch
        XCTAssertTrue(readBack.waitForExistence(timeout: Self.answer), "the grant did not land")

        // The thread over the dimmed page, kept as an alternate: it is the
        // sentence and the receipt in one frame, and the door row it produced
        // is invisible behind it (the stage dims to .05).
        settle(1.0)
        capture("shot-03-thread")

        blur(app)
        XCTAssertTrue(readBack.waitForNonExistence(timeout: Self.overlay), "the thread did not clear")
        // "Instagram, open till 4:31" — the row's own three strings, spoken in
        // one breath by the button that carries them.
        let openRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                        "Instagram", "till")).firstMatch
        XCTAssertTrue(openRow.waitForExistence(timeout: Self.appear),
                      "the door row is not showing a re-lock time")

        settle(1.2)
        capture("shot-03")
    }

    /// 04 — Mirror, day. The score for the last full day, the week beside it,
    /// and a hedgerow with a week of growth in it.
    ///
    /// The seeded week is what makes this a shot at all. A fresh install shows
    /// today's running score under the word "Today", six bare seats and a
    /// day-one border — honest, and not the page. `-silkSeedDays 7` seats seven
    /// closed days ending yesterday and back-dates the install eight days
    /// (`AppModel.seedClosedDays`, DEBUG-only, and only ever inside the
    /// `-silkReset` wipe), so the page here is the page after a week.
    @MainActor
    func testShot04Mirror() throws {
        let app = launchFresh(["-silkSeedDays", "7"])
        completeSetup(app)

        // The dot, not a swipe: the same shortcut OnboardingUITests navigates
        // by, and it lands the page without a drag that could be read as a
        // scroll.
        let week = app.staticTexts["Week"]
        tap(app.buttons["silk.dot.1"], "the Mirror dot", raising: week, "Mirror")

        // The seed's own last day. Asserting the number rather than "some
        // numeral" is the point of the assertion: 81 can only be on screen if
        // the seeded records went in through the store and came back out
        // through the real decode. Its spoken value is the weekday name, so a
        // hero that had fallen back to today's running score would read
        // "Today" here and fail.
        let hero = app.staticTexts["81"]
        XCTAssertTrue(hero.waitForExistence(timeout: Self.appear),
                      "the hero is not showing the seeded last closed day")
        XCTAssertNotEqual(hero.value as? String, "Today",
                          "the hero fell back to today's running score")

        // Longer than the others: the planting is built off the main actor and
        // then creeps in over 1.15s, and a capture mid-creep is a border in
        // transit rather than the one the page settles on.
        settle(2.4)
        capture("shot-04")
    }

    // MARK: - Capture

    /// A full-resolution PNG, attached under a name the exporter can find.
    /// `XCTAttachment(screenshot:)` is deliberately not used — its encoding is
    /// a quality setting, and these frames are the product's own pixels.
    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation,
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Let the last curve finish. Every capture follows an assertion that the
    /// state arrived, and a state arrives before the animation carrying it
    /// does — Silk's longest is the crossing at .8s. Runs the loop rather than
    /// sleeping so the runner stays alive.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: .now.addingTimeInterval(seconds))
    }

    /// The thread's tap-out catcher covers the screen while the bar holds
    /// focus, so a tap on the ground is the blur that takes the thread down
    /// and gives the page back undimmed.
    @MainActor
    private func blur(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }

    // MARK: - Getting there (copied from OnboardingUITests)

    @MainActor
    @discardableResult
    private static func dismissScreenTimeConsent(timeout: TimeInterval = 4) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        guard decline.waitForExistence(timeout: timeout) else { return false }
        decline.tap()
        _ = decline.waitForNonExistence(timeout: Self.appear)
        return true
    }

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

    @MainActor
    private func tap(_ element: XCUIElement, _ what: String,
                     timeout: TimeInterval = ScreenshotWalk.appear,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element, "exists == true AND isHittable == true", timeout: timeout),
                      "\(what) never became tappable", file: file, line: line)
        element.tap()
    }

    @MainActor
    private func tap(_ trigger: XCUIElement, _ what: String,
                     raising target: XCUIElement, _ raised: String,
                     timeout: TimeInterval = ScreenshotWalk.overlay,
                     file: StaticString = #filePath, line: UInt = #line) {
        tap(trigger, what, file: file, line: line)
        if target.waitForExistence(timeout: timeout) { return }
        Self.dismissScreenTimeConsent(timeout: 0)
        if trigger.isHittable { trigger.tap() }
        XCTAssertTrue(target.waitForExistence(timeout: timeout),
                      "\(raised) did not rise on \(what)", file: file, line: line)
    }

    @MainActor
    private static func stop(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        dismissScreenTimeConsent(timeout: 0)
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackgroundSuspended, timeout: 2)
        app.terminate()
        guard !app.wait(for: .notRunning, timeout: Self.appear) else { return }
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: Self.appear)
    }

    @MainActor
    private func launchFresh(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += Self.launchArguments + Self.clockGuard() + extra
        app.launch()
        return app
    }

    /// The window's edge moved off the wall clock, and only when the clock is
    /// inside it. The day shots are meant to run mid-afternoon; run at four in
    /// the morning they land inside the 10 PM–7 AM default and every grant
    /// answers "Down hours. Opens 7:00 AM." instead of opening. Now states only
    /// the window's START ("Down hours at 10:00 PM."), so pulling the END back
    /// to the hour before now changes nothing a day shot shows; a run after
    /// 10 PM has to move the start instead, and that one does change the line.
    /// Mid-afternoon, this is empty and the default window stands as the
    /// doc above says.
    private static func clockGuard() -> [String] {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 7 { return ["-silkDownEnd", "\(max(hour - 1, 0))"] }
        if hour >= 22 { return ["-silkDownStart", "\(min(hour + 1, 23))"] }
        return []
    }

    /// Setup, with both named doors bound — the two the store page names — and
    /// the budget optionally moved off its default. Returns the bar, which is
    /// also the proof that Now arrived.
    @MainActor
    @discardableResult
    private func completeSetup(_ app: XCUIApplication, budget: Int? = nil) -> XCUIElement {
        let ok = app.buttons["silk.setup.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: Self.launch), "onboarding did not show")
        tap(ok, "OK", raising: app.staticTexts["Which apps should Silk block?"], "the apps step")
        Self.dismissScreenTimeConsent()

        let instagram = app.buttons["chip.Instagram"]
        XCTAssertTrue(instagram.waitForExistence(timeout: Self.appear), "the Instagram chip is missing")
        bindThroughPicker(app, app: "Instagram", from: instagram, "the Instagram chip")
        bindThroughPicker(app, app: "TikTok", from: app.buttons["chip.TikTok"], "the TikTok chip")

        tap(ok, "OK", raising: app.staticTexts["How many minutes a day?"], "the limits step")
        if let budget { setBudget(app, to: budget) }

        let bar = app.textFields["silk.bar"]
        tap(ok, "OK", raising: bar, "Now")
        return bar
    }

    /// The slider is the only way into a budget other than 40: a bigger one is
    /// a loosening everywhere else in the app, and a loosening waits for
    /// tomorrow.
    ///
    /// `adjust(toNormalizedSliderPosition:)` does nothing here, and it fails
    /// silently — eight passes left the value on 40. XCTest locates the knob by
    /// parsing the element's `value` as a percentage, and this slider's value
    /// is Silk's own sentence ("40 min"), so the drag it synthesises starts at
    /// the far-left edge of the track rather than on the knob, which a SwiftUI
    /// Slider ignores. So the knob is found from the value Silk actually
    /// states and the drag starts on it.
    ///
    /// The track is not the frame: the knob's centre travels between one radius
    /// in from each end, so a value maps to `inset + v · (1 − 2·inset)`. That
    /// is only the opening guess — the drag lands short of where the finger
    /// lifts, by an amount that is a system control's business and not ours, so
    /// the aim is corrected against the value Silk states after each pass.
    ///
    /// **The next press starts where the last one lifted, not where the value
    /// says the knob should be.** Computing the grip from the value is a fixed
    /// point and it was reached: one walk landed on 50 and stayed there for
    /// seven passes, because the knob was under the lift point and every
    /// subsequent press was aimed at the model's idea of 50, which is not where
    /// 50 turned out to be. A press that misses the knob moves nothing, and a
    /// correction loop that cannot move is just a slow failure.
    @MainActor
    private func setBudget(_ app: XCUIApplication, to target: Int) {
        let slider = app.sliders["silk.setup.budget"]
        XCTAssertTrue(slider.waitForExistence(timeout: Self.appear), "the budget slider is missing")
        let inset = 0.065
        let span = 1 - inset * 2
        func knob(_ value: Int) -> Double { inset + Double(value - 10) / 110 * span }
        guard var landed = budgetValue(app) else {
            XCTFail("the budget slider states no value")
            return
        }
        var grip = knob(landed)
        var aim = knob(target)
        for _ in 0..<10 {
            if landed == target { return }
            slider.coordinate(withNormalizedOffset: CGVector(dx: grip, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: aim, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.35)
            grip = aim
            settle(0.3)
            guard let read = budgetValue(app) else { break }
            landed = read
            aim = min(max(aim + Double(target - landed) / 110 * span, 0), 1)
        }
        XCTAssertEqual(budgetValue(app), target, "the budget slider would not sit on \(target)")
    }

    /// The numeral above the slider is hidden from the tree (one voice per
    /// control), so the slider's own value — "60 min" — is the read.
    @MainActor
    private func budgetValue(_ app: XCUIApplication) -> Int? {
        guard let value = app.sliders["silk.setup.budget"].value as? String,
              let number = value.split(separator: " ").first else { return nil }
        return Int(number)
    }

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
        XCTAssertTrue(wait(for: done, "isEnabled == true", timeout: Self.appear),
                      "Done stayed dead on exactly one app", file: file, line: line)
        tap(done, "Done", file: file, line: line)
        XCTAssertTrue(header.waitForNonExistence(timeout: Self.overlay),
                      "the picker sheet did not come down", file: file, line: line)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Types a sentence at the bar. A cold simulator has been seen to take the
    /// session's first focus and then drop it, so the walk waits for focus and
    /// asks once more if it went. (OnboardingUITests.say)
    @MainActor
    private func say(_ bar: XCUIElement, _ sentence: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        tap(bar, "the bar", file: file, line: line)
        if !waitForFocus(bar, timeout: 4) {
            tap(bar, "the bar, again", file: file, line: line)
            _ = waitForFocus(bar, timeout: 4)
        }
        bar.typeText(sentence)
    }

    @MainActor
    @discardableResult
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"),
                                  evaluatedWith: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }
}
