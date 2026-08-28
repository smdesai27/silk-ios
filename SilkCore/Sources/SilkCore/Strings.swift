/// Everything Silk says.
///
/// The rule is plain language: short sentences that state what is happening.
/// Apps are apps, blocking is blocking — no metaphors, no coined vocabulary.
///
///   - No "I". No sorry, no please, no exclamation marks. Never chatty.
///   - Replies are short, plain, and state what happened — not what Silk thinks.
///   - Refusals are time-statements. A "no" weighs less than a decision.
///   - You speak in durations; a rule answers in deadlines.
///
/// App names, numbers and times are user data, not strings; composed
/// renderings do not count as new ones.
public enum SilkStrings {
    // Now
    public static let goodMorning = "Good morning."
    public static let goodAfternoon = "Good afternoon."
    public static let goodEvening = "Good evening."
    /// Composes with the down-hours start hour: "Down hours at 10."
    public static let downHoursAt = "Down hours at"
    public static let minLeftToday = "min left today"

    // Answers — the shapes the handoff's reply table specifies.
    public static let till = "Till"
    /// The shield's word. The row's serif slot uses lowercase "till" instead —
    /// it follows a separator rather than opening a headline.
    public static let until = "Until"
    public static let leftToday = "left today"        // composes: "0 left today"
    public static let minLeft = "min left."           // composes: "40 min left."
    public static let isOpenFor = "is open for"       // "Instagram is open for 15 min."
    public static let closedUntil = "closed until"    // "TikTok closed until 9:00."
    /// The subject of a close-all: "Everything closed until 9:00."
    public static let everything = "Everything"
    /// "TikTok closed until 9:00." — and, with subject `everything`, the
    /// close-all's plural confirmation. The ONE composition of `closedUntil`:
    /// the bar's cap refusal, the close and close-all receipts, the status
    /// tail, the ceiling receipt and Siri's dialog all speak this sentence,
    /// and they were held byte-identical by comments before they were held
    /// here. A rendering, not a new string: subject and hour are user data.
    public static func closedUntil(_ subject: String, until: TimeOfDay) -> String {
        let phrase: String = closedUntil
        return "\(subject) \(phrase) \(until.display)."
    }
    public static let minutes = "min"
    public static let howLong = "How long?"
    public static let didntGetThat = "Didn’t get that."

    /// "11am or 11pm?", "7:30am or 7:30pm?" — the whole question, and the whole
    /// reply. A bare hour whose two readings move the night in opposite
    /// directions is not a sentence Silk can act on, and the shortest way to
    /// say so is to hand both readings back. Composed from the user's own
    /// number, so it is a rendering rather than a new string: no "which did you
    /// mean", no apology, no explanation of the rule it declined to guess at.
    ///
    /// The minutes come too. Offering "7am or 7pm?" to someone who said 7:30
    /// names two times and neither of them the one asked for.
    public static func amOrPm(_ time: TimeOfDay) -> String {
        let h = time.hour % 12 == 0 ? 12 : time.hour % 12
        let clock = time.minute == 0 ? "\(h)" : "\(h):\(String(format: "%02d", time.minute))"
        return "\(clock)am or \(clock)pm?"
    }
    public static let downHoursRun = "Down hours run" // "…run 10:00 PM to 7:00 AM."
    public static let to = "to"
    public static let downHoursOpens = "Down hours. Opens"
    public static let ok = "OK"

    // The shield — whose wall this is, and where to go. The extension links
    // SilkCore, so its words live here like everyone else's.
    public static let brand = "Silk"
    public static let openSilk = "Open Silk"

    /// Blocking's truth-telling row: authorization revoked, or a new phone
    /// holding tokens that no longer shield. Shown on Now the moment either is
    /// detected — a calm screen over dead blocking is the one lie Silk could
    /// accidentally tell. (docs/market/gaps.md #5)
    ///
    /// The Spend intent says it too, on exactly the same signal and no other:
    /// a spend refused because no re-lock would arm answers with this sentence
    /// only when the wall is not standing, and with nothing at all otherwise.
    /// Said on any other arming failure it would be that same lie inverted —
    /// the Shortcut calling blocking dead while Now, which reads authorization
    /// and tokens and nothing about schedules, draws the wall whole.
    public static let blockingOff = "Blocking is off."
    public static let turnItOn = "Turn it on."

    // Rule changes
    public static let tomorrow = "Tomorrow:"          // composes: "Tomorrow: 60"
    public static let appliesTomorrow = "Applies tomorrow."
    public static let applyNow = "Apply now."

    /// The receipt a parked loosening leaves — "Tomorrow: Reddit no cap",
    /// "Tomorrow: 60", "Tomorrow: 10:00–7:00".
    ///
    /// A rendering, not a new sentence: both halves are already here, and
    /// `summary` is user data (a door's name, a number, an hour) composed by
    /// `AppModel.pendingSummary` — the same call Now's pending row makes, so
    /// the reply and the row cannot disagree about what is waiting.
    ///
    /// Why it replaces the bare constant everywhere it can: "Applies tomorrow."
    /// names nothing. It is byte-identical after a budget raise, a shortened
    /// night and a cleared ceiling, and a gesture that visibly changes nothing —
    /// which every loosening is, by rule 3 — answered by a sentence carrying no
    /// user data at all is indistinguishable from a dropped command. Every other
    /// receipt in the app states what moved; this one now does too.
    ///
    /// The constant stays, and this falls back to it, because a loosening can
    /// still be one no surface can summarise (the wall itself). Saying "Tomorrow:"
    /// with nothing after it would be worse than saying less.
    ///
    /// Deliberately NOT an explanation. The canon's rule is that a deferral is a
    /// time-statement and never a lecture, so the sentence names the day and the
    /// thing, and the *reason* it is not now is carried by form and placement —
    /// the key offered beside it, the ceiling still standing on the row behind it.
    public static func parked(_ summary: String?) -> String {
        guard let summary else { return appliesTomorrow }
        return "\(tomorrow) \(summary)"
    }
    public static let undo = "Undo"
    public static let putBack = "Put back."

    // Mirror
    public static let week = "Week"
    /// The hero's day name before any day has closed: the running score is
    /// today's, and it says so.
    public static let today = "Today"

    // Settings
    public static let downHours = "Down hours"
    public static let budget = "Budget"
    public static let apps = "Apps"
    /// A closed app's state word, where no reopen time applies: "closed".
    public static let closed = "closed"
    public static let perDay = "day"
    /// The cap wheel's first seat, the Settings row's value for a door with no
    /// ceiling, and — lowercased, as `till` is — the pending row's rendering of
    /// a matured clearing. Minutes cannot express absence, and a blank wheel
    /// seat would be invisible and silent both.
    public static let noCap = "No cap"
    /// The door editor's middle row. Deliberately not `budget`: under a door's
    /// name that word reads as a per-door allowance, which is the one thing a
    /// cap is not, on a page whose global row already says "Budget".
    public static let dailyCap = "Daily cap"

    // Setup — three steps, three prompts.
    public static let setupPermission = "Silk uses Screen Time to block the apps you choose."
    public static let setupPickApps = "Which apps should Silk block?"
    public static let howManyMinutesADay = "How many minutes a day?"
    /// Caption over the night-window wheels on the last setup step.
    public static let lockedOvernight = "Locked overnight"
    /// The quiet second path on the apps step: block apps Silk can't open by
    /// name (anything outside the launch catalogue).
    public static let otherApps = "Other apps"

    // The picker sheet. Silk owns the sheet the system list sits inside, so
    // every one of these lines is on screen the whole time the list is —
    // the earlier design said them once, underneath, and the sheet buried
    // them. Nothing here corrects a mistake after the fact: the sheet's own
    // Done refuses to commit until the pick is singular.
    /// Under the door's name: "Find Instagram below and tap it. Just Instagram."
    public static func findAndTap(_ name: String) -> String {
        "Find \(name) below and tap it. Just \(name)."
    }
    /// The reason the step exists at all. Without it, naming the app to Silk
    /// and then hunting the same app in Apple's list reads as a bug.
    public static let iosWontSay = "iOS won't tell Silk which app is which, so you point once."
    /// The extras' own header — plural is correct there, and saying so is what
    /// keeps the one-app rule from reading as arbitrary.
    public static let pickAsMany = "Pick as many as you like."
    public static let extrasStayShut = "These stay shut without a name, so Silk never has to speak them."

    /// The footer, before anything is picked.
    public static let nothingPickedYet = "Nothing picked yet"
    /// The footer once the pick went plural. Composes: "2 picked — tap one to remove."
    public static func pickedTapToRemove(_ n: Int) -> String {
        "\(n) picked — tap one to remove."
    }
    /// A category is a whole class of apps; a door is one app with one name.
    public static let categoryNotADoor = "A category can't be a door — pick one app."
    /// The extras take apps only, so a category picked there is dropped rather
    /// than stored and never enforced.
    public static let categoriesDropped = "Categories are dropped — Silk blocks apps."
    /// The extras' count. Composes: "1 app" / "4 apps".
    public static func appsPicked(_ n: Int) -> String {
        "\(n) app\(n == 1 ? "" : "s")"
    }
    public static let done = "Done"
    public static let cancel = "Cancel"

    // Settings — editing the doors group after setup. The rows opened up
    // deliberately (they were statements only, once); the editor speaks the
    // same one-app language setup does.
    /// The editor's first action: run the one-app binding again. Plain words
    /// — "rebind" is internal vocabulary (DoorBinding), not a sentence.
    public static let rebind = "Change app"
    /// The editor's second action: the door leaves the policy and the wall.
    public static let remove = "Remove"
    /// The quiet row after the last door, and the add overlay's title.
    public static let addAnApp = "Add an app"
    /// The removal receipt's tail. Composes: "Reddit removed."
    public static let removed = "removed."
    /// The answer to a door asked for at the bar. A name is half a door; the
    /// app behind it comes from Apple's picker, which no sentence can raise —
    /// so the reply names the one place both are answered at once.
    public static let addInSettings = "Add it in Settings."
}
