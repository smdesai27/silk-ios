import Testing
import Foundation
import UIKit
@testable import Silk
@testable import SilkCore

// The day turning, from the app's side: the parked loosening that matures on a
// cold launch, and the sweep that closes yesterday's books.
//
// Two boundaries meet here and nothing else in `SilkTests/` stands where they
// meet. `applyPendingIfDayTurned` is the only code that can hand the user a
// loosening she asked for yesterday, and it is reached from `init` — so its
// failures look like "the app opened with the wrong budget", which no test that
// builds its model through `completeSetup` can ever see. `compactLedgerIfDayTurned`
// is the only code that destroys grants, and it destroys them behind a gate
// (`recordClosedDays`) whose own unit is in the spine over a scripted store; what
// the spine cannot show is the two of them wired to the real App Group, in the
// order `foregrounded()` runs them.
//
// **Written against outcomes, never against schedule.** Nothing below asserts
// that a sweep happens on a tick, on a foreground, or once — only that after
// the app has been brought forward, yesterday is compacted, today is not, and
// the closed day has a record. Where and how often the work is triggered is
// free to move.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group. That
// makes state global to the process, which is why every test starts from a wipe
// and why the suites are `.serialized` over a non-parallel target.

// MARK: - Fixtures

/// Seed the App Group the way a previous launch would have left it, and build
/// nothing. The model under test is the one the *next* `AppModel()` makes —
/// `applyPendingIfDayTurned` runs inside `init`, so a fixture that constructs
/// the model first has already missed the thing it wants to watch.
@MainActor
@discardableResult
private func seedStore(budget: Int = 40,
                       doors: [Door] = [Door(name: "Instagram")]) -> PolicyState {
    SharedStore.wipeAll()
    let policy = PolicyState(budgetMinutes: budget,
                             downHours: nightWellClearOfNow(),
                             doors: doors)
    SharedStore.save(policy: policy)
    return policy
}

/// The same policy with one field moved — a loosening, which is what parks.
private func loosened(_ policy: PolicyState, budget: Int) -> PolicyState {
    PolicyState(budgetMinutes: budget, downHours: policy.downHours,
                doors: policy.doors, wallEnabled: policy.wallEnabled,
                doorCaps: policy.doorCaps)
}

private func daysAgo(_ n: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: -n, to: .now) ?? .now.addingTimeInterval(-86_400 * Double(n))
}

// MARK: - The parked loosening, at the boundary it was promised

@Suite(.serialized) @MainActor struct APendingLooseningMeetsItsBoundary {

    /// The promise the whole park exists to keep: say "budget 90" today, and
    /// tomorrow's app opens on 90 without being asked twice.
    ///
    /// Two days rather than one, deliberately. One day ago is one day ago *by
    /// the wall clock*, and the Silk boundary sits at `downHours.end` — so a
    /// run six hours before its own fixture boundary would find a
    /// twenty-four-hour-old stamp still on this side of it and the test would
    /// pass or fail on the hour the suite happened to start.
    @Test func aLooseningAskedTwoDaysAgoMaturesOnTheNextLaunch() {
        let live = seedStore(budget: 40)
        SharedStore.save(pendingLoosening: loosened(live, budget: 90),
                         baseline: live,
                         proposedAt: daysAgo(2))

        let model = AppModel()

        #expect(model.policy.budgetMinutes == 90,
                "the loosening never arrived — the app opened on \(model.policy.budgetMinutes)")
        #expect(model.pendingLoosening == nil, "the matured loosening is still parked")
        #expect(SharedStore.loadPendingLoosening() == nil,
                "the store still holds a pending that has already been applied")
        #expect(SharedStore.loadPendingProposedAt() == nil)
        #expect(SharedStore.loadPolicy()?.budgetMinutes == 90,
                "the matured policy was never persisted")
    }

    /// And the other half, which is the rule itself: a loosening asked for
    /// *today* has not had its boundary, and force-quitting is not a boundary.
    /// This is the regression the timestamp exists for — comparing `dayStart`
    /// to `now` is always true, so every relaunch applied every pending.
    @Test func aLooseningAskedTodayIsStillParkedOnTheNextLaunch() {
        let live = seedStore(budget: 40)
        let asked = Date.now
        SharedStore.save(pendingLoosening: loosened(live, budget: 90),
                         baseline: live,
                         proposedAt: asked)

        let model = AppModel()

        #expect(model.policy.budgetMinutes == 40,
                "a relaunch spent the boundary the user is supposed to wait for")
        #expect(model.pendingLoosening?.budgetMinutes == 90,
                "the parked loosening was dropped instead of held")
        #expect(SharedStore.loadPendingProposedAt() == asked,
                "the pending was re-stamped, which would push its boundary out a day")
    }

    /// A pending persisted by a build that stored no timestamp. There is
    /// nothing a boundary can be measured against, so it is stamped NOW and
    /// made to wait one — erring toward the edge holding, which is the whole
    /// rule. What it must never do is take the absence as "long enough ago".
    @Test func aPendingWithNoTimestampIsStampedRatherThanApplied() {
        let live = seedStore(budget: 40)
        SharedStore.save(pendingLoosening: loosened(live, budget: 90),
                         baseline: live,
                         proposedAt: daysAgo(2))
        // The shape the old build left behind: the pending and its baseline,
        // and no `silk.pending.at` beside them.
        SharedStore.defaults.removeObject(forKey: "silk.pending.at")
        #expect(SharedStore.loadPendingProposedAt() == nil, "the fixture did not remove the stamp")
        let before = Date.now

        let model = AppModel()

        #expect(model.policy.budgetMinutes == 40,
                "an unstamped pending was applied on sight")
        #expect(model.pendingLoosening?.budgetMinutes == 90,
                "the unstamped pending was thrown away instead of made to wait")
        let stamped = SharedStore.loadPendingProposedAt()
        #expect(stamped != nil, "the pending was left unstamped — it can never mature")
        #expect((stamped ?? .distantPast) >= before,
                "the stamp is not this launch's, so the boundary it waits for is unknowable")
        #expect(SharedStore.loadPendingBaseline()?.budgetMinutes == 40,
                "the baseline was dropped, which matures the pending to nothing")
    }

    /// A pending with no baseline cannot say what it proposed — every field of
    /// the snapshot is equally suspect — so at its boundary it matures to
    /// nothing and is cleared rather than re-parked. A loosening lost is the
    /// safe direction; the sentence can be said again.
    @Test func aPendingWithNoBaselineIsClearedAtItsBoundary() {
        seedStore(budget: 40)
        let live = SharedStore.loadPolicy()!
        SharedStore.save(pendingLoosening: loosened(live, budget: 90),
                         baseline: nil,
                         proposedAt: daysAgo(2))
        #expect(SharedStore.loadPendingBaseline() == nil, "the fixture stored a baseline anyway")

        let model = AppModel()

        #expect(model.policy.budgetMinutes == 40,
                "a baseline-less pending was assigned wholesale")
        #expect(model.pendingLoosening == nil,
                "the baseline-less pending survived its boundary — a card offering a change that can never come")
        #expect(SharedStore.loadPendingLoosening() == nil)
    }
}

// MARK: - The sweep that closes yesterday

@Suite(.serialized) @MainActor struct TheDayTurnSweepClosesYesterdaysBooks {

    /// Coming back to the app is where the boundary is noticed. After it,
    /// yesterday's spent grants are gone from the hot ledger and today's are
    /// untouched — the two halves of "compaction is not deletion".
    ///
    /// Asserted over the ledger's own contents rather than its size, so a
    /// change to what else the sweep folds in cannot make this pass by
    /// accident.
    @Test func comingBackAfterABoundaryCompactsYesterdayAndKeepsToday() {
        let policy = seedStore(budget: 40)
        let door = policy.doors[0]
        let model = AppModel()
        let dayStart = DayBoundary.dayStart(now: .now, downHours: policy.downHours,
                                            calendar: .current)

        // Written straight into the App Group, which is where a grant from a
        // previous day actually comes from: the app was not running when it
        // was issued and was not running when it expired.
        let yesterday = Grant(door: door, minutes: 60,
                              issuedAt: dayStart.addingTimeInterval(-2 * 3600),
                              expiresAt: dayStart.addingTimeInterval(-3600))
        let today = Grant(door: door, minutes: 10, issuedAt: .now,
                          expiresAt: Date.now.addingTimeInterval(600))
        var seeded = GrantLedger()
        seeded.record(yesterday)
        seeded.record(today)
        SharedStore.save(ledger: seeded)

        model.foregrounded()

        #expect(model.ledger.grants.contains { $0.id == today.id },
                "the sweep dropped a grant issued today")
        #expect(model.ledger.grants.contains { $0.id == yesterday.id } == false,
                "yesterday's spent grant is still in the hot ledger")
        #expect(SharedStore.loadLedger().grants.contains { $0.id == yesterday.id } == false,
                "the compaction never reached the store")
        #expect(SharedStore.loadLedger().grants.contains { $0.id == today.id },
                "the persisted ledger lost today's grant")
    }

    /// Nothing is destroyed without a record: the same sweep must leave a
    /// `DayRecord` for the day it just cut.
    ///
    /// **`observed` is false here, and that is the honest answer on this
    /// machine.** A day is observed only when the permanent daily schedule
    /// fired inside it, and the simulator has no Screen Time authorization —
    /// `WallController.armHeartbeat` catches the throw from `startMonitoring`
    /// and returns false, so nothing ever writes `silk.heartbeat` and no day a
    /// simulator run summarises can be alive. The heartbeat log is asserted
    /// empty first, so a runner that somehow *could* arm one fails on the
    /// premise rather than silently inverting the verdict below.
    @Test func theSweepWritesYesterdaysRecordAndCallsItUnobserved() {
        let policy = seedStore(budget: 40)
        let door = policy.doors[0]
        let model = AppModel()
        let dayStart = DayBoundary.dayStart(now: .now, downHours: policy.downHours,
                                            calendar: .current)
        var seeded = GrantLedger()
        seeded.record(Grant(door: door, minutes: 60,
                            issuedAt: dayStart.addingTimeInterval(-2 * 3600),
                            expiresAt: dayStart.addingTimeInterval(-3600)))
        SharedStore.save(ledger: seeded)
        #expect(SharedStore.dayRecords().isEmpty, "the wipe left day records behind")

        // The premise, stated rather than assumed: no schedule can arm here.
        #expect(model.wall.armHeartbeat(downHours: policy.downHours) == false,
                "this runner CAN arm the heartbeat — `observed` below is no longer a constant")
        #expect(SharedStore.heartbeats().isEmpty,
                "something recorded a heartbeat; the day may legitimately be observed")

        model.foregrounded()

        let yesterdayStart = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!
        let record = SharedStore.dayRecords().first { $0.dayStart == yesterdayStart }
        #expect(record != nil,
                "the day whose grants were just cut has no record — nothing can ever summarise it again")
        #expect(record?.observed == false,
                "a day with no heartbeat behind it was recorded as observed")
        #expect(record?.score == 0, "an unobserved day credited a score")
    }
}

// MARK: - The attempts tail, against the real App Group
//
// The properties of the fold itself are pinned in `SilkCore`
// (`AttemptsTailTests`), over the pure function both the fold and the merge go
// through. What cannot be asserted there is the BINDING: that
// `SharedStore.recordAttempt` really appends to the tail key, that every
// reader really routes through the merge, and that the compaction gate's
// `attemptsBlob()` — the array §3.5 takes its "at cap" reading from — really
// sees the tail before anything has folded it.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group;
// serialized over a non-parallel target, and every test starts from a wipe,
// because that state is global to the process.

@Suite(.serialized) @MainActor struct TheAttemptsTailIsInvisibleToEveryReader {

    /// The whole point of the split, stated as the thing that would otherwise
    /// break: a reach recorded by a shield render is on Mirror's week chart
    /// before the app has folded anything.
    @Test func aReachRecordedThroughTheTailIsVisibleBeforeFolding() {
        SharedStore.wipeAll()
        let now = Date()
        SharedStore.recordAttempt(at: now)

        let since = now.addingTimeInterval(-3600)
        #expect(SharedStore.attempts(since: since).contains(now),
                "an attempt sitting in the tail is invisible to `attempts(since:)`")
        #expect(SharedStore.attemptsMerged().contains(now))
    }

    /// Folding does not change what anybody can see — the reader's answer is
    /// the same array on both sides of it — and it does empty the tail, which
    /// is the only reason to run it at all.
    @Test func foldingPreservesTheRecordAndEmptiesTheTail() {
        SharedStore.wipeAll()
        // Three reaches, each clear of the 60-second dedupe window.
        let base = Date().addingTimeInterval(-3600)
        let recorded = (0..<3).map { base.addingTimeInterval(Double($0) * 120) }
        for at in recorded { SharedStore.recordAttempt(at: at) }

        let before = SharedStore.attemptsMerged()
        #expect(before == recorded, "the tail did not preserve the order attempts arrived in")

        SharedStore.foldAttemptsTail()

        #expect(SharedStore.attemptsMerged() == before,
                "folding changed what a reader sees")
        #expect(SharedStore.defaults.data(forKey: "silk.attempts.tail") == nil,
                "the fold left the tail standing; the render path's encode never gets cheaper")
        #expect(SharedStore.defaults.data(forKey: "silk.attempts") != nil,
                "the fold never reached the blob")

        // And a second fold is a no-op rather than a doubling — the property
        // that lets the app and an overflowing render both fold.
        SharedStore.foldAttemptsTail()
        #expect(SharedStore.attemptsMerged() == before, "a second fold double-counted a reach")
    }

    /// §3.5's reading, taken through the live store. The compaction gate reads
    /// the whole array to decide whether the blob is at its cap; that reading
    /// must not depend on whether a fold has happened yet.
    @Test func theObservabilityReadingIsTheSameBeforeAndAfterFolding() {
        SharedStore.wipeAll()
        let base = Date().addingTimeInterval(-7200)
        for i in 0..<3 { SharedStore.recordAttempt(at: base.addingTimeInterval(Double(i) * 120)) }

        let policy = PolicyState(budgetMinutes: 40, downHours: nightWellClearOfNow(),
                                 doors: [Door(name: "Instagram")])
        let dayStart = DayBoundary.dayStart(now: .now, downHours: policy.downHours,
                                            calendar: .current)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!

        func summary(_ attempts: [Date]) -> DayRecord {
            DayLog.summarise(dayStart: yesterday, downHours: policy.downHours, grants: [],
                             attempts: attempts, heartbeats: [], wallStanding: true,
                             calendar: .current)
        }
        let unfolded = summary(SharedStore.attemptsMerged())
        SharedStore.foldAttemptsTail()
        let folded = summary(SharedStore.attemptsMerged())

        #expect(unfolded.observed == folded.observed,
                "a day's `observed` verdict turns on whether the app happened to fold")
        #expect(unfolded.reaches == folded.reaches)
    }

    /// The 60-second dedupe is unchanged, and it is now answered off the tail
    /// rather than off the blob — which is the read the split exists to avoid.
    @Test func theSixtySecondDedupeStillHolds() {
        SharedStore.wipeAll()
        let now = Date()
        SharedStore.recordAttempt(at: now)
        SharedStore.recordAttempt(at: now.addingTimeInterval(30))
        #expect(SharedStore.attemptsMerged().count == 1,
                "a render 30 seconds after the last one counted as a second attempt")
        SharedStore.recordAttempt(at: now.addingTimeInterval(90))
        #expect(SharedStore.attemptsMerged().count == 2,
                "a render well past the dedupe window was swallowed")
    }

    /// THE REVISION IS A COUNTER OF APPENDS AND NOT OF CALLS. `AppModel`'s
    /// minute tick and its return-from-background both hold a decoded week of
    /// buckets and drop it only when this integer moves — one integer read
    /// against four JSON decodes, sixty times an hour — so anything that moves
    /// the revision without changing what a reader sees is a full invalidation
    /// pass and a re-decode of the whole attempts blob, paid to redraw a chart
    /// that is identical.
    ///
    /// A burst of shield renders is exactly that shape. Renders arrive in
    /// bursts, `recordAttempt` collapses everything inside sixty seconds into
    /// one reach, and the bump sits after the two dedupe guards — so a swallowed
    /// render must leave the counter where it stood.
    @Test func aSwallowedDuplicateReachDoesNotMoveTheRevision() {
        SharedStore.wipeAll()
        let now = Date()
        SharedStore.recordAttempt(at: now)
        let afterFirst = SharedStore.attemptsRevision()

        // Thirty seconds later: inside the window, so the record does not move.
        SharedStore.recordAttempt(at: now.addingTimeInterval(30))
        #expect(SharedStore.attemptsMerged().count == 1,
                "the fixture's second render was not swallowed — this test is not about the dedupe any more")
        #expect(SharedStore.attemptsRevision() == afterFirst,
                "a render swallowed by the 60-second dedupe moved the revision: every cache in the app fell for a reach that never happened")

        // And past it, where a reach really is recorded and the counter must
        // move — otherwise the assertion above is satisfied by a counter that
        // never moves at all.
        SharedStore.recordAttempt(at: now.addingTimeInterval(90))
        #expect(SharedStore.attemptsRevision() != afterFirst,
                "a reach past the dedupe window left every cached week chart standing on the old blob")
    }

    /// And the fold moves it either, which is the same argument from the other
    /// side: `foldAttemptsTail` changes where the record is STORED and not what
    /// any reader can see (`foldingPreservesTheRecordAndEmptiesTheTail` above
    /// is that claim). A revision bumped there would invalidate every cache in
    /// the app on a bookkeeping write — and the app folds on its own minute
    /// tick, so it would be doing it to itself, once a minute, forever.
    @Test func foldingTheTailDoesNotMoveTheRevision() {
        SharedStore.wipeAll()
        let base = Date().addingTimeInterval(-3600)
        for i in 0..<3 { SharedStore.recordAttempt(at: base.addingTimeInterval(Double(i) * 120)) }
        let before = SharedStore.attemptsRevision()
        #expect(before > 0, "the fixture recorded nothing, so there is no fold to test")

        SharedStore.foldAttemptsTail()

        #expect(SharedStore.attemptsRevision() == before,
                "the fold moved the revision — the app invalidates its own week chart on every tick that folds")
        // Not a tautology: the fold really did happen.
        #expect(SharedStore.defaults.data(forKey: "silk.attempts.tail") == nil,
                "nothing was folded, so the assertion above says nothing")
    }

    /// The tail cannot grow without bound while the app is never opened: at
    /// its cap the render folds rather than evicting, so nothing is lost and
    /// the tail stays small.
    @Test func anOverflowingTailFoldsItselfRatherThanDroppingReaches() {
        SharedStore.wipeAll()
        let base = Date().addingTimeInterval(-86_400)
        let n = DayLog.attemptsTailCap + 5
        for i in 0..<n { SharedStore.recordAttempt(at: base.addingTimeInterval(Double(i) * 120)) }

        #expect(SharedStore.attemptsMerged().count == n,
                "the tail dropped reaches instead of folding at its cap")
        let tail = (SharedStore.defaults.data(forKey: "silk.attempts.tail")
            .flatMap { try? JSONDecoder().decode([Date].self, from: $0) }) ?? []
        #expect(tail.count < DayLog.attemptsTailCap,
                "the tail is past its own cap; the render path's encode is unbounded again")
    }
}

// MARK: - The minute clock, and what it is allowed to redraw

/// `AppModel.now` is the one stored instant the whole tree observes — the root,
/// all three pages, and every derived property on the model hang off it — so a
/// write to it is a full invalidation pass. The clock wakes once a minute
/// because deadlines are rendered to the minute, and it used to write `now` on
/// every one of those wakes: sixty passes an hour, of which about three change
/// a pixel.
///
/// The gate is written against the FACE — day/night and the greeting's band —
/// because that is the only thing on any page that reads the wall clock
/// continuously. Everything else `now` feeds (`dayStart`, `remainingMinutes`,
/// `state(of:)`, the rule in force) moves only at an instant the tick already
/// watches for by other means, which is the same argument the wall's own
/// reconcile gate is built on.
///
/// Asked of `tick(at:transition:)` rather than of the sleeping loop: what is
/// worth asserting is what a wake at a *chosen* instant does, and a sleep
/// cannot be asked that.
@Suite(.serialized) @MainActor struct TheMinuteTickWritesOnlyWhatMoves {

    /// 10 PM to 7 AM. An anchor at 2 PM is clear of both edges, and one at
    /// 21:59 is a minute from crossing the first.
    private static let night = DownHours(start: TimeOfDay(hour: 22, minute: 0),
                                         end: TimeOfDay(hour: 7, minute: 0))

    /// Today at a stated hour. The tick takes its instant as an argument, so
    /// nothing here depends on the hour the suite happens to run at.
    private static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    private static func seed() {
        SharedStore.wipeAll()
        SharedStore.save(policy: PolicyState(budgetMinutes: 40,
                                             downHours: night,
                                             doors: [Door(name: "Instagram")]))
    }

    /// The first wake of a process always writes: `compactedDayStart` is nil on
    /// a model this young, so `turned` is true and the day-turn sweep runs. It
    /// is the wake AFTER that one that this suite is about, which is why every
    /// test below takes a settling tick first.
    private static func settled(_ model: AppModel, at anchor: Date) -> Date {
        model.tick(at: anchor, transition: nil)
        return model.now
    }

    @Test func aPlainMinuteDoesNotMoveTheClockTheTreeReads() {
        Self.seed()
        let model = AppModel()
        let anchor = Self.today(14, 0)
        let settled = Self.settled(model, at: anchor)

        model.tick(at: anchor.addingTimeInterval(60), transition: nil)

        #expect(model.now == settled,
                "a minute in which nothing moved wrote `now` — the whole tree redrew for a clock nobody can see")
    }

    /// The face the gate exists for. 21:59 and 22:00 are the same greeting band
    /// ("Down hours at 10."), so the only thing that moves across this minute is
    /// day into night — and that recolours every page.
    @Test func crossingIntoDownHoursMovesIt() {
        Self.seed()
        let model = AppModel()
        let settled = Self.settled(model, at: Self.today(21, 59))
        #expect(model.isDownHours == false,
                "the fixture began inside its own night — the crossing below is not one")

        let crossing = Self.today(22, 0)
        model.tick(at: crossing, transition: nil)

        #expect(model.now == crossing, "the night arrived and the screen was not told")
        #expect(model.now != settled)
        #expect(model.isDownHours, "the night face never landed")
    }

    /// The other thing the minute exists to redraw: a grant expiring, which
    /// reaches the tick as the transition its sleep was aimed at. A door that
    /// just shut must move `now`, or its row goes on reading "till 4:52" over a
    /// door that is closed.
    @Test func aTransitionThatHasPassedMovesIt() {
        Self.seed()
        let model = AppModel()
        let anchor = Self.today(14, 0)
        let settled = Self.settled(model, at: anchor)
        let wake = anchor.addingTimeInterval(60)

        model.tick(at: wake, transition: anchor.addingTimeInterval(30))

        #expect(model.now == wake,
                "a grant expired inside this minute and the rows were never asked to redraw")
        #expect(model.now != settled)
    }

    /// The OTHER half of the face, and the one the night crossing above cannot
    /// reach: the greeting's band. "Good morning." and "Good afternoon." are the
    /// same page in two different sentences, and `face` carries the band — 20,
    /// 17, 12 or 0 — precisely so the tick can tell 11:59 from 12:00 while
    /// telling 12:01 from 12:59.
    ///
    /// Both minutes are broad daylight under the fixture's 10 PM–7 AM window, so
    /// `night` is equal across them and the band is the only thing that moves.
    /// Delete the band from `Face` and the greeting reads "Good morning." until
    /// something else happens to write `now` — which on a quiet afternoon is the
    /// next grant.
    @Test func crossingAGreetingBandMovesIt() {
        Self.seed()
        let model = AppModel()
        let settled = Self.settled(model, at: Self.today(11, 59))
        #expect(model.isDownHours == false,
                "the fixture began inside its own night — the crossing below is not a band change")

        let noon = Self.today(12, 0)
        model.tick(at: noon, transition: nil)

        #expect(model.now == noon,
                "the morning became the afternoon and the greeting was never asked to redraw")
        #expect(model.now != settled)
        #expect(model.isDownHours == false,
                "the fixture crossed into its night as well — this is no longer a band-only test")
    }

    /// The `ledgerMoved` arm: another process wrote the App Group while Silk sat
    /// here. The tick's own sync folds it in, and a fold that did not also write
    /// `now` would leave the balance, the door rows and the receipt drawing a
    /// ledger this copy no longer holds.
    ///
    /// Not hypothetical: `SpendIntent` performs in its own background process,
    /// against this store, with no scene to tell Silk anything.
    @Test func aWriteFromAnotherProcessMovesIt() {
        Self.seed()
        let model = AppModel()
        let anchor = Self.today(14, 0)
        let settled = Self.settled(model, at: anchor)
        #expect(model.ledger.grants.isEmpty, "the fixture started with a grant in it")

        // Somebody else, mid-minute.
        var theirs = SharedStore.loadLedger()
        theirs.record(Grant(door: Door(name: "Instagram"), minutes: 10, issuedAt: .now,
                            expiresAt: Date.now.addingTimeInterval(10 * 60)))
        SharedStore.save(ledger: theirs)

        let wake = anchor.addingTimeInterval(60)
        model.tick(at: wake, transition: nil)

        #expect(model.ledger.grants.count == 1,
                "the tick never re-read the store another process had written")
        #expect(model.now == wake,
                "a grant landed from another process and this copy's screen was never told")
        #expect(model.now != settled)
    }

    /// AND A DROPPED CACHE IS A VISIBLE MOVE. A shield render in the other half
    /// of an iPad split screen records a reach while Silk stays `.active`: the
    /// attempts revision moves and nothing else does. Both of Mirror's caches
    /// are `@ObservationIgnored`, so nilling one tells no view anything — the
    /// score would have gone on standing on the old blob until the next band
    /// change, which on an afternoon is hours.
    ///
    /// `todayScore` is read first on purpose. The cache the tick compares does
    /// not exist until something asks for the week, and a test that skipped that
    /// line would be asserting the `cachesMoved` arm against a nil cache — which
    /// takes the arm nowhere and passes for the wrong reason.
    @Test func aReachRecordedWhileSilkStaysOpenMovesIt() {
        Self.seed()
        let model = AppModel()
        let anchor = Self.today(14, 0)
        let settled = Self.settled(model, at: anchor)
        // Mirror, asked once, so there is a decoded week to invalidate.
        _ = model.todayScore

        SharedStore.recordAttempt(at: .now)

        let wake = anchor.addingTimeInterval(60)
        model.tick(at: wake, transition: nil)

        #expect(model.now == wake,
                "a reach recorded beside Silk moved the revision and the score was never asked to redraw")
        #expect(model.now != settled)
    }

    /// THE NEGATIVE HALF, and it is the one the whole gate exists for: a plain
    /// minute writes nothing and reconciles nothing.
    ///
    /// The receipt is `silk.migrated.categories`. `WallController.reconcile()`
    /// is `Wall.reconcile(restating: true)`, and a restatement sets that flag
    /// unconditionally on every path that writes the app layer — so clearing it
    /// after the settling tick gives this test a one-bit record of whether the
    /// reconcile ran, from outside, with no Screen Time authorization and no
    /// `ManagedSettingsStore` to read. Nothing else in the suite can see a
    /// reconcile at all.
    ///
    /// The control is the last two lines. Without them the assertions above are
    /// satisfied by a `tick` that does nothing ever, which is the failure mode a
    /// gate like this actually has.
    @Test func aPlainMinuteReconcilesNothingAndWritesNothing() {
        Self.seed()
        // A reach, so the tail is a real blob and not an absent key: "unchanged"
        // has to be a comparison of something. Recorded before the model is
        // built, so the revision it bumps is the one the model starts from.
        SharedStore.recordAttempt(at: Date().addingTimeInterval(-3600))
        let model = AppModel()
        let anchor = Self.today(14, 0)
        _ = Self.settled(model, at: anchor)

        SharedStore.defaults.removeObject(forKey: "silk.migrated.categories")
        let tail = SharedStore.defaults.data(forKey: "silk.attempts.tail")
        let stamp = SharedStore.ledgerStamp()
        #expect(tail != nil, "the fixture put no reach in the tail, so there is nothing to hold still")

        model.tick(at: anchor.addingTimeInterval(60), transition: nil)

        #expect(SharedStore.categoryShieldsMigrated == false,
                "a minute in which nothing moved restated the wall — four decodes and a cross-process write into the Screen Time daemon, to say what it already knew")
        #expect(SharedStore.defaults.data(forKey: "silk.attempts.tail") == tail,
                "a plain minute rewrote the attempts tail")
        #expect(SharedStore.ledgerStamp() == stamp,
                "a plain minute wrote the ledger back — every other process now believes the truth moved")

        // The control: a wake the tick is allowed to act on does all of it.
        let later = anchor.addingTimeInterval(120)
        model.tick(at: later, transition: anchor.addingTimeInterval(90))
        #expect(SharedStore.categoryShieldsMigrated,
                "a wake at a passed transition did not reconcile either — the assertions above pass for a tick that has stopped doing anything at all")
    }
}
