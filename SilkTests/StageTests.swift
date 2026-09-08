import Testing
import SwiftUI
@testable import Silk

// THE STAGE, IN THREE STATES, WITHOUT A PIXEL.
//
// `SilkStage` is the modifier the root wraps the pager and the dots in, and it
// has exactly three states: at rest, dimmed under the thread, and gone under
// the wait's veil. Two of those three were argued for at length in the design
// (docs/design/wait.md §3.1) and neither is checked anywhere — a walk can see
// that the veil stands, and cannot read back an opacity or a blur radius.
//
// So the two rules were pulled out of `body` as static functions, which is what
// makes this file possible at all: what is left in `body` is the plumbing
// SwiftUI owns (which animation carries which value), and what is here is the
// arithmetic the design decided.
//
// The veiled row is the one worth having. At 0.05 opacity under a 0.97 veil the
// budget ensō still reads, faintly, as a ring above the mark being drawn — the
// "ghost ring" the canon refuses, and the one thing the wait's mark must never
// be mistaken for. The fix was zero, not "very small": zero removes it from the
// image and from the compositor both. `veiled ? 0` is the whole of that
// decision, and a well-meaning tidy that folded the veil back into the dim
// ramp would put the ghost ring back with nothing to say so.

// `@MainActor` on the suite, not for state — there is none, these are pure
// functions of two flags — but because `ViewModifier` is a `@MainActor`
// protocol and a conforming type infers that isolation for its whole
// declaration, statics included. Reaching them from a nonisolated suite would
// not build.
@Suite @MainActor struct TheStageHasThreeStatesAndTwoOfThemAreArgued {

    /// At rest the stage is the page: no fade, no blur, nothing between the
    /// user and it.
    @Test func atRestTheStageIsUntouched() {
        #expect(SilkStage.opacity(dimmed: false, veiled: false) == 1)
        #expect(SilkStage.blur(dimmed: false, veiled: false) == 0)
    }

    /// Under the thread the page dims to five percent and blurs by seven — the
    /// thread's own backdrop, and the reason a tap lands on the catcher rather
    /// than on a row.
    @Test func underTheThreadTheStageDimsAndBlurs() {
        #expect(SilkStage.opacity(dimmed: true, veiled: false) == 0.05)
        #expect(SilkStage.blur(dimmed: true, veiled: false) == 7)
    }

    /// Under the veil the stage is GONE, not dim — and the blur goes with it.
    ///
    /// Both halves are load-bearing and they are load-bearing for different
    /// reasons. Zero opacity is the ghost ring, above. Zero radius is the
    /// frame budget: the veil is already crossing on its own curve over the top
    /// of this, and a Gaussian tweening underneath it is a full-screen
    /// offscreen pass per frame spent on a change nothing can see — on the one
    /// screen in Silk that is nothing but motion.
    @Test func underTheVeilTheStageIsGoneAndCostsNothingToDraw() {
        #expect(SilkStage.opacity(dimmed: true, veiled: true) == 0)
        #expect(SilkStage.blur(dimmed: true, veiled: true) == 0)
    }

    /// And the veil outranks the dim from either side of it, which is what makes
    /// the two flags a state machine rather than two independent switches. A
    /// veil rises over an undimmed page whenever the thread was already blurred
    /// away — and that page must go too, or the ensō stands sharp behind the
    /// mark being drawn.
    @Test func theVeilOutranksTheDimWhicheverWayItArrives() {
        #expect(SilkStage.opacity(dimmed: false, veiled: true) == 0,
                "a veil over an undimmed page left the page standing")
        #expect(SilkStage.blur(dimmed: false, veiled: true) == 0)
        #expect(SilkStage.opacity(dimmed: true, veiled: true)
                == SilkStage.opacity(dimmed: false, veiled: true),
                "the veil's answer depends on the dim underneath it")
        #expect(SilkStage.blur(dimmed: true, veiled: true)
                == SilkStage.blur(dimmed: false, veiled: true))
    }
}
