import Foundation
import SwiftUI
import FamilyControls
import ManagedSettings
import SilkCore

@MainActor
@Observable
final class AppModel {
    private(set) var policy: PolicyState
    private(set) var ledger: GrantLedger
    /// The stamp under the ledger blob the last time this process read or
    /// wrote it. The app is not the ledger's only writer — SpendIntent lands
    /// grants straight in the App Group while the app sits suspended — and
    /// every writer stamps through `SharedStore.save(ledger:)`, so a stamp
    /// that differs is proof of an external write. The in-memory copy may not
    /// be trusted, and above all not written, past that proof: persisting it
    /// wholesale deletes the external grant — the door re-shields mid-grant
    /// and the debited minutes silently reappear.
    @ObservationIgnored private var ledgerStamp: String?
    /// Bumped on every ledger movement this process observes: a reload from
    /// the store, and every local mutation `persist` lands (a close, a grant,
    /// the day-turn compaction, a landed restore). Undo closures snapshot the
    /// ledger wholesale, so an undo may only restore its snapshot while the
    /// live value still descends from it — each offer is keyed to the
    /// generation its OWN mutation landed as, and quietly expires the moment
    /// any later movement leaves that number behind. Two offers can coexist
    /// for minutes (the window runs to 300 s); without the per-mutation bump
    /// the older one restores a pre-both ledger and erases the newer turn
    /// whole. An undo applies whole or not at all.
    @ObservationIgnored private var ledgerGeneration = 0

    /// The one parked ask, the policy it was measured against, and the
    /// generation that keys its undo offers. All three move together or not at
    /// all, which is why they are one value and not three properties — see
    /// `SilkCore.PendingSlot`, where the staleness rule is stated and pinned.
    ///
    /// Observed, unlike the ledger's generation: Now's row, the reservation it
    /// makes and the detail card all read the pending, and they must redraw when
    /// it moves. The baseline rides inside for the reason it was held in memory
    /// in the first place — `matured` is asked three times on every body pass of
    /// Now, and each ask used to be an App Group read plus a whole `PolicyState`
    /// decode on the main thread, on every clock tick, keyboard rise and layout
    /// pass. In memory the merge is free, so the call sites can go on asking.
    private var slot: PendingSlot

    /// What is waiting, for everything that only needs to know that.
    var pendingLoosening: PolicyState? { slot.pending }
    /// Setup is complete once a policy has been persisted. Until then the app
    /// shows onboarding and holds nothing.
    private(set) var onboarded: Bool

    /// Confirmations that are not part of a conversation: a Settings commit,
    /// the App Intent's dialog-less cousins.
    /// Everything the bar is asked lands in the thread instead — a toast
    /// answers changes made elsewhere. (handoff README.md:251-252)
    let toasts = ToastCenter()

    /// The running exchange over the bar. `handle` asks here and lands here;
    /// blur clears it, because a thread is a moment, not a log.
    let conversation = ConversationModel()

    /// Which page the pager rests on. A command no longer drags the pager to
    /// Now — the reply lands in the thread over whichever page asked, and the
    /// handoff has no jump anywhere in it.
    var page = 0

    /// Which wheel is up, if any. The three global rows on Settings set this,
    /// and now the door editor's cap row does too; the backdrop tap commits and
    /// clears it. (handoff README.md §4)
    var picker: PickerKind? {
        // A wheel up is a `tighten` coming: the backdrop tap commits in the
        // same gesture that dismisses, so this is the last moment with
        // enough lead to warm the Taptic Engine for it.
        didSet { if picker != nil { Silk.Haptic.prepare() } }
    }
    /// No raw type: Swift forbids associated values on a raw-value enum, and
    /// `cap` needs to know which door. Nothing ever read the String — there is
    /// no `.rawValue` and no `PickerKind(rawValue:)` anywhere — so dropping it
    /// is free. Carrying the door in the case rather than in a parallel
    /// `var capDoor: Door?` is the point: two properties could disagree about
    /// which door is being edited after a removal, and this shape cannot.
    enum PickerKind: Equatable { case down, budget, undo, cap(Door) }

    /// A Settings row asked for its wheel. Raised through here and not by
    /// assignment from the view, for the same reason `raiseShield` exists: the
    /// overlay's curve belongs to the moment it is raised, not to a container
    /// modifier on the stage that would lend it to the pager as well.
    func raisePicker(_ kind: PickerKind) {
        withAnimation(Silk.motion(Silk.Motion.overlay)) { picker = kind }
    }

    /// The take-it-back window, in seconds. One number bounds both offers:
    /// the undo-bearing toast and the thread's Undo pill. The third Settings
    /// row edits it; 60 is the handoff's shipped value.
    private(set) var undoSeconds: Int

    /// The clock the views read instead of `.now`. Deadlines are absolute and
    /// the day turns on its own, so the screen has to be able to change with
    /// nobody touching it.
    private(set) var now: Date = .now
    @ObservationIgnored private var clock: Task<Void, Never>?

    let wall = WallController()

    init() {
        #if DEBUG
        // Debug/QA: launch with -silkReset YES to wipe state and re-onboard.
        // Release must never carry this: UserDefaults is the only persistence
        // Silk has, so wipeAll() there is unrecoverable.
        if UserDefaults.standard.bool(forKey: "silkReset") {
            SharedStore.wipeAll()
        }
        #endif
        let saved = SharedStore.loadPolicy()
        self.onboarded = saved != nil
        self.policy = saved ?? AppModel.defaultPolicy
        // Stamp before the blob it proves, as every stamp reader must
        // (`syncLedgerIfStale`, the Spend intent, DayLog.recordClosedDays).
        // Read blob-first, a SpendIntent save landing between the two — Siri
        // grant, then cold launch, causally adjacent — seats the pre-grant
        // blob under the post-grant stamp: `syncLedgerIfStale` then never
        // reloads, and the first `persist` writes the stale copy wholesale,
        // erasing the grant. Stamp-first, the worst a write in the gap yields
        // is a fresh blob under an old stamp, which the next compare reads as
        // stale and re-syncs.
        self.ledgerStamp = SharedStore.ledgerStamp()
        self.ledger = SharedStore.loadLedger()
        self.slot = PendingSlot(pending: SharedStore.loadPendingLoosening(),
                                baseline: SharedStore.loadPendingBaseline())
        self.undoSeconds = SharedStore.loadUndoSeconds()
        toasts.undoLifetime = .seconds(undoSeconds)
        // No local state means a fresh install — and possibly a previous
        // install's orphaned shield still standing. Clear it before anything
        // draws. (docs/market/gaps.md #5)
        if saved == nil {
            wall.clearOrphans()
        }
        applyPendingIfDayTurned()
        wall.reconcile()
        refreshWallStanding()
        // Re-armed on every launch rather than once, because the daemon's
        // activity list is not documented to survive everything that can
        // happen to it, and arming is a restatement (it stops before it
        // starts) rather than a second registration.
        if onboarded {
            // The anchor is recorded only for an arm that took. A throw here —
            // authorization not yet effective, the daemon's activity limit — must
            // leave the next boundary free to try again, or the failure latches.
            if wall.armHeartbeat(downHours: policy.downHours) { armedHeartbeatAnchor = policy.downHours.end }
        }
        refreshDoorIcons()
        startClock()
        #if DEBUG
        // QA: -silkPage 1 opens on Mirror. There is no other way in — the pager
        // is driven by touch, and a screenshot harness has no fingers.
        self.page = UserDefaults.standard.integer(forKey: "silkPage")
        #endif
    }

    deinit {
        clock?.cancel()
        waitTask?.cancel()
    }

    /// The end of setup — permission, apps, limits — persisted in one motion,
    /// the wall raised, and never asked again. `wallSelection` is the extras:
    /// apps blocked without a name or launch entry.
    func completeSetup(doors: [Door],
                       doorSelections: [UUID: FamilyActivitySelection],
                       wallSelection: FamilyActivitySelection,
                       budget: Int,
                       downHours: DownHours) {
        policy = PolicyState(budgetMinutes: budget, downHours: downHours, doors: doors)
        SharedStore.save(policy: policy)
        SharedStore.save(wallSelection: wallSelection)
        SharedStore.save(doorSelections: doorSelections)
        refreshDoorIcons(doorSelections)
        wall.reconcile()
        // First arming: authorization has just been granted, so this is the
        // earliest point the schedule can take. Until it fires, days record
        // as unobserved — which is honest, not a bug.
        // The anchor is recorded only for an arm that took. A throw here —
        // authorization not yet effective, the daemon's activity limit — must
        // leave the next boundary free to try again, or the failure latches.
        if wall.armHeartbeat(downHours: downHours) { armedHeartbeatAnchor = downHours.end }
        onboarded = true
    }

    static let defaultPolicy = PolicyState(
        budgetMinutes: 40,
        downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
        doors: []
    )

    // MARK: - What the screen reads

    /// The ESTABLISHED day's start — the ledger's own stamp while the day she
    /// is standing in still runs, the live boundary otherwise. Every ledger
    /// window on this screen reads it, so a mid-day "down hours end at 9am"
    /// cannot refill the hero, reopen a capped door or lift a close
    /// (`GrantLedger.effectiveDayStart` carries the rationale). The sweep in
    /// `compactLedgerIfDayTurned` reads the live boundary itself, because it
    /// is the writer of this very stamp.
    var dayStart: Date {
        ledger.effectiveDayStart(now: now, downHours: policy.downHours, calendar: .current)
    }

    var remainingMinutes: Int {
        ledger.remainingMinutes(budget: policy.budgetMinutes, dayStart: dayStart)
    }

    /// The stroke is the budget. A budget of zero has no circle to draw, which
    /// is why this reads 0 rather than clamping to something visible.
    var fractionRemaining: Double {
        guard policy.budgetMinutes > 0 else { return 0 }
        return Double(remainingMinutes) / Double(policy.budgetMinutes)
    }

    var isDownHours: Bool {
        #if DEBUG
        // QA: -silkNight YES pins the night face so the crossing can be seen
        // without waiting for 10 PM. Same shape as -silkReset; debug only.
        if UserDefaults.standard.bool(forKey: "silkNight") { return true }
        #endif
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return policy.downHours.contains(TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0))
    }

    func state(of door: Door) -> DoorState {
        ledger.state(of: door, at: now, dayStart: dayStart, cap: policy.doorCaps[door.id])
    }

    /// Five branches, not three. Down hours say nothing at all — ☾ is the whole
    /// message — and from 8 PM the greeting names the hour the wall goes up, so
    /// the evening is warned without a countdown anywhere on the screen.
    var greeting: String {
        // The prototype writes `hour >= 22 || hour < 7` as a second test, but
        // those literals are its own fixed 10 PM–7 AM window. `isDownHours` asks
        // the same question against the user's actual window, and keeping both
        // would make ☾ appear on a full day face for any narrower one.
        if isDownHours { return "☾" }
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 20 {
            // Names the real start, minutes and all — the wheels take 9:30 PM
            // as readily as 10, and "Down hours at 9." would be a lie about
            // the window the user actually set.
            let start = policy.downHours.start
            let h12 = start.hour % 12 == 0 ? 12 : start.hour % 12
            let when = start.minute == 0 ? "\(h12)" : start.display
            return "\(SilkStrings.downHoursAt) \(when)."
        }
        if hour >= 17 { return SilkStrings.goodEvening }
        if hour >= 12 { return SilkStrings.goodAfternoon }
        return SilkStrings.goodMorning
    }

    // MARK: - Mirror

    /// The closed-day records, decoded and sorted once and then held — the
    /// same bargain `weekAttemptBuckets` strikes with the attempts blob, under
    /// the counter `SharedStore.daysRevision` keeps for exactly this. Mirror's
    /// body reads `lastClosedScore`, `closedWeekScores` and `daysHeld` several
    /// times a pass and each one was a full decode and sort of the whole blob.
    ///
    /// The revision is read BEFORE the blob, as the attempts cache reads its
    /// own: a record written between the two reads then shows as a mismatch on
    /// the next tick and the cache falls, which errs toward a redundant decode
    /// rather than a stale band.
    private var dayRecords: [DayRecord] {
        if let cache = dayRecordsCache { return cache.records }
        let revision = SharedStore.daysRevision()
        let records = SharedStore.dayRecords()
        dayRecordsCache = (revision, records)
        return records
    }

    @ObservationIgnored private var dayRecordsCache: (revision: Int, records: [DayRecord])?

    /// Drop the cache when the blob's own counter says it moved — one integer
    /// read against a decode of up to a week of records. A day sealed by the
    /// Spend intent in another process is the case this exists for; nothing
    /// else can move the counter.
    private func invalidateDayRecordsIfStale() {
        if let cache = dayRecordsCache, cache.revision != SharedStore.daysRevision() {
            dayRecordsCache = nil
        }
    }

    /// **Days held** — the accumulating hero, over closed observed days only.
    ///
    /// Not yet on screen. `MirrorView` still draws `lastClosedScore`, and the
    /// swap is deliberately not made here: growth-metaphor §10 puts the
    /// re-lock device test and the daily heartbeat ahead of every drawing,
    /// and mirror-continuity §9.5 calls `DayLog.allowance` provisional until
    /// it is calibrated from a real device day. Reading it now means the
    /// records accumulate from this build forward, so the calibration has
    /// data to read when the gate opens.
    ///
    /// Repairs the shipped inversion: `100 − attempts − late` has no term for
    /// granted minutes, so the current hero is strictly higher on a day you
    /// spent than a day you resisted. This one charges a granted minute.
    var daysHeld: Int {
        DayLog.daysHeld(dayRecords)
    }

    /// A day is scored once, when it closes, so the hero prefers the last
    /// closed day and holds it. `nil` before there is a closed day to read:
    /// on a fresh install the hero showed 100 under a real weekday name, a
    /// flawless week that never happened — Mirror falls back to `todayScore`
    /// then, labelled as today, so the screen is never scoreless.
    var lastClosedScore: Int? { closedWeekScores.last ?? nil }

    /// Today's running score. The record's own equation on the live counts —
    /// a granted minute now costs what `DayRecord.fraction` will charge for it
    /// when the day closes, so the number moves the moment an unlock lands
    /// instead of flattering the day that spent. Written in stone only when
    /// the day turns.
    var todayScore: Int {
        let bucket = weekAttemptBuckets.last ?? (0, 0)
        let cal = Calendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let granted = DayLog.grantedMinutes(ledger.grants, from: dayStart, to: dayEnd)
        return DayLog.runningScore(grantedMinutes: granted,
                                   reaches: bucket.attempts, lateReaches: bucket.late,
                                   unlocks: DayLog.unlocks(ledger.grants,
                                                           from: dayStart, to: dayEnd))
    }

    /// The shipped equation (canon.md: "82 = 100 − 12 attempts − 6 late"),
    /// kept ONLY as the fallback for a closed day that has no record — a day
    /// from before the day log shipped, or one whose monitor never vouched.
    /// It has no term for granted minutes ("the shipped inversion"); a day
    /// with a record scores through `DayRecord.score` instead.
    private static func score(_ bucket: (attempts: Int, late: Int)) -> Int {
        max(0, 100 - bucket.attempts - bucket.late)
    }

    var lastClosedDayName: String {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: -1, to: dayStart) else { return "" }
        return Self.weekdayFormatter.string(from: d)
    }

    /// Mirror asks for the name on every body pass, and a fresh DateFormatter
    /// resolves an ICU template each time — real work for a word that changes
    /// once a day. Held for the process: a locale or timezone change could in
    /// principle stale it, but iOS relaunches the app for both, and that is
    /// the whole of the bargain. It is now the only formatter Mirror holds —
    /// the footnote's "MMM d" left with the lifetime key log.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// Six closed days, oldest first; today is excluded by construction. A day
    /// that ended before Silk was installed is `nil` — zero recorded attempts is
    /// not the same fact as a perfect day, and the design's rule for an unscored
    /// day is a bare seat, never a number.
    var closedWeekScores: [Int?] {
        let cal = Calendar.current
        let installed = SharedStore.firstRun()
        // One decode for the whole band — and now not even that on most
        // passes, the cache above holding it. An observed record is the day's
        // number — the equation with the granted-minutes term, frozen when
        // the day closed. The attempts bucket is only the fallback for a day
        // no record vouches for.
        let records = dayRecords
        return weekAttemptBuckets.dropLast().enumerated().map { i, bucket in
            // Bucket i covers [dayStart - (6 - i) days, +1 day).
            guard let end = cal.date(byAdding: .day, value: i - 5, to: dayStart),
                  end > installed else { return nil }
            if let start = cal.date(byAdding: .day, value: -1, to: end),
               let record = records.first(where: {
                   start <= $0.dayStart && $0.dayStart < end && $0.observed
               }) {
                return record.score
            }
            return Self.score(bucket)
        }
    }

    /// Today's unlocks: how many times a door was opened since the day began.
    ///
    /// It was the lifetime key journal ("3 · Jul 12"), and that is a number
    /// which only ever rises. Mirror is a screen where every other element is
    /// one day — the hero, the band, the ring — and a running total since
    /// install was the one thing on it that could not be acted on.
    ///
    /// Read from the ledger rather than the key journal, which changes the
    /// subject as well as the window. The journal also takes an entry on the
    /// "Tap your key." path, and a loosening is not an unlock: `keyTapped`
    /// applies a pending policy early and opens no door. Counting grants means
    /// the line now counts what its glyph has always claimed.
    ///
    /// No cache, deliberately. The old one existed because `keyJournal()`
    /// decoded a blob out of UserDefaults on every body pass; `ledger` is
    /// already in memory and already observed, so the read is free — and the
    /// three invalidation sites that could go stale leave with it.
    var unlocksToday: Int {
        ledger.unlocks(dayStart: dayStart)
    }

    // MARK: - The shield, raised from a door row

    private(set) var shield: ShieldPreview?
    struct ShieldPreview: Equatable { var title: String; var app: String }

    /// The wall fades in and never slams (canon.md), and the curve is set here
    /// rather than by an `.animation(_:value:)` on the root's stage. That
    /// modifier is not scoped to the child whose value changed: it stamps
    /// `transaction.animation` onto every descendant for the update pass, so
    /// raising the shield handed the same 0.45 to the UIPageViewController-backed
    /// pager, both GeometryReader-scaled page columns, the bar, the dots and the
    /// thread on the frame the veil was inserted. Raising an overlay is a thing
    /// the model does, so the model states what it costs.
    func raiseShield(for door: Door) {
        let raised = shieldPreview(for: door)
        withAnimation(Silk.motion(Silk.Motion.shield)) { shield = raised }
    }

    /// An open door has no wall to show. Everything else does, and what it says
    /// is a time, not an explanation.
    ///
    /// Down hours outrank both: the wall is up for everything, so the headline is
    /// the hour it comes down. (Silk Mockup.dc.html:305-308)
    private func shieldPreview(for door: Door) -> ShieldPreview? {
        if isDownHours {
            return ShieldPreview(title: "☾ \(policy.downHours.end.displayWithMeridiem)",
                                 app: door.name)
        }
        switch state(of: door) {
        case .open:
            return nil
        case .rest(let until):
            if let until {
                // Rule-bound: a stated hour holds the door, and the headline is
                // that hour — "Until 5:00", the shield's own word, not the
                // row's lowercase "till". (README.md:189)
                let t = Validator.timeOfDay(until, calendar: .current).display
                return ShieldPreview(title: "\(SilkStrings.until) \(t)", app: door.name)
            }
            // Plainly resting: the wall says the name and nothing more —
            // the same sentence the row is already not saying.
            return ShieldPreview(title: door.name, app: "")
        case .live:
            // Behind the wall with nothing scheduled: the wall says the name.
            return ShieldPreview(title: door.name, app: "")
        }
    }

    func dismissShield() {
        withAnimation(Silk.motion(Silk.Motion.shield)) { shield = nil }
    }

    /// Seven Silk-day buckets of shielded attempts, oldest first, each split
    /// into (all, late) — late being attempts inside the down-hours window,
    /// which the score counts twice. Days turn when down hours end, not at
    /// midnight, so a 1 AM attempt belongs to the day before. Bucketed here
    /// and once: `SharedStore.attempts(since:)` decodes the whole array on
    /// every call, and Mirror was asking ten times per redraw.
    private var weekAttemptBuckets: [(attempts: Int, late: Int)] {
        let start = dayStart
        if let cache = weekAttemptsCache, cache.dayStart == start { return cache.buckets }
        // Read before the blob, not after: an attempt recorded between the
        // two reads then shows as a mismatch on the next tick and the cache
        // falls, which errs toward a redundant decode rather than a stale
        // chart.
        let revision = SharedStore.attemptsRevision()
        let cal = Calendar.current
        let bounds = (0...7).compactMap { cal.date(byAdding: .day, value: $0 - 6, to: start) }
        guard bounds.count == 8 else { return Array(repeating: (0, 0), count: 7) }
        let all = SharedStore.attempts(since: bounds[0])
        let window = policy.downHours
        let buckets: [(Int, Int)] = (0..<7).map { i in
            let day = all.filter { bounds[i] <= $0 && $0 < bounds[i + 1] }
            let late = day.count {
                let c = cal.dateComponents([.hour, .minute], from: $0)
                return window.contains(TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0))
            }
            return (day.count, late)
        }
        weekAttemptsCache = (start, revision, buckets)
        return buckets
    }

    /// The revision is the attempts blob's own counter at the moment it was
    /// decoded — the tick compares it instead of deleting the cache blind.
    @ObservationIgnored private var weekAttemptsCache:
        (dayStart: Date, revision: Int, buckets: [(attempts: Int, late: Int)])?

    // MARK: - The clock

    /// Wakes at the next thing that could change the screen: a grant expiring,
    /// the day turning, or simply the next minute — deadlines are rendered to
    /// the minute, so anything finer would redraw for nothing.
    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                // Nothing strong may be held across the sleep, or the weak
                // capture buys nothing and the model outlives its owner.
                guard let wake = self?.nextWake() else { return }
                try? await Task.sleep(for: .seconds(wake.seconds))
                guard !Task.isCancelled, let self else { return }
                // A shield render can record attempts while Silk stays
                // .active — iPad Split View — so the tick cannot blindly
                // trust the cache; but a blind delete re-decoded the whole
                // attempts blob every minute for a page that mostly is not
                // Mirror. The revision is one integer read, and it moves
                // only when `recordAttempt` actually appended.
                if let cache = self.weekAttemptsCache,
                   cache.revision != SharedStore.attemptsRevision() {
                    self.weekAttemptsCache = nil
                }
                // The records blob is the same bargain under its own counter:
                // the Spend intent's sweep can seal a day in another process
                // while Silk sits on Mirror.
                self.invalidateDayRecordsIfStale()
                let ledgerMoved = self.syncLedgerIfStale()
                self.now = .now
                // The wall is re-applied only when something it enforces could
                // actually have moved. `Wall.reconcile` reads the union of the
                // selections and subtracts the doors the ledger says are open,
                // and the only inputs to that answer which change while nobody
                // touches Silk are `now` crossing a grant's expiry or a close's
                // lift (both are `nextTransition`, and the sleep is aimed at
                // them), the day boundary passing under a close (`turned`), and
                // a write from another process (`ledgerMoved`). Every local
                // write reconciles at its own commit. A wake that is none of
                // those is the plain minute, and it exists to redraw a deadline
                // — four JSON decodes and a settings-store write to change
                // nothing was the whole cost of showing the time.
                let turned = DayBoundary.dayStart(now: self.now,
                                                  downHours: self.policy.downHours)
                    != self.compactedDayStart
                // Asked of the clock this wake actually landed on, not of the
                // one it was aimed at: a sleep the system overshoots past an
                // expiry must still close that door, and a transition tested at
                // scheduling time would have said "not yet" and never asked
                // again — `nextTransition` drops a row once it is in the past.
                // Fail-closed is the only direction this may be wrong in.
                let passed = wake.transition.map { $0 <= self.now } ?? false
                guard passed || ledgerMoved || turned else { continue }
                // A grant that just expired has to close its door, and a day
                // that turned matures whatever was waiting for it.
                self.wall.reconcile()
                self.applyPendingIfDayTurned()
                self.compactLedgerIfDayTurned()
            }
        }
    }

    /// When to wake, and the instant the LEDGER wanted waking for — a grant
    /// expiring or a close lifting, as against the plain minute the deadlines
    /// are rendered to. The instant is carried across the sleep rather than
    /// resolved here, because whether it has passed is a question about the
    /// clock the tick woke on and not the one it was aimed at.
    private func nextWake() -> (seconds: Double, transition: Date?) {
        let cal = Calendar.current
        let nextMinute = cal.nextDate(after: .now, matching: DateComponents(second: 0),
                                      matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let transition = ledger.nextTransition(after: .now)
        let wake = min(nextMinute, transition ?? nextMinute)
        return (max(1, wake.timeIntervalSince(.now)), transition)
    }

    // MARK: - The bar

    /// The compile pipeline: deterministic grammar first; the on-device model
    /// widens rule-change paraphrases only; everything passes the Validator.
    ///
    /// The turn is asked before the pipeline runs and landed after it — the
    /// thread shows "…" in between. The deterministic path answers in
    /// microseconds, which reads as the machine finishing your sentence, so
    /// the reply waits out the balance of the handoff's ~480ms beat
    /// (README.md:226-228); a slow model parse has already spent it.
    func handle(_ utterance: String) async {
        // Every landing below — grant, tighten, refusal — fires a haptic at
        // least a beat after the send, and a cold Taptic Engine spins up tens
        // of milliseconds behind its visual moment. Waking it at the turn's
        // start puts the click on the beat.
        Silk.Haptic.prepare()
        let id = conversation.ask(utterance)
        let asked = ContinuousClock.now

        var outcome = DeterministicParser.parse(utterance, state: policy)
        if outcome == .silence {
            // The one unbounded leg of this function, and it is bounded now:
            // `SilkModelParser.deadline` is two seconds, after which the
            // widener answers silence and the turn lands "Didn't get that."
            // rather than drawing "…" for as long as the model feels like it.
            outcome = await SilkModelParser.shared.parse(utterance, state: policy)
        }

        let beat: Duration = .milliseconds(480)
        let elapsed = asked.duration(to: .now)
        if elapsed < beat {
            try? await Task.sleep(for: beat - elapsed)
        }

        // Validated on apply's side of the beat, ledger synced in the same
        // breath. `apply` lands this verdict exactly as computed — nothing
        // re-validates — and SpendIntent writes the App Group from its own
        // process moment, so a verdict carried across an await can debit a
        // pool another writer has already drawn down. From this sync to the
        // mutation arms there is no suspension point: validation and apply
        // read the same ledger.
        //
        // A grant is the one verdict that may not land on this pass, and
        // `landWait` states the rule this comment is the other half of: the
        // wait is time, so its verdict is stale by construction and the whole
        // sync-then-validate-then-apply run is done a second time on the far
        // side of it. Not an exception to the no-suspension-point discipline —
        // that discipline applied twice.
        syncLedgerIfStale()
        let verdict = Validator.validate(outcome, utterance: utterance,
                                         state: policy, ledger: ledger, now: .now)

        // Down hours answer everything with the hour they end
        // (Silk Mockup.dc.html:317, the first line of `reply`) — with two
        // deliberate departures, both of which `deferredByDownHours` carries. A
        // tighten still lands, because "tightening is instant from anywhere" is
        // a product rule and refusing to let someone shut a door at night would
        // be the edge yielding in the wrong direction. And a door asked for at
        // the bar is refused at seven exactly as it is at eleven, so quoting
        // the hour would send her back in the morning for nothing.
        if isDownHours, verdict.deferredByDownHours {
            conversation.land(
                refuse("\(SilkStrings.downHoursOpens) \(policy.downHours.end.displayWithMeridiem)."),
                for: id)
            return
        }
        // A grant does not land here. Its price is seconds of watching, and
        // nothing is debited, unshielded or armed until they are paid — so the
        // verdict is put down and the wait is raised over it. `raiseWait`
        // answers false for an ask too small to draw one, and that ask lands
        // below exactly as every ask did before this feature existed.
        // Two waits cannot be watched at once, and this is reachable: `handle`
        // is async, the bar stays live through a slow model parse, and a second
        // sentence sent before the first raised its veil arrives here with one
        // already standing. Overwriting it would strand the first turn at "…"
        // for good and swap the door name under a mark already being drawn.
        //
        // The second ask is dropped rather than landed. Falling through to
        // `apply` below would be the worse half of the same bug — a grant
        // debited and a door opened behind a veil, with nobody watching the
        // wait that was supposed to pay for it.
        if case .grant = verdict, waiting != nil {
            conversation.drop(id)
            return
        }

        if case .grant(let door, let minutes, _) = verdict,
           raiseWait(door: door, minutes: minutes, outcome: outcome,
                     utterance: utterance, answering: id) {
            return
        }

        let (reply, undo) = apply(verdict)
        conversation.land(reply, undo: undo, for: id)
        if undo != nil { scheduleUndoExpiry(for: id) }
    }

    // MARK: - The wait (docs/design/wait.md)

    /// The wait on screen: the clock, and the ask it is holding.
    ///
    /// One value and not four properties, for the reason `PickerKind.cap(Door)`
    /// carries its door in the case rather than in a parallel `var capDoor` —
    /// a wait and the door it will open must not be able to disagree about
    /// which door that is, and this shape cannot.
    struct Waiting: Equatable {
        var wait: Wait
        var door: Door
        /// The parse this wait is holding, kept whole so the second validation
        /// is the first one run again rather than one reassembled from its
        /// output.
        ///
        /// This is load bearing, and it cost a UI walk to learn. The Validator
        /// runs a **number-provenance check** — `NumberParser.allNumbers(in:
        /// utterance).contains(minutes)`, Validator.swift:149 — so the minutes
        /// it is asked for must be words the user actually said. But the
        /// minutes a `.grant` verdict carries are the **clamped** ones: ask for
        /// sixty against a budget of forty and the verdict says 40, which
        /// appears nowhere in "give me sixty minutes of reddit". Re-validating
        /// from the verdict therefore failed provenance and returned `.silence`
        /// — so every clamped ask in the app answered "Didn't get that." after
        /// the wait it had just been made to watch. Holding the outcome makes
        /// the second pass identical to the first by construction, and the
        /// clamp is re-applied where it belongs: against the balance as it
        /// stands when the ink lands.
        var outcome: ParseOutcome
        /// Kept verbatim for the same reason. The Validator takes the utterance
        /// for provenance, and re-deriving one here ("Instagram 20") would hand
        /// it a sentence the user never said.
        var utterance: String
        /// The turn in the thread this wait will answer when the ink lands.
        var turn: ConversationModel.Turn.ID
    }

    private(set) var waiting: Waiting?

    /// The one timer in the feature, and it does not draw anything: it sleeps
    /// out the watching still owed and lands the grant. The *surface* redraws
    /// itself from a pure function of the clock, so this task can be cancelled
    /// and re-armed on every pause and resume without a frame knowing.
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    /// Seconds of watching an ask costs. The curve lives in the spine, where it
    /// is tested; this is only the debug seam over it.
    static func waitLength(forMinutes minutes: Int) -> TimeInterval {
        #if DEBUG
        // QA: -silkWait 0.6 pins the wait so a UI walk is not priced off the
        // product curve, and -silkWait 0 turns the feature off entirely. Same
        // shape as -silkNight and -silkPage, and debug-only for the same
        // reason: a launch argument that shortens a self-control price has no
        // business existing in a shipped build.
        if let pinned = UserDefaults.standard.string(forKey: "silkWait").flatMap(Double.init) {
            return max(0, pinned)
        }
        #endif
        return Wait.length(forMinutes: minutes)
    }

    /// How long a parked wait survives being ignored. The rule lives in the
    /// spine; this is only the debug seam over it, so a walk can prove the
    /// abandonment path without standing still for two minutes.
    static var waitStaleAfter: TimeInterval {
        #if DEBUG
        if let pinned = UserDefaults.standard.string(forKey: "silkStale").flatMap(Double.init) {
            return max(0, pinned)
        }
        #endif
        return Wait.staleAfter
    }

    /// Raise the wait over a granted ask. False when there is no wait to draw,
    /// which is the caller's signal to land the grant the old way.
    private func raiseWait(door: Door, minutes: Int, outcome: ParseOutcome,
                           utterance: String,
                           answering turn: ConversationModel.Turn.ID) -> Bool {
        // Priced off the minutes she will actually be GIVEN, not the ones she
        // said: an over-ask of sixty against a balance of forty buys forty, and
        // charging the wait for sixty would charge for minutes that do not
        // exist. The spoken number survives inside `outcome`, which is what the
        // second validation needs — see `Waiting.outcome`.
        let length = Self.waitLength(forMinutes: minutes)
        guard Wait.isWorthDrawing(length) else { return false }

        var wait = Wait(doorID: door.id, minutes: minutes, length: length)
        // Watching starts here — but only if there is actually someone here.
        //
        // This does NOT run on the frame the sentence was sent. `handle` is
        // async and suspends twice before it reaches this line: once on the
        // model parse, which can take seconds, and once on the deliberate
        // 480 ms beat. Swiping home inside that window backgrounds Silk while
        // the wait is still unborn, so `pauseWait` finds `waiting == nil` and
        // does nothing, and a watching span opened here would then run for the
        // whole time she is away — `ContinuousClock` counts through process
        // suspension by design. She comes back an hour later, the veil flashes,
        // and the door opens on zero seconds watched. That is the exact bypass
        // the attention gate exists to refuse, and `pausedAt` staying nil means
        // staleness would not have caught it either.
        //
        // So a wait born in the background is born PARKED: watched, then
        // immediately looked away from, which banks nothing and stamps
        // `pausedAt` so the two-minute window governs it from the start.
        wait.watch(from: Monotonic.reading)
        if UIApplication.shared.applicationState == .background {
            wait.lookAway(at: Monotonic.reading, wallClock: .now)
        }

        // The minute clock stands down for the duration. Its wake syncs the
        // ledger, reconciles the wall (four App Group decodes and a
        // cross-process ManagedSettings write) and runs two day-turn sweeps,
        // all on the MainActor — a multi-frame hitch dropped into the one
        // screen in Silk that is nothing but motion. The one thing behind the
        // veil that still reads `now` is the day/night face, which cannot cross
        // inside twenty seconds without having been about to cross anyway, and
        // the cost of standing the clock down is that a grant expiring during
        // these seconds closes up to twenty seconds late. The re-lock schedules
        // are what actually close it, and `RelockWindow` already states the
        // rule this leans on: late, never never.
        clock?.cancel()

        withAnimation(Silk.motion(Silk.Motion.overlay)) {
            waiting = Waiting(wait: wait, door: door, outcome: outcome,
                              utterance: utterance, turn: turn)
        }
        armWaitLanding()
        return true
    }

    /// Sleep out the watching still owed, then land. Re-armed from scratch on
    /// every resume, because the amount owed is only knowable then.
    private func armWaitLanding() {
        waitTask?.cancel()
        waitTask = nil
        guard let wait = waiting?.wait, wait.isWatching else { return }
        let owed = max(0, wait.length - wait.watched(at: Monotonic.reading))
        waitTask = Task { [weak self] in
            // The same clock the surface draws on and the same one `Wait`
            // measures with — `Task.sleep(for:)` is ContinuousClock — so the
            // ink and the landing cannot drift apart.
            try? await Task.sleep(for: .seconds(owed))
            guard !Task.isCancelled else { return }
            self?.landWait()
        }
    }

    /// She left. The ink stops where it is, and the landing is disarmed with
    /// it: a task left sleeping would open the door while Silk was in the
    /// background, which is the one thing the attention gate exists to forbid.
    func pauseWait() {
        waitTask?.cancel()
        waitTask = nil
        guard var w = waiting?.wait, w.isWatching else { return }
        w.lookAway(at: Monotonic.reading, wallClock: .now)
        waiting?.wait = w
    }

    /// An ask whose answer is never coming: the turn goes, and so does the dim
    /// it was being read over.
    ///
    /// Dropping the turn alone was not enough, and the state it left was the
    /// worst-looking screen in the feature. The stage dims on
    /// `conversation.focused`, the wait deliberately suppresses the blur that
    /// would clear it (the turn is still in flight, and the reply has to have
    /// somewhere to land), and `barFocused` is already false — so nothing was
    /// left that could turn the dim off. She came back to a blurred, five-
    /// percent-opacity page with an empty thread over it: recoverable in one
    /// tap, and indistinguishable from a broken app until she made it.
    private func dropAsk(_ turn: ConversationModel.Turn.ID) {
        conversation.drop(turn)
        // Clears the thread and lifts the stage in one move — there is nothing
        // left in it to preserve. Through `blur()` rather than by writing the
        // shadow, so that a SECOND turn still in flight keeps the dim it is
        // being read over: this path drops one ask, and a teardown that took
        // another turn's receipt with it would be the bug `blur()` exists for,
        // arriving through the one door that used to bypass it.
        conversation.blur()
    }

    /// She is back. A wait she left long enough ago is gone; the rest resume
    /// from exactly where they stopped.
    func resumeWait() {
        guard let waiting else { return }
        if waiting.wait.isStale(at: .now, after: Self.waitStaleAfter) {
            dropAsk(waiting.turn)
            clearWait()
            return
        }
        var w = waiting.wait
        w.watch(from: Monotonic.reading)
        self.waiting?.wait = w
        armWaitLanding()
    }

    /// Lower the veil and put the clock back up. Nothing else: every path that
    /// ends a wait decides for itself what to say, because they do not agree.
    private func clearWait() {
        waitTask?.cancel()
        waitTask = nil
        withAnimation(Silk.motion(Silk.Motion.overlay)) { waiting = nil }
        startClock()
    }

    /// The ink landed. Ask the second question and act on its answer.
    ///
    /// The verdict computed before the wait is stale by construction — a wait
    /// is time, and a budget, a day boundary and the down-hours edge are all
    /// made of time. So the whole run is done again: sync, validate, apply.
    /// She can be answered differently than she would have been six seconds
    /// ago, and that is the edge holding at the last possible moment rather
    /// than the first. Under the other ordering she would be holding a live
    /// grant that outlived the aperture closing, which is the fail-open shape
    /// rule 4 forbids.
    private func landWait() {
        guard let waiting else { return }
        // Never from the background. The sleep's continuation and the scene
        // phase change are two separate jobs on this actor, so a departure at
        // the last instant can let the landing win the race — and the landing
        // debits minutes, drops the wall and calls `UIApplication.open` from an
        // app on its way out. Park it instead and let her return finish it: the
        // door opens on a frame she is present for or it does not open.
        guard UIApplication.shared.applicationState != .background else {
            pauseWait()
            return
        }
        // The clock is the authority, never the task: `Task.sleep` promises no
        // more than "at least this long", and a wait that has been paused and
        // resumed has been re-armed off a recomputed remainder more than once.
        // Re-arm rather than return — returning with the veil up and nothing
        // running to bring it down is the one failure this screen may not have.
        // (`armWaitLanding` no-ops on a parked wait, which is correct: the
        // resume re-arms it.)
        guard waiting.wait.isOver(at: Monotonic.reading) else {
            armWaitLanding()
            return
        }
        clearWait()

        // The door could have been removed from Settings in the seconds she
        // watched — the veil covers Settings, but a Shortcut cannot be covered.
        // Checked here rather than left to the Validator, which would answer a
        // deleted door with "Didn't get that." — true of the sentence, and a
        // lie about what happened.
        guard policy.doors.contains(where: { $0.id == waiting.door.id }) else {
            dropAsk(waiting.turn)
            return
        }

        syncLedgerIfStale()
        now = .now
        // The parse she made, validated again — not a command rebuilt from the
        // first verdict. `Waiting.outcome` states what that cost to learn.
        let verdict = Validator.validate(waiting.outcome, utterance: waiting.utterance,
                                         state: policy, ledger: ledger, now: .now)

        // Down hours can have begun while she watched, and they answer
        // everything with the hour they end — the same branch `handle` runs,
        // for the same reason, on the far side of the wait.
        if isDownHours, verdict.deferredByDownHours {
            conversation.land(
                refuse("\(SilkStrings.downHoursOpens) \(policy.downHours.end.displayWithMeridiem)."),
                for: waiting.turn)
            return
        }

        let (reply, undo) = apply(verdict)
        conversation.land(reply, undo: undo, for: waiting.turn)
        if undo != nil { scheduleUndoExpiry(for: waiting.turn) }
    }

    /// A landed offer is withdrawn when the undo window shuts. The pill goes
    /// quietly; the reply stands. Nothing to cancel and nothing to race: an
    /// undone or blurred-away turn expires into a no-op.
    private func scheduleUndoExpiry(for id: ConversationModel.Turn.ID) {
        let window = undoSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            self?.conversation.expireUndo(id)
        }
    }

    /// Replies are composed here, from the verdict the Validator already produced
    /// — never generated. The model's job is parsing; if it also wrote the reply,
    /// the sentence would no longer be checkable against the policy that ran.
    ///
    /// Everything that changed state hands back the way back beside the words:
    /// the ledger is a value, so undo is the prior value restored wholesale —
    /// no diffing, no knowledge of what the turn did (README.md:303-304). The
    /// closure reports whether the restore landed: an offer can expire under
    /// the pill (any later ledger mutation retires it), and the thread must
    /// not write "Put back." over a restore that never happened.
    private func apply(_ verdict: Verdict) -> (reply: String, undo: (() -> Bool)?) {
        switch verdict {
        case .silence:
            return (refuse(SilkStrings.didntGetThat), nil)

        case .status(let remaining):
            return (status(remaining: remaining), nil)

        case .downHours(let window):
            // A question, not a change: the window read back whole.
            return (window.runText, nil)

        case .refuseNothingLeft:
            return (refuse("0 \(SilkStrings.leftToday)."), nil)

        case .refuseDownHours(let until):
            return (refuse("\(SilkStrings.downHoursOpens) \(until.displayWithMeridiem)."), nil)

        case .refuseSayHowManyMinutes:
            return (refuse(SilkStrings.howLong), nil)

        case .refuseSayAmOrPm(let at):
            // Nothing moved, so there is nothing to take back — the whole
            // reply is the question, and the next sentence answers it.
            return (refuse(SilkStrings.amOrPm(at)), nil)

        case .refuseDoorNeedsApp:
            // A door is a name and an app; the bar can only carry the name.
            return (refuse(SilkStrings.addInSettings), nil)

        case .refuseDoorClosed(let door, let until):
            // Byte-identical to the sentence the `.close` branch below speaks,
            // because it is the same fact: this door, until this hour. The bare
            // "0 left today." it replaces was a lie whenever the pool still had
            // minutes in it — which, once a door can run out on its own, is the
            // ordinary case.
            let t = Validator.timeOfDay(until, calendar: .current)
            return (refuse(SilkStrings.closedUntil(door.name, until: t)), nil)

        case .restated(let door, let until):
            // The ask was already covered, so nothing was debited and nothing
            // moved — no haptic, and no way back to offer. The row's own form,
            // said out loud: "TikTok till 4:52."
            //
            // But the app still opens. She asked for the door, the wall is
            // genuinely down behind it, and rule 1 ends "the app opened" — this
            // is the ordinary "I'm back, let me in" sentence, said a second time
            // inside a grant she already paid for. Before this case existed it
            // reached the `.grant` arm and launched; answering it with a
            // deadline and leaving her in Silk to find the app by hand would be
            // a regression for every user, capped or not.
            let t = Validator.timeOfDay(until, calendar: .current).display
            LaunchCatalog.open(doorName: door.name)
            return ("\(door.name) \(SilkStrings.till.lowercased()) \(t).", nil)

        case .close(let door, let until):
            // The Validator already resolved the lift — a stated hour's next
            // occurrence, or the day boundary — and the sentence states it.
            syncLedgerIfStale()
            let previous = ledger
            // The offer is keyed to the generation this close will land as:
            // `persist` bumps once for a riding mutation, so +1 is this
            // turn's own landing on the clean path — and any second movement
            // (a reload folding in an external write, any later mutation)
            // leaves the offer expired. Every later mutation expires every
            // earlier offer; an undo applies whole or not at all.
            let generation = ledgerGeneration + 1
            // The mutation rides to `persist` as a closure so a stamp
            // mismatch there re-applies it over the freshly reloaded ledger:
            // a tighten the user has been answered for is never dropped.
            let close: (inout GrantLedger) -> Void = { $0.closeDoor(door, at: .now, until: until) }
            close(&ledger)
            // Fired off the mutation, not off the write. The door is shut the
            // instant the line above runs — `persist` re-applies the closure
            // over any reload, so there is no path where this lands and the
            // close does not — and the tap belongs to the moment it shut, not
            // to the far side of a settings-store write.
            Silk.Haptic.tighten()
            commit(reapplying: close)
            let t = Validator.timeOfDay(until, calendar: .current)
            return (SilkStrings.closedUntil(door.name, until: t),
                    restore(previous, ifStill: generation))

        case .closeAll(let doors, let until):
            // Every door, one lift, one sentence — and one way back.
            syncLedgerIfStale()
            let previous = ledger
            // Keyed to this turn's own landing, exactly as `.close` explains.
            let generation = ledgerGeneration + 1
            let closeAll: (inout GrantLedger) -> Void = { fresh in
                for door in doors {
                    fresh.closeDoor(door, at: .now, until: until)
                }
            }
            closeAll(&ledger)
            Silk.Haptic.tighten()   // off the mutation, as `.close` explains
            commit(reapplying: closeAll)
            let t = Validator.timeOfDay(until, calendar: .current)
            return (SilkStrings.closedUntil(SilkStrings.everything, until: t),
                    restore(previous, ifStill: generation))

        case .grant(let door, let minutes, let relockAt):
            syncLedgerIfStale()
            let previous = ledger
            // Keyed to this turn's own landing, exactly as `.close` explains.
            let generation = ledgerGeneration + 1
            let grant = Grant(door: door, minutes: minutes, issuedAt: .now, expiresAt: relockAt)
            let record: (inout GrantLedger) -> Void = { $0.record(grant) }
            record(&ledger)
            // The door is open in memory here, and this is the landing frame —
            // the veil starts its fall and the phone is handed to the granted
            // app. The tap goes with the opening, ahead of the write and the
            // arming, for the reason `.close` gives: `persist` re-applies the
            // closure over any reload, so nothing between here and the return
            // can leave the haptic describing a grant that did not land.
            Silk.Haptic.grant()
            commit(reapplying: record)
            // Off the committed ledger, not off `relockAt`: `commit` may have
            // reloaded and re-applied over another process's write, and a door
            // that already had a longer grant running keeps ITS deadline.
            restateRelockLayers(for: door)
            // Every unlock is an exception spent, so the journal takes one
            // here, at the landing, not only on the key-tap path. Sanil's call
            // (2026-08-25): the counter must visibly rise each time an unlock
            // is used. The counter is no longer read from here — the footnote
            // counts today's grants off the ledger, which needs no write at
            // all — but the journal keeps the entry as a record.
            //
            // Synchronous on purpose, even though nothing reads it here: the
            // next line hands the phone to the granted app, and a hop to the
            // next turn of this actor's loop is a hop that may never come
            // before the scene suspends. A dropped entry is the record going
            // missing on the one path it exists for.
            SharedStore.recordKeyUse()
            LaunchCatalog.open(doorName: door.name)
            return ("\(door.name) \(SilkStrings.isOpenFor) \(minutes) \(SilkStrings.minutes).",
                    { [weak self] in
                        guard let self else { return false }
                        // The check syncs first: an external write not yet
                        // observed expires the offer, it does not slip past
                        // it — and any mutation since this turn's own has
                        // already moved the generation. An undo applies
                        // whole or not at all, and says so: false is "the
                        // offer expired; nothing was put back".
                        self.syncLedgerIfStale()
                        guard self.ledgerGeneration == generation else { return false }
                        self.ledger = previous
                        self.commit()
                        // The restore rides `persist` with no mutation on
                        // purpose — it must never be re-applied over a
                        // reloaded ledger — so an unmoved generation is the
                        // landing receipt: a same-instant external write
                        // makes `persist` reload instead of write (the
                        // generation moves again), and the grant that reload
                        // restores must keep its timers.
                        guard self.ledgerGeneration == generation else { return false }
                        // The landed restore is itself a ledger mutation:
                        // the generation moves so every other offer expires.
                        self.ledgerGeneration += 1
                        // The re-lock timers were armed for a grant that no
                        // longer exists, so they have to be re-stated against
                        // the ledger that is back — but only for a restore
                        // that landed. Re-stated and not simply disarmed: the
                        // two names are keyed by door, and `previous` can still
                        // hold an EARLIER grant on this one, live and unshielded
                        // (a second ask extends a running door rather than
                        // replacing it). Clearing them outright there left that
                        // grant with no layer at all — the door stayed open past
                        // its own expiry until Silk was next opened by hand.
                        self.restateRelockLayers(for: door)
                        return true
                    })

        case .ruleChange(let proposed, let polarity):
            if polarity == .unchanged {
                // Nothing moved, so there is no receipt to give — but every
                // branch of the design's reply table says something, and a
                // screen that does not move is indistinguishable from a
                // dropped command. State what is true instead.
                return (receipt(for: policy, movedFrom: policy), nil)
            }
            return enact(proposed, polarity)
        }
    }

    /// One rule change, wherever it was asked — a sentence at the bar or a
    /// wheel on Settings — so the polarity rule cannot be sidestepped by
    /// choosing the door you knock on: a tighten lands now with the way back
    /// offered; a loosening waits for tomorrow, or the key.
    private func enact(_ proposed: PolicyState, _ polarity: Polarity) -> (reply: String, undo: (() -> Bool)?) {
        switch polarity {
        case .unchanged:
            return (receipt(for: policy, movedFrom: policy), nil)

        case .tighten:
            // The undo window to take it back. Undo restores the prior values
            // directly rather than proposing them: routing a reversal through
            // the polarity engine would read as a loosening and defer to
            // tomorrow, which is the opposite of what Undo means.
            let previous = policy
            // Which doors this change drops is read from the state diff, never
            // from the words — the same discipline polarity itself is held to.
            let dropped = policy.doors.filter { door in
                !proposed.doors.contains { $0.id == door.id }
            }
            // Kept for the way back, and only read when there is one: a budget
            // or window tighten drops nothing and has no reason to decode the
            // whole selections dictionary.
            let droppedSelections: [UUID: FamilyActivitySelection] = dropped.isEmpty ? [:]
                : SharedStore.loadDoorSelections().filter { id, _ in
                    dropped.contains { $0.id == id }
                }
            // A door dropped at the bar has to leave the way it leaves the
            // editor, and it did not: the re-lock layers stayed armed for a
            // door that no longer exists, and `commit` only wrote the policy
            // and re-applied the wall — which unions every stored selection
            // with no policy filter, so the dropped door's app stayed shielded
            // with no row, no grant path and no Settings entry until a wipe.
            // `commit` retires the selection now; the timers are this branch's.
            for door in dropped { wall.stopMonitoring(door: door) }
            policy = proposed
            commit()
            Silk.Haptic.tighten()
            return (receipt(for: proposed, movedFrom: previous), { [weak self] in
                guard let self else { return false }
                // Undo puts back what this turn changed and nothing else. The
                // window runs up to five minutes with Settings usable
                // underneath, so restoring the whole prior state would silently
                // destroy a door added — or a budget moved — in between, and a
                // door destroyed that way now loses its app off the wall too,
                // because the commit below retires the selection of any door
                // the policy no longer holds. (Settings' own removal undo is
                // surgical for the first half of that reason.)
                //
                // AND ONLY WHILE THIS TURN'S OWN VALUE IS STILL STANDING.
                // "Somewhere else" was never the only other hand: a later
                // sentence can move the SAME field, and then putting back is
                // not undoing this turn, it is overwriting a newer one. Say
                // "budget 30" and then, inside the window, "budget 20", and
                // tapping the older pill wrote 40 over the live 20 — a
                // LOOSENING applied instantly, which canon forbids (saying
                // "budget 40" out loud would have parked until tomorrow) — and
                // it destroyed the second tighten with no receipt, while the
                // second turn's pill still stood offering to put back 30. Same
                // shape for the night window, and `Caps.restoring` now states
                // the same rule for ceilings where a test can reach it.
                //
                // The interleaved variant is the same defect arriving faster:
                // one sentence on the widener's path and one on the grammar's
                // land in the opposite order from the one they were typed in.
                //
                // The ledger path has had `ledgerGeneration` for this since it
                // shipped; the policy path was waived, and this is the waiver
                // being paid.
                var restored = self.policy
                var restoredSomething = false
                if proposed.budgetMinutes != previous.budgetMinutes,
                   self.policy.budgetMinutes == proposed.budgetMinutes {
                    restored.budgetMinutes = previous.budgetMinutes
                    restoredSomething = true
                }
                if proposed.downHours != previous.downHours,
                   self.policy.downHours == proposed.downHours {
                    restored.downHours = previous.downHours
                    restoredSomething = true
                }
                // Per key, for the same reason the budget and window clauses are
                // per field: the window runs up to five minutes with Settings
                // usable underneath, so a wholesale restore would erase a cap
                // set on a different door in between. `Caps.restoring` states
                // that rule where it can be tested; here it is one call.
                let caps = Caps.restoring(previous.doorCaps, over: proposed.doorCaps,
                                          into: restored.doorCaps)
                restored.doorCaps = caps.caps
                restoredSomething = restoredSomething || caps.changed
                var selections = SharedStore.loadDoorSelections()
                var returning: [Door] = []
                for door in dropped {
                    // The same yield the editor's undo performs: the same door
                    // cannot come back twice, and a name re-added meanwhile —
                    // or a roster refilled to the cap — keeps its seat.
                    guard !restored.doors.contains(where: { $0.id == door.id }),
                          DoorRoster.canAdd(door.name,
                                            taken: restored.doors.flatMap(\.spokenForms),
                                            count: restored.doors.count) else { continue }
                    let seat = previous.doors.firstIndex { $0.id == door.id }
                    restored.doors.insert(door, at: min(seat ?? restored.doors.count,
                                                        restored.doors.count))
                    // A door comes back with its app or not at all: a name
                    // restored alone parses and launches and can never be
                    // excepted from the wall.
                    selections[door.id] = droppedSelections[door.id]
                    returning.append(door)
                }
                // Closing the closure: a cap restored above for a door the yield
                // refused to bring back would be an orphan nothing can remove.
                // One line makes the rule structural rather than remembered.
                restored.doorCaps = restored.owned(restored.doorCaps)
                self.policy = restored
                if !returning.isEmpty { SharedStore.save(doorSelections: selections) }
                self.commit()
                for door in returning { self.restateRelockLayers(for: door) }
                // A policy restore CAN expire, and this is how it says so. The
                // per-field surgery above no longer "always has something true
                // to put back": a later turn that moved the same field owns it
                // now, and every clause declines rather than writing a value
                // nobody asked for. When they all decline there is nothing to
                // report, and `ConversationModel.undo` answers that by dropping
                // the pill and LEAVING THE REPLY — the sentence keeps stating
                // what actually happened, and the turn is not marked undone,
                // because it was not. Exactly what the ledger's own offers have
                // always done under `ledgerGeneration`.
                return restoredSomething || !returning.isEmpty
            })

        case .loosen:
            // Applies at the next day start — or now, with the key. Undo here
            // withdraws the ask and puts back whatever was already waiting; it
            // is offered in the thread, where a sentence was said, and NOT on
            // the Settings toast, which offers the key instead (see `settle`).
            //
            // There is exactly ONE pending slot, and the decision recorded here
            // is that the newest ask replaces the waiting one — silently, with
            // no receipt: parking a second loosening discards the first, each
            // reply names only its own ask, and Now's row then names only the
            // survivor. That was tolerable while three dimensions could
            // be parked and no gesture chained them; caps take it to 3 + N (up
            // to nine) and make chaining ordinary — park a raise on TikTok, then
            // clear the cap on Instagram, and the first ask is gone. Knowingly
            // unfixed (spec §6.9); surfacing the displacement in the reply is
            // the recommended follow-up, and PR 4 lists it under Build status in
            // `docs/design/README.md`.
            //
            // What is NOT left standing is the second loss that hid behind it.
            // The offer below used to restore blind, so tapping a displaced one
            // put back this park's predecessor and DELETED the newer ask on top
            // of it — two losses in one tap, under a pill that then wrote "Put
            // back." `PendingSlot`'s generation is what closes that.
            let previous = slot.pending
            // The baseline travels with the pending: at maturity it is the only
            // way to tell which of the four fields the sentence actually moved.
            // Undo puts back the withdrawn pending's own baseline, not this one.
            let previousBaseline = slot.baseline
            // Keyed to this park's own generation, exactly as a ledger undo is
            // keyed to its mutation's. Any later park expires this offer.
            let generation = park(proposed, baseline: policy)
            // The one haptic on this path, and it is the warning rather than the
            // impact. `tighten()`'s rigid thump is the feel of a rule landing,
            // and nothing landed here — saying so with the same tap would make
            // the two states physically identical, which is most of why clearing
            // a cap reads as broken. `grant()`'s success is worse: it is the feel
            // of "you have it", and she does not. `refusal()` is the two-beat
            // warning Silk already fires when an edge holds, and rule 3 is an
            // edge holding — the softest one it has, because it names a day
            // rather than a no. Three haptics still, and no fourth.
            Silk.Haptic.refusal()
            // Named, not a constant. `pendingSummary` is the same call Now's row
            // makes, so the receipt and the row cannot disagree about what is
            // waiting; the composition is `SilkStrings.parked`, in the spine
            // where it is pinned.
            return (SilkStrings.parked(pendingSummary(proposed)), { [weak self] in
                guard let self else { return false }
                // An undo applies whole or not at all. A second loosening parked
                // in the meantime — the window runs to five minutes — has
                // displaced this one, and putting back this ask's predecessor
                // would delete that newer ask on top of restoring something
                // nobody asked for. The offer expires instead, and reports it,
                // so the thread does not write "Put back." over a park that
                // never happened.
                guard self.slot.stands(generation) else { return false }
                self.park(previous, baseline: previousBaseline)
                return true
            })
        }
    }

    /// The close way back: the prior ledger, restored wholesale — but only
    /// while the live value still descends from the snapshot. Any ledger
    /// movement in between — a reload folding in an external writer's grant,
    /// or a later turn's own mutation — means the live ledger holds a write
    /// the snapshot does not, and restoring it then is the same clobber a
    /// stale persist would be. The offer expires instead — and the check
    /// syncs first, so an external write not yet observed expires the offer
    /// too; it does not slip past it.
    ///
    /// Returns whether the restore landed, because the receipt must not lie:
    /// the caller says "Put back." only over a ledger that was actually put
    /// back — an expired offer reports false and the pill just goes.
    private func restore(_ previous: GrantLedger, ifStill generation: Int) -> () -> Bool {
        { [weak self] in
            guard let self else { return false }
            self.syncLedgerIfStale()
            guard self.ledgerGeneration == generation else { return false }
            self.ledger = previous
            self.commit()
            // The restore rides `persist` with no mutation on purpose — it
            // must never be re-applied over a reloaded ledger — so an unmoved
            // generation is the landing receipt: a same-instant external
            // write makes `persist` reload instead of write, the generation
            // moves, and the restore did not land.
            guard self.ledgerGeneration == generation else { return false }
            // The landed restore is itself a ledger mutation: the generation
            // moves so every other outstanding offer expires.
            self.ledgerGeneration += 1
            return true
        }
    }

    // MARK: - Settings, and the wheels

    /// The three global rows' serif slots, composed here because the model
    /// owns the clock and the composition rules. The window string is
    /// SilkCore's own aperture line — separator, nbsp and en dash included.
    var settingsDownHours: String { policy.downHours.apertureText }

    var settingsBudget: String {
        "\(policy.budgetMinutes) \(SilkStrings.minutes) \u{00B7} \(SilkStrings.perDay)"
    }

    var settingsUndo: String { Self.undoText(seconds: undoSeconds) }

    /// "60 s" below two minutes, "2 min" from there — the wheel's own table
    /// speaks this way (README.md:177), and the row must read back what the
    /// wheel would show.
    static func undoText(seconds: Int) -> String {
        seconds < 120 ? "\(seconds) s" : "\(seconds / 60) \(SilkStrings.minutes)"
    }

    /// The app icon behind each door, for the detail card's header — the door's
    /// one bound application, or nothing.
    ///
    /// A **stored** property, and that is the whole design of it. `@Observable`
    /// tracks storage, and the selections do not live in storage this class owns:
    /// they live in an App Group blob that nothing observes. A computed accessor
    /// reading `SharedStore.loadDoorSelections()` would therefore be read once,
    /// when the card was built, and never re-read — the card would go on showing
    /// the previous app's icon for as long as it stayed up after a rebind, which
    /// is the one moment the icon exists to prove anything at all. Refreshed
    /// wherever the pair (policy, selections) is written: `init`, `completeSetup`,
    /// `commit` and `commitDoorChange`, which between them are every path a
    /// binding can arrive or leave by.
    private(set) var doorIcons: [UUID: ApplicationToken] = [:]

    /// Keyed by door and not by selection, so a selection whose door has gone
    /// cannot leave an icon behind. Callers that have just written the dictionary
    /// hand it in; only the caller that genuinely has to — a cold `init`, which
    /// has written nothing — pays for a decode. Never called from a body pass.
    private func refreshDoorIcons(_ selections: [UUID: FamilyActivitySelection]? = nil) {
        let selections = selections ?? SharedStore.loadDoorSelections()
        doorIcons = policy.doors.reduce(into: [:]) { icons, door in
            icons[door.id] = selections[door.id]?.applicationTokens.first
        }
    }

    /// One door's ceiling, said the way the card must say it — through
    /// `Caps.settingsValue(cap:)`, the same call `settingsDoors` makes, so the
    /// card and the row and the wheel cannot drift apart. The spine pins the
    /// round trip (`CapsTests`); nothing here formats minutes.
    func settingsCap(for door: Door) -> String {
        Caps.settingsValue(cap: policy.doorCaps[door.id])
    }

    /// One row per door. Settings is the rules; Now's list is the day. So the
    /// value is the door's own ceiling — or the wheel's No-cap seat when it has
    /// none, because the row must read back what the wheel would show (the same
    /// round-trip rule the undo row states just above). Printing
    /// `policy.budgetMinutes` on every row made one column mean two things the
    /// moment one door had a cap: four rows reading "40 min" and one reading
    /// "20 min" is an allocation summing to 140 against a budget of 40, which is
    /// the model this feature is not. The `.rest` → "closed" branch goes with
    /// it: a rule has no today, and a capped door that spent its cap would
    /// otherwise hide its own cap on the one page whose job is to show it,
    /// precisely on the day it bit.
    var settingsDoors: [SettingsDoorItem] {
        policy.doors.map {
            SettingsDoorItem(name: $0.name, value: Caps.settingsValue(cap: policy.doorCaps[$0.id]))
        }
    }

    /// The wheel tables' backing values, in the same order as the strings in
    /// `WheelValues` — the picker renders those verbatim, and these map the
    /// committed indices back out. (README.md:174-177)
    private static let budgetTable = [15, 30, 45, 60, 75, 90, 120]        // minutes
    private static let undoTable = [15, 30, 60, 90, 120, 300]             // seconds
    private static let downStartTable = (0..<8).map { 20 * 60 + $0 * 30 } // 8:00 PM…11:30 PM
    private static let downEndTable = (0..<8).map { 5 * 60 + $0 * 30 }    // 5:00 AM…8:30 AM

    /// A stored value said at the bar can sit between wheel seats ("budget of
    /// 50"), so the wheel opens on the nearest one rather than crashing or
    /// snapping to the top. The cap table and its seat arithmetic live in
    /// `SilkCore.Caps`, where the +1 No-cap offset can be asserted in a tenth of
    /// a second; this is the same helper, shared so there is one of it.
    private static func nearestIndex(to value: Int, in table: [Int]) -> Int {
        Caps.nearestIndex(to: value, in: table)
    }

    func pickerTitle(for kind: PickerKind) -> String {
        switch kind {
        case .down: SilkStrings.downHours
        case .budget: SilkStrings.budget
        case .undo: SilkStrings.undo
        // The door's own name, exactly as the editor's title carried it — the
        // editor is taken down before this wheel goes up, so this title is the
        // only thing left saying which door is being capped.
        case .cap(let door): door.name
        }
    }

    func pickerColumns(for kind: PickerKind) -> [WheelColumn] {
        switch kind {
        case .down:
            // Two wheels side by side — start then end (README.md:169).
            [WheelColumn(id: "down.start", values: WheelValues.downStart,
                         selected: Self.nearestIndex(to: policy.downHours.start.minutes,
                                                     in: Self.downStartTable)),
             WheelColumn(id: "down.end", values: WheelValues.downEnd,
                         selected: Self.nearestIndex(to: policy.downHours.end.minutes,
                                                     in: Self.downEndTable))]
        case .budget:
            [WheelColumn(id: "budget", values: WheelValues.budgets,
                         selected: Self.nearestIndex(to: policy.budgetMinutes,
                                                     in: Self.budgetTable))]
        case .undo:
            [WheelColumn(id: "undo", values: WheelValues.undos,
                         selected: Self.nearestIndex(to: undoSeconds,
                                                     in: Self.undoTable))]
        case .cap(let door):
            // Seat 0 is "No cap", so a capped door opens one seat past its
            // nearest minute — the same off-by-one `commitPicker` undoes.
            [WheelColumn(id: "cap", values: WheelValues.caps,
                         selected: Caps.wheelSeat(for: policy.doorCaps[door.id]))]
        }
    }

    /// The backdrop tap: commit and close in one gesture. Budget, window and a
    /// door's cap go through `enact` — the same path a sentence takes — so the
    /// polarity rule holds from Settings too: a tighten lands now with Undo on
    /// the toast, a loosening names what it parked ("Tomorrow: Reddit no cap")
    /// and offers the key beside it. The undo window is not a policy, so it
    /// commits directly and quietly: the row reading the new value is its own
    /// receipt.
    ///
    /// `picks` is nil when the wheel was never moved. Looking at a wheel must
    /// cost nothing: the backdrop tap is the overlay's only exit, so a dismissal
    /// and a commit are the same gesture — and `nearestIndex` opens an off-grid
    /// value on its nearest seat, so leaving without touching anything would
    /// write that seat. A budget of 35 opens on "30 min" and would silently
    /// become 30; a cap of 25 opens on "20 min" and would silently tighten,
    /// answered by nothing. (Reachable on the budget wheel today; caps make an
    /// off-grid value ordinary once the bar can set one.)
    ///
    /// The overlay decides it, not this method, and it decides it from whether
    /// the wheel actually MOVED. Comparing the committed indices against the
    /// ones the wheel opened on reads the same and is not: it also swallows a
    /// deliberate spin away and back, which made the seat a wheel opened on
    /// permanently uncommittable — with the budget at 35 there was no gesture on
    /// that wheel that could set it to 30. One silent wrong write traded for one
    /// silently dead control. Whether a wheel was touched is a fact only the
    /// wheel has; asking it is the fix an index comparison structurally cannot
    /// be. (Spec §6.2 prescribes the index form and is amended.)
    func commitPicker(_ kind: PickerKind, picks: [Int]?) {
        // Only the overlay's teardown rides the overlay's curve. Everything
        // below this line is a policy commit, a wall reconcile and a toast —
        // wrapping `enact` in the veil's animation would hand the wheel's 0.4s
        // to the ensō, the doors and the receipt, each of which already states
        // its own motion. `defer` is what keeps the scope honest: it runs after
        // the commit, not around it.
        defer { withAnimation(Silk.motion(Silk.Motion.overlay)) { picker = nil } }
        guard let picks else { return }
        switch kind {
        case .down:
            guard picks.count == 2 else { return }
            var proposed = policy
            proposed.downHours = DownHours(
                start: TimeOfDay(minutesSinceMidnight: Self.downStartTable[picks[0]]),
                end: TimeOfDay(minutesSinceMidnight: Self.downEndTable[picks[1]]))
            settle(proposed)
        case .budget:
            guard picks.count == 1 else { return }
            var proposed = policy
            proposed.budgetMinutes = Self.budgetTable[picks[0]]
            settle(proposed)
        case .undo:
            guard picks.count == 1 else { return }
            undoSeconds = Self.undoTable[picks[0]]
            SharedStore.save(undoSeconds: undoSeconds)
            toasts.undoLifetime = .seconds(undoSeconds)
        case .cap(let door):
            guard picks.count == 1 else { return }
            var proposed = policy
            // Seat 0 is "No cap": the nil-bearing subscript removes the key,
            // which is what an absent ceiling actually is.
            proposed.doorCaps[door.id] = Caps.wheelMinutes(atSeat: picks[0])
            // `settle`, never `commitDoorChange`. A cap is policy, and the whole
            // point of `enact` is that the polarity rule cannot be sidestepped
            // by choosing which door you knock on: raising or clearing a cap
            // waits for tomorrow exactly as it does at the bar. The neighbouring
            // door writes go through `commitDoorChange` because a door add or
            // removal is instant by decision — the wrong neighbour to copy.
            settle(proposed)
        }
    }

    /// A Settings commit is not part of a conversation, so its receipt is a
    /// toast — and a wheel put back where it started asked for nothing, so it
    /// gets nothing. That question is about the state, so it is put to the
    /// state; classify agrees on both fields committed here, so the guard is a
    /// plainer way of asking rather than a stronger one.
    private func settle(_ proposed: PolicyState) {
        guard proposed != policy else { return }
        let polarity = PolarityEngine.classify(current: policy, proposed: proposed)
        let (reply, undo) = enact(proposed, polarity)
        if polarity == .loosen {
            // The one affordance beside a parked receipt is the key, not Undo,
            // and this is where that decision is made rather than in the toast.
            //
            // Undo on a parked loosening means "withdraw the ask" — it does not
            // undo the waiting, which is what the word plainly reads as after a
            // gesture that visibly changed nothing. Withdrawing is also not what
            // anyone wants in that second: she asked for the change, was told it
            // waits, and the one thing she wants is to have it now. That control
            // existed and was two page-swipes away on Now's pending row, on a row
            // she had no reason to look for. It is here now, at the point of the
            // gesture, and it spends the key exactly as Now's does.
            //
            // The withdrawal is not lost with it. A loosening said at the BAR
            // still lands in the thread with its Undo pill — `handle` offers the
            // closure `enact` returned — and a loosening committed from a wheel
            // is withdrawn the way rule 3 already provides for: tighten the same
            // field, and the merge declines the parked ask. The card now shows
            // the parked change, so that is a visible act rather than a guess.
            toasts.show(reply, label: SilkStrings.applyNow, id: "silk.toast.apply") {
                [weak self] in self?.keyTapped()
            }
            return
        }
        // The landing report is the thread's concern — its pill rewrites the
        // reply to a receipt, and only a landed restore may earn one. A toast
        // dismisses on tap either way and rewrites nothing, so it has nothing
        // to do with the answer and drops it.
        //
        // It is no longer true that a policy undo always lands: since a later
        // turn moving the same field expires the older offer, this `_ =` is
        // discarding a real Bool rather than a formality. That is still correct
        // HERE — a toast has no receipt to protect — and it is worth knowing
        // the difference, because the thread's pill does and reads it.
        toasts.show(reply, undo: undo.map { u in { _ = u() } })
    }

    /// A tighten states the balance it leaves, read through the ledger — not the
    /// new budget. Printing the budget put "40 min left today" on screen beside
    /// a hero reading 15, because 25 of those 40 were already spent.
    ///
    /// A cap moved the pool's number not at all, so the pool's sentence is the
    /// wrong receipt for it: "40 left today." after capping TikTok is
    /// byte-identical to what a bare status says, and it advertises the one
    /// number that did not move. Worse, capping a door *below what it has
    /// already spent today* shuts that door for the rest of the day, and
    /// clearing the cap again is a loosening that waits until tomorrow — so this
    /// sentence is the only thing standing between the user and being locked out
    /// of a door by a change she was told nothing about.
    ///
    /// What moved is derived by state diff — the same discipline polarity is
    /// held to — in `Caps.receipt`, which is where the composition and its
    /// ordering can be asserted without a simulator. A nil there means no
    /// ceiling moved, and the pool's own sentence is the receipt it has always
    /// had.
    ///
    /// `previous` is passed in rather than read off `policy`, because the one
    /// caller that has a change to report has already assigned `policy` by the
    /// time it asks — diffing the live policy there compares a state against
    /// itself, finds nothing, and quietly falls back to the pool's sentence,
    /// which is the exact failure this rewrite exists to end. The two callers
    /// with nothing to report pass the same state twice, which is what they mean.
    private func receipt(for proposed: PolicyState, movedFrom previous: PolicyState) -> String {
        if let capped = Caps.receipt(for: proposed, movedFrom: previous, ledger: ledger,
                                     now: now, dayStart: dayStart) {
            return capped
        }
        let remaining = ledger.remainingMinutes(budget: proposed.budgetMinutes, dayStart: dayStart)
        return "\(remaining) \(SilkStrings.leftToday)."
    }

    /// A refusal is words plus the haptic, and the words go where the caller
    /// sends them — the thread, now that refusals are turns like any other.
    private func refuse(_ words: String) -> String {
        Silk.Haptic.refusal()
        return words
    }

    /// "40 min left." — and the live rule after it when there is one, which is
    /// what the design's "40 min left. Social until 5:00." is showing. Silk has no
    /// tags yet, so the door names itself.
    private func status(remaining: Int) -> String {
        var s = "\(remaining) \(SilkStrings.minLeft)"
        // The design's second clause names a rule in force ("Social until
        // 5:00."). Silk's per-door rules are a door shut for the day and a door
        // that has spent its own ceiling, so that is what it can honestly name —
        // a plain close runs to the day boundary, and that boundary is its
        // deadline.
        //
        // A door closed by hand is preferred over a cap-exhausted one, and it is
        // looked for across ALL the doors before any rest is named — which is
        // `ledger.ruleInForce`'s whole job, in one pass, so the preference
        // cannot strand the fallback.
        if let rule = ledger.ruleInForce(for: policy, at: now, dayStart: dayStart) {
            let lifts = rule.lifts ?? DayBoundary.nextDayStart(after: dayStart)
            let t = Validator.timeOfDay(lifts, calendar: .current)
            s += " \(SilkStrings.closedUntil(rule.door.name, until: t))"
        }
        return s
    }

    /// Persist, raise the wall, and let the screen catch up in one motion.
    ///
    /// The orphan sweep runs here, before the wall reads anything, because a
    /// door does not only leave from Settings' editor — it leaves by sentence
    /// too, and that removal comes through this call. `Wall.reconcile` unions
    /// every stored selection with no policy filter, so a selection left behind
    /// shields its app with no row, no grant path and no Settings entry, and
    /// only a wipe cleared it. `commitDoorChange` never reaches here, so it
    /// states the same rule itself.
    ///
    /// `mutation` is the ledger change riding this commit, when there is one
    /// — `persist` re-applies it over a reload rather than let a stamp race
    /// drop it.
    private func commit(reapplying mutation: ((inout GrantLedger) -> Void)? = nil) {
        persist(reapplying: mutation)
        // The one decode this path has always made, now feeding the icons too:
        // a door lost here (a matured loosening swapping the roster) must not
        // leave its icon standing in a card raised a moment later.
        refreshDoorIcons(retireOrphanedSelections())
        wall.reconcile()
        now = .now
    }

    /// Written back only when there is something to retire, so a grant on its
    /// way through re-encodes nothing. Returns what the store now holds — the
    /// pruned dictionary when it pruned, the loaded one when it did not — so the
    /// caller's own read of the same blob is the same read.
    @discardableResult
    private func retireOrphanedSelections() -> [UUID: FamilyActivitySelection] {
        let selections = SharedStore.loadDoorSelections()
        let owned = policy.owned(selections)
        guard owned.count != selections.count else { return selections }
        SharedStore.save(doorSelections: owned)
        return owned
    }

    // MARK: - Editing the doors (Settings' two door overlays)

    /// Which of the two overlays a doors row raised, if either. A door row opens
    /// that door's detail card; the quiet add row opens the catalogue chips. The
    /// mount site switches on this and builds one component or the other — they
    /// share a stratum and an identifier, not a layout.
    enum DoorEdit: Equatable {
        case menu(Door)
        case add
    }
    var doorEdit: DoorEdit?

    /// The door added moments ago and still waiting for its first app — the
    /// rollback flag for an add abandoned at the binding sheet, and **nothing to
    /// do with what is on screen**.
    ///
    /// It used to be `doorEdit == .add`, one variable doing two jobs, and the
    /// second job was invisible from the first. `addDoor` makes the door
    /// name-only (exactly as setup allows) and raises the system sheet over the
    /// overlay; if the sheet is cancelled, `abandonDoorBinding` has to take the
    /// name back, and it decided whether to by asking what the overlay was
    /// showing. Any change that lowered the overlay before raising the sheet — a
    /// natural instinct, since the sheet covers it anyway — made that test read
    /// nil, and a cancelled add would have silently left a name-only door with no
    /// app behind it: a door that shows a Settings row, appears in Now, parses at
    /// the bar, launches, and can never be excepted from the wall, because there
    /// is no token to except. Setup's own binding flow already calls this state
    /// `provisional`; this is the same idea under the same word, and it is keyed
    /// by the door's id so a stale flag cannot roll back a different door.
    @ObservationIgnored private var provisionalDoorID: UUID?

    /// Catalogue names not already doors — what the add overlay offers. Every
    /// spoken form counts as taken, so a door answering to "x" holds the
    /// catalogue's "X" seat too.
    var addableDoorNames: [String] {
        DoorRoster.available(catalog: LaunchCatalog.entries.map(\.display),
                             taken: policy.doors.flatMap(\.spokenForms))
    }

    /// Whether Settings shows the add row at all: room under the maximum of
    /// six, and something left in the catalogue to add.
    var canAddDoor: Bool {
        policy.doors.count < DoorRoster.maxDoors && !addableDoorNames.isEmpty
    }

    /// A door row was tapped. Rows carry names (that is all Settings renders),
    /// so the door is looked up here; a name that no longer resolves is a row
    /// mid-removal, and the tap dies quietly.
    func editDoor(named name: String) {
        guard let door = policy.doors.first(where: { $0.name == name }) else { return }
        withAnimation(Silk.motion(Silk.Motion.overlay)) { doorEdit = .menu(door) }
    }

    func beginAddDoor() {
        withAnimation(Silk.motion(Silk.Motion.overlay)) { doorEdit = .add }
    }

    /// The backdrop tap — the editor's one exit.
    ///
    /// The animation wraps this assignment and nothing else, which matters at
    /// the two call sites that close the editor as part of a larger commit
    /// (`removeDoor`, `abandonDoorBinding`): the policy write happens outside
    /// it, so a door leaving the roster is not dragged along on the veil's curve.
    func closeDoorEdit() {
        withAnimation(Silk.motion(Silk.Motion.overlay)) { doorEdit = nil }
    }

    /// Daily cap: the editor's middle row hands the door to the wheel. The
    /// editor goes down and the wheel goes up in one frame, and **neither
    /// crosses the other** — that is the whole of the `withAnimation(nil)`.
    ///
    /// Both overlays are drawn on the same stratum and both wear the same .97
    /// veil (SettingsView.swift, WheelPicker.swift). Cross-faded, the departing
    /// veil is `a = 1 − f(t)` and the arriving one `b = f(t)` with `a + b = 1`
    /// throughout, and `.transition(.opacity)` multiplies each whole overlay —
    /// so the composited coverage is `1 − (1 − .97a)(1 − .97b)`. That is .97 at
    /// both ends and **.735 at the midpoint**: for a fifth of a second the
    /// Settings page underneath returns at better than a quarter strength and
    /// vanishes again. It is not a perceived flicker, it is an arithmetic one.
    ///
    /// A cut has no midpoint. Both veils are the same colour at the same alpha
    /// and the wheel's title is the door name the editor was already showing
    /// (`pickerTitle`), so the only thing that visibly changes across the frame
    /// is the three rows becoming a wheel — which is the handoff, stated once.
    /// Leaving the editor up instead is the other failure: its backdrop would
    /// eat every touch aimed at the wheel above it.
    func openCapWheel(for door: Door) {
        withAnimation(nil) {
            doorEdit = nil
            picker = .cap(door)
        }
    }

    /// Change app: the same sheet setup uses, so there is one idiom and not
    /// two. It opens on the tap — the reading beat existed to buy time for a
    /// line the sheet was about to cover, and the line now rides inside the
    /// sheet, above Apple's list, for as long as the list is up.
    func rebind(_ door: Door) {
        activitySelection = FamilyActivitySelection()
        activityPicker = .doorBinding(door)
    }

    /// Remove: the door leaves the policy AND its selection, and the wall is
    /// re-applied — one motion, mirroring completeSetup's never-half-saved
    /// ordering. Instant by decision (the task's call; see the receipt's
    /// undo): removal reads as tighten-adjacent housekeeping.
    ///
    /// **Known exemption from the polarity rule, accepted:** removing a capped
    /// door and adding it back is an instant, keyless uncapping. Doors are keyed
    /// by UUID (spec §2.1, deliberately, so a re-added name cannot inherit a
    /// ceiling the user never set on it), and both halves are instant, so the
    /// door returns with a fresh id and no cap while clearing that cap from the
    /// wheel would have parked until tomorrow. It is not the loosening it looks
    /// like from the outside — between the two taps the app is not blocked at
    /// all, so the re-add is strictly a tightening on the state it starts from —
    /// but the two-tap route does reach a place rule 3 makes the one-tap route
    /// wait for. Closing it means keying a removed cap by name for the rest of
    /// the Silk day, which is a model change and belongs in the spec first.
    /// Recorded here; PR 4 lists it under Build status in `docs/design/README.md`.
    ///
    /// The undo is surgical: the one door back at its old seat, its one
    /// selection back in the dictionary. The undo window runs up to five
    /// minutes and the editor stays usable under the toast, so a snapshot
    /// restore would silently destroy any door added — or budget moved — in
    /// between.
    func removeDoor(_ door: Door) {
        let removedIndex = policy.doors.firstIndex { $0.id == door.id }
        let removedSelection = SharedStore.loadDoorSelections()[door.id]
        // The cap leaves with the door and comes back with it. Without the pair,
        // remove-then-undo is a two-tap keyless uncapping: the door returns with
        // no ceiling and free to draw the whole pool, delivered instantly by a
        // button labelled "Put back.", with no key, no wait and no diff to
        // audit. It would also break maturity for good — the live cap would move
        // away from the pending's baseline permanently, so a parked cap raise on
        // that door could never mature even after the removal was undone.
        let removedCap = policy.doorCaps[door.id]
        var newPolicy = policy
        newPolicy.doors.removeAll { $0.id == door.id }
        newPolicy.doorCaps[door.id] = nil
        var selections = SharedStore.loadDoorSelections()
        selections[door.id] = nil
        // The re-lock timers were armed for a door that no longer exists.
        wall.stopMonitoring(door: door)
        commitDoorChange(policy: newPolicy, selections: selections)
        closeDoorEdit()
        toasts.show("\(door.name) \(SilkStrings.removed)", undo: { [weak self] in
            guard let self else { return }
            var restored = self.policy
            // The window is long enough for the world to have moved: the same
            // door cannot come back twice, and a name re-added meanwhile (or
            // a roster refilled to the cap) keeps its seat — the undo yields.
            guard !restored.doors.contains(where: { $0.id == door.id }),
                  DoorRoster.canAdd(door.name,
                                    taken: restored.doors.flatMap(\.spokenForms),
                                    count: restored.doors.count) else { return }
            restored.doors.insert(door, at: min(removedIndex ?? restored.doors.count,
                                                restored.doors.count))
            // After the yield, never before it: a door that cannot come back
            // must leave no cap behind, and an orphan keyed by a doorless id can
            // never be seen, spent or removed.
            restored.doorCaps[door.id] = removedCap
            var selections = SharedStore.loadDoorSelections()
            selections[door.id] = removedSelection
            self.commitDoorChange(policy: restored, selections: selections)
            self.restateRelockLayers(for: door)
        })
    }

    /// State the door's re-lock layers against the ledger as it stands now.
    ///
    /// The one call every path that moves a grant goes through, and it takes a
    /// door rather than an instant on purpose. The two DeviceActivity names are
    /// keyed by door (`WallController.stopMonitoring`), and the wall shuts a
    /// door at the LAST of its live grants to expire — `openDoors` implies it
    /// and `activeGrant` states it. So the schedules belong to the door's
    /// deadline, not to whichever grant a turn happened to touch, and reading
    /// that deadline back off the ledger is the only way the armed instant and
    /// the enforced one cannot drift apart.
    ///
    /// Handing it one grant's expiry instead is how a door is left with nothing
    /// to close it. Two overlapping grants share one schedule pair, so undoing
    /// the newer one used to disarm both names outright while the older stayed
    /// live in the restored ledger — the reconcile keeps the door open and
    /// nothing is left to shut it — and a second ask clamped at the night edge
    /// can mint a grant that ends *before* one already running, pulling the
    /// door's only schedules in ahead of the expiry the ledger will enforce.
    /// Both wake the monitor early, find a live grant, and close nothing.
    ///
    /// No live grant means nothing to close, and then disarming is the whole
    /// job: a restored ledger must leave no schedule standing behind it. Only
    /// the schedules — every caller reaches here through a commit, and the
    /// shield that commit reconciled is already the one the ledger asks for.
    /// So it arms directly rather than through `wall.open`, whose first act is
    /// a second `Wall.reconcile` — four decodes and a settings-store write to
    /// arrive at the union the commit a line earlier already wrote, on the one
    /// frame the veil is falling and the granted app is being handed the phone.
    private func restateRelockLayers(for door: Door) {
        guard let grant = ledger.activeGrant(for: door, at: .now) else {
            wall.stopMonitoring(door: door)
            return
        }
        wall.arm(door: door, until: grant.expiresAt)
    }

    /// Add: the chip tap makes the door (name-only, exactly as setup allows),
    /// then immediately runs the same one-app binding. Cap and dedupe are the
    /// roster's rules; the overlay only offers free names, so this guard is
    /// the belt to its suspenders.
    func addDoor(named display: String) {
        guard DoorRoster.canAdd(display,
                                taken: policy.doors.flatMap(\.spokenForms),
                                count: policy.doors.count) else { return }
        let door = Door(name: display)
        var newPolicy = policy
        newPolicy.doors.append(door)
        commitDoorChange(policy: newPolicy, selections: SharedStore.loadDoorSelections())
        // Set with the door, not with the overlay: this is what a cancelled
        // binding rolls back, and it must outlive whatever the screen does.
        provisionalDoorID = door.id
        activitySelection = FamilyActivitySelection()
        activityPicker = .doorBinding(door)
    }

    /// The binding picker came down. Setup's verdict, verbatim: exactly one
    /// app binds; an empty return is a cancel (a rebind keeps its old tokens,
    /// an added door stays name-only, as setup allows); anything plural binds
    /// nothing and puts the correction in the editor's guidance slot — for an
    /// add, the door leaves again so "tap Instagram again" is literally true.
    private func finishDoorBinding(_ door: Door) {
        // The door can be gone by the time the sheet comes down — removed
        // and its removal undone into a different door, or swapped out by a
        // matured loosening. A selection stored for a doorless id would
        // shield its app forever with no row, no grant path, and no UI able
        // to remove it — so a vanished door binds nothing, and any stray
        // selection under its id goes too.
        guard policy.doors.contains(where: { $0.id == door.id }) else {
            provisionalDoorID = nil
            var selections = SharedStore.loadDoorSelections()
            if selections[door.id] != nil {
                selections[door.id] = nil
                commitDoorChange(policy: policy, selections: selections)
            }
            closeDoorEdit()
            return
        }
        switch DoorBinding.validate(applications: activitySelection.applicationTokens.count,
                                    categories: activitySelection.categoryTokens.count,
                                    webDomains: activitySelection.webDomainTokens.count) {
        case .bound:
            provisionalDoorID = nil
            var selections = SharedStore.loadDoorSelections()
            selections[door.id] = activitySelection
            commitDoorChange(policy: policy, selections: selections)
            // The usage-threshold layer is armed on the door's OWN tokens
            // (`WallController.arm`, layer 3), and those tokens are what just
            // changed. A rebind made mid-grant left that event counting the
            // app the door no longer is — the schedules still close it, but
            // the layer whose whole point is an independent failure mode was
            // watching the wrong thing. `commitDoorChange` has reconciled, so
            // this is the arming only.
            restateRelockLayers(for: door)
            closeDoorEdit()
        case .cancelled, .retry:
            #if targetEnvironment(simulator)
            // Done cannot produce a token here. The stand-in list drives the
            // sheet's gate so the flow can be walked and tested, but
            // ApplicationToken is opaque and cannot be minted, so a committed
            // binding arrives empty and lands on this branch. Keep the door
            // name-only rather than discarding a name that was just answered
            // for — Cancel still takes it back, through cancelActivityPicking.
            provisionalDoorID = nil
            closeDoorEdit()
            #else
            // On a device the sheet's Done only lights on exactly one app, so
            // neither verdict can arrive from a tap on it. This is the
            // defensive path, and it abandons the binding as Cancel does.
            abandonDoorBinding(door)
            #endif
        }
    }

    /// Every door mutation lands through here: policy and selections
    /// persisted together, then the wall re-applied — the same ordering
    /// completeSetup keeps, so the shield's doorName(matching:) and the
    /// grant exceptions never read a half-saved state.
    private func commitDoorChange(policy newPolicy: PolicyState,
                                  selections: [UUID: FamilyActivitySelection]) {
        policy = newPolicy
        // A selection with no door is a shield with no row, no grant path and
        // no way off. This gate does not go through `commit`, so it states the
        // rule itself: the wall is re-applied two lines down and would read the
        // orphan otherwise. `commit` carries the same rule for the writes that
        // do come through it — a door dropped at the bar, among them.
        SharedStore.save(policy: newPolicy)
        let owned = newPolicy.owned(selections)
        SharedStore.save(doorSelections: owned)
        // The icons take exactly what was just saved, so a rebind's new icon is
        // in hand on the same frame the card redraws — and no second decode.
        refreshDoorIcons(owned)
        wall.reconcile()
        now = .now
    }

    // MARK: - The key (NFC tap or written code; hardware flow arrives later)

    /// Coming back to the app is a clock tick with a longer gap behind it.
    /// It is also the only moment revocation can be seen: Settings sends no
    /// callback when Silk is toggled off there.
    func foregrounded() {
        // First, before anything below runs. A wait resumed after the sync and
        // the reconcile would have those milliseconds fall outside its watching
        // span — she was looking at Silk for them, and they are hers. Taking
        // the reading first also puts the frame the eye reads as "it started
        // again" after the hitch rather than inside it.
        resumeWait()
        weekAttemptsCache = nil
        invalidateDayRecordsIfStale()
        // The suspension is where external writes accumulate — a Shortcuts
        // grant performed against the store while this copy slept — so the
        // return is where the copy has to catch up, before anything on
        // screen reads it or any commit writes it back.
        syncLedgerIfStale()
        now = .now
        wall.reconcile()
        refreshWallStanding()
        applyPendingIfDayTurned()
        compactLedgerIfDayTurned()
        // The clock slept through the suspension, and its sleep is aimed at an
        // instant now in the past — so it wakes the moment the loop is
        // scheduled and does this whole paragraph a second time, milliseconds
        // after the frame the user is looking at. Restarting it here retires
        // that iteration: the next wake is computed against the ledger and the
        // clock as they are now, which is what the sleep was always trying to
        // express.
        startClock()
    }

    // MARK: - The wall's standing (docs/market/gaps.md #5)

    /// True when the wall cannot actually stand — authorization revoked, or a
    /// restored install whose selection no longer shields. Now shows the truth
    /// and the one action that raises it.
    private(set) var wallDown = false

    // MARK: - The one system picker (docs/market/gaps.md #5; door editing)

    /// Everything the onboarded app asks the family picker for. One request
    /// enum, one selection, one `.familyActivityPicker` modifier (on RootView)
    /// — two modifiers in one presented view tree conflict, the same rule
    /// OnboardingView documents for setup's pair of requests.
    enum ActivityPickerRequest: Equatable {
        /// Re-arm the wall's extras from Now's truth-telling row.
        case rearm
        /// Bind (or rebind) a door to its one app, from Settings' editor.
        case doorBinding(Door)
    }
    var activityPicker: ActivityPickerRequest?
    /// The selection the picker edits. For a re-arm it seeds from the stored
    /// extras so re-arming edits what she chose, not a blank slate; on a new
    /// phone the doors' restored tokens are dead too, so whatever is re-picked
    /// here still stands the whole wall (standing reads the union of doors
    /// and extras). For a door binding it seeds empty — a rebind is a fresh
    /// answer to "which one app", not an edit of dead tokens.
    var activitySelection = FamilyActivitySelection()

    private func refreshWallStanding() {
        #if DEBUG
        // Debug/QA: -silkWallDown YES forces the row; the simulator's standing
        // is always .up (it has no real wall to lose).
        if UserDefaults.standard.bool(forKey: "silkWallDown") {
            wallDown = onboarded
            return
        }
        #endif
        wallDown = onboarded && wall.standing != .up
    }

    /// The row's one action. Authorization first; then the picker, when the
    /// selection is what's missing — or when this is a new phone, whose
    /// restored tokens decode but no longer shield.
    func raiseWall() {
        switch wall.standing {
        case .up:
            refreshWallStanding()
        case .needsSelection:
            activitySelection = SharedStore.loadWallSelection() ?? FamilyActivitySelection()
            activityPicker = .rearm
        case .needsAuthorization(let freshDevice):
            Task {
                let granted = await wall.requestAuthorization()
                // Authorization is what every wall write was silently failing
                // for, so the moment it comes back is the moment to state the
                // wall again. Nothing else does it: this row is reached while
                // Silk is already foregrounded, so no `foregrounded()` follows,
                // and until the next grant or day boundary the shield stayed
                // down, the heartbeat stayed unarmed, and a door with minutes
                // still running had no schedule left to close it.
                if granted { restateWall() }
                if granted && (freshDevice || wall.standing == .needsSelection) {
                    activitySelection = SharedStore.loadWallSelection() ?? FamilyActivitySelection()
                    activityPicker = .rearm
                }
                refreshWallStanding()
            }
        }
    }

    /// The picker came down — for either request. A re-arm persists,
    /// reconciles, re-judges: one motion, like completeSetup — the wall is
    /// never half-saved. A door binding runs the same one-app verdict setup
    /// does, and only a verdict of exactly-one binds anything at all.
    func finishActivityPicking() {
        guard let request = activityPicker else { return }
        activityPicker = nil
        switch request {
        case .rearm:
            SharedStore.save(wallSelection: activitySelection)
            restateWall()
            refreshWallStanding()
        case .doorBinding(let door):
            finishDoorBinding(door)
        }
    }

    /// Everything the wall consists of, stated again: the shield, the daily
    /// heartbeat, and the re-lock layers of every door still holding a grant.
    ///
    /// The two places a wall comes back — authorization re-granted, extras
    /// re-picked — used to restate only the shield. The other two are the ones
    /// that were never going to restate themselves: `armHeartbeat` is called
    /// at launch and at the day boundary, and the re-lock schedules are armed
    /// only when a grant lands. A door with minutes still running, on a wall
    /// that was just raised, had nothing scheduled to close it.
    private func restateWall() {
        wall.reconcile()
        // Unconditional, and the anchor is remembered so the day sweep does
        // not restate it again: this is the launch case, not the tick's.
        // The anchor is recorded only for an arm that took. A throw here —
        // authorization not yet effective, the daemon's activity limit — must
        // leave the next boundary free to try again, or the failure latches.
        if wall.armHeartbeat(downHours: policy.downHours) { armedHeartbeatAnchor = policy.downHours.end }
        // Only the doors with something to close. `restateRelockLayers`
        // answers a doorless grant with `stopMonitoring`, and disarming every
        // resting door here would be a stop per door for nothing.
        for door in policy.doors where ledger.activeGrant(for: door, at: .now) != nil {
            restateRelockLayers(for: door)
        }
    }

    /// Cancel, or a swipe down. Nothing the sheet gathered is kept — a cancel
    /// that quietly committed whatever had been tapped so far would make the
    /// Done gate a decoration.
    func cancelActivityPicking() {
        guard let request = activityPicker else { return }
        activityPicker = nil
        activitySelection = FamilyActivitySelection()
        if case .doorBinding(let door) = request { abandonDoorBinding(door) }
    }

    /// A binding that ended without binding. A door added moments ago and
    /// never given an app leaves with the sheet; an existing door keeps the
    /// app it already had.
    ///
    /// The test is `provisionalDoorID`, not `doorEdit == .add`. The two agree
    /// today and the second one is free, which is exactly what made it dangerous:
    /// it read as a UI question and answered a data one, so any future change to
    /// when the overlay comes down would have turned a cancelled add into a
    /// name-only door with no app behind it, silently. See the flag's own note.
    private func abandonDoorBinding(_ door: Door) {
        let wasProvisional = provisionalDoorID == door.id
        provisionalDoorID = nil
        if wasProvisional {
            var newPolicy = policy
            newPolicy.doors.removeAll { $0.id == door.id }
            // A door added seconds ago has no cap to drop, so this line is
            // structure rather than repair: every site a door leaves from takes
            // its ceiling with it, and a rule with an exception in it is a rule
            // the next door-removal path will forget.
            newPolicy.doorCaps[door.id] = nil
            var selections = SharedStore.loadDoorSelections()
            selections[door.id] = nil
            commitDoorChange(policy: newPolicy, selections: selections)
        }
        closeDoorEdit()
    }

    func keyTapped() {
        guard let pending = slot.pending else { return }
        // The key buys the wait, not the merge: a tighten made since the
        // sentence was said still stands, exactly as it would at the boundary.
        let next = matured(pending)
        // An exception spent is an exception journalled, but only an exception
        // actually spent. The merge can legitimately deliver nothing — every
        // field the sentence proposed may have been overtaken by a tighten
        // since — and the key is scarce and hand-tapped. Burning it on a no-op
        // is the one outcome the user can neither see nor undo, and it is more
        // invisible than it was: the footnote counts today's unlocks now, so
        // nothing on screen surfaces this journal at all. The pending stays
        // parked and the journal stays untouched. `pendingChange` hides the button before it comes to
        // this; the guard is here because the key will also arrive over NFC,
        // where nothing consults the screen.
        guard next != policy else { return }
        policy = next
        park(nil, baseline: nil)
        // The NFC key will record through the same call when the hardware flow
        // lands.
        SharedStore.recordKeyUse()
        commit()
    }

    /// One write, both halves, in memory and in the App Group. The pair is the
    /// truth: `save(pendingLoosening:)` was already the call most likely to be
    /// got half-right, and now that the baseline is also held in memory,
    /// splitting the two would let Now read a merge against a baseline the store
    /// no longer has. Nothing outside this method assigns either.
    ///
    /// Returns the generation this park landed as, so a caller offering a way
    /// back can key it to its own park and expire when anything else parks.
    @discardableResult
    private func park(_ pending: PolicyState?, baseline: PolicyState?) -> Int {
        let generation = slot.park(pending, baseline: baseline)
        SharedStore.save(pendingLoosening: pending, baseline: baseline)
        return generation
    }

    /// What a parked loosening would actually deliver, merged against what the
    /// policy has become since. Everything on screen reads this rather than the
    /// snapshot: the pending is what was *asked for*, and after a tighten the
    /// two are no longer the same thing.
    private func matured(_ pending: PolicyState) -> PolicyState {
        policy.maturing(pending, parkedAgainst: slot.baseline)
    }

    /// What a pending loosening will change, in one value — or nil when it will
    /// change nothing and there is no row to draw.
    ///
    /// Diffed against the *matured* policy, not the snapshot. Diffing the
    /// snapshot against live advertises what was asked for, which after a
    /// tighten is a number guaranteed not to arrive: the card would promise 90
    /// all evening and the boundary would silently deliver 30. The doors branch
    /// is gone with it — a loosening cannot change the door list, so it was
    /// unreachable and would have lied if it were not.
    func pendingSummary(_ pending: PolicyState) -> String? {
        let next = matured(pending)
        if next.budgetMinutes != policy.budgetMinutes { return "\(next.budgetMinutes)" }
        if next.downHours != policy.downHours {
            return "\(next.downHours.start.display)–\(next.downHours.end.display)"
        }
        // A parked cap loosening had no row at all, and the "Apply now." button
        // that spends the key lives only inside that row — so the user was told
        // "Applies tomorrow." and then found nothing on Now to see, apply or
        // cancel. The line itself is composed in `Caps.pendingSummary`, where
        // the whole seat-0 → park → row → key round trip is pinned.
        return Caps.pendingSummary(next: next, live: policy)
    }

    /// What a parked ceiling change will deliver for ONE door — the detail
    /// card's own line, and nil for a door with nothing waiting on it.
    ///
    /// The card is where the gesture happened, and before this it stated only the
    /// ceiling in force. So clearing a cap left the row, the card and the wheel
    /// all reading the old ceiling with the ask invisible on every one of them:
    /// re-open the wheel, spin to No cap again, and the same reply arrives over
    /// an unchanged screen. That loop is what "it doesn't work for some reason"
    /// is. The card says it now, and offers the key beside it.
    ///
    /// The WHEEL still opens on the live ceiling, deliberately: seating it on the
    /// pending would show a value that is not in force, which is a worse lie than
    /// the one this fixes.
    func settingsPendingCap(for door: Door) -> String? {
        guard let pending = slot.pending else { return nil }
        return Caps.pendingValue(next: matured(pending), live: policy, door: door)
    }

    /// A loosening matures once a day boundary has passed since it was asked
    /// for. Comparing the boundary to `now` cannot express that: `dayStart` is
    /// by construction the boundary at or before `now`, so the comparison is
    /// always true and every pending loosening applied on the next launch —
    /// force-quitting was enough to skip the wait. The pending change's own
    /// timestamp is the only thing a boundary can be measured against.
    private func applyPendingIfDayTurned() {
        // The in-memory slot, not a decode: `park` is the only writer of the
        // pending pair and it writes both halves at once, so the slot is the
        // store — and this runs on the minute tick, where a JSON decode to
        // learn "still nothing parked" is the commonest answer there is.
        guard let pending = slot.pending else { return }
        guard let proposedAt = SharedStore.loadPendingProposedAt() else {
            // Persisted by a build that stored no timestamp. Stamp it now and
            // make it wait a boundary: erring toward the edge holding is the
            // whole point of the rule. The baseline is carried through
            // untouched — inventing one from the live policy here would make
            // `live == baseline` true for every field and hand the snapshot a
            // wholesale revert at the next boundary.
            park(pending, baseline: slot.baseline)
            return
        }
        let dayStart = DayBoundary.dayStart(now: .now, downHours: policy.downHours)
        guard proposedAt < dayStart else { return }
        // A pending with no stored baseline matures to nothing (see
        // `maturing`), and it is cleared rather than re-parked: it has had its
        // boundary, it cannot say what it proposed, and keeping it would leave
        // a card on Now offering a change that will never come. A loosening
        // lost is the safe direction; the sentence can be said again.
        policy = matured(pending)
        park(nil, baseline: nil)
        // `commit`, not `persist`: the window this just moved decides which
        // doors count as open, so the wall has to be re-applied, and the orphan
        // sweep has to run on this write like every other one that goes through
        // it. At `init` the reconcile on the next line is then redundant rather
        // than harmful — `now` already holds its declaration default there.
        commit()
    }

    /// One sweep per Silk day. Yesterday's spent grants say nothing about
    /// today's arithmetic — `spentMinutes` filters on `issuedAt >= dayStart`
    /// — but every shield render, minute tick and monitor wake decodes the
    /// whole blob, so a ledger nothing compacts grows for the life of the
    /// install. Guarded by the day start it last swept, so the minute tick
    /// pays one Date compare on every day but the one that turned.
    @ObservationIgnored private var compactedDayStart: Date?

    /// The time of day the heartbeat schedule is currently anchored at — the
    /// end of down hours, which is the only input `armHeartbeat` has. Held so
    /// that restating the schedule is a restatement of something that moved
    /// and not a stop-and-start of the daemon's one live activity for nothing.
    @ObservationIgnored private var armedHeartbeatAnchor: TimeOfDay?

    /// Restate the heartbeat when — and only when — its anchor has moved.
    /// A launch and the end of setup arm unconditionally on purpose (the
    /// daemon's activity list is not documented to survive everything that can
    /// happen to it); this is for the paths that can run again and again
    /// inside one process. A failed arm records no anchor, so the next
    /// boundary retries it — the retry the unconditional day-turn arm used
    /// to be.
    private func armHeartbeatIfAnchorMoved() {
        guard armedHeartbeatAnchor != policy.downHours.end else { return }
        // The anchor is recorded only for an arm that took. A throw here —
        // authorization not yet effective, the daemon's activity limit — must
        // leave the next boundary free to try again, or the failure latches.
        if wall.armHeartbeat(downHours: policy.downHours) { armedHeartbeatAnchor = policy.downHours.end }
    }

    private func compactLedgerIfDayTurned() {
        // The LIVE boundary, deliberately not `dayStart`: the sweep is what
        // detects the turn and stamps the established day, so it must read
        // the clock the policy claims, not the stamp it maintains.
        let start = DayBoundary.dayStart(now: now, downHours: policy.downHours)
        guard compactedDayStart != start else { return }
        compactedDayStart = start
        syncLedgerIfStale()
        // The day turned, which is also the one moment the heartbeat's anchor
        // could have moved under it — down hours are the boundary. Restating
        // it here keeps the schedule pinned to the boundary the records are
        // being cut on — but only when the anchor actually moved. Arming is a
        // `stopMonitoring` and a `startMonitoring` against the DeviceActivity
        // daemon, and this method is reachable on every tick (see the retry
        // marker below), which made the one signal that proves the wall alive
        // into something torn down and rebuilt once a minute.
        armHeartbeatIfAnchorMoved()

        // No compaction without a record. `compact` drops every grant older
        // than its cut, and a day whose grants are gone can never be
        // summarised again — so every closed day must be written AND read
        // back before anything is dropped. The cut is therefore the
        // FRONTIER the records themselves vouch for, not `start`: cutting at
        // `start` only when the gate said yes deferred compaction *forever*
        // in a permanently-moved-boundary regime (the frontier trails the
        // live boundary by a couple of hours every single day), while the
        // frontier compacts exactly as far as the summarised chain reaches —
        // the same instant when the anchors agree, a day behind when not.
        //
        // The gate's own Bool is discarded, and both halves of it are asked
        // again below off the one read-back it forces: the cut has taken the
        // frontier rather than the gate's verdict since the paragraph above
        // was written, and the retry marker needs the other half on its own.
        _ = SharedStore.recordClosedDays(
            upTo: start,
            downHours: policy.downHours,
            ledger: ledger,
            wallStanding: policy.wallEnabled && wall.standing == .up
        )
        // One decode, read back after the write, and both questions below are
        // asked of it: what the cut may reach, and whether anything is still
        // owed a record.
        let sealed = Set(SharedStore.dayRecords().map(\.dayStart))
        // The gate may have written; Mirror's copy is stale exactly when it
        // did, and the counter is what says so.
        invalidateDayRecordsIfStale()
        // A `false` from the gate is two different facts wearing one Bool.
        // One is "a day I owe a record did not land" — a real failure, and
        // retrying it on the next tick is exactly right. The other is "the
        // summarised chain does not reach the live boundary", which is the
        // standing condition of every install whose down-hours END has ever
        // moved LATER: the chain is anchored at the OLD time of day and walks
        // forward a day at a time, so its frontier lands short of the live
        // boundary today and on every day after it (pinned in
        // `AMovedBoundaryTrailsTheFrontierWithNothingOwed`). Retried, that
        // one clears the marker on every tick — and the whole sweep, the
        // heartbeat's stop-and-start included, ran every minute Silk was
        // foregrounded, forever. Only the first fact is a retry.
        if !DayLog.missingBoundaries(recorded: sealed, upTo: start).isEmpty {
            // Days are still owed. Clear the marker so the next tick retries
            // rather than treating this day as done.
            compactedDayStart = nil
        }

        // The standing day's start is stamped before anything is cut: the
        // spend/close windows read the ESTABLISHED day
        // (`GrantLedger.effectiveDayStart`), and this sweep — the moment the
        // day actually turns — is what advances the stamp. A `start` that
        // jumped because down hours moved mid-day is refused inside
        // `establishDay`, so the stamp moves once per real day and never
        // under the user's feet.
        var next = ledger
        next.establishDay(startingAt: start, calendar: .current)

        // The cut runs only when the frontier's own day reaches past `now`:
        // `compact` treats a grant issued at or past the cut day's end as a
        // phantom, and a frontier lagging real time (a long absence, a
        // forward-set clock holding the walk) must not eat a grant minted
        // today.
        let cut = DayLog.compactionFrontier(recorded: sealed, upTo: start)
        let mayCut = DayBoundary.nextDayStart(after: cut) > now
        if mayCut { next.compact(dayStart: cut) }

        // Written back only when something moved, so a quiet day's boundary
        // re-encodes nothing.
        guard next != ledger else { return }
        ledger = next
        // Re-appliable for the same reason a close is — and marking the day
        // swept before this write stays honest because of it: a stamp race
        // cannot skip the sweep, only re-run the stamp and the compaction
        // over the fresh ledger, which drops nothing an external writer
        // landed (compaction only sheds entries spent before the frontier,
        // and the day stamp advances at most once per real day).
        persist(reapplying: {
            $0.establishDay(startingAt: start, calendar: .current)
            if mayCut { $0.compact(dayStart: cut) }
        })
    }

    private func persist(reapplying mutation: ((inout GrantLedger) -> Void)? = nil) {
        SharedStore.save(policy: policy)
        // Checked at the last instant: a commit that never touched the ledger
        // — a wheel commit, a matured pending — must not write the in-memory
        // copy over a grant an external writer landed meanwhile. Two
        // invariants hold here, and both halves of the wall's doctrine hang
        // on them: an externally-written grant is never overwritten by a
        // wholesale write of a stale copy, and a local mutation the user has
        // already been answered for is never dropped. A mismatch with no
        // mutation is a stale copy, re-read and never written; a mismatch
        // WITH a mutation re-reads first and applies the mutation over the
        // fresh ledger, so both writes stand in the one blob saved. What is
        // left is a same-instant cross-process write between this check and
        // the save, and its loser can never be a close: a close riding here
        // re-applies on top of whatever that check read, and a commit
        // carrying nothing yields by reloading instead of writing.
        if SharedStore.ledgerStamp() == ledgerStamp {
            ledgerStamp = SharedStore.save(ledger: ledger)
            // A mutation that landed is a ledger the outstanding undo offers
            // no longer describe, so the generation moves and expires them —
            // this branch is the choke point every local mutation rides
            // through, which is what lets no mutation site forget. A commit
            // with nothing riding (a wheel commit, a matured pending) rewrites
            // the same ledger and moves nothing. Restores ride with no
            // mutation on purpose: an unmoved generation is how they tell
            // their write landed, and a landed restore bumps at its own site.
            if mutation != nil { ledgerGeneration += 1 }
        } else {
            syncLedgerIfStale()
            guard let mutation else { return }
            mutation(&ledger)
            ledgerStamp = SharedStore.save(ledger: ledger)
            // The reload above already moved the generation once; the
            // re-applied mutation is a second movement on top of it, and
            // counting both is what leaves an offer keyed to "my mutation,
            // over the ledger I snapshotted" behind — its snapshot predates
            // the external write this branch just folded in.
            ledgerGeneration += 1
        }
    }

    /// Catch up with the writers this process is not. Cheap when nothing
    /// happened — one string read against the remembered stamp — and a full
    /// re-read only when the stamp says someone else wrote. Every ledger
    /// mutation syncs first, so its snapshot-and-mutate runs on the ledger
    /// that actually stands; the reload bumps the generation, retiring any
    /// undo whose snapshot predates it.
    ///
    /// Reports whether it actually reloaded, which is the one signal the tick
    /// has that another process moved the truth under it — every other caller
    /// discards the answer and is only asking to be current.
    @discardableResult
    private func syncLedgerIfStale() -> Bool {
        let stamp = SharedStore.ledgerStamp()
        guard stamp != ledgerStamp else { return false }
        ledger = SharedStore.loadLedger()
        ledgerStamp = stamp
        ledgerGeneration += 1
        return true
    }
}
