import Foundation

/// The stretch between asking for an app and walking into it, and the one rule
/// that makes it a price rather than a delay: **it only passes while someone is
/// watching it.**
///
/// Look away and it stops where it stopped. Come back and it goes on from
/// there. Nothing resets it and nothing shortens it. That single sentence is
/// the whole contract, and every method here exists to keep it true.
///
/// Kept in the spine, and kept pure, for the reason `RelockWindow` is: the
/// arithmetic that decides whether a door opens has to be checkable without a
/// simulator, a scene phase, or a running clock. So this type never reads a
/// clock — every question takes its reading as an argument, and the app hands
/// it one from a monotonic source. A test hands it a number.
///
/// Two clocks, deliberately, because the two questions are different:
///
///   - **How much has been watched** is measured in `reading`s — a monotonic
///     count of seconds that only ever goes forward (`ContinuousClock` in the
///     app). Wall time is the wrong instrument: `Date` moves when the user
///     moves it in Settings, when the network corrects it, and across a DST
///     edge, and each of those would hand back seconds nobody watched.
///   - **How long ago it was parked** is wall time, and only staleness asks.
///     A wait left at noon and found at four is a different fact from one left
///     eight seconds ago.
///
/// Deliberately **not** `Codable`. A wait is a moment, and it dies with the
/// process that held it — see `Wait.diesWithTheProcess` for why that is the
/// fail-closed direction and not a gap.
public struct Wait: Equatable, Sendable {

    /// Which door is waiting. The ask is re-validated against the ledger when
    /// the wait ends, so this is the subject of that second question and not a
    /// promise it will be answered the same way.
    public let doorID: UUID

    /// The minutes asked for. Carried because the re-validation at the end
    /// needs the number again, and because the length was priced off it —
    /// never so a surface can print it.
    public let minutes: Int

    /// The total watching this ask costs, in seconds.
    public let length: TimeInterval

    /// Watching already banked. Every pause adds the span that just ended;
    /// nothing ever subtracts.
    public private(set) var watched: TimeInterval

    /// The monotonic reading at which the current watching span began, or nil
    /// while nobody is looking.
    public private(set) var since: TimeInterval?

    /// Wall clock at the last pause, for staleness alone. nil while watching.
    public private(set) var pausedAt: Date?

    public init(doorID: UUID, minutes: Int, length: TimeInterval, watched: TimeInterval = 0) {
        self.doorID = doorID
        self.minutes = minutes
        self.length = max(0, length)
        self.watched = max(0, watched)
    }

    // MARK: - The price

    /// Seconds of watching a grant of `minutes` costs.
    ///
    /// **Proportional, and that is the whole argument.** Amendment A (`docs/
    /// market/vision-amendments.md` §A) is explicit that a *toll* is the
    /// competitors' mechanic and a *price with a slope* is Silk's: a fixed
    /// ceremony habituates, and a cost set by what you just chose to spend
    /// cannot, because it is not the same cost twice. So there is no floor
    /// here. A one-minute ask is cheap because a one-minute ask is cheap, and
    /// clamping the bottom would put a step exactly where most asks live and
    /// turn the slope back into the toll it exists to refuse.
    ///
    /// **The slope is 0.3 s a minute**, which puts a twenty-minute ask — the
    /// modal one — at six seconds. Six is the dose the only arm's-length
    /// randomised trial in this literature used (Danish Competition & Consumer
    /// Authority, N=269, ~1.2M interactions), and the default nine of ten one
    /// sec users never move off its 3–60 s slider. It is also below amendment
    /// A's original 0.4 and well above the 29 July retune's ~0.1: the retune's
    /// argument survives as the reason Silk prices *under* the literature's
    /// first-friction curve rather than at it.
    ///
    /// **Linear, not `√m`.** A concave price would reward "make it 30 while
    /// I'm here"; a convex one would punish the single honest use of the whole
    /// pool. Linear is the only shape with nothing to game: the day's total
    /// watching is `rate × budget` however she splits it.
    ///
    /// **Twenty seconds is the ceiling** and it binds above 66 minutes. Not an
    /// argument about attention — an admission about evidence. There is no
    /// field measurement anywhere above ~20 s, and the reviews that kill apps
    /// in this category are never "too long", they are "it would not end".
    public static func length(forMinutes minutes: Int) -> TimeInterval {
        min(ceiling, rate * Double(max(0, minutes)))
    }

    public static let rate: TimeInterval = 0.30
    public static let ceiling: TimeInterval = 20

    /// Under this, there is no wait — the door simply opens, as it always did.
    ///
    /// It is not a floor on the price; it is the point below which the price
    /// cannot be *drawn*. The veil's own rise is 0.4 s, so a shorter wait would
    /// be a screen that arrives and leaves inside its own fade — a flash, which
    /// is a thing the canon calls a slam. The mark never gets drawn, the pause
    /// has nothing to pause, and the honest rendering of a cost that small is
    /// no ceremony at all.
    public static let tooShortToDraw: TimeInterval = 0.4

    public static func isWorthDrawing(_ length: TimeInterval) -> Bool {
        length >= tooShortToDraw
    }

    // MARK: - Watching

    public var isWatching: Bool { since != nil }

    /// Start (or restate) watching. Idempotent: iOS hands out `.active` more
    /// than once without an intervening leave — a Face ID sheet dismissing, a
    /// system alert going away — and restarting the span on the second one
    /// would silently throw away everything watched since the first.
    public mutating func watch(from reading: TimeInterval) {
        guard since == nil else { return }
        since = reading
        pausedAt = nil
    }

    /// Stop watching, banking the span that just ended. Idempotent for the same
    /// reason `watch` is, and against a worse failure: banking twice off one
    /// span would credit attention nobody paid.
    public mutating func lookAway(at reading: TimeInterval, wallClock: Date) {
        guard let start = since else { return }
        watched += span(from: start, to: reading)
        since = nil
        pausedAt = wallClock
    }

    /// A monotonic source cannot go backwards, but a caller can pass a stale
    /// reading — a queued frame, a value captured before a hop. One negative
    /// span would be attention handed back, so the clamp lives at the only
    /// place a span is ever computed.
    private func span(from start: TimeInterval, to reading: TimeInterval) -> TimeInterval {
        max(0, reading - start)
    }

    // MARK: - What the screen asks

    /// Seconds watched as of this reading — banked, plus the span in flight.
    public func watched(at reading: TimeInterval) -> TimeInterval {
        guard let start = since else { return watched }
        return watched + span(from: start, to: reading)
    }

    /// 0...1 — how much of the mark has been drawn.
    ///
    /// The only form the wait is ever stated in, and deliberately the only
    /// accessor the surface has. There is no `remaining`: a remainder is the
    /// shape of a countdown, and a type that offers one invites a surface to
    /// print it. (`docs/design/per-app-caps.md` reaches the same conclusion
    /// about a remaining cap, for the same reason.)
    ///
    /// A zero-length wait is finished, not half-drawn: the divide has no answer
    /// and the honest one is 1.
    public func fraction(at reading: TimeInterval) -> Double {
        guard length > 0 else { return 1 }
        return min(1, max(0, watched(at: reading) / length))
    }

    public func isOver(at reading: TimeInterval) -> Bool {
        watched(at: reading) >= length
    }

    /// A wait can only END while it is being watched — which is the property
    /// that makes the whole design honest, and it is worth naming because two
    /// surfaces depend on it.
    ///
    /// `watched(at:)` moves only inside a watching span, so `isOver` cannot
    /// turn true while nobody is looking. There is therefore no state in which
    /// she returns to Silk and finds a finished wait sitting there waiting to
    /// be dismissed — she is always present at the instant it lands. The door
    /// opening is a thing she watched happen, and the launch is always made
    /// from a foreground app.
    public var canOnlyEndWhileWatched: Bool { true }

    // MARK: - Staleness

    /// True when this wait has been parked, unwatched, longer than `window`.
    ///
    /// A wait is a moment, not an errand. The case this rule exists for is not
    /// abuse, it is a trap: come back to Silk twenty minutes later to close a
    /// door or read the balance, and a wait you had already abandoned resumes
    /// under your thumb and posts you into Instagram. So a parked wait has a
    /// short life, and past it the ask is simply gone — she says the sentence
    /// again, and the new wait starts at nothing.
    ///
    /// A wait being watched is never stale, whatever the wall clock says.
    /// Someone is looking at it right now.
    public func isStale(at now: Date, after window: TimeInterval = Wait.staleAfter) -> Bool {
        guard let pausedAt else { return false }
        return now.timeIntervalSince(pausedAt) > window
    }

    /// How long a parked wait survives being ignored.
    ///
    /// Two minutes is the interruption a wait exists to be interrupted by — a
    /// message answered, a caller sent to voicemail, a word with someone in the
    /// room. It is deliberately not fifteen: the longer the window, the wider
    /// the trap above, and every second past the errand buys nothing. Coming
    /// back later is coming back to a different moment.
    public static let staleAfter: TimeInterval = 120

    /// Not persisted, and this is the rule rather than an omission.
    ///
    /// Nothing is debited until the ink lands (`AppModel.landWait`), so a wait
    /// that dies with its process costs the sentence and not one minute. That
    /// makes forgetting it the fail-closed direction: the wall never came down,
    /// there is no orphaned schedule, no ledger write, no App Group key, and no
    /// extension has to learn a new blob. Force-quitting mid-wait therefore
    /// buys nothing — the door was never open — and costs only the retyping.
    ///
    /// The alternative was considered and rejected: a resumable obligation
    /// surviving a kill, keyed to a verdict computed against a ledger and a
    /// clock that have both moved since, is a great deal of machinery to
    /// preserve a few seconds of watching that the user can simply watch again.
    public static let diesWithTheProcess = true
}
