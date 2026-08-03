import Testing
@testable import SilkCore

// MARK: - DoorBinding: one door, one app

/// The rule for door bindings: exactly one application token, nothing else.
/// The system picker will happily hand back three apps and a category; this
/// is the arithmetic that refuses them. The picker itself can't be driven on
/// the simulator, so the verdicts — and the copy that answers each one — are
/// proved here.
@Suite struct DoorBindingTests {
    @Test func exactlyOneAppBinds() {
        #expect(DoorBinding.validate(applications: 1, categories: 0, webDomains: 0) == .bound)
    }

    @Test func emptyReturnIsACancel() {
        #expect(DoorBinding.validate(applications: 0, categories: 0, webDomains: 0) == .cancelled)
    }

    /// Plural apps never truncate to the first token — they bind nothing.
    @Test func extraAppsAskAgain() {
        #expect(DoorBinding.validate(applications: 2, categories: 0, webDomains: 0) == .retry)
        #expect(DoorBinding.validate(applications: 5, categories: 0, webDomains: 0) == .retry)
    }

    /// One app is not enough if anything rides along with it.
    @Test func oneAppPlusAnythingElseAsksAgain() {
        #expect(DoorBinding.validate(applications: 1, categories: 1, webDomains: 0) == .retry)
        #expect(DoorBinding.validate(applications: 1, categories: 0, webDomains: 1) == .retry)
        #expect(DoorBinding.validate(applications: 1, categories: 2, webDomains: 3) == .retry)
    }

    /// A category or a domain alone is not an app at all.
    @Test func nonAppTokensAloneAskAgain() {
        #expect(DoorBinding.validate(applications: 0, categories: 1, webDomains: 0) == .retry)
        #expect(DoorBinding.validate(applications: 0, categories: 0, webDomains: 2) == .retry)
    }

    /// The sheet's lines, word for word what the UI test asserts on screen.
    /// The correction that used to follow a plural return is gone: the sheet's
    /// Done never lights on a plural pick, so there is nothing to correct.
    @Test func sheetLinesComposeWithTheAppName() {
        #expect(SilkStrings.findAndTap("Instagram")
                == "Find Instagram below and tap it. Just Instagram.")
        #expect(SilkStrings.pickedTapToRemove(2) == "2 picked — tap one to remove.")
        #expect(SilkStrings.appsPicked(1) == "1 app")
        #expect(SilkStrings.appsPicked(4) == "4 apps")
    }
}
