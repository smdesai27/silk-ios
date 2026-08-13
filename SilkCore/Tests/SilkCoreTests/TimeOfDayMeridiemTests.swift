import Foundation
import Testing
@testable import SilkCore

// Context-free spoken deadlines carry a meridiem. `display` is for a
// sentence that already said morning or night ("Till 7:00." inside a
// paragraph about the night window). Siri has no such paragraph: the
// refusal is the whole utterance, spoken at 11 PM as easily as at 11 AM.
//
// This is the pin that drives the finding-2 fix. Swap
// `SpendDialog.downHours` back to `until.display` and this suite goes red.

@Suite struct TimeOfDayMeridiemTests {

    @Test func aContextFreeSpokenDeadlineCarriesTheMeridiem() {
        let seven = TimeOfDay(hour: 7)
        let spoken = SpendDialog.downHours(until: seven)
        #expect(spoken.contains(seven.displayWithMeridiem))
        #expect(spoken == "\(SilkStrings.till) \(seven.displayWithMeridiem).")
        #expect(spoken != "\(SilkStrings.till) \(seven.display).")
    }

    @Test func anEveningOpeningIsNotReadAsMorning() {
        let ten = TimeOfDay(hour: 22)
        let spoken = SpendDialog.downHours(until: ten)
        #expect(spoken.contains("PM"))
        #expect(spoken.contains(ten.displayWithMeridiem))
        #expect(spoken != "\(SilkStrings.till) \(ten.display).")
    }

    @Test func noonAndMidnightStayUnambiguous() {
        #expect(SpendDialog.downHours(until: TimeOfDay(hour: 12)).contains("PM"))
        #expect(SpendDialog.downHours(until: TimeOfDay(hour: 0)).contains("AM"))
    }

    @Test func displayItselfStaysMeridiemLessForSentencesThatCarryContext() {
        // The row, the closed-door sentence, the grant deadline sitting
        // after "till" — those already named the relation. A meridiem there
        // would be noise. This file does not take that away.
        #expect(TimeOfDay(hour: 7).display == "7:00")
        #expect(TimeOfDay(hour: 22).display == "10:00")
    }
}
