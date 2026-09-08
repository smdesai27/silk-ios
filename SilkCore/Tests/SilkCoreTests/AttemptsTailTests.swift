import Foundation
import Testing
@testable import SilkCore

// The attempts blob has two halves now, and this file is the proof that no
// reader can tell.
//
// A shield render may not re-encode a 2000-entry `[Date]` to add one
// timestamp, so `SharedStore.recordAttempt` appends to a small tail key and
// the app folds it back later. That split is only safe while "the attempts"
// means the same array whether or not the fold has run — and §3.5's
// observability rule is the reader that could tell, because it turns on the
// blob sitting AT its cap and on which instant is oldest in it. A merge that
// trimmed differently from the fold would move a real day's verdict by nothing
// more than when the app was last opened.
//
// So `DayLog.foldedAttempts` is one function with two callers — the fold that
// writes the blob, and the merge every reader goes through — and everything
// below is a property of that function. The App Group binding (does
// `attempts(since:)` actually route through it) is asserted in `SilkTests`,
// where `SharedStore` resolves against a real container.

private let epoch = Date(timeIntervalSince1970: 1_750_000_000)

/// `count` attempts a minute apart, oldest first, starting `offset` minutes
/// after the epoch — the shape `recordAttempt`'s 60-second dedupe produces.
private func attempts(_ count: Int, from offset: Int = 0) -> [Date] {
    (0..<count).map { epoch.addingTimeInterval(Double(offset + $0) * 60) }
}

@Suite struct TheAttemptsTailFoldsWithoutMovingAnything {

    @Test func aTailEntryIsInTheMergedViewBeforeAnyFold() {
        let blob = attempts(10)
        let tail = attempts(3, from: 10)
        let merged = DayLog.foldedAttempts(blob: blob, tail: tail)
        #expect(merged.count == 13)
        #expect(Array(merged.suffix(3)) == tail,
                "a reach the render path appended is not visible until the app folds it")
    }

    @Test func theFoldPreservesOrder() {
        let blob = attempts(50)
        let tail = attempts(7, from: 50)
        let merged = DayLog.foldedAttempts(blob: blob, tail: tail)
        #expect(merged == blob + tail)
        #expect(merged == merged.sorted(), "the fold reordered the record")
    }

    /// The cap is applied to the merged whole, exactly as `recordAttempt`
    /// used to apply it to the blob — so the oldest entries fall off the
    /// front and the newest tail entry is the last thing in the array.
    @Test func theFoldTrimsToTheCapFromTheFront() {
        let blob = attempts(DayLog.attemptsCap)
        let tail = attempts(5, from: DayLog.attemptsCap)
        let merged = DayLog.foldedAttempts(blob: blob, tail: tail)
        #expect(merged.count == DayLog.attemptsCap, "the fold grew the blob past its cap")
        #expect(merged.first == blob[5], "the trim did not take the oldest five")
        #expect(merged.last == tail.last, "the newest reach fell off the wrong end")
    }

    /// Folding is idempotent, which is what lets the app and an overflowing
    /// shield render both fold the same tail without double-counting a reach.
    /// `UserDefaults` has no compare-and-swap; this property is the whole
    /// defence.
    @Test func foldingTwiceIsFoldingOnce() {
        let blob = attempts(30)
        let tail = attempts(6, from: 30)
        let once = DayLog.foldedAttempts(blob: blob, tail: tail)
        let twice = DayLog.foldedAttempts(blob: once, tail: tail)
        #expect(once == twice, "a doubled fold double-counted a reach")
    }

    @Test func foldingAnEmptyTailChangesNothing() {
        let blob = attempts(40)
        #expect(DayLog.foldedAttempts(blob: blob, tail: []) == blob)
    }

    /// The reading §3.5 actually makes, taken on both sides of a fold.
    ///
    /// A blob at its cap whose oldest entry is newer than the day being
    /// summarised makes `reaches` a floor rather than a count, and the day is
    /// recorded unobserved. The tail can be what pushes the array to the cap,
    /// so this is exactly the reading that would move if the merge and the
    /// fold disagreed by a single entry.
    @Test func theAtCapReadingIsTheSameBeforeAndAfterFolding() {
        let calendar = Calendar.current
        let down = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))
        // The blob one short of its cap; the tail is what fills it.
        let blob = attempts(DayLog.attemptsCap - 1, from: 1)
        let tail = attempts(1, from: DayLog.attemptsCap)
        // A day that starts before everything recorded — the shape the
        // truncation term exists to catch.
        let dayStart = calendar.startOfDay(for: epoch.addingTimeInterval(-10 * 86_400))

        let merged = DayLog.foldedAttempts(blob: blob, tail: tail)
        #expect(merged.count == DayLog.attemptsCap, "the fixture is not at the cap")

        func verdict(_ all: [Date]) -> DayRecord {
            DayLog.summarise(dayStart: dayStart, downHours: down, grants: [],
                             attempts: all, heartbeats: [dayStart.addingTimeInterval(60)],
                             wallStanding: true, calendar: calendar)
        }

        // THE TAIL IS WHAT DECIDES THE READING, and that is what makes this
        // test worth running. The blob alone is one short of its cap, so a
        // reader that lost the tail calls the day observed; the merged array
        // is AT the cap, so the truncation term fires and it is not. The two
        // verdicts must therefore DIFFER — an assertion a fold that dropped
        // the tail, or capped the blob before appending it, cannot satisfy.
        let readingIt = verdict(merged)
        let ignoringTheTail = verdict(blob)
        #expect(ignoringTheTail.observed,
                "the fixture is not sensitive to the tail; the test below proves nothing")
        #expect(readingIt.observed == false,
                "a blob at its cap over a day older than its first entry was called observed")

        // And the fold, replayed. Once it has run the store holds `merged` and
        // the tail is still there to be folded again — the doubled fold the
        // shield and the app can race into. It must not move the verdict.
        // (Comparing against `foldedAttempts(blob: merged, tail: [])` is what
        // used to stand here, and that is `merged` by definition: a value
        // compared with itself. Replaying the real tail exercises the dedupe.)
        #expect(verdict(DayLog.foldedAttempts(blob: merged, tail: tail)) == readingIt,
                "a doubled fold moved the day's verdict")
    }

    /// The same reading on a store that is NOT at its cap: the fold must not
    /// be able to make a day unobservable either.
    @Test func aShortRecordStaysObservableAcrossAFold() {
        let calendar = Calendar.current
        let down = DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))
        let dayStart = calendar.startOfDay(for: epoch)
        let blob = [dayStart.addingTimeInterval(3600)]
        let tail = [dayStart.addingTimeInterval(7200)]
        let merged = DayLog.foldedAttempts(blob: blob, tail: tail)

        func verdict(_ all: [Date]) -> DayRecord {
            DayLog.summarise(dayStart: dayStart, downHours: down, grants: [],
                             attempts: all, heartbeats: [dayStart.addingTimeInterval(60)],
                             wallStanding: true, calendar: calendar)
        }
        #expect(verdict(merged).observed, "a two-entry record was called unobservable")
        #expect(verdict(merged).reaches == 2,
                "the reach the render path appended is missing from the day's count")
        // The replayed fold, not a fold of an empty tail: `foldedAttempts(blob:
        // merged, tail: [])` returns `merged` unchanged, so the line that used
        // to stand here compared a value with itself. Handing the fold the same
        // tail it already absorbed is the race the dedupe exists for, and the
        // reach count must survive it — a doubled count is a wrong verdict on
        // a real day, which is worse than a missing one.
        #expect(verdict(DayLog.foldedAttempts(blob: merged, tail: tail)).reaches == 2,
                "a doubled fold double-counted the reach")
    }

    /// The tail cap is the render path's budget, and it has to be well under
    /// the blob's or the "small encode" the split buys is not small.
    @Test func theTailCapIsSmallAgainstTheBlobCap() {
        #expect(DayLog.attemptsTailCap > 0)
        #expect(DayLog.attemptsTailCap * 8 <= DayLog.attemptsCap,
                "the tail is no longer small enough for the encode it saves to be worth the split")
    }
}
