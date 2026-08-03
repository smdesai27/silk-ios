import Foundation

/// Silk's complete instruction set. Eleven intents, at most two parameters each.
/// If a sentence doesn't compile to one of these, Silk does nothing.
public enum Command: Equatable, Sendable {
    /// Grant minutes on a door, now. The only hot-path intent.
    case spend(door: Door, minutes: Int)
    /// A grant tied to a place, with no number. Understandable but not
    /// executable — the compiler answers "Say how many minutes."
    /// (docs/market/open-language.md: a condition can start a grant;
    /// only a number can end one.)
    case placeBoundAsk(door: Door)
    /// Close a door, until a stated hour or (nil) the rest of today.
    /// "block tiktok until 9" carries the 9; "no more tiktok" carries nothing
    /// and rests to the day boundary. Tightening; instant either way.
    /// (docs/design/handoff/README.md:243)
    case closeDoorToday(door: Door, until: TimeOfDay?)
    /// Close every door at once — "close everything", "close all". The same
    /// tighten, multiplied; the Validator expands it against the live door
    /// list so the parser never has to know what the doors are.
    case closeAllToday(until: TimeOfDay?)
    case setBudget(minutes: Int)
    case setDownHoursStart(TimeOfDay)
    case setDownHoursEnd(TimeOfDay)
    case addDoor(name: String)
    case removeDoor(door: Door)
    case status
    /// A question about the night window, not a change to it: "down hours"
    /// with no time attached. Answered with the window as it stands.
    /// (docs/design/handoff/README.md:244)
    case downHoursQuery
}

/// What the compiler produced. `.silence` is a first-class outcome: zero
/// parses or two parses both end here, and Silk says nothing new.
public enum ParseOutcome: Equatable, Sendable {
    case command(Command)
    case silence
}
