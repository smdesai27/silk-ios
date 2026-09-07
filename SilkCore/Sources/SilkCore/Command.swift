import Foundation

/// Silk's complete instruction set. Twelve intents, at most two parameters each.
/// If a sentence doesn't compile to one of these, Silk does nothing.
public enum Command: Equatable, Sendable {
    /// Grant minutes on a door, now. The only hot-path intent.
    case spend(door: Door, minutes: Int)
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
    /// A ceiling on one door's draw from the shared pool. `nil` clears it.
    /// The only producer is the deterministic grammar — `SilkModelParser`'s
    /// `ModelAction` is deliberately not extended — so a `nil` here is always a
    /// sentence and never a hallucination.
    case setDoorCap(door: Door, minutes: Int?)
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
    /// The sentence was a PARTIAL SPEND: it named a door, or a number, or
    /// both, but not the opening verb that turns a mention into an ask. Here
    /// is the door it named (or the first door, when it named none) and the
    /// minutes it said (nil when it said none) — everything the guidance
    /// reply needs to show the user the exact sentence that would grant.
    ///
    /// A POSITIVE outcome, and that is the whole of its job. A bare "instagram
    /// 10" used to compile straight to a grant; refusing it with silence would
    /// hand the sentence to the widener, which would guess at it. This is the
    /// third answer: nothing is debited, nothing opens, and the turn ends here
    /// with the sentence written out.
    case writeItOut(door: Door, minutes: Int?)
    case silence
}
