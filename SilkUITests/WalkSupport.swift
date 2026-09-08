import XCTest

/// The base every walk in this bundle is written on: how long it waits, how it
/// taps, how it types, and how it puts the app down.
///
/// **Why this file exists.** These helpers were written once, in
/// `OnboardingUITests`, where they are the accumulated answer to about a dozen
/// specific CI failures — a swallowed chip tap, a consent alert that outlived a
/// process, a predicate query that came back "not there" because it was never
/// answered, a cold simulator that took the session's first keyboard focus and
/// then dropped it. Each carries a comment naming the failure it exists for.
/// They were then copied, byte for byte, into two more files, and the copies
/// carried none of those comments — so the reasoning lived in one place and the
/// code lived in three, which is the arrangement where a fix lands in one copy
/// and not the others. `dismissScreenTimeConsent` had already drifted: two of
/// the three looked in `springboard.alerts.buttons` and one looked in
/// `springboard.buttons`, and nobody could have said which was right.
///
/// The reasoning below is the ORIGINAL, moved rather than rewritten. Nothing
/// here is new except the union of the consent query, which is the one place
/// the three copies actually disagreed.
///
/// A subclass rather than free functions because half of these are instance
/// methods on `XCTestCase` (`expectation(for:evaluatedWith:)`) and because the
/// `setUpWithError` / `tearDown` pair is the other half of the same contract:
/// stop on first failure, and put the app down properly afterwards.
class SilkWalk: XCTestCase {

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
    static let appear: TimeInterval = 12

    /// A sheet or an overlay arriving on a gesture. Longer because a sheet's
    /// own 0.4s curve is the smallest part of what it waits on: a simulator
    /// xcodebuild has just booted is still serving the app's first launch, the
    /// accessibility server's first tree, and Screen Time's daemons waking, and
    /// the presentation queues behind all of it.
    static let overlay: TimeInterval = 20

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
    static let launch: TimeInterval = 90

    /// A reply in the thread. The bar answers behind a deliberate ~480ms beat
    /// and the parse that precedes it, so this is the beat plus room.
    static let answer: TimeInterval = 15

    // MARK: - The identifiers the walks name elements by

    /// The bar's answer (`ConversationView.swift`, the reply `Text`).
    static let replyID = "silk.turn.reply"

    /// The budget numeral inside the ensō (`NowView.swift`).
    static let ensoID = "silk.enso.value"

    // MARK: - Setup and teardown

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
            SilkWalk.stop(XCUIApplication())
        }
    }

    /// Puts the app down and waits until it is actually gone, rather than
    /// asking and moving on. Used between the relaunches a test makes and again
    /// in teardown, so the process is never killed while it is busy and never
    /// assumed dead while it is dying. A consent alert left standing outlives
    /// the process and would land over whatever launches next, so it goes
    /// first.
    @MainActor
    static func stop(_ app: XCUIApplication) {
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
        guard !app.wait(for: .notRunning, timeout: appear) else { return }
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: appear)
    }

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
    ///
    /// **The union of the three copies.** Two of them queried
    /// `springboard.alerts.buttons` and one queried `springboard.buttons`, with
    /// no note anywhere saying why — and both are right, at different times:
    /// the alert is an `alert` when SpringBoard has published it as one, and a
    /// bare button hierarchy while it is still arriving or when the runtime
    /// presents it as a sheet. Asking the narrow query first and falling back
    /// to the broad one costs one query on the path that finds nothing, which
    /// is most runs, and cannot be wrong in the direction that matters: an
    /// undismissed alert eats the next tap five seconds and two helpers away
    /// from here.
    @MainActor
    @discardableResult
    static func dismissScreenTimeConsent(timeout: TimeInterval = 4) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // "Don't Allow", curly quote and all — matched loosely so the copy
        // owning the apostrophe stays Apple's problem.
        let inAlert = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch
        if inAlert.waitForExistence(timeout: timeout) {
            inAlert.tap()
            _ = inAlert.waitForNonExistence(timeout: overlay)
            return true
        }
        let bare = springboard.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch
        if bare.waitForExistence(timeout: 0) {
            bare.tap()
            _ = bare.waitForNonExistence(timeout: overlay)
            return true
        }
        return false
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
    func wait(for element: XCUIElement, _ predicate: String,
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

    /// A tap that waits until it can land. `exists` is answered from a snapshot
    /// of the accessibility tree and says nothing about whether a touch would
    /// reach the element: a row still sliding in under a page transition, or a
    /// chip under SpringBoard's alert, exists and is not hittable. A tap
    /// delivered then is not an error — it goes somewhere harmless and the walk
    /// carries on against a screen that never changed, which is how a missed
    /// tap surfaces five seconds later and two helpers away from where it
    /// actually happened.
    @MainActor
    func tap(_ element: XCUIElement, _ what: String,
             timeout: TimeInterval = SilkWalk.appear,
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
    func tap(_ trigger: XCUIElement, _ what: String,
             raising target: XCUIElement, _ raised: String,
             timeout: TimeInterval = SilkWalk.overlay,
             file: StaticString = #filePath, line: UInt = #line) {
        tap(trigger, what, file: file, line: line)
        if target.waitForExistence(timeout: timeout) { return }
        Self.dismissScreenTimeConsent(timeout: 0)
        if trigger.isHittable { trigger.tap() }
        XCTAssertTrue(target.waitForExistence(timeout: timeout),
                      "\(raised) did not rise on \(what)", file: file, line: line)
    }

    // MARK: - Naming elements

    /// Identifier lookup that does not guess the element's type: a combined
    /// Settings row reads as a button on some releases and a plain element on
    /// others, and the picker's layers are bare stacks.
    @MainActor
    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// THE BAR'S ANSWER, named by the view that draws it AND read for the
    /// sentence a person sees on it.
    ///
    /// Both halves, in one predicate, and the pair is the point. Nineteen
    /// assertions used to match the reply by hunting the whole tree for a label
    /// containing some English — which is a query for "anything on this screen
    /// that says this", not a query for the reply. It found the right element
    /// most of the time by luck: the thread is the only thing on the page
    /// carrying whole sentences. It also found the wrong one at least once —
    /// `testAnAbandonedWaitSpendsNothingAndPutsTheClockBack` matched the ensō's
    /// own numeral with a `CONTAINS` on a bare number, and would have stayed
    /// green with the thread stone dead.
    ///
    /// With the identifier in front of it, a copy change fails on the sentence
    /// and an identifier that drifts off the reply `Text` fails on the
    /// identifier — two different regressions with two different messages,
    /// instead of one query that quietly stops meaning what it says.
    ///
    /// Matched over `descendants(matching: .any)` and not over `staticTexts`
    /// for the reason `element(_:_:)` gives: guessing the element type is how a
    /// query starts missing on a release that renders the same view
    /// differently.
    @MainActor
    func reply(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                        SilkWalk.replyID, fragment)
        ).firstMatch
    }

    /// The same, when the whole sentence is the assertion rather than a
    /// fragment of it.
    @MainActor
    func reply(_ app: XCUIApplication, saying sentence: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label == %@",
                        SilkWalk.replyID, sentence)
        ).firstMatch
    }

    /// THE ENSŌ'S NUMERAL, which the walks used to find by matching the bare
    /// string "30" anywhere in the tree.
    ///
    /// That query asks for "an element whose whole label is that number", and
    /// Now has several: a door row's cap, a wheel seat, a Settings value. It
    /// happened to resolve to the hero because the hero is usually the first
    /// such element in the tree — a fact about traversal order, not about the
    /// product. The identifier names the one element the assertion is about,
    /// and the number stays the label, so the balance is still what fails.
    @MainActor
    func enso(_ app: XCUIApplication, reading minutes: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label == %@",
                        SilkWalk.ensoID, "\(minutes)")
        ).firstMatch
    }

    // MARK: - Typing at the bar

    /// Types a sentence at the bar. The tap has to take focus before a
    /// character can go anywhere, and the bar is the last thing to settle when
    /// a page or an overlay has just moved, so it waits to be tappable like
    /// every other tap here.
    @MainActor
    func say(_ bar: XCUIElement, _ sentence: String,
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
    func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"),
                                  evaluatedWith: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }
}
