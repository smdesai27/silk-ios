import Foundation

/// Every sentence the Spend intent can speak.
///
/// The wording lives here, not in the intent, so the spine can pin it without
/// AppIntents and without a simulator. `SpendIntent.perform` is a thin
/// dispatcher over these compositions; a character that changes here is the
/// character Siri says.
///
/// Several of these diverge from the bar on purpose. The table in
/// `IntentDialogRenderingTests` names each divergence; the grant dialog is
/// the load-bearing one (finding 3): Siri states the re-lock deadline because
/// nobody is watching the screen. The bar says the door is open, and opens it.
public enum SpendDialog {

    /// "Instagram · 15 · till 4:52" — the grant, with the hour it ends.
    /// Deliberately not "Instagram is open for 15 min.": the intent never
    /// launches, and the deadline is the fact a Shortcut has to carry.
    public static func granted(door: String, minutes: Int, until: TimeOfDay) -> String {
        "\(door) · \(minutes) · \(SilkStrings.till.lowercased()) \(until.display)"
    }

    /// "Instagram · till 4:52" — a live grant restated, no second debit.
    public static func restated(door: String, until: TimeOfDay) -> String {
        "\(door) · \(SilkStrings.till.lowercased()) \(until.display)"
    }

    /// "Till 7:00 AM." — spoken with no screen and no sentence that already
    /// named the night, so the hour carries its meridiem. The bar's fuller
    /// "Down hours. Opens 7:00 AM." is the same hour in a different sentence;
    /// both use `displayWithMeridiem`. The meridiem-less `display` is for
    /// sentences that already carry the context, which this one does not.
    public static func downHours(until: TimeOfDay) -> String {
        "\(SilkStrings.till) \(until.displayWithMeridiem)."
    }

    /// "0 left today" — no period. The bar's toast adds one; Siri's dialog
    /// is the composition `SilkStrings.leftToday` documents.
    public static var nothingLeft: String {
        "0 \(SilkStrings.leftToday)"
    }

    /// "TikTok closed until 7:00." — byte-identical to the bar. A capped-out
    /// door and a hand-closed door share this sentence; `until` is the lift.
    public static func doorClosed(door: String, until: TimeOfDay) -> String {
        "\(door) \(SilkStrings.closedUntil) \(until.display)."
    }

    public static var blockingOff: String { SilkStrings.blockingOff }

    /// Unknown door, unknown verdict, a schedule that would not take while
    /// the wall still stands: silence, never a guessed sentence.
    public static var silence: String { "" }
}
