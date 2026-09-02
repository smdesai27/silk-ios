import Testing
import Foundation
@testable import Silk
@testable import SilkCore

// Fixture helpers shared by more than one file in this target. Each used to be
// copy-pasted per-file; consolidated here so a fix (or a drift, like the copy
// that only cleared "silkWait") cannot land in one copy and not the others.

/// A down-hours window that opens six hours out from `now` — clear of the
/// moment the suite runs, so nothing below is refused by the night or clamped
/// by its edge.
func nightWellClearOfNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay + 6 * 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 7 * 60))
}

/// A down-hours window the current minute sits inside — the night, wherever
/// the suite happens to run.
func nightContainingNow(_ now: Date = .now) -> DownHours {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return DownHours(start: TimeOfDay(minutesSinceMidnight: minuteOfDay - 60),
                     end: TimeOfDay(minutesSinceMidnight: minuteOfDay + 60))
}

/// A down-hours window containing no minute of any day, whose edge sits half a
/// day out whatever the clock says when the suite runs.
func noWindowTonight(at reference: Date = .now) -> DownHours {
    let hour = (Calendar.current.component(.hour, from: reference) + 12) % 24
    let nowhere = TimeOfDay(hour: hour, minute: 30)
    return DownHours(start: nowhere, end: nowhere)
}

/// Clears both debug seams — a pinned wait and a pinned staleness window —
/// from `UserDefaults.standard`, so neither leaks into a later test. This is
/// the superset of what any one copy of this used to clear: no suite may pin
/// only "silkWait" and leave "silkStale" to leak.
func unpinTheSeams() {
    UserDefaults.standard.removeObject(forKey: "silkWait")
    UserDefaults.standard.removeObject(forKey: "silkStale")
}

/// A grammar precondition: asserts the deterministic parser still claims
/// `sentence` (i.e. does not answer with silence) against `model`'s policy,
/// so a test that types it is measuring the grammar and not the on-device
/// widener.
@MainActor
func claimed(_ sentence: String, _ model: AppModel) {
    #expect(DeterministicParser.parse(sentence, state: model.policy) != .silence,
            "the grammar stopped claiming \"\(sentence)\" — this test now measures the widener")
}

/// Polls `reached` until it returns true or `seconds` elapse, returning
/// whether it was reached in time — waits for a state instead of a fixed
/// duration.
@MainActor
func settle(within seconds: Double = 3.0,
           until reached: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !reached() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
