import Foundation
import Testing
@testable import SilkCore

// Every sentence the Spend intent can speak, pinned as a composition against
// `SilkStrings` — and, where the bar says a different sentence for the same
// fact, pinned as a divergence. Nothing here is AppIntents; `SpendIntent`
// is a dispatcher over `SpendDialog`.

private let seven = TimeOfDay(hour: 7)
private let fourFiftyTwo = TimeOfDay(hour: 16, minute: 52)

/// The bar's own compositions, restated from `AppModel.apply`. The spine
/// cannot import the app, so the table names the shipped sentences rather
/// than calling the function that speaks them. A bar wording change that
/// is not mirrored here is a stale row, not a silent pass.
private enum BarDialog {
    static func downHours(_ until: TimeOfDay) -> String {
        "\(SilkStrings.downHoursOpens) \(until.displayWithMeridiem)."
    }
    static var nothingLeft: String { "0 \(SilkStrings.leftToday)." }
    static func doorClosed(door: String, until: TimeOfDay) -> String {
        "\(door) \(SilkStrings.closedUntil) \(until.display)."
    }
    static func granted(door: String, minutes: Int) -> String {
        "\(door) \(SilkStrings.isOpenFor) \(minutes) \(SilkStrings.minutes)."
    }
    static func restated(door: String, until: TimeOfDay) -> String {
        "\(door) \(SilkStrings.till.lowercased()) \(until.display)."
    }
}

@Suite struct IntentDialogRenderingTests {

    @Test func nothingLeftIsTheBareCount() {
        #expect(SpendDialog.nothingLeft == "0 \(SilkStrings.leftToday)")
        #expect(SpendDialog.nothingLeft.hasSuffix(".") == false)
    }

    @Test func downHoursNamesTheHourWithAMeridiem() {
        #expect(SpendDialog.downHours(until: seven)
                == "\(SilkStrings.till) \(seven.displayWithMeridiem).")
        // The old line, "Till 7:00.", is the sentence `display`'s own comment
        // used as an example of context already present. Siri has none.
        #expect(SpendDialog.downHours(until: seven)
                != "\(SilkStrings.till) \(seven.display).")
    }

    @Test func aClosedDoorNamesItselfAndTheBoundary() {
        #expect(SpendDialog.doorClosed(door: "TikTok", until: seven)
                == "TikTok \(SilkStrings.closedUntil) 7:00.")
    }

    @Test func theGrantDialogStatesTheDeadline() {
        #expect(SpendDialog.granted(door: "Instagram", minutes: 15, until: fourFiftyTwo)
                == "Instagram · 15 · \(SilkStrings.till.lowercased()) 4:52")
    }

    @Test func aRestatedGrantRepeatsTheDeadlineAndDebitsNothing() {
        #expect(SpendDialog.restated(door: "Instagram", until: fourFiftyTwo)
                == "Instagram · \(SilkStrings.till.lowercased()) 4:52")
    }

    @Test func silenceIsEmpty() {
        #expect(SpendDialog.silence.isEmpty)
    }

    /// The intent speaks the shield's sentence rather than a second copy of it.
    ///
    /// `SpendDialog.blockingOff == SilkStrings.blockingOff` used to stand here
    /// and could not fail: the former is *defined* as the latter
    /// (`SpendDialog.swift:49`), so it was a value compared with itself and
    /// would have stayed green if the sentence had been rewritten to anything
    /// at all. The pinnable fact is the sentence, asserted at both ends — a
    /// second copy introduced anywhere has to disagree with one of them.
    @Test func blockingOffIsTheShieldsOwnSentence() {
        #expect(SilkStrings.blockingOff == "Blocking is off.")
        #expect(SpendDialog.blockingOff == "Blocking is off.")
    }

    /// One row per fact the two surfaces can both speak. `same` is the
    /// product decision, not a leftover: a true means the sentences must
    /// stay byte-identical, a false means the intent's form is deliberate
    /// and a unification would be a regression.
    @Test(arguments: [
        (name: "down hours",
         intent: SpendDialog.downHours(until: seven),
         bar: BarDialog.downHours(seven),
         same: false),
        (name: "nothing left",
         intent: SpendDialog.nothingLeft,
         bar: BarDialog.nothingLeft,
         same: false),
        (name: "door closed",
         intent: SpendDialog.doorClosed(door: "TikTok", until: seven),
         bar: BarDialog.doorClosed(door: "TikTok", until: seven),
         same: true),
        (name: "grant",
         intent: SpendDialog.granted(door: "Instagram", minutes: 15, until: fourFiftyTwo),
         bar: BarDialog.granted(door: "Instagram", minutes: 15),
         same: false),
        (name: "restated",
         intent: SpendDialog.restated(door: "Instagram", until: fourFiftyTwo),
         bar: BarDialog.restated(door: "Instagram", until: fourFiftyTwo),
         same: false),
    ])
    func intentAndBarWording(_ row: (name: String, intent: String, bar: String, same: Bool)) {
        if row.same {
            #expect(row.intent == row.bar, "\(row.name) must stay byte-identical")
        } else {
            #expect(row.intent != row.bar, "\(row.name) is a deliberate divergence")
        }
        if row.name == "down hours" {
            #expect(row.intent.contains(seven.displayWithMeridiem),
                    "the spoken down-hours refusal lost its meridiem")
        }
    }

    @Test func theGrantDivergenceIsTheDeadlineVersusTheOpening() {
        // Finding 3, pinned. Siri states when the door shuts; the bar states
        // that it opened, and launches it. Unifying these would drop the
        // deadline from the one surface with no screen.
        let intent = SpendDialog.granted(door: "Instagram", minutes: 15, until: fourFiftyTwo)
        let bar = BarDialog.granted(door: "Instagram", minutes: 15)
        #expect(intent.contains(SilkStrings.till.lowercased()))
        #expect(bar.contains(SilkStrings.isOpenFor))
        #expect(intent.contains("4:52"))
        #expect(bar.contains("15"))
    }
}
