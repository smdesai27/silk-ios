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

    /// Every number expressible in the utterance, in order of appearance.
    /// Used both for parsing and for the validator's provenance check: a grant
    /// whose minutes do not appear here was invented and must be refused.
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
        for (pattern, value) in idioms where consumed.contains(pattern) {
            results.append(value)
            consumed = consumed.replacingOccurrences(of: pattern, with: " ")
        }

        // Digits.
        var tokens = tokenize(consumed)
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if let digits = Int(tok) {
                results.append(digits)
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
                    results.append(t + u)
                    i += 2
                    continue
                }
                results.append(t)
            } else if let v = teens[tok] ?? units[tok] {
                results.append(v)
            }
            i += 1
        }
        return results
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
        let text = utterance.lowercased()
            .replacingOccurrences(of: "p.m.", with: "pm")
            .replacingOccurrences(of: "a.m.", with: "am")
        let tokens = tokenize(text)

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
                // themselves — "23" cannot be a morning — and so does a 0.
                stated = h > 12 || h == 0
                if h <= 12, assumeEvening, h < 12 {
                    // "down hours start at ten" — an evening reading.
                    h += 12
                }
            }
            return StatedTime(time: TimeOfDay(hour: h % 24, minute: minute),
                              meridiemWasStated: stated)
        }
        return nil
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

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":")).inverted)
            .filter { !$0.isEmpty }
    }
}
