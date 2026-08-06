import Foundation

/// The one parked ask, its baseline, and the generation that keys undo offers
/// to it.
///
/// There is exactly ONE pending slot and the newest ask replaces the waiting
/// one — knowingly, and recorded under Build status in `docs/design/README.md`.
/// That decision is not what this type changes. What it closes is the second,
/// silent loss the first one hides.
///
/// A parked loosening leaves an Undo offer live for as long as the undo window
/// runs (`undoSeconds`, 60 by default and settable to 300). The offer's whole
/// body is "put back whatever was waiting before I parked" — and it used to run
/// unconditionally. So: park a loosening on TikTok, park a second one on
/// Instagram four minutes later, then tap the first offer, which is still on
/// screen in the thread. It parks the FIRST park's predecessor — normally nil —
/// and the second, newer ask is gone. Two losses in one tap, neither of them
/// asked for, and the thread writes "Put back." over both.
///
/// The rule is the ledger's, in the one place a policy pending can state it: an
/// undo applies whole or not at all, and an offer describes the slot it was made
/// against. Every park moves the generation, so any later park — a second
/// loosening, a maturity at the boundary, a key spent, another undo landing —
/// expires every offer made before it. An expired offer reports that it did not
/// land, and the surface that made it must not claim otherwise.
///
/// Held here rather than in `AppModel` so the guard can be asserted in a tenth
/// of a second instead of thirteen minutes of simulator: the failure mode is a
/// five-minute window in a two-park sequence, which is exactly the shape of test
/// no UI walk will ever be written for.
public struct PendingSlot: Equatable, Sendable {
    /// The loosening waiting for a day boundary, as it was proposed.
    public private(set) var pending: PolicyState?

    /// The policy the pending was measured against. It travels with the pending
    /// because at maturity it is the only way to tell which field the sentence
    /// actually moved — and the pair is written in one motion, always, so no
    /// surface can read a merge against a baseline the slot no longer has.
    public private(set) var baseline: PolicyState?

    /// Bumped on every park, including the park that empties the slot. Starts at
    /// zero and is never persisted: it keys offers made by *this* process, and a
    /// process that has just launched holds no offers. (A restored slot with a
    /// counter restored beside it would be worse than useless — it would let an
    /// offer from a previous launch, which cannot exist, appear to stand.)
    public private(set) var generation = 0

    public init(pending: PolicyState? = nil, baseline: PolicyState? = nil) {
        self.pending = pending
        self.baseline = baseline
    }

    /// Park an ask, or clear the slot. Returns the generation the caller's own
    /// offer is keyed to — read it, do not recompute it.
    @discardableResult
    public mutating func park(_ pending: PolicyState?, baseline: PolicyState?) -> Int {
        self.pending = pending
        self.baseline = baseline
        generation += 1
        return generation
    }

    /// Whether an offer made at `generation` still describes this slot. False
    /// the instant anything else parks.
    public func stands(_ generation: Int) -> Bool { self.generation == generation }
}
