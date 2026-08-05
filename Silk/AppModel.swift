import Foundation
import SwiftUI
import FamilyControls
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
    private(set) var pendingLoosening: PolicyState?
    /// The policy the parked loosening was measured against — held here rather
    /// than re-read, and always written by `park` in the same breath as the
    /// pending itself.
    ///
    /// `matured` is asked three times on every body pass of Now (the row, the
    /// height it reserves, and the animation that keys them together), and each
    /// ask used to be an App Group read plus a whole `PolicyState` decode on the
    /// main thread — on every clock tick, keyboard rise and layout pass. In
    /// memory the merge is free, so the three call sites can go on asking the
    /// one question, which is the point of asking it.
    @ObservationIgnored private var pendingBaseline: PolicyState?
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
        // Debug/QA: launch with -silkReset YES to wipe state and re-onboard.
        if UserDefaults.standard.bool(forKey: "silkReset") {
            SharedStore.wipeAll()
        }
        let saved = SharedStore.loadPolicy()
        self.onboarded = saved != nil
        self.policy = saved ?? AppModel.defaultPolicy
        self.ledger = SharedStore.loadLedger()
        self.ledgerStamp = SharedStore.ledgerStamp()
        self.pendingLoosening = SharedStore.loadPendingLoosening()
        self.pendingBaseline = SharedStore.loadPendingBaseline()
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
        startClock()
        #if DEBUG
        // QA: -silkPage 1 opens on Mirror. There is no other way in — the pager
        // is driven by touch, and a screenshot harness has no fingers.
        self.page = UserDefaults.standard.integer(forKey: "silkPage")
        #endif
    }

    deinit { clock?.cancel() }

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
        wall.reconcile()
        onboarded = true
    }

    static let defaultPolicy = PolicyState(
        budgetMinutes: 40,
        downHours: DownHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7)),
        doors: []
    )

    // MARK: - What the screen reads

    var dayStart: Date { DayBoundary.dayStart(now: now, downHours: policy.downHours) }

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

    /// A day is scored once, when it closes, so the hero prefers the last
    /// closed day and holds it. `nil` before there is a closed day to read:
    /// on a fresh install the hero showed 100 under a real weekday name, a
    /// flawless week that never happened — Mirror falls back to `todayScore`
    /// then, labelled as today, so the screen is never scoreless.
    var lastClosedScore: Int? { closedWeekScores.last ?? nil }

    /// Today's running score. Same equation as a closed day, still moving —
    /// written in stone only when the day turns.
    var todayScore: Int {
        weekAttemptBuckets.last.map(Self.score) ?? 100
    }

    /// The planned equation (canon.md: "82 = 100 − 12 attempts − 6 late"):
    /// every attempt at the wall costs one, and an attempt during down hours
    /// costs one more. Floor at zero — a worse day than that has no number.
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
    /// principle stale it, but iOS relaunches the app for those, the same
    /// bargain `keyLog`'s cached "MMM d" already accepts.
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
        return weekAttemptBuckets.dropLast().enumerated().map { i, bucket in
            // Bucket i covers [dayStart - (6 - i) days, +1 day).
            guard let end = cal.date(byAdding: .day, value: i - 5, to: dayStart),
                  end > installed else { return nil }
            return Self.score(bucket)
        }
    }

    /// "1 · Jul 12" — exceptions spent and when the last one was, read from the
    /// key journal in SharedStore. Today the journal's only writer is the
    /// in-app "Tap your key." path; the physical key will record through the
    /// same call when it lands, and this line needs no new wiring. Zero
    /// exceptions is a real count, so it reads "0" and no date.
    var keyLog: String {
        if let cached = keyLogCache { return cached }
        let journal = SharedStore.keyJournal()
        let line: String
        if let last = journal.last {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("MMM d")
            line = "\(journal.count) · \(f.string(from: last))"
        } else {
            line = "0"
        }
        keyLogCache = line
        return line
    }

    @ObservationIgnored private var keyLogCache: String?

    // MARK: - The shield, raised from a door row

    private(set) var shield: ShieldPreview?
    struct ShieldPreview: Equatable { var title: String; var app: String }

    /// An open door has no wall to show. Everything else does, and what it says
    /// is a time, not an explanation.
    ///
    /// Down hours outrank both: the wall is up for everything, so the headline is
    /// the hour it comes down. (Silk Mockup.dc.html:305-308)
    func raiseShield(for door: Door) {
        if isDownHours {
            shield = ShieldPreview(title: "☾ \(policy.downHours.end.displayWithMeridiem)",
                                   app: door.name)
            return
        }
        switch state(of: door) {
        case .open:
            shield = nil
        case .rest(let until):
            if let until {
                // Rule-bound: a stated hour holds the door, and the headline is
                // that hour — "Until 5:00", the shield's own word, not the
                // row's lowercase "till". (README.md:189)
                let t = Validator.timeOfDay(until, calendar: .current).display
                shield = ShieldPreview(title: "\(SilkStrings.until) \(t)", app: door.name)
            } else {
                // Plainly resting: the wall says the name and nothing more —
                // the same sentence the row is already not saying.
                shield = ShieldPreview(title: door.name, app: "")
            }
        case .live:
            // Behind the wall with nothing scheduled: the wall says the name.
            shield = ShieldPreview(title: door.name, app: "")
        }
    }

    func dismissShield() { shield = nil }

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
                guard let interval = self?.secondsUntilNextWake() else { return }
                try? await Task.sleep(for: .seconds(interval))
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
                self.syncLedgerIfStale()
                self.now = .now
                // A grant that just expired has to close its door, and a day
                // that turned matures whatever was waiting for it.
                self.wall.reconcile()
                self.applyPendingIfDayTurned()
                self.compactLedgerIfDayTurned()
            }
        }
    }

    private func secondsUntilNextWake() -> Double {
        let cal = Calendar.current
        let nextMinute = cal.nextDate(after: .now, matching: DateComponents(second: 0),
                                      matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let wake = min(nextMinute, ledger.nextTransition(after: .now) ?? nextMinute)
        return max(1, wake.timeIntervalSince(.now))
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
            outcome = await SilkModelParser.parse(utterance, state: policy)
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
        let (reply, undo) = apply(verdict)
        conversation.land(reply, undo: undo, for: id)
        if undo != nil { scheduleUndoExpiry(for: id) }
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
            let t = Validator.timeOfDay(until, calendar: .current).display
            return (refuse("\(door.name) \(SilkStrings.closedUntil) \(t)."), nil)

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
            commit(reapplying: close)
            Silk.Haptic.tighten()
            let t = Validator.timeOfDay(until, calendar: .current).display
            return ("\(door.name) \(SilkStrings.closedUntil) \(t).",
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
            commit(reapplying: closeAll)
            Silk.Haptic.tighten()
            let t = Validator.timeOfDay(until, calendar: .current).display
            return ("\(SilkStrings.everything) \(SilkStrings.closedUntil) \(t).",
                    restore(previous, ifStill: generation))

        case .grant(let door, let minutes, let relockAt):
            syncLedgerIfStale()
            let previous = ledger
            // Keyed to this turn's own landing, exactly as `.close` explains.
            let generation = ledgerGeneration + 1
            let grant = Grant(door: door, minutes: minutes, issuedAt: .now, expiresAt: relockAt)
            let record: (inout GrantLedger) -> Void = { $0.record(grant) }
            record(&ledger)
            commit(reapplying: record)
            wall.open(door: door, until: relockAt)
            Silk.Haptic.grant()
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
                        // longer exists; disarming them is part of putting
                        // the ledger back — but only for a restore that
                        // landed.
                        self.wall.stopMonitoring(door: door)
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
                var restored = self.policy
                if proposed.budgetMinutes != previous.budgetMinutes {
                    restored.budgetMinutes = previous.budgetMinutes
                }
                if proposed.downHours != previous.downHours {
                    restored.downHours = previous.downHours
                }
                // Per key, for the same reason the budget and window clauses are
                // per field: the window runs up to five minutes with Settings
                // usable underneath, so a wholesale restore would erase a cap
                // set on a different door in between. `Caps.restoring` states
                // that rule where it can be tested; here it is one call.
                restored.doorCaps = Caps.restoring(previous.doorCaps, over: proposed.doorCaps,
                                                   into: restored.doorCaps)
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
                for door in returning { self.rearmLiveGrant(for: door) }
                // A policy restore has no generation to expire under: the
                // per-field surgery above always has something true to put
                // back, so the receipt it earns is always earned.
                return true
            })

        case .loosen:
            // Applies at the next day start — or now, with the key. Undo here
            // withdraws the ask and puts back whatever was already waiting.
            //
            // There is exactly ONE pending slot, and the decision recorded here
            // is that the newest ask replaces the waiting one — silently, with
            // no receipt: parking a second loosening discards the first and
            // answers "Applies tomorrow." both times, and Now's row then names
            // only the survivor. That was tolerable while three dimensions could
            // be parked and no gesture chained them; caps take it to 3 + N (up
            // to nine) and make chaining ordinary — park a raise on TikTok, then
            // clear the cap on Instagram, and the first ask is gone. Knowingly
            // unfixed (spec §6.9); surfacing the displacement in the reply is
            // the recommended follow-up, and PR 4 lists it under Build status in
            // `docs/design/README.md`.
            let previous = pendingLoosening
            // The baseline travels with the pending: at maturity it is the only
            // way to tell which of the four fields the sentence actually moved.
            // Undo puts back the withdrawn pending's own baseline, not this one.
            let previousBaseline = pendingBaseline
            park(proposed, baseline: policy)
            return (SilkStrings.appliesTomorrow, { [weak self] in
                guard let self else { return false }
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
    /// the toast, a loosening answers "Applies tomorrow." and waits. The undo
    /// window is not a policy, so it commits directly and quietly: the row
    /// reading the new value is its own receipt.
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
        defer { picker = nil }
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
        // The landing report is the thread's concern — its pill rewrites the
        // reply to a receipt, and only a landed restore may earn one. A toast
        // dismisses on tap either way and rewrites nothing, and the policy
        // undos that ride here always land, so the report is dropped.
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
            let t = Validator.timeOfDay(lifts, calendar: .current).display
            s += " \(rule.door.name) \(SilkStrings.closedUntil) \(t)."
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
        retireOrphanedSelections()
        wall.reconcile()
        now = .now
    }

    /// Written back only when there is something to retire, so a grant on its
    /// way through re-encodes nothing.
    private func retireOrphanedSelections() {
        let selections = SharedStore.loadDoorSelections()
        let owned = policy.owned(selections)
        guard owned.count != selections.count else { return }
        SharedStore.save(doorSelections: owned)
    }

    // MARK: - Editing the doors (Settings' editor overlay)

    /// What the editor overlay is showing, if anything. A door row opens the
    /// menu (Rebind / Remove); the quiet add row opens the catalogue chips.
    enum DoorEdit: Equatable {
        case menu(Door)
        case add
    }
    var doorEdit: DoorEdit?

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
        doorEdit = .menu(door)
    }

    func beginAddDoor() {
        doorEdit = .add
    }

    /// The backdrop tap — the editor's one exit.
    func closeDoorEdit() {
        doorEdit = nil
    }

    /// Daily cap: the editor's middle row hands the door to the wheel — and puts
    /// the editor down first, in that order.
    ///
    /// Both overlays are drawn on the same stratum and the editor fades out over
    /// its own 0.4s curve, so leaving it standing would mount the wheel under a
    /// .97 veil for most of half a second, with the editor's backdrop eating
    /// every touch aimed at the wheel — including the blind coordinate tap the
    /// UI walk commits with. The wheel's title carries the door name from here,
    /// so the editor's has done its job.
    func openCapWheel(for door: Door) {
        closeDoorEdit()
        picker = .cap(door)
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
            self.rearmLiveGrant(for: door)
        })
    }

    /// A removal disarms the re-lock layers, so an undone removal has to arm
    /// them again: a restored door with a grant still live in the ledger
    /// reopens on that commit's reconcile, and without this only wake-based
    /// layer 4 would ever shut it. (Inverse of the grant undo.) A door dropped
    /// at the bar undoes through here too, so it comes back armed the same way
    /// whichever path dropped it.
    private func rearmLiveGrant(for door: Door) {
        guard let grant = ledger.grants
            .filter({ $0.doorID == door.id && $0.isActive(at: .now) })
            .max(by: { $0.expiresAt < $1.expiresAt }) else { return }
        wall.open(door: door, until: grant.expiresAt)
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
            var selections = SharedStore.loadDoorSelections()
            selections[door.id] = activitySelection
            commitDoorChange(policy: policy, selections: selections)
            closeDoorEdit()
        case .cancelled, .retry:
            #if targetEnvironment(simulator)
            // Done cannot produce a token here. The stand-in list drives the
            // sheet's gate so the flow can be walked and tested, but
            // ApplicationToken is opaque and cannot be minted, so a committed
            // binding arrives empty and lands on this branch. Keep the door
            // name-only rather than discarding a name that was just answered
            // for — Cancel still takes it back, through cancelActivityPicking.
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
        SharedStore.save(doorSelections: newPolicy.owned(selections))
        wall.reconcile()
        now = .now
    }

    // MARK: - The key (NFC tap or written code; hardware flow arrives later)

    /// Coming back to the app is a clock tick with a longer gap behind it.
    /// It is also the only moment revocation can be seen: Settings sends no
    /// callback when Silk is toggled off there.
    func foregrounded() {
        weekAttemptsCache = nil
        keyLogCache = nil
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
        // Debug/QA: -silkWallDown YES forces the row; the simulator's standing
        // is always .up (it has no real wall to lose).
        if UserDefaults.standard.bool(forKey: "silkWallDown") {
            wallDown = onboarded
            return
        }
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
            wall.reconcile()
            refreshWallStanding()
        case .doorBinding(let door):
            finishDoorBinding(door)
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
    private func abandonDoorBinding(_ door: Door) {
        if doorEdit == .add {
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
        guard let pending = pendingLoosening else { return }
        // The key buys the wait, not the merge: a tighten made since the
        // sentence was said still stands, exactly as it would at the boundary.
        let next = matured(pending)
        // An exception spent is an exception journalled, but only an exception
        // actually spent. The merge can legitimately deliver nothing — every
        // field the sentence proposed may have been overtaken by a tighten
        // since — and the key is scarce, hand-tapped, and counted in Mirror's
        // footnote. Burning it on a no-op is the one outcome the user can
        // neither see nor undo, so the pending stays parked and the journal
        // stays untouched. `pendingChange` hides the button before it comes to
        // this; the guard is here because the key will also arrive over NFC,
        // where nothing consults the screen.
        guard next != policy else { return }
        policy = next
        park(nil, baseline: nil)
        // The NFC key will record through the same call when the hardware flow
        // lands.
        SharedStore.recordKeyUse()
        keyLogCache = nil
        commit()
    }

    /// One write, both halves, in memory and in the App Group. The pair is the
    /// truth: `save(pendingLoosening:)` was already the call most likely to be
    /// got half-right, and now that the baseline is also held in memory,
    /// splitting the two would let Now read a merge against a baseline the store
    /// no longer has. Nothing outside this method assigns either.
    private func park(_ pending: PolicyState?, baseline: PolicyState?) {
        pendingLoosening = pending
        pendingBaseline = baseline
        SharedStore.save(pendingLoosening: pending, baseline: baseline)
    }

    /// What a parked loosening would actually deliver, merged against what the
    /// policy has become since. Everything on screen reads this rather than the
    /// snapshot: the pending is what was *asked for*, and after a tighten the
    /// two are no longer the same thing.
    private func matured(_ pending: PolicyState) -> PolicyState {
        policy.maturing(pending, parkedAgainst: pendingBaseline)
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

    func cancelPending() {
        park(nil, baseline: nil)
    }

    /// A loosening matures once a day boundary has passed since it was asked
    /// for. Comparing the boundary to `now` cannot express that: `dayStart` is
    /// by construction the boundary at or before `now`, so the comparison is
    /// always true and every pending loosening applied on the next launch —
    /// force-quitting was enough to skip the wait. The pending change's own
    /// timestamp is the only thing a boundary can be measured against.
    private func applyPendingIfDayTurned() {
        guard let pending = SharedStore.loadPendingLoosening() else { return }
        guard let proposedAt = SharedStore.loadPendingProposedAt() else {
            // Persisted by a build that stored no timestamp. Stamp it now and
            // make it wait a boundary: erring toward the edge holding is the
            // whole point of the rule. The baseline is carried through
            // untouched — inventing one from the live policy here would make
            // `live == baseline` true for every field and hand the snapshot a
            // wholesale revert at the next boundary.
            park(pending, baseline: pendingBaseline)
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

    private func compactLedgerIfDayTurned() {
        let start = dayStart
        guard compactedDayStart != start else { return }
        compactedDayStart = start
        syncLedgerIfStale()
        var compacted = ledger
        compacted.compact(dayStart: start)
        // Written back only when something was dropped, so a quiet day's
        // boundary re-encodes nothing.
        guard compacted != ledger else { return }
        ledger = compacted
        // Re-appliable for the same reason a close is — and marking the day
        // swept before this write stays honest because of it: a stamp race
        // cannot skip the sweep, only re-run the compaction over the fresh
        // ledger, which drops nothing an external writer landed (compaction
        // only sheds entries spent before this day began).
        persist(reapplying: { $0.compact(dayStart: start) })
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
    private func syncLedgerIfStale() {
        let stamp = SharedStore.ledgerStamp()
        guard stamp != ledgerStamp else { return }
        ledger = SharedStore.loadLedger()
        ledgerStamp = stamp
        ledgerGeneration += 1
    }
}
