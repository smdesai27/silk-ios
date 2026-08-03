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

    /// Parse a clock time: "10", "10:30", "ten", "5 pm", "10 p.m.".
    /// Bare hours ≤ 12 are ambiguous; the caller resolves am/pm from context
    /// (a down-hours *start* is an evening, an *end* is a morning).
    public static func timeOfDay(in utterance: String, assumeEvening: Bool) -> TimeOfDay? {
        let text = utterance.lowercased()
            .replacingOccurrences(of: "p.m.", with: "pm")
            .replacingOccurrences(of: "a.m.", with: "am")
        let tokens = tokenize(text)

        for (i, tok) in tokens.enumerated() {
            var hour: Int?
            var minute = 0
            if tok.contains(":") {
                let parts = tok.split(separator: ":")
                if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h <= 24, m < 60 {
                    hour = h
                    minute = m
                }
            } else if let h = Int(tok), (0...24).contains(h) {
                hour = h
            } else if let h = teens[tok] ?? units[tok], h <= 12 {
                hour = h
            }
            guard var h = hour else { continue }

            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            if next == "pm" { h = h % 12 + 12 } else if next == "am" {
                h = h % 12
            } else if h <= 12, assumeEvening {
                // "down hours start at ten" — an evening reading.
                if h < 12 { h += 12 }
            }
            return TimeOfDay(hour: h % 24, minute: minute)
        }
        return nil
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":")).inverted)
            .filter { !$0.isEmpty }
    }
}
