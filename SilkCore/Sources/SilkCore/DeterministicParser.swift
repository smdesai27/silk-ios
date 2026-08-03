import Foundation

/// The deterministic grammar. Complete on its own: it must handle 100% of the
/// SPEND hot path and every canonical rule phrasing with no model present.
/// The on-device model (SilkModelParser, app target) is a widener for unseen
/// paraphrases of the rare rule intents — its output passes through the same
/// Validator, and this parser always runs first.
public enum DeterministicParser {

    public static func parse(_ utterance: String, state: PolicyState) -> ParseOutcome {
        let text = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .silence }
        let tokens = NumberParser.tokenize(text)
        guard !tokens.isEmpty else { return .silence }

        let door = firstDoor(in: tokens, state: state)
        let number = NumberParser.singleNumber(in: text)

        // 1. STATUS — a question about the balance, with no number and no door verb.
        if isStatusAsk(text, hasDoor: door != nil) { return .command(.status) }

        // 2. DOWN HOURS — must be checked before budget: both can carry a number.
        //    With a time it is a setter; without one it is a question, and the
        //    answer is the window as it stands ("Down hours run 10:00 PM to
        //    7:00 AM." — docs/design/handoff/README.md:244). "night" matches as
        //    a token, never a substring: "tonight" belongs to sentences about
        //    today ("no more instagram tonight"), not the window. Bare "night"
        //    stays a mention: the prototype's query triggers are down hours,
        //    bedtime, quiet (Silk Mockup.dc.html:333), and "night" alone
        //    appears in too many sentences that are not about the window.
        let windowMention = text.contains("down hour") || tokens.contains("night")
            || text.contains("bedtime") || text.contains("quiet")
        // The setter is about the window, and window sentences never name a
        // door or ask to be let in. Without those two guards, "give me 20
        // minutes of tiktok before bedtime" reads its 20 as 8 PM and a spend
        // request lands as a global tighten.
        if windowMention, door == nil, !hasOpeningVerb(text) {
            // One reading of the edge, used twice: the evening assumption and
            // the setter must never disagree about which edge this is, or a
            // stated 7 becomes 19:00 and then lands on the end.
            let edgeIsStart = isStart(text)
            if let t = NumberParser.timeOfDay(in: strip(text, of: "down hours"),
                                              assumeEvening: edgeIsStart) {
                return .command(edgeIsStart ? .setDownHoursStart(t) : .setDownHoursEnd(t))
            }
        }
        if text.contains("down hour") { return .command(.downHoursQuery) }
        if tokens.contains("night") { return .silence }
        if text.contains("bedtime") || text.contains("quiet"), door == nil {
            return .command(.downHoursQuery)
        }

        // 3. BUDGET — "make it thirty minutes a day", "thirty a day", "budget of 40".
        if text.contains(" a day") || text.contains("per day") || text.contains("daily") || text.contains("budget") {
            if let n = number { return .command(.setBudget(minutes: n)) }
            return .silence
        }

        // 4. CLOSING VERBS — "no more X today", "block X", "im done with X",
        //    "stop letting me open X", "close X". Lexical proposal only; the
        //    polarity that matters is recomputed by state diff in the Validator.
        //    A trailing "until 9" rides along as a stated hour; "everything" or
        //    "all" in the door slot closes every door at once.
        //    (docs/design/handoff/Silk Mockup.dc.html:327-331)
        if hasClosingVerb(text) {
            let until = restUntil(in: text)
            if let d = door {
                return .command(.closeDoorToday(door: d, until: until))
            }
            if tokens.contains("everything") || tokens.contains("all") {
                return .command(.closeAllToday(until: until))
            }
        }

        // 5. ADD / REMOVE a door. "add reddit" — the name is whatever follows,
        //    unless it carries a number: "add 30 minutes" is a budget ask in
        //    disguise, not a door called "30 minutes". Silence over minting.
        if tokens.first == "add", tokens.count >= 2 {
            let name = tokens.dropFirst().joined(separator: " ")
            if !NumberParser.allNumbers(in: name).isEmpty { return .silence }
            if let existing = state.door(named: name) {
                // Adding an existing door is a no-op ask; treat as silence.
                _ = existing
                return .silence
            }
            return .command(.addDoor(name: name))
        }
        if (tokens.first == "remove" || tokens.first == "drop"), let d = door {
            return .command(.removeDoor(door: d))
        }

        // 6. PLACE-BOUND SPEND — a door plus a place-phrase and no usable number.
        //    "give me instagram until i leave the gym" / "while im at the gym…"
        if let d = door, hasPlaceBinding(text), number == nil {
            return .command(.placeBoundAsk(door: d))
        }

        // 7. SPEND — the hot path. A door and exactly one number, with the door
        //    occupying a real slot (not an incidental mention). Window words
        //    make the number's meaning ambiguous — "keep instagram quiet until
        //    9" must not become a nine-minute grant — so those sentences defer
        //    to the model instead.
        if let d = door, let n = number, !windowMention {
            return .command(.spend(door: d, minutes: n))
        }

        // 8. ELLIPTICAL ASK — a door named with an opening verb and no duration.
        //    "give me instagram" is a real request missing one word, and the
        //    answer is that word: "How long?" Silence here read as not listening.
        //    (docs/design/handoff/Silk Mockup.dc.html:322)
        if let d = door, number == nil, hasOpeningVerb(text) {
            return .command(.placeBoundAsk(door: d))
        }

        return .silence
    }

    // MARK: - Recognizers

    private static func firstDoor(in tokens: [String], state: PolicyState) -> Door? {
        // Single-token names and aliases.
        for tok in tokens {
            if let d = state.door(named: tok) { return d }
        }
        // Two-token names ("focus friend" style), just in case.
        for i in 0..<max(0, tokens.count - 1) {
            if let d = state.door(named: tokens[i] + " " + tokens[i + 1]) { return d }
        }
        return nil
    }

    private static func hasClosingVerb(_ text: String) -> Bool {
        // Exactly two closer phrases embed an opener word, and only those may
        // outrank the opener veto: "stop letting me OPEN instagram" is a
        // close the veto must not see first. The rest stay behind the veto,
        // or "im done after this, give me ten of instagram" would close the
        // very door being asked for.
        let openerEmbeddedClosers = ["stop letting", "stop opening"]
        if openerEmbeddedClosers.contains(where: { text.contains($0) }) { return true }

        // Openers win: "unlock instagram" contains the substring "lock",
        // which is precisely the silent polarity flip the research warned
        // about. Token-boundary matching only; never bare substring for verbs.
        let tokens = Set(NumberParser.tokenize(text))
        let openerTokens: Set<String> = ["unlock", "open", "give", "let"]
        if !tokens.isDisjoint(with: openerTokens) { return false }

        let closerTokens: Set<String> = ["block", "close", "lock", "shut"]
        if !tokens.isDisjoint(with: closerTokens) { return true }

        // "no more THAN ten" is a quantifier on an ask, not a close; the word
        // boundary keeps "no more thanksgiving football" a close.
        let phraseText = text.replacingOccurrences(of: "no more than\\b", with: " ",
                                                   options: .regularExpression)
        let closerPhrases = [
            "no more", "im done", "i'm done", "done with", "cut off",
        ]
        return closerPhrases.contains { phraseText.contains($0) }
    }

    /// The stated hour of a close — whatever parses as a clock time after
    /// "until"/"till". Bare hours read as evenings ("until 9" is 9 PM): a close
    /// is a promise about the rest of today, and today's mornings are behind
    /// her. An explicit "9 am" still wins, exactly as it does for down hours.
    private static func restUntil(in text: String) -> TimeOfDay? {
        for marker in [" until ", " till ", " til "] {
            guard let r = text.range(of: marker) else { continue }
            return NumberParser.timeOfDay(in: String(text[r.upperBound...]), assumeEvening: true)
        }
        return nil
    }

    private static func hasPlaceBinding(_ text: String) -> Bool {
        let bindings = [
            "until i leave", "til i leave", "till i leave", "while im at", "while i'm at",
            "while im", "while i'm", "as long as im", "as long as i'm", "when im at", "when i'm at",
            "at the gym", "at work", "at the office",
        ]
        return bindings.contains { text.contains($0) }
    }

    /// Words that mean "let me in". Without one of these a bare door name is a
    /// mention, not a request, and silence is still the right answer.
    private static func hasOpeningVerb(_ text: String) -> Bool {
        ["give me", "open", "let me", "unlock", "i want", "can i"].contains { text.contains($0) }
    }

    private static func isStatusAsk(_ text: String, hasDoor: Bool) -> Bool {
        // The bare word is the design's first listed example, and "left today"
        // its fourth. (docs/design/handoff/Silk Mockup.dc.html:318) The word
        // matches as a token so "status?" and "check status" read too — but
        // only doorless: "block instagram and give me my status" must not
        // swallow the close into a balance readback.
        if !hasDoor, NumberParser.tokenize(text).contains("status") { return true }
        if text.contains("left today") { return true }
        guard text.contains("how many") || text.contains("how much") || text.contains("whats left")
            || text.contains("what's left") || text.contains("balance") else { return false }
        return true
    }

    /// Which edge of the window a stated time belongs to: "down hours start at
    /// ten" vs "…end at seven"/"…till seven".
    ///
    /// The markers match as whole words for the reason the closing verbs do —
    /// "end" lives inside "weekend", and the substring test heard "down hours
    /// start at 10 on weekends" as a 10 AM end, a twelve-hour night that lands
    /// instantly because a longer window tightens. Missing a marker costs the
    /// same in reverse: "till" was absent, so "down hours till 7" became a 7 PM
    /// start. Whole words are only safe if the set is complete, so every
    /// inflection the substring caught for free is spelled out; a dropped word
    /// hands the time to the wrong edge, and both directions of that mistake
    /// buy hours of lockdown under a reply that never mentions the window.
    private static func isStart(_ text: String) -> Bool {
        let tokens = NumberParser.tokenize(text)
        let startWords: Set<String> = ["start", "starts", "started", "starting"]
        let endWords: Set<String> = ["end", "ends", "ended", "ending",
                                     "finish", "finishes", "finished", "finishing",
                                     "until", "untill", "till", "til"]
        // The setter moves one edge and the reader takes one time — the first
        // one in the sentence — so the word that owns it is the last marker
        // BEFORE it, not the first in the sentence. "until further notice down
        // hours start at 11" opens with an end marker governing no hour, and
        // letting that win reads the 11 as a morning end: a thirteen-hour
        // night, instant, from a sentence whose only slot word said "start".
        let statedTime = tokens.firstIndex(where: readsAsHour) ?? tokens.endIndex
        guard let slot = tokens[..<statedTime].lastIndex(where: {
            startWords.contains($0) || endWords.contains($0)
        }) else { return true }
        return startWords.contains(tokens[slot])
    }

    /// Whether a token is one NumberParser would read as a clock hour. isStart
    /// asks the reader itself instead of restating its rules, because the two
    /// have to agree on which time is the stated one — disagree, and the marker
    /// chosen governs a different hour than the one that lands.
    private static func readsAsHour(_ token: String) -> Bool {
        NumberParser.timeOfDay(in: token, assumeEvening: false) != nil
    }

    private static func strip(_ text: String, of phrase: String) -> String {
        text.replacingOccurrences(of: phrase, with: " ")
    }
}
