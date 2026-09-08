import XCTest

/// THE REAL SCREEN, WITH NO MODEL BEHIND IT.
///
/// `NoModelTurnTests` drives `AppModel.handle` directly and proves the grammar
/// answers every canonical sentence on its own. That is the pipeline; this is
/// the product. It launches the app under `-silkNoModel YES` — which sets
/// `SilkModelParser.testForceSilent` in `AppModel.init`,
/// making the widener answer `.silence` exactly as an unavailable one does —
/// walks setup, and types five sentences at the bar: half a spend, the whole
/// sentence it is answered with, a paraphrase only a model could read, a budget
/// change and a balance question. Each reply is read off the screen and
/// photographed.
///
/// The first two are one fact in two turns. "instagram 10" names a door and a
/// number and asks for neither, so it grants nothing and is answered with the
/// sentence that would — and that sentence, typed next, opens the door. Silence
/// on the first turn is what the design cannot afford: it would reach the
/// widener, and a model reads "instagram 10" as the grant the grammar declined.
///
/// The simulator carries Apple Intelligence, so without the seam the paraphrase
/// would reach a real generation and whatever it answered would be a property
/// of the machine. With it, the screen is the one a phone with the feature
/// switched off actually shows.
///
/// The waits, the taps, the typing and the teardown are `SilkWalk`'s — the base
/// class in `WalkSupport.swift`. They used to be copied here from
/// `OnboardingUITests`, without the comments that say what each one exists for;
/// the copies are gone and the reasoning is in one place.
final class NoModelUITests: SilkWalk {

    /// The four words, with the typographic apostrophe `SilkStrings` actually
    /// carries. Spelled with an escape so a copy-paste through an editor that
    /// normalises quotes cannot silently turn this assertion into a different
    /// one.
    private static let didntGetThat = "Didn\u{2019}t get that."

    /// The guidance reply, composed by `SilkStrings.writeItOut(_:minutes:)` for
    /// Instagram and the ten minutes the user herself typed. Plain ASCII, and
    /// spelled out here rather than built, so this walk asserts the sentence a
    /// person reads off the glass and not a call to the same function that
    /// produced it.
    private static let writeItOut = "Write it out: unlock Instagram for 10 min."

    /// A fresh launch with the model switched off. The night window is parked
    /// six hours ahead of the wall clock for the reason `OnboardingUITests`
    /// gives: a fixed window springs whenever the suite runs near it, and every
    /// sentence below would then be answered with the opening hour instead of
    /// what it asked for.
    @MainActor
    private func launchWithNoModel() -> XCUIApplication {
        let hour = Calendar.current.component(.hour, from: .now)
        let start = (hour + 6) % 24
        let app = XCUIApplication()
        app.launchArguments += [
            "-silkReset", "YES",
            "-silkNoModel", "YES",
            // Pinned OFF, not short: a grant behind a veil would put the
            // re-lock row's assertion on the far side of a wait this test is
            // not about, and the refusal's timing is the number being measured.
            "-silkWait", "0",
            "-silkDownStart", "\(start)", "-silkDownEnd", "\((start + 1) % 24)",
        ]
        app.launch()
        return app
    }

    /// Setup, naming both doors the walk types at. The budget slider is left
    /// alone, so the default 40 stands and every number below rests on it.
    @MainActor
    @discardableResult
    private func completeSetup(_ app: XCUIApplication) -> XCUIElement {
        let ok = app.buttons["silk.setup.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: Self.launch), "onboarding did not show")
        tap(ok, "OK", raising: app.staticTexts["Which apps should Silk block?"], "the apps step")
        Self.dismissScreenTimeConsent()
        bindThroughPicker(app, app: "Instagram", from: app.buttons["chip.Instagram"],
                          "the Instagram chip")
        bindThroughPicker(app, app: "TikTok", from: app.buttons["chip.TikTok"],
                          "the TikTok chip")
        tap(ok, "OK", raising: app.staticTexts["How many minutes a day?"], "the limits step")
        let bar = app.textFields["silk.bar"]
        tap(ok, "OK", raising: bar, "Now")
        return bar
    }

    @MainActor
    private func bindThroughPicker(_ ui: XCUIApplication, app named: String,
                                   from trigger: XCUIElement, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(trigger.waitForExistence(timeout: Self.appear),
                      "the \(named) chip is missing", file: file, line: line)
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

    /// A photograph of whatever is on screen, kept whatever the outcome.
    @MainActor
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Any element whose spoken label begins with `prefix` — the door rows carry
    /// their whole sentence as one accessibility label on the button
    /// (NowView.swift:258), and a query that guessed the element type would miss
    /// it on the releases where a styled Button reads as something else.
    @MainActor
    private func labelled(_ app: XCUIApplication, beginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
    }

    // MARK: - The walk

    @MainActor
    func testTheBarAnswersWithoutTheModel() throws {
        let app = launchWithNoModel()
        let bar = completeSetup(app)
        XCTAssertTrue(app.staticTexts["Instagram"].waitForExistence(timeout: Self.appear),
                      "the Instagram row is missing from Now")
        shoot("00 — Now, no model")

        // 1. THE SHORTCUT, WRITTEN OUT. A door beside a number is not an ask:
        //    it names the app and the amount and asks for neither. The grammar
        //    answers it with the sentence that WOULD grant — in her own door
        //    and her own number — and this is the row the tightening rests on,
        //    because silence here would hand "instagram 10" to a model that
        //    reads it as the grant the grammar just declined.
        say(bar, "instagram 10\n")
        let guidance = reply(app, containing: "Write it out")
        XCTAssertTrue(guidance.waitForExistence(timeout: Self.answer),
                      "half a spend was left unanswered with no model behind the bar")
        XCTAssertEqual(guidance.label, Self.writeItOut,
                       "the guidance read \"\(guidance.label)\"")
        // Nothing moved: the whole budget is still on the ring, no door row
        // carries a re-lock time, and there is nothing to take back.
        XCTAssertTrue(enso(app, reading: 40).waitForExistence(timeout: Self.appear),
                      "a sentence that granted nothing moved the balance")
        XCTAssertFalse(labelled(app, beginsWith: "Instagram, open till").exists,
                       "a sentence that granted nothing opened the door")
        XCTAssertFalse(app.buttons["silk.turn.undo"].exists,
                       "a reply that moved nothing offered a way back")
        shoot("01 — instagram 10 — \(guidance.label)")

        // 2. THE SPEND, in the sentence the reply just spelled out. The
        //    grammar's hot path, and the widener never sees it.
        say(bar, "unlock Instagram for 10 min\n")
        let grant = reply(app, containing: "Instagram is open for 10")
        XCTAssertTrue(grant.waitForExistence(timeout: Self.answer),
                      "the grant read-back did not appear with no model behind the bar")
        XCTAssertEqual(grant.label, "Instagram is open for 10 min.",
                       "the grant answered \"\(grant.label)\"")
        // The door row states the deadline it will re-lock at — the fact the
        // reply deliberately does not carry.
        let row = labelled(app, beginsWith: "Instagram, open till")
        XCTAssertTrue(wait(for: row, "exists == true", timeout: Self.appear),
                      "the Instagram row does not show a re-lock time after the grant")
        XCTAssertTrue(enso(app, reading: 30).waitForExistence(timeout: Self.appear),
                      "the ensō did not debit to 30")
        shoot("02 — unlock Instagram for 10 min — \(row.label)")

        // 3. THE PARAPHRASE. Nothing in the grammar reads this sentence, and
        //    with no model there is nothing behind the grammar — so the answer
        //    is the four words, and it must arrive on the beat rather than on
        //    the widener's two-second clock.
        tap(bar, "the bar")
        if !waitForFocus(bar, timeout: 4) {
            tap(bar, "the bar, again")
            _ = waitForFocus(bar, timeout: 4)
        }
        let sent = Date.now
        bar.typeText("how about a little tiktok\n")
        let typed = Date.now
        let refusal = reply(app, containing: "get that.")
        XCTAssertTrue(refusal.waitForExistence(timeout: Self.answer),
                      "a sentence nothing could read was left unanswered")
        let landed = Date.now
        XCTAssertEqual(refusal.label, Self.didntGetThat,
                       "the refusal read \"\(refusal.label)\"")
        let sinceTyping = landed.timeIntervalSince(typed)
        let sinceFocus = landed.timeIntervalSince(sent)
        print(String(format: "[no-model-walk] refusal visible %.3f s after the newline "
                     + "(%.3f s from the tap into the bar)", sinceTyping, sinceFocus))
        // PRINTED, NOT ASSERTED, and the deleted bound is why.
        //
        // It read `XCTAssertLessThan(sinceTyping, 4.0)` with a message about
        // the widener's two-second deadline — but what the stopwatch above
        // actually measures is a `waitForExistence` returning, which is
        // XCUITest polling an accessibility tree across a process boundary on
        // a simulator. That poll is worth a second on its own on a good day
        // and several on a loaded runner, so the margin between the product's
        // number and the bound was mostly the harness. A test that fails
        // because the runner was busy, with a message accusing the parser, is
        // worse than no test: it teaches the reader to disbelieve the suite.
        //
        // The property is not lost. `NoModelTurnTests` measures the same
        // refusal five times against `SilkModelParser.deadline` with no
        // simulator between the clock and the code
        // (`theRefusalLandsOnTheBeatAndNothingIsLeftRunning`), which is where a
        // bound like this can mean something. What this walk is for is that the
        // refusal appears ON THE GLASS at all, which the assertion above says.
        XCTAssertTrue(enso(app, reading: 30).exists, "a refused sentence moved the balance")
        shoot(String(format: "03 — paraphrase refused in %.2fs", sinceTyping))

        // 4. THE BUDGET. A raise is a loosening, so canon parks it and the
        //    receipt names the day and the number.
        say(bar, "budget 60\n")
        let parked = reply(app, saying: "Tomorrow: 60")
        XCTAssertTrue(parked.waitForExistence(timeout: Self.answer),
                      "the budget change was not answered with its receipt")
        shoot("04 — budget 60 — Tomorrow: 60")

        // 5. THE BALANCE. Ten spent out of forty, and the raise is not in force
        //    until tomorrow.
        say(bar, "how much is left\n")
        let balance = reply(app, saying: "30 min left.")
        XCTAssertTrue(balance.waitForExistence(timeout: Self.answer),
                      "the balance question was not answered")
        shoot("05 — how much is left — 30 min left.")
    }
}
