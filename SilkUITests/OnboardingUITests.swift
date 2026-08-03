import XCTest

/// Walks the whole product on the simulator: onboarding end to end, the first
/// grant through the bar, and the surfaces that shipped after it — the
/// wall-down row, the thread's Undo, the status ask, the Settings wheels.
/// This is the file that answers "does it work in the simulator" with
/// something better than a guess.
final class OnboardingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
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
    @MainActor
    private func dismissScreenTimeConsent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // "Don't Allow", curly quote and all — matched loosely so the copy
        // owning the apostrophe stays Apple's problem.
        let decline = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        if decline.waitForExistence(timeout: 4) { decline.tap() }
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
        XCTAssertTrue(ok.waitForExistence(timeout: 5), "onboarding did not show")
        ok.tap()  // permission
        XCTAssertTrue(app.staticTexts["Which apps should Silk block?"].waitForExistence(timeout: 5))
        dismissScreenTimeConsent()
        let chip = app.buttons["chip.\(door)"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        bindThroughPicker(app, app: door)
        ok.tap()  // apps
        XCTAssertTrue(app.staticTexts["How many minutes a day?"].waitForExistence(timeout: 5))
        ok.tap()  // limits — setup completes here
        let bar = app.textFields["silk.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "did not land on Now after setup")
        return bar
    }

    /// Naming a door now raises Silk's picker sheet, and the sheet's Done is
    /// the gate — so binding is part of finishing the apps step, not something
    /// a simulator run can skip. Picks the one app and commits.
    @MainActor
    private func bindThroughPicker(_ ui: XCUIApplication, app named: String) {
        let header = element(ui, "silk.picker.header")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the picker sheet did not rise")
        let row = ui.buttons["silk.picker.row.\(named)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(named) was not in the list")
        row.tap()
        let done = ui.buttons["silk.picker.done"]
        XCTAssertTrue(done.isEnabled, "Done stayed dead on exactly one app")
        done.tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "the picker sheet did not come down")
    }

    /// Identifier lookup that does not guess the element's type: a combined
    /// Settings row reads as a button on some releases and a plain element on
    /// others, and the picker's layers are bare stacks.
    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The backdrop is the picker's commit button, but the wheels fold into
    /// single adjustable elements and the backdrop's own element does not
    /// surface reliably — so tap through the overlay itself, low, under the
    /// wheels, where only the backdrop listens.
    @MainActor
    private func tapPickerBackdrop(_ app: XCUIApplication) {
        element(app, "silk.picker")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
            .tap()
    }

    /// Steps a wheel by whole rows. The wheel folds into one adjustable
    /// element and its identifiers don't surface to XCUI, so the drag goes
    /// through the overlay's frame: the single wheel sits centred, ~25pt below
    /// the overlay's middle (title + its 34pt seat above). A slow 52pt-per-row
    /// drag with a settling hold snaps exactly `rows` seats — positive drags
    /// the column down (earlier values).
    @MainActor
    private func dragWheel(_ app: XCUIApplication, rows: Int) {
        let start = element(app, "silk.picker")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
        let end = start.withOffset(CGVector(dx: 0, dy: CGFloat(rows) * 52))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    @MainActor
    func testOnboardingWalkthroughAndFirstGrant() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.launchArguments
        app.launch()

        let ok = app.buttons["silk.setup.ok"]

        // Step 1 — permission
        XCTAssertTrue(app.staticTexts["Silk uses Screen Time to block the apps you choose."].waitForExistence(timeout: 5),
                      "onboarding did not show")
        XCTAssertTrue(ok.isEnabled)
        ok.tap()

        // Step 2 — apps
        XCTAssertTrue(app.staticTexts["Which apps should Silk block?"].waitForExistence(timeout: 5),
                      "stuck on the permission step — authorization gated the flow")
        dismissScreenTimeConsent()
        // Each name raises its own sheet and is answered there before the next
        // one is named — one app at a time, which is the whole point of the
        // step. Naming and binding are no longer separable.
        let instagram = app.buttons["chip.Instagram"]
        XCTAssertTrue(instagram.waitForExistence(timeout: 5))
        instagram.tap()
        bindThroughPicker(app, app: "Instagram")
        app.buttons["chip.TikTok"].tap()
        bindThroughPicker(app, app: "TikTok")
        // The quiet door to the extras sits below the chips — plural is
        // correct there, and its own sheet says so.
        XCTAssertTrue(app.buttons["silk.setup.other"].exists, "the Other apps button is missing")
        // Simulator: OK stays enabled regardless of selection.
        XCTAssertTrue(ok.isEnabled)
        ok.tap()

        // Step 3 — limits: the slider reads 40 until moved, and the wheels
        // sit under their caption.
        XCTAssertTrue(app.staticTexts["How many minutes a day?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["silk.setup.budget"].exists,
                      "the budget slider is missing")
        XCTAssertTrue(app.staticTexts["Locked overnight"].exists,
                      "the overnight caption is missing above the wheels")
        ok.tap()

        // Now — setup complete after three steps, apps listed, the bar present
        let bar = app.textFields["silk.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "did not land on Now after setup")
        XCTAssertTrue(app.staticTexts["Instagram"].exists)
        XCTAssertTrue(app.staticTexts["TikTok"].exists)

        // The first grant, through the whole pipeline: parse → validate →
        // debit → read-back. 40 - 10 = 30 left.
        bar.tap()
        bar.typeText("Instagram, ten\n")
        // The reply is a sentence now, not a time-statement: the current design
        // gives the bar a conversation, so "Instagram · 10 · till 5:12" became
        // "Instagram is open for 10 min."
        let readBack = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Instagram is open for 10")
        ).firstMatch
        XCTAssertTrue(readBack.waitForExistence(timeout: 10), "grant read-back did not appear")
        XCTAssertTrue(app.staticTexts["30"].waitForExistence(timeout: 5), "ensō did not debit to 30")
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
        XCTAssertTrue(ok.waitForExistence(timeout: 5), "onboarding did not show")
        ok.tap()  // permission
        XCTAssertTrue(app.staticTexts["Which apps should Silk block?"].waitForExistence(timeout: 5))
        dismissScreenTimeConsent()

        let header = element(app, "silk.picker.header")
        XCTAssertFalse(header.exists, "the picker sheet was up before any chip was tapped")

        let instagram = app.buttons["chip.Instagram"]
        XCTAssertTrue(instagram.waitForExistence(timeout: 5))
        instagram.tap()

        // The sheet rises on the tap — no reading beat to wait out — and its
        // header carries the door's name and the rule, above Apple's list
        // rather than underneath it.
        XCTAssertTrue(header.waitForExistence(timeout: 5), "no picker sheet after the chip tap")
        XCTAssertTrue(header.label.contains("Instagram"), "the sheet did not name the door")
        XCTAssertTrue(header.label.contains("Just Instagram"),
                      "the sheet did not state the one-app rule: \(header.label)")

        // Done is the gate, and it starts shut: nothing is picked yet.
        let done = app.buttons["silk.picker.done"]
        XCTAssertTrue(done.exists, "the sheet offered no Done")
        XCTAssertFalse(done.isEnabled, "Done was live with nothing picked")
        XCTAssertEqual(app.staticTexts["silk.picker.status"].label, "Nothing picked yet")

        // One app wakes it.
        app.buttons["silk.picker.row.Instagram"].tap()
        XCTAssertTrue(done.isEnabled, "Done stayed dead on exactly one app")

        // A second kills it again, and says why — the mistake the old flow
        // only caught after the list came down.
        app.buttons["silk.picker.row.TikTok"].tap()
        XCTAssertFalse(done.isEnabled, "Done stayed live on two apps")
        XCTAssertEqual(app.staticTexts["silk.picker.status"].label,
                       "2 picked — tap one to remove.")

        // A category can never be a door, however many apps ride with it.
        app.buttons["silk.picker.row.TikTok"].tap()
        app.buttons["silk.picker.row.Social"].tap()
        XCTAssertFalse(done.isEnabled, "a category got past Done")
        XCTAssertEqual(app.staticTexts["silk.picker.status"].label,
                       "A category can't be a door — pick one app.")

        // Cancelling a name that never got an app takes the name with it:
        // setup will not carry a door with nothing behind it.
        app.buttons["silk.picker.cancel"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "the sheet did not come down")
        XCTAssertFalse(app.buttons["chip.Instagram"].isSelected,
                       "a cancelled binding left its name selected")
    }

    /// The extras are the one place plural is right, and the sheet says so
    /// instead of applying the door rule everywhere and looking arbitrary.
    @MainActor
    func testOtherAppsSheetAllowsMany() throws {
        let app = launchFresh()
        let ok = app.buttons["silk.setup.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5), "onboarding did not show")
        ok.tap()
        XCTAssertTrue(app.staticTexts["Which apps should Silk block?"].waitForExistence(timeout: 5))
        dismissScreenTimeConsent()

        app.buttons["silk.setup.other"].tap()
        let header = element(app, "silk.picker.header")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the extras sheet did not rise")
        XCTAssertTrue(header.label.contains("Other apps"), "the extras sheet kept a door's title")

        let done = app.buttons["silk.picker.done"]
        XCTAssertFalse(done.isEnabled, "Done was live with nothing picked")
        app.buttons["silk.picker.row.Facebook"].tap()
        XCTAssertTrue(done.isEnabled, "one extra was refused")
        app.buttons["silk.picker.row.Snapchat"].tap()
        XCTAssertTrue(done.isEnabled, "the extras refused a second app — plural is correct here")
        XCTAssertEqual(app.staticTexts["silk.picker.status"].label, "2 apps")
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
        bar.tap()
        bar.typeText("give me sixty minutes of reddit\n")
        let clamped = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit is open for 40")
        ).firstMatch
        XCTAssertTrue(clamped.waitForExistence(timeout: 10), "clamped grant read-back did not appear")
        // The clamp is real, not just spoken: the whole balance was debited.
        XCTAssertTrue(app.staticTexts["0"].waitForExistence(timeout: 5), "ensō did not debit to 0")
    }

    /// The wall's truth-telling row (docs/market/gaps.md #5). The standing is
    /// re-judged on an onboarded init or foreground, so the flag is asserted
    /// across a relaunch: setup happens under -silkReset, then the app comes
    /// back onboarded with — and without — the wall forced down.
    @MainActor
    func testWallDownRowShowsOnlyWhenForced() throws {
        let app = launchFresh()
        completeSetup(app)
        app.terminate()

        // Onboarded, no flag: the simulator's standing is always up, so the
        // row must stay away. No -silkReset here — it would wipe the walk above.
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.textFields["silk.bar"].waitForExistence(timeout: 5),
                      "did not land on Now when already onboarded")
        XCTAssertFalse(app.staticTexts["Blocking is off."].exists)
        XCTAssertFalse(app.buttons["silk.wall.raise"].exists)
        app.terminate()

        // -silkWallDown YES forces the standing down, and the row states it
        // with its one action — "Turn it on." — beside it.
        app.launchArguments = ["-silkWallDown", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Blocking is off."].waitForExistence(timeout: 5),
                      "the blocking-off row did not show under -silkWallDown")
        XCTAssertTrue(app.buttons["silk.wall.raise"].exists,
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
        bar.tap()
        bar.typeText("no more reddit today\n")
        let closed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Reddit closed until")
        ).firstMatch
        XCTAssertTrue(closed.waitForExistence(timeout: 10), "close read-back did not appear")

        let undoPill = app.buttons["silk.turn.undo"]
        XCTAssertTrue(undoPill.waitForExistence(timeout: 5), "the tighten offered no way back")
        undoPill.tap()
        XCTAssertTrue(app.staticTexts["Put back."].waitForExistence(timeout: 5),
                      "Undo did not answer")

        // The restore is real, not just spoken: status names a closed door
        // when there is one, and after Undo it has none to name — the reply
        // is the bare balance, nothing appended.
        bar.tap()
        bar.typeText("status\n")
        XCTAssertTrue(app.staticTexts["40 min left."].waitForExistence(timeout: 10),
                      "status did not read a clean balance after Undo")
    }

    /// The status ask, straight through: a question changes nothing and is
    /// answered in the thread with the balance.
    @MainActor
    func testTypedStatusAskAnswersBalance() throws {
        let app = launchFresh()
        let bar = completeSetup(app)

        bar.tap()
        bar.typeText("status\n")
        XCTAssertTrue(app.staticTexts["40 min left."].waitForExistence(timeout: 10),
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

        app.buttons["silk.dot.2"].tap()
        let budgetRow = element(app, "silk.settings.budget")
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5), "Settings did not arrive on the dot tap")
        budgetRow.tap()

        let picker = element(app, "silk.picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the wheel did not rise")

        tapPickerBackdrop(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "the wheel did not fade out")
    }

    /// A Settings tighten answers with a toast carrying Undo — the one
    /// undo-bearing toast in the product — and Undo puts the old rule back
    /// where the row can read it.
    @MainActor
    func testSettingsTightenToastCarriesUndo() throws {
        let app = launchFresh()
        completeSetup(app)

        app.buttons["silk.dot.2"].tap()
        let budgetRow = element(app, "silk.settings.budget")
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 5))
        budgetRow.tap()
        XCTAssertTrue(element(app, "silk.picker").waitForExistence(timeout: 5))

        // 40 → 15 is a tighten: it lands on the backdrop tap, and the receipt
        // states the balance the new rule leaves. The wheel opens centred on
        // 45 (nearest seat to 40), so 15 is two rows up the table.
        dragWheel(app, rows: 2)
        tapPickerBackdrop(app)

        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "the tighten receipt did not toast")
        XCTAssertEqual(toast.label, "15 left today.")
        let undo = app.buttons["silk.toast.undo"]
        XCTAssertTrue(undo.exists, "the tighten toast carried no Undo")

        // The row already reads the new rule…
        XCTAssertTrue(budgetRow.label.contains("15 min"), "the budget row did not take the tighten")

        // …and Undo restores the old one, row and all.
        undo.tap()
        let restored = app.descendants(matching: .any)
            .matching(identifier: "silk.settings.budget")
            .matching(NSPredicate(format: "label CONTAINS %@", "40 min")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5), "Undo did not restore the budget")
    }

    /// The editor's backdrop is the exit; like the wheel's, its element does
    /// not surface reliably, so tap through the overlay itself, low, where
    /// only the backdrop listens.
    @MainActor
    private func tapEditorBackdrop(_ app: XCUIApplication) {
        element(app, "silk.settings.editor")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
            .tap()
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

        app.buttons["silk.dot.2"].tap()
        let doorRow = element(app, "silk.settings.door.Reddit")
        XCTAssertTrue(doorRow.waitForExistence(timeout: 5), "the Reddit row did not arrive")
        doorRow.tap()

        let editor = element(app, "silk.settings.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the door editor did not rise")
        let rebind = app.buttons["silk.settings.rebind"]
        XCTAssertTrue(rebind.exists, "the editor offered no Rebind")
        XCTAssertTrue(app.buttons["silk.settings.remove"].exists, "the editor offered no Remove")

        // Change app raises the same sheet setup uses — one idiom, not two.
        rebind.tap()
        let header = element(app, "silk.picker.header")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Change app raised no picker sheet")
        XCTAssertTrue(header.label.contains("Reddit"), "the sheet did not name the door")
        XCTAssertFalse(app.buttons["silk.picker.done"].isEnabled,
                       "Done was live before an app was picked")
        app.buttons["silk.picker.cancel"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "the sheet did not come down")
    }

    /// The add row offers only what is genuinely free (Reddit, already a
    /// door, must not be offered twice), a chip tap makes the door and lands
    /// the one-app guidance, and Remove takes a door out with the undo toast
    /// carrying the whole way back.
    @MainActor
    func testSettingsAddAndRemoveDoorWithUndo() throws {
        let app = launchFresh()
        completeSetup(app)   // one door: Reddit

        app.buttons["silk.dot.2"].tap()
        let addRow = element(app, "silk.settings.door.add")
        XCTAssertTrue(addRow.waitForExistence(timeout: 5), "the add row did not arrive")
        addRow.tap()

        let editor = element(app, "silk.settings.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the add overlay did not rise")
        XCTAssertTrue(app.buttons["add.chip.Instagram"].waitForExistence(timeout: 5),
                      "Instagram was not offered")
        XCTAssertFalse(app.buttons["add.chip.Reddit"].exists,
                       "Reddit is already a door and was offered again")

        // The chip tap makes the door and raises its binding sheet at once.
        // Cancelling takes the name back with it: an added door with no app
        // behind it is the half-state neither setup nor the editor will carry.
        app.buttons["add.chip.Instagram"].tap()
        let header = element(app, "silk.picker.header")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "no picker sheet after the chip tap")
        XCTAssertTrue(header.label.contains("Instagram"), "the sheet did not name the new door")
        app.buttons["silk.picker.cancel"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "the sheet did not come down")
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the add overlay did not fade out")
        let instagramRow = element(app, "silk.settings.door.Instagram")
        XCTAssertFalse(instagramRow.exists,
                       "a cancelled add left a door with no app behind it")

        // Again, answered this time: the door arrives only once it has its app.
        addRow.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["add.chip.Instagram"].tap()
        bindThroughPicker(app, app: "Instagram")
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the add overlay did not fade out")
        XCTAssertTrue(instagramRow.waitForExistence(timeout: 5),
                      "the added door has no Settings row")

        // Remove: instant, and the toast carries the way back.
        instagramRow.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["silk.settings.remove"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the editor outlived the removal")
        XCTAssertTrue(instagramRow.waitForNonExistence(timeout: 5), "the removed door kept its row")
        let toast = app.staticTexts["silk.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "the removal did not toast")
        XCTAssertEqual(toast.label, "Instagram removed.")
        let undo = app.buttons["silk.toast.undo"]
        XCTAssertTrue(undo.exists, "the removal toast carried no Undo")
        undo.tap()
        XCTAssertTrue(instagramRow.waitForExistence(timeout: 5), "Undo did not restore the door")
    }
}
