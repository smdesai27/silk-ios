import Foundation

/// Hand-rolled spoken/typed number parsing for the 1–300 minute domain.
///
/// NEVER replace this with `NumberFormatter(.spellOut)`: measured on this
/// machine, it parses "twenty five" (space, as a transcript renders it) as
/// **2005** and "forty five" as 4005, silently. See docs/market/language-layer.md §4.
public enum NumberParser {

    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Every number expressible in the utterance, **in minutes**, in order of
    /// appearance. Used both for parsing and for the validator's provenance
    /// check: a grant whose minutes do not appear here was invented and must be
    /// refused.
    ///
    /// THE UNIT IS PART OF THE NUMBER. This function used to read a bare digit
    /// and stop, so "give me 2 hours of tiktok" put **2** in a domain whose
    /// every consumer means minutes: the grant was two minutes, the reply said
    /// "TikTok is open for 2 minutes.", and the sentence that asked for two
    /// hours was answered sixty times too small — silently wrong on the one
    /// axis this architecture promises never to be. It reached further than the
    /// grant: "set my budget to 2 hours" cut the whole day's allowance to two
    /// minutes, instantly, because tightening does not wait. Only the article
    /// idioms below ever worked, and only because they are spelled out here by
    /// hand.
    ///
    /// So an hours unit standing on a number multiplies it, and the same is
    /// true whether the unit is spelled out ("2 hours"), abbreviated ("2 hrs")
    /// or a single spaced letter ("2 h") — but NOT glued to the digits: "2h"
    /// is deliberately not read, and `hourUnits` states why. Every consumer
    /// keeps its contract unchanged: the domain was always minutes, and this
    /// is the reading that makes it so.
    ///
    /// The idiom table is untouched and still runs first — its quantities live
    /// in no token at all ("half an hour" is 30 with no digit anywhere), which
    /// is exactly why they had to be spelled out and why nothing below can see
    /// them.
    public static func allNumbers(in utterance: String) -> [Int] {
        let text = utterance.lowercased()
        var results: [Int] = []

        // Duration idioms first — their component words must not double-count.
        var consumed = text
        let idioms: [(pattern: String, value: Int)] = [
            ("an hour and a half", 90), ("hour and a half", 90),
            ("a quarter of an hour", 15), ("quarter of an hour", 15), ("quarter hour", 15),
            ("half an hour", 30), ("half hour", 30),
            ("an hour", 60), ("one hour", 60),
        ]
        // ONCE PER OCCURRENCE, NOT ONCE PER PATTERN. The scan appended one
        // value and then REPLACED every copy, so a sentence carrying the
        // same idiom twice read as one quantity — "capping tiktok at an
        // hour never lasted an hour" was ONE 60 to every caller, and the
        // two-quantity terminations that kill the digit twin ("cap tiktok
        // at 20 never lasted 20" dies on numbers.count == 1) never fired:
        // the duration-idiom decoy carried the anchor gate's own
        // determiner and parked a RAISE to 60 out of a complaint that the
        // cap never held (ROUND 7, n26). The digit and word paths below
        // already append per occurrence; the idioms now count the same
        // way, and the duplicate is visible to every count.
        for (pattern, value) in idioms {
            var occurrences = 0
            var search = consumed.startIndex
            while let r = consumed.range(of: pattern, range: search..<consumed.endIndex) {
                occurrences += 1
                search = r.upperBound
            }
            guard occurrences > 0 else { continue }
            results.append(contentsOf: repeatElement(value, count: occurrences))
            consumed = consumed.replacingOccurrences(of: pattern, with: " ")
        }

        // Digits, and the unit standing on them.
        //
        // GROUPED AT PUNCTUATION, because a unit binds to the number it stands
        // ON and a comma is not a space. `tokenize` erases punctuation, so
        // without this "give me tiktok for 20, hours of homework left" read its
        // 20 as twenty HOURS — a 1200-minute ask out of a sentence stating
        // twenty minutes and then changing the subject. Same shape on the pool
        // ("set my budget to 30, hundred things going on" set 3000) and on the
        // Validator, whose provenance check reads the whole utterance and so
        // disagreed with a grammar that reads one clause.
        //
        // Only the UNIT lookahead is bounded. Word compounding still crosses a
        // comma — "twenty, five minutes of tiktok" is 25 — because that is the
        // tokenizer's pinned contract and changing it is a deliberate decision
        // the fuzz campaign already declined to make.
        var tokens: [String] = []
        var opensGroup: [Bool] = []
        for (g, piece) in groups(of: consumed).enumerated() {
            for (t, token) in tokenize(String(piece)).enumerated() {
                tokens.append(token)
                opensGroup.append(g > 0 && t == 0)
            }
        }

        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if let digits = Int(tok) {
                if !hundredPoisons(i, tokens, opensGroup) {
                    results.append(scaled(digits, at: i, in: tokens, opensGroup))
                }
                tokens[i] = ""
            }
            i += 1
        }

        // Number words, combining "twenty five" / "twenty-five" → 25.
        i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if let t = tens[tok] {
                if i + 1 < tokens.count, let u = units[tokens[i + 1]] {
                    if !hundredPoisons(i + 1, tokens, opensGroup) {
                        results.append(scaled(t + u, at: i + 1, in: tokens, opensGroup))
                    }
                    i += 2
                    continue
                }
                if !hundredPoisons(i, tokens, opensGroup) {
                    results.append(scaled(t, at: i, in: tokens, opensGroup))
                }
            } else if let v = teens[tok] ?? units[tok] {
                if !hundredPoisons(i, tokens, opensGroup) {
                    results.append(scaled(v, at: i, in: tokens, opensGroup))
                }
            }
            i += 1
        }
        return results
    }

    /// The sentence cut at punctuation, keeping whitespace inside a piece.
    ///
    /// `tokenize` cannot answer this — it erases a comma and a space alike —
    /// and the unit reading needs the difference. Colons stay inside a piece so
    /// "10:30" survives, exactly as the tokenizer keeps it whole.
    ///
    /// THE HYPHEN IS A SPACE HERE, because it is a space to the tokenizer:
    /// `tokenize` rewrites "-" to " " before it splits, so the grammar's token
    /// stream for "2-hour" is identical to "2 hour" everywhere else in the
    /// file. When this predicate treated it as punctuation instead, the two
    /// spellings diverged in exactly one place — the unit lookahead refused to
    /// cross the group boundary the hyphen opened — and "give me a 2-hour
    /// break from tiktok" granted TWO MINUTES where the spaced spelling grants
    /// 120: the sixty-times-too-small class this file's header claims is
    /// killed, reachable through the one spelling a phone keyboard favours.
    /// The comma rationale ("a unit must not bind across ', hours of
    /// homework'") never applied to a character the tokenizer defines as
    /// whitespace — the "twenty-five" → 25 contract already depends on it.
    private static func groups(of text: String) -> [Substring] {
        text.split(whereSeparator: { c in
            !(c.isLetter || c.isNumber || c == ":" || c == " " || c == "\t" || c == "-")
        })
    }

    /// The units that stand on a number and change what it means. "m" and
    /// "min" are minutes and so are the identity; the hours are the sixty.
    ///
    /// GLUED SPELLINGS ARE DELIBERATELY NOT READ. "20min" and "2h" were split
    /// here for one round and taken back out: a glued duration is legible
    /// inside ordinary prose in a way a spaced one is not, so "give me tiktok,
    /// its 2h until dinner" became a two-hour ask — a sentence that states no
    /// duration for the door, answered with a grant that drains the pool. The
    /// spaced spellings carry the same meaning with none of that reach, and
    /// "20min of youtube" reaches the elliptical ask and is answered "How
    /// long?", which is a question the user can answer rather than a grant she
    /// cannot take back.
    private static let hourUnits: Set<String> = ["h", "hr", "hrs", "hour", "hours"]
    private static let minuteUnits: Set<String> = ["m", "min", "mins", "minute", "minutes"]

    /// The seconds units, read by the GUARDS and deliberately not by the
    /// reader. `allNumbers` scales hours because an hour is sixty of the
    /// domain's own unit; a second is a sixtieth of one, and no consumer of
    /// this file can hold a fraction of a minute — so "30 seconds of youtube"
    /// must not put 30 in a domain whose every consumer means minutes. That
    /// was the mirror of the "2 hours -> 2 minutes" class the header above
    /// records: a grant SIXTY TIMES the stated ask, in the loosening
    /// direction. The spend and cap paths decline a seconds unit the way
    /// `numberIsNotMinutes` declines hours, and silence reaches the widener.
    private static let secondUnits: Set<String> = ["second", "seconds", "sec", "secs"]

    /// The words a speaker puts BETWEEN a number and its hour word for
    /// emphasis, and nothing else. "give me 2 whole hours of tiktok" stated
    /// two hours as plainly as the unadorned spelling, and a lookahead of
    /// exactly one token read it as 2 — a two-minute grant out of a two-hour
    /// sentence, the sixty-times-too-small class this file exists to kill,
    /// and on the cap side a permanent two-minute ceiling ("cap tiktok at 2
    /// whole hours"). The list is a whitelist and stays one: each entry is an
    /// adjective that never carries a quantity of its own, so skipping it can
    /// only connect a number to the unit already standing on it, never invent
    /// one. It is consulted only when the very next token IS an hour word —
    /// "20 full of tiktok" reads nothing here.
    private static let hourIntensifiers: Set<String> = ["whole", "full", "entire"]

    /// `value` with the hours unit standing on it applied.
    ///
    /// `at` is the position of the LAST token the number occupies, which is why
    /// the compound arm passes `i + 1`: "twenty five hours" is 25 × 60, and
    /// looking one past the "twenty" would find "five" and no unit at all.
    ///
    /// Neither multiplier crosses a group boundary — see the comment in
    /// `allNumbers` for the sentence that cost. The intensifier walk is bounded
    /// the same way: "for 2 whole, hours later" scales nothing, because the
    /// comma opens a group between the intensifier and the unit.
    private static func scaled(_ value: Int, at i: Int, in tokens: [String],
                               _ opensGroup: [Bool]) -> Int {
        // At most two tokens past the number — an optional intensifier and the
        // unit — and never past a group boundary.
        var end = i + 1
        while end < tokens.count, end <= i + 2, !opensGroup[end] { end += 1 }
        if statesAnHour(following: tokens[(i + 1)..<end]) { return saturating(value, times: 60) }
        return value
    }

    /// **A HUNDRED IS REFUSED, NOT READ**, and the refusal is the reading.
    ///
    /// "one hundred minutes of reddit" used to grant ONE — the tens/units
    /// tables have no hundred in them, so the leading word won and the rest of
    /// the number was dropped. Reading it properly was tried and cost more than
    /// it bought, three separate ways, because the quantity a "hundred" phrase
    /// states occupies NO SINGLE TOKEN:
    ///
    ///   - `capSet` finds its number with a per-token scan, so it went blind to
    ///     "keep tiktok under a hundred minutes" and rule 7 took the sentence —
    ///     a GRANT out of a restriction, which is the exact defect the cap
    ///     feature exists to kill. The digit spelling of the same sentence sets
    ///     a ceiling.
    ///   - `numberIsNotMinutes` looks one token past the number, and "hundred"
    ///     standing there hid the hours unit behind it, so "cap tiktok at two
    ///     hundred hours" wrote a ceiling instead of declining.
    ///   - `numberClauseNamesADoor` is per-token too, and went blind the same
    ///     way.
    ///
    /// Each is repairable and none of the repairs is small: they are position
    /// tests in a grammar that has been wrong about positions before. So the
    /// word poisons the phrase instead. A number standing next to "hundred"
    /// yields nothing at all, which makes "give me one hundred minutes of
    /// reddit" reach the elliptical ask and be answered "How long?" — a
    /// question the user can answer, where the old reading granted one minute
    /// and the new one granted a hundred out of "a hundred percent".
    ///
    /// People type "100". This costs the spelled-out form and keeps every
    /// position test in the grammar honest.
    private static func hundredPoisons(_ i: Int, _ tokens: [String], _ opensGroup: [Bool]) -> Bool {
        let next = i + 1
        if next < tokens.count, !opensGroup[next], tokens[next] == "hundred" { return true }
        return i > 0 && !opensGroup[i] && tokens[i - 1] == "hundred"
    }

    /// Multiplication that saturates rather than trapping.
    ///
    /// THE PARSER MAY NOT CRASH ON A SENTENCE, and a plain `*` here does:
    /// "give me 999999999999999999 hours of tiktok" is nineteen digits inside
    /// `Int`, and sixty times it is not. Swift traps on overflow, so the
    /// multiplier this file added turned a merely absurd sentence into a
    /// SIGTRAP in the bar — caught by attacking the change, not by the suite,
    /// because `everyStringCompilesOrFallsSilentAndNeverTraps` fuzzes shapes
    /// rather than magnitudes.
    ///
    /// `Int.max` and not a refusal, because it is the reading that keeps the
    /// behaviour it already had: an absurd number of MINUTES has always parsed
    /// and then been clamped to the balance by the Validator, and an absurd
    /// number of hours is the same sentence with a unit on it. It clamps
    /// identically, and provenance still holds — the Validator asks this same
    /// function and gets the same `Int.max` back.
    private static func saturating(_ value: Int, times factor: Int) -> Int {
        let (product, overflowed) = value.multipliedReportingOverflow(by: factor)
        return overflowed ? Int.max : product
    }

    /// Whether an hours unit stands on a number whose following tokens are
    /// `following` — "2 hours", "2 hrs", "2 h", and through one intensifier,
    /// "2 whole hours". The caller passes AT MOST the two tokens its own
    /// bounds admit (a clause for the guard, a group for the reader), so the
    /// walk can never reach past a boundary the caller respects.
    ///
    /// `internal` so the grammar's cap guard can ask the same question this
    /// file answers when it reads the number. It used to keep its own list, and
    /// a reader and its guard that disagree about one token make the guard
    /// decoration: `allNumbers` learned the spaced "2 h" and the guard's
    /// inline set had not, so the one spelling it could not read was the one
    /// that wrote a two-hour ceiling. (The glued "2h" is a different story:
    /// deliberately read by NEITHER side — see `hourUnits`.) Taking the
    /// following tokens rather than one keeps the pair agreeing about the
    /// intensifiers too, or "cap tiktok at 2 whole hours" would be 120 to the
    /// reader and invisible to the guard — a two-hour ceiling written in the
    /// vocabulary the guard exists to decline.
    static func statesAnHour(following: ArraySlice<String>) -> Bool {
        var it = following.makeIterator()
        guard var word = it.next() else { return false }
        if hourIntensifiers.contains(word) {
            guard let unit = it.next() else { return false }
            word = unit
        }
        return hourUnits.contains(word)
    }

    /// Whether a seconds unit stands on a number whose following tokens are
    /// `following` — "30 seconds", "30 secs", and through one intensifier,
    /// "30 whole seconds". The same shape as `statesAnHour` and answered here
    /// for the same reason: a guard that reads a unit differently from the
    /// file that owns the unit lexicon is a guard with a hole in it.
    static func statesSeconds(following: ArraySlice<String>) -> Bool {
        var it = following.makeIterator()
        guard var word = it.next() else { return false }
        if hourIntensifiers.contains(word) {
            guard let unit = it.next() else { return false }
            word = unit
        }
        return secondUnits.contains(word)
    }

    /// The single number an utterance carries, or nil when there are zero or
    /// several. Two numbers is ambiguity, and compilers don't guess.
    public static func singleNumber(in utterance: String) -> Int? {
        let all = allNumbers(in: utterance)
        return all.count == 1 ? all.first : nil
    }

    /// A stated clock time, and whether the sentence said which half of the day
    /// it meant.
    ///
    /// The flag has to be carried rather than recovered. Reading the same text
    /// twice with opposite assumptions looks like it would reveal it — a bare
    /// hour would answer differently, an explicit one the same — but the two
    /// readings also coincide at 12, at 0, and above 12, because the evening
    /// assumption only bumps an hour when it is under 12. "till 12" is the most
    /// ambiguous sentence there is and that test calls it explicit.
    public struct StatedTime: Equatable, Sendable {
        public let time: TimeOfDay
        public let meridiemWasStated: Bool
    }

    /// Parse a clock time: "10", "10:30", "ten", "5 pm", "10 p.m.", "11pm".
    /// Bare hours ≤ 12 are ambiguous; the caller resolves am/pm from context
    /// (a down-hours *start* is an evening, an *end* is a morning).
    public static func timeOfDay(in utterance: String, assumeEvening: Bool) -> TimeOfDay? {
        statedTime(in: utterance, assumeEvening: assumeEvening)?.time
    }

    /// The same reading, with the provenance of the am/pm attached. The flag
    /// belongs to the hour that was matched, not to the sentence: "i am up till
    /// 11" carries an "am" token that has nothing to do with the 11, and a
    /// scan of the whole string would call that hour explicit and wave the
    /// guess through.
    public static func statedTime(in utterance: String, assumeEvening: Bool) -> StatedTime? {
        scanStatedTimes(in: utterance, assumeEvening: assumeEvening, stopAtFirst: true).first
    }

    /// EVERY clock the sentence states, in order.
    ///
    /// `statedTime` answers with the FIRST, which is the right answer for a
    /// grammar that reads one edge at a time — and the wrong domain for a
    /// provenance check. "lock me out from 10pm to 7am" states two hours, and a
    /// widened `setDownHoursEnd(07:00)` is a correct reading of it; asking only
    /// for the first clock silenced it because 22:00 is not 07:00. The question
    /// provenance actually asks is "did the user say this hour", and that is
    /// membership, not identity with the first.
    public static func statedTimes(in utterance: String, assumeEvening: Bool) -> [TimeOfDay] {
        scanStatedTimes(in: utterance, assumeEvening: assumeEvening, stopAtFirst: false)
            .map(\.time)
    }

    /// Every clock the sentence states, WITH each hour's own am/pm provenance.
    ///
    /// `statedTimes` answers the membership question and deliberately drops the
    /// flags; the Validator's am/pm guard then re-fetched the flag from
    /// `statedTime` — the sentence's FIRST clock — and read the wrong hour's
    /// provenance: "lock me out from 10pm to 10" matched its bare trailing 10
    /// for membership and then took the explicit 10pm's flag, so the question
    /// the guard exists to ask ("10am or 10pm?") was never asked and a
    /// twelve-hour night landed instantly. The doc on `statedTime` already
    /// states the rule — the flag belongs to the hour that was matched, not to
    /// the sentence — and this is the reading that lets a caller honor it.
    public static func statedTimesDetailed(in utterance: String,
                                           assumeEvening: Bool) -> [StatedTime] {
        scanStatedTimes(in: utterance, assumeEvening: assumeEvening, stopAtFirst: false)
    }

    /// One pass over one tokenization, for both readers above.
    ///
    /// THE ALL-CLOCKS READER MUST TOKENIZE THE SENTENCE ONCE. Its first
    /// version re-ran `statedTime` on the string with one leading token
    /// dropped per iteration — each call re-tokenizing everything that
    /// remained — so a clock near the END of a long utterance cost O(n²)
    /// tokenizations and returned thousands of duplicate entries. That is not
    /// a widener-only path: rule 2 compiles "…night should start at 10" out
    /// of any prose that mentions the night, and the Validator's provenance
    /// guard then asked this question of the WHOLE utterance — three thousand
    /// words of ordinary text ending in that clause hung validation for
    /// seconds, quadratically worse as the text grows, on hardware slower
    /// than the machine that measured it. The parser's own huge-input bounds
    /// never saw it because they stop at `parse`;
    /// `aHugeUtteranceValidatesInOnePass` now bounds this side too.
    private static func scanStatedTimes(in utterance: String, assumeEvening: Bool,
                                        stopAtFirst: Bool) -> [StatedTime] {
        let text = utterance.lowercased()
            .replacingOccurrences(of: "p.m.", with: "pm")
            .replacingOccurrences(of: "a.m.", with: "am")
        let tokens = tokenize(text)
        var found: [StatedTime] = []

        for (i, tok) in tokens.enumerated() {
            // "11pm" arrives as one token — the tokenizer splits on characters
            // that are neither alphanumeric nor ":", and there is nothing
            // between the digits and the suffix to split on. Peel it off so the
            // spaced and unspaced spellings read alike. This is not a nicety:
            // Silk asks "11am or 11pm?" when an hour is ambiguous, and an
            // answer typed the way the question was written has to parse.
            let (body, glued) = splitMeridiem(tok)
            var hour: Int?
            var minute = 0
            if body.contains(":") {
                let parts = body.split(separator: ":")
                if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h <= 24, m < 60 {
                    hour = h
                    minute = m
                }
            } else if let h = Int(body), (0...24).contains(h) {
                hour = h
            } else if let h = teens[body] ?? units[body], h <= 12 {
                hour = h
            }
            guard var h = hour else { continue }

            let next = glued ?? (i + 1 < tokens.count ? tokens[i + 1] : "")
            var stated = true
            if next == "pm" { h = h % 12 + 12 } else if next == "am" {
                h = h % 12
            } else {
                // Nothing said which half of the day. Hours above 12 say it
                // themselves — "23" cannot be a morning — and so does a 0: an
                // hour that states its own half is never the evening guess's
                // to move, or "until 0" lands at noon instead of midnight.
                stated = h > 12 || h == 0
                if !stated, assumeEvening, h < 12 {
                    // "down hours start at ten" — an evening reading.
                    h += 12
                }
            }
            found.append(StatedTime(time: TimeOfDay(hour: h % 24, minute: minute),
                                    meridiemWasStated: stated))
            if stopAtFirst { return found }
        }
        return found
    }

    /// A token's clock body and its glued-on meridiem, if it carries one:
    /// "11pm" → ("11", "pm"), "11" → ("11", nil), "spam" → ("spam", nil).
    /// Only splits when what precedes the suffix is itself a clock body, so
    /// ordinary words ending in those two letters are left whole.
    private static func splitMeridiem(_ token: String) -> (String, String?) {
        guard token.count > 2 else { return (token, nil) }
        let suffix = String(token.suffix(2))
        guard suffix == "am" || suffix == "pm" else { return (token, nil) }
        let body = String(token.dropLast(2))
        guard body.allSatisfy({ $0.isNumber || $0 == ":" }) else { return (token, nil) }
        return (body, suffix)
    }

    /// The separator set, built once.
    ///
    /// It used to be a union and an inversion of two Unicode sets, constructed
    /// inside `tokenize` — and `tokenize` runs several times over the same
    /// sentence on the hot path (`allNumbers` alone tokenizes an idiom-stripped
    /// copy, `statedTime` a meridiem-rewritten one, the parser the trimmed one,
    /// and every clause guard re-asks it a token at a time). Building the set
    /// per call was measured at the majority of a short sentence's parse. It is
    /// the same set; it is now computed once.
    private static let separators: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":")).inverted

    static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "-", with: " ")
        guard lowered.contains(where: { apostrophes.contains($0) }) else {
            return lowered.components(separatedBy: separators).filter { !$0.isEmpty }
        }
        return foldingApostrophes(lowered).components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// The four spellings of one mark. iOS smart punctuation types U+2019 by
    /// default, so the "exotic" one is the ordinary one.
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "\u{FF07}"]

    /// AN APOSTROPHE SPLITS, WITH ONE EXCEPTION, AND THE EXCEPTION IS THE WHOLE
    /// POINT.
    ///
    /// Splitting on every apostrophe — the original — cut "don't" into
    /// ["don", "t"], which matches nothing. So every apostrophe entry in
    /// `negators`, `auxiliaries` and `modals` was unreachable, and "don't cap
    /// tiktok at 20" wrote the ceiling it refuses while "dont cap tiktok at 20"
    /// correctly fell silent. iOS smart punctuation types U+2019 by default, so
    /// the broken spelling was the ordinary one.
    ///
    /// The fix is exactly as wide as the defect: **"'t" joins, everything else
    /// still splits.** The negator family is the entire set of lexemes the
    /// grammar spells without the mark — dont, cant, wont, isnt, doesnt, arent,
    /// hasnt, havent, couldnt, shouldnt, wouldnt, mustnt, didnt, wasnt, werent,
    /// hadnt, aint — and joining "'t" is what makes all of them reachable.
    ///
    /// A wider rule was tried and taken back out, and the reason is worth
    /// keeping. Deleting EVERY apostrophe, or folding a word-final "'s" to its
    /// base, each fixed the negators and then broke a different word: a clitic
    /// glued to a door name erased the door ("tiktok'll be capped at 20 a day"
    /// lost TikTok, and rule 3 then cut the SHARED budget for every app), and
    /// folding "'s" ate the contracted copula that the report gate reads ("the
    /// tiktok cap's 20 a day" is a statement of fact and compiled to a ceiling).
    /// Splitting leaves "tiktok'll" as ["tiktok", "ll"] and "cap's" as
    /// ["cap", "s"] — the door still names itself, the copula still marks the
    /// clause, and the orphaned clitic matches nothing, which is the harmless
    /// direction. A possessive door name needs nothing special either: "hinge's"
    /// is ["hinge", "s"] and "hinge" is the door.
    ///
    /// "1'20" also keeps splitting into two numbers, which is what it is.
    private static func foldingApostrophes(_ text: String) -> String {
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            guard apostrophes.contains(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            let before: Character = i > 0 ? chars[i - 1] : " "
            let after: Character = i + 1 < chars.count ? chars[i + 1] : " "
            let beyond: Character = i + 2 < chars.count ? chars[i + 2] : " "
            if before.isLetter, after == "t", !beyond.isLetter, !beyond.isNumber {
                i += 1                      // "'t" joins: don't -> dont
            } else {
                out.append(" ")             // everything else is a boundary
                i += 1
            }
        }
        return out
    }
}

// MARK: - Clause structure

extension NumberParser {

    /// Which clause each token belongs to, for rules that need to know whether
    /// two words are in the same breath.
    ///
    /// `tokenize` erases punctuation — it splits on everything that is not
    /// alphanumeric or ":", so a comma, a semicolon and a full stop all vanish
    /// before any rule sees the sentence:
    ///
    ///     "drop tiktok, im at my limit"  →  [drop, tiktok, im, at, my, limit]
    ///
    /// Every rule downstream therefore reasons about the DISTANCE between
    /// tokens across a boundary it cannot see, and "four tokens away" means one
    /// thing inside a clause and nothing at all across a comma. That is not a
    /// hypothetical: the per-app cap grammar failed three adversarial rounds on
    /// it, twice shipping a fully green suite over a parser that read a
    /// tightening sentence as a loosening, because the only structure available
    /// to a rule was counting. This type is the structure that was missing.
    ///
    /// It carries its own `tokens` rather than taking them from the caller, and
    /// that is the whole safety argument. Callers preprocess before tokenizing —
    /// `allNumbers` strips duration idioms out of the text first, `statedTime`
    /// rewrites "p.m." to "pm", `DeterministicParser` lowercases and trims —
    /// and a clause list built from one string against a token list built from
    /// another is misaligned in exactly the silent way this file has been wrong
    /// before. A rule must index into `index.tokens`, never into a separately
    /// tokenized array, and the type gives it nowhere else to look.
    ///
    /// Nothing in the parser builds one yet. It is O(n) and lazy by absence: a
    /// sentence that never asks a clause question never pays for the answer,
    /// which is what keeps `hugeInputStaysCheapAndSilent` honest.
    struct ClauseIndex {

        /// Exactly `tokenize(utterance)`, and the array the indices below refer
        /// to. Equal by construction: the clauses are cut only at characters
        /// `tokenize` already treats as separators, and each piece is handed to
        /// `tokenize` itself — the tokens are never re-derived here. Proved
        /// rather than asserted: `clausesAlignWithTokens` walks every string in
        /// the test corpus.
        let tokens: [String]

        /// One clause id per token, dense from 0. Deliberately private: the only
        /// legitimate question is whether two tokens share a clause, and an
        /// exposed id invites the arithmetic that caused the bug — "two clauses
        /// apart" is not a smaller version of "same clause", it is the same
        /// counting mistake one level up.
        private let ids: [Int]

        /// Token ranges, one per clause, in order. Contiguous and covering:
        /// `bounds` partitions `0..<tokens.count` with no gaps, which is the
        /// alignment contract stated as something a test can walk.
        private let bounds: [Range<Int>]

        /// How many clauses the utterance has. 0 for an utterance with no
        /// tokens at all; 1 for a sentence with no separator in it.
        var clauseCount: Int { bounds.count }

        init(_ utterance: String) {
            var tokens: [String] = []
            var ids: [Int] = []
            var bounds: [Range<Int>] = []
            var clause = 0
            var clauseStart = 0
            // Set by a separator, cleared by the next token that actually
            // lands. A separator does not open a clause — a TOKEN does. That is
            // what keeps "wait,, what" and a trailing "tiktok 20 a day." from
            // minting empty clauses that would shift every id after them.
            var pendingBreak = false

            for piece in ClauseIndex.split(utterance) {
                for token in NumberParser.tokenize(String(piece)) {
                    let opensClause = pendingBreak || ClauseIndex.clauseOpeners.contains(token)
                    if opensClause, !tokens.isEmpty {
                        bounds.append(clauseStart..<tokens.count)
                        clauseStart = tokens.count
                        clause += 1
                    }
                    pendingBreak = false
                    tokens.append(token)
                    ids.append(clause)
                }
                // The gap to the next piece is a separator that was consumed.
                // (Set after the last piece too, where nothing reads it.)
                pendingBreak = true
            }
            if !tokens.isEmpty { bounds.append(clauseStart..<tokens.count) }

            self.tokens = tokens
            self.ids = ids
            self.bounds = bounds
        }

        /// Whether two token positions fall in the same clause.
        ///
        /// Total on purpose: an out-of-range index answers "no" instead of
        /// trapping. A rule that miscounts should decline to connect two words,
        /// which costs a silence and defers to the model; a crash in the parser
        /// costs the user her sentence.
        ///
        /// The totality has a cost, and it is the one thing to be careful of
        /// here: an IN-range position from the wrong tokenization gets a
        /// confident answer about the wrong two words rather than a trap. The
        /// parser has several differently preprocessed strings in flight —
        /// `allNumbers` tokenizes an idiom-stripped copy, so "cap tiktok at an
        /// hour and a half" is 8 tokens to this index and 3 to that pass — and a
        /// position carried across from one of them lands somewhere real and
        /// wrong. Positions passed here must come from `tokens` on THIS index.
        func sameClause(_ a: Int, _ b: Int) -> Bool {
            guard tokens.indices.contains(a), tokens.indices.contains(b) else { return false }
            return ids[a] == ids[b]
        }

        /// The token range of the clause holding `i`, so a rule can scan the
        /// words around a door without walking out of its breath. nil when `i`
        /// is not a token position.
        ///
        /// This exists so that "look for the cap word near the door" can be
        /// written as a bounded scan rather than as a distance threshold. The
        /// distance thresholds are what failed.
        func clauseRange(containing i: Int) -> Range<Int>? {
            guard tokens.indices.contains(i) else { return nil }
            return bounds[ids[i]]
        }

        // MARK: Separators

        /// Words that begin a new clause where they stand, keeping the word.
        ///
        /// A word separator cannot break alignment the way a character one
        /// could — it removes no token, it only moves the id boundary — so the
        /// question for each is purely whether it opens a new predicate often
        /// enough to be worth the times it does not.
        ///
        /// All four cost recall, and the cost is stated here rather than argued
        /// away, because an earlier draft of this comment called the wrong
        /// readings "inert" and they are not. What makes them acceptable is the
        /// DIRECTION of the error. A word that opens a clause it should not have
        /// opened strands a number from its verb, and a rule that cannot find a
        /// number declines — a silence, which defers to the model and which the
        /// user can repair by saying it again. The opposite error, two commands
        /// read as one breath, is what turned a tightening into a loosening
        /// twice. Over-splitting is the recoverable direction; every entry here
        /// is admitted on that ground and none on the ground that it is free.
        ///
        /// - "but": the plain adversative, and the only one of the four with no
        ///   competing sense in this lexicon. "cap tiktok at 20 but give me
        ///   instagram" is two commands. It costs the quantifier sense: "give me
        ///   nothing but 20 of tiktok" and "i have but 20 minutes" both break at
        ///   it, the first harmlessly (door and number stay together on the
        ///   right), the second into a clause with no door in it.
        /// - "so": a purpose clause — "block tiktok so i stop scrolling". This
        ///   one is admitted for what it PREVENTS, not for what it reads: a
        ///   purpose clause routinely carries a quantity of its own ("block
        ///   instagram so i can get 8 hours"), and glued to the command that
        ///   quantity is a number sitting next to a door, which is a cap out of
        ///   thin air. It costs the intensifier and degree senses — "im so over
        ///   tiktok, block it" makes three clauses, and "cap tiktok so i only
        ///   get 20 a day" puts the door in one clause and its number in the
        ///   next, which reads as a silence. That is the trade: a silence on a
        ///   sentence a user can repeat, against an invented cap she cannot see.
        /// - "anyway" and "though": discourse markers that trail a clause more
        ///   often than they open one, which is precisely why they are safe. A
        ///   trailing one ("block tiktok though") makes a one-word clause
        ///   holding no door and no number, which no rule can match; a leading
        ///   one ("anyway give me 20", typed without the comma it would carry in
        ///   print) is a fresh command that would otherwise be glued to the
        ///   previous sentence.
        ///
        /// NOT here, and for the first two the corpus itself is the argument:
        /// - "and" — phrasal far more often than clausal here, and it lives
        ///   inside a number: splitting "an hour and a half" cuts a single
        ///   quantity in two, and `allNumbers` reads that idiom as 90. "down
        ///   hours start at 10 and end at 7" loses by the exclusion, and that
        ///   is the right trade.
        /// - "or" — "ten or twenty minutes", "11am or 11pm?", both corpus
        ///   strings, both phrasal.
        /// - "then" — as often temporal inside a clause ("and then some",
        ///   "until then") as it is a clause opener, and no sentence in the
        ///   corpus needs it to break.
        private static let clauseOpeners: Set<String> = ["but", "so", "anyway", "though"]

        /// Characters that end a clause wherever they stand, asking nothing
        /// about their neighbours. Held as SCALARS, not as `Character`s, and
        /// that is load-bearing twice over.
        ///
        /// Once for correctness: a `Character` is an extended grapheme cluster,
        /// and "\r\n" is ONE of them, equal to neither Character("\r") nor
        /// Character("\n"). A switch written over characters therefore misses
        /// every CRLF — which is what a paste from Windows, from most mail
        /// clients and from many iOS text fields produces — and hands two typed
        /// lines to the rules as one breath. A per-character test loop cannot
        /// see that, because it never forms the pair.
        ///
        /// Once for alignment: `tokenize` splits on SCALARS, so scalars are the
        /// unit this has to agree with. The line-break family below is the whole
        /// of it — LF, VT, FF, CR, NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR —
        /// listed out rather than reached through a predicate so that each one
        /// is a thing a test can name.
        private static let unconditionalSeparators: Set<Unicode.Scalar> = [
            ",", ";", "!", "?",
            "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}",
            "\u{0085}", "\u{2028}", "\u{2029}",
        ]

        /// Cut the raw text at clause-separating characters, dropping the
        /// separator. Every character below is one `tokenize` already treats as
        /// a delimiter, which is what makes the pieces' tokens add up to exactly
        /// `tokenize(whole)`: splitting on a subset of the delimiters and then
        /// splitting each piece on all of them is the same partition, once the
        /// empty pieces are filtered — which `tokenize` does.
        ///
        /// That argument is about scalars, and a cluster can hold more than one,
        /// so a cluster is cut only when EVERY scalar in it is a separator. It
        /// is not pedantry: "!" followed by a combining acute is one cluster
        /// whose second scalar is a Unicode mark, and marks are in
        /// `CharacterSet.alphanumerics` — the tokenizer keeps that mark as a
        /// token. Cutting the cluster would drop a token the tokenizer kept, and
        /// the alignment contract would be broken by a stray diacritic.
        ///
        /// The unconditional set is , ; ! ? and the line breaks. The full stop
        /// and the dashes are admitted CONDITIONALLY, because English spells
        /// both of them inside quantities as well as between clauses. Each of
        /// the following is not admitted at all:
        ///
        /// - ":" is a CLOCK. `tokenize` keeps it as a token character precisely
        ///   so "10:30" survives whole, so splitting on it would hand back two
        ///   tokens where the tokenizer hands back one — the alignment contract
        ///   broken by the very first time someone says a time. It is on
        ///   everyone's list of sentence punctuation and it cannot be on this
        ///   one.
        /// - "'" is a POSSESSIVE. "tiktok's" already arrives as two tokens; if
        ///   the apostrophe also split clauses, every possessive and every
        ///   contraction would be a sentence boundary.
        /// - "/" and brackets separate items, not clauses.
        private static func split(_ text: String) -> [Substring] {
            var pieces: [Substring] = []
            var start = text.startIndex
            var i = text.startIndex
            var prev: Character?
            var prevPrev: Character?
            // Length of the run of letters and digits ending just before `i`.
            // Only the full stop consults it, and only to decide a break — it
            // never decides a token, so approximating the tokenizer's
            // alphanumeric set with `isLetter || isNumber` is free of
            // consequence here.
            var alnumRun = 0
            // The word standing to the left of `i`, for the dashes: the run in
            // progress if one is, otherwise the last completed run provided only
            // whitespace has passed since. Tracked as we go rather than scanned
            // backwards so the cost stays O(1) per character — the cost test
            // pins that this whole pass is linear.
            var currentWord = ""
            var lastWord = ""
            var onlyWhitespaceSinceWord = false

            while i < text.endIndex {
                let c = text[i]
                let after = text.index(after: i)
                let next: Character? = after < text.endIndex ? text[after] : nil
                let wordBefore = currentWord.isEmpty
                    ? (onlyWhitespaceSinceWord ? lastWord : "")
                    : currentWord
                if isSeparator(c, in: text, after: after,
                               prev: prev, prevPrev: prevPrev, next: next,
                               alnumRunBefore: alnumRun, wordBefore: wordBefore) {
                    pieces.append(text[start..<i])
                    start = after
                }
                if c.isLetter || c.isNumber || c == ":" {
                    currentWord.append(c)
                } else {
                    if !currentWord.isEmpty {
                        lastWord = currentWord
                        currentWord = ""
                        onlyWhitespaceSinceWord = true
                    }
                    if !c.isWhitespace { onlyWhitespaceSinceWord = false }
                }
                alnumRun = (c.isLetter || c.isNumber) ? alnumRun + 1 : 0
                prevPrev = prev
                prev = c
                i = after
            }
            pieces.append(text[start...])
            return pieces
        }

        /// The word standing to the right of a candidate separator, skipping the
        /// whitespace between. Bounded by the run it reads and by the gap it
        /// skips, and those are disjoint between candidates, so the whole pass
        /// stays linear.
        private static func wordAfter(_ text: String, from index: String.Index) -> String {
            var i = index
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            var word = ""
            while i < text.endIndex {
                let c = text[i]
                guard c.isLetter || c.isNumber || c == ":" else { break }
                word.append(c)
                i = text.index(after: i)
            }
            return word
        }

        /// Whether a word is a QUANTITY rather than a predicate — a count, a
        /// clock, or the meridiem that finishes one.
        ///
        /// Only the dashes ask, and they ask because a dash between two
        /// quantities is a RANGE, not a clause break. This is not a guess about
        /// English in general: it is what this product itself writes. The
        /// aperture's one line is "☾  10:00 PM – 7:00 AM", the settings row
        /// composes "\(start.display)–\(end.display)", and the doc comments
        /// spell the domain "1–300 minute" and "3–6 named doors". A dash with a
        /// clock on each side is the down-hours window, and cutting it hands a
        /// rule a start with no end — the same "splitting cuts a single quantity
        /// in two" failure that keeps "and" out of `clauseOpeners`, committed
        /// against the character English reserves for ranges.
        private static func isQuantity(_ word: String) -> Bool {
            guard let first = word.first else { return false }
            // Anything opening with a digit: "20", "10:00", "7am", "450ms".
            if first.isNumber { return true }
            let w = word.lowercased()
            // The meridiem is half of a clock and stands as its own word.
            if w == "am" || w == "pm" { return true }
            return NumberParser.units[w] != nil
                || NumberParser.teens[w] != nil
                || NumberParser.tens[w] != nil
        }

        private static func isSeparator(_ c: Character, in text: String, after: String.Index,
                                        prev: Character?, prevPrev: Character?, next: Character?,
                                        alnumRunBefore: Int, wordBefore: String) -> Bool {
            // Decided over the cluster's scalars, and over ALL of them — see the
            // note on `split` for the diacritic that makes "all" the operative
            // word, and on `unconditionalSeparators` for the CRLF that makes
            // "scalars" it.
            if c.unicodeScalars.allSatisfy({ unconditionalSeparators.contains($0) }) { return true }

            switch c {
            case ".":
                // A full stop is the separator English also spells inside a
                // number and inside a word, so it looks around before it fires.

                // Next to another dot it is an ellipsis, and in a typed bar an
                // ellipsis is a hesitation inside one thought rather than the
                // end of one. "tiktok... 20?" is a single ask; breaking it puts
                // the door and its number in different breaths, which is the
                // exact failure this type exists to prevent. Checked on both
                // sides, or the last dot of the three fires on its own.
                if prev == "." || prev == "\u{2026}" { return false }
                if next == "." || next == "\u{2026}" { return false }

                // A DOTTED ABBREVIATION's dot, not a stop — "p.m.", "a.m.",
                // "e.g.". Both halves of that shape are required, and requiring
                // them is the fix for a real defect: this test used to read
                // `alnumRunBefore == 1` alone, and a run of one is also every
                // single digit and every one-letter word. "cap tiktok at 5. no
                // cap on instagram" came back as ONE clause holding a cap, a
                // number, a second door and a cap removal — a tightening and a
                // loosening in one breath, which is verbatim the confusion that
                // cost the cap grammar three rounds. "block x. give me 20 of
                // instagram" did the same, and X is a real door.
                //
                // So the run must be a LETTER (a lone digit is never an
                // abbreviation), and the dot must be one of the two dots that
                // shape actually has: the INTERNAL one, whose next character is
                // alphanumeric with no space ("p." of "p.m"), or the CLOSING
                // one, whose single letter was itself opened by a dot ("m." of
                // "p.m."). Everything else is a stop.
                //
                // WHAT THIS STILL COSTS, named because a rule author will build
                // on it: the closing dot of an abbreviation is suppressed even
                // when it is ALSO ending the sentence, so "shut youtube until 9
                // p.m. give me tiktok back" is one clause holding a close verb,
                // a door, an hour and a second command. Punctuation cannot tell
                // that from "shut youtube until 9 p.m. today", which is one
                // command and which `anAbbreviationDotIsNotAClauseBreak` pins as
                // one clause. Both readings are pinned in the tests, this one as
                // a known hole, so the shape is inherited announced rather than
                // discovered. A clause here may hold more than one predicate,
                // and the cap and down-hours rules must not assume otherwise.
                // The fix, if one is wanted, is to break after an abbreviation
                // when what follows opens a fresh predicate — which needs a verb
                // lexicon, and a verb lexicon belongs in a rule, not in the
                // primitive the rules are supposed to be able to trust.
                if alnumRunBefore == 1, let p = prev, p.isLetter {
                    if let n = next, n.isLetter || n.isNumber { return false }
                    if prevPrev == "." { return false }
                }

                // Digits on both sides is a decimal point or a British clock:
                // "1.5", "2.30" and "10.30" all reach this line and all need it
                // — the abbreviation rule above deliberately no longer covers
                // them, since it now insists on a letter. Digits and not
                // alphanumerics, deliberately — widened to letters it swallows
                // the missing space in "block tiktok.give me instagram", which
                // is a real typed sentence and really is two commands.
                if let p = prev, p.isNumber, let n = next, n.isNumber { return false }

                return true

            case "\u{2014}", "\u{2013}", "-":
                // The dashes. A dash between two quantities is a range and must
                // not break — see `isQuantity` for why this product's own
                // writing settles that.

                // The hyphen is admitted only with whitespace on BOTH sides,
                // which is how a phone keyboard spells a clause dash. Without
                // the spaces it is a number: `tokenize` rewrites "-" to a space
                // so that "twenty-five" reads as 25, and a break there would put
                // the tens and the units in different breaths, or would cut the
                // corpus's "tiktok -5 a day" between the door and its number.
                // Neither of those has a space on both sides, so the condition
                // is exactly the thing that tells them apart.
                if c == "-" {
                    guard let p = prev, p.isWhitespace, let n = next, n.isWhitespace else {
                        return false
                    }
                }
                if isQuantity(wordBefore), isQuantity(wordAfter(text, from: after)) { return false }
                return true

            case "\u{2026}":
                // The single-character ellipsis, silent for the reason its
                // three-dot spelling is.
                return false

            default:
                return false
            }
        }
    }
}
