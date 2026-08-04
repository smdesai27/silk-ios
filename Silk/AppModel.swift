import Foundation
import SwiftUI
import FamilyControls
import SilkCore

@MainActor
@Observable
final class AppModel {
    private(set) var policy: PolicyState
    private(set) var ledger: GrantLedger
    private(set) var pendingLoosening: PolicyState?
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

    /// Which wheel is up, if any. The three global rows on Settings set this;
    /// the backdrop tap commits and clears it. (handoff README.md §4)
    var picker: PickerKind?
    enum PickerKind: String { case down, budget, undo }

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
        self.pendingLoosening = SharedStore.loadPendingLoosening()
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
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: d)
    }

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
        weekAttemptsCache = (start, buckets)
        return buckets
    }

    @ObservationIgnored private var weekAttemptsCache:
        (dayStart: Date, buckets: [(attempts: Int, late: Int)])?

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
                self.weekAttemptsCache = nil
                self.now = .now
                // A grant that just expired has to close its door, and a day
                // that turned matures whatever was waiting for it.
                self.wall.reconcile()
                self.applyPendingIfDayTurned()
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
        let id = conversation.ask(utterance)
        let asked = ContinuousClock.now

        var outcome = DeterministicParser.parse(utterance, state: policy)
        if outcome == .silence {
            outcome = await SilkModelParser.parse(utterance, state: policy)
        }
        let verdict = Validator.validate(outcome, utterance: utterance,
                                         state: policy, ledger: ledger, now: .now)

        let beat: Duration = .milliseconds(480)
        let elapsed = asked.duration(to: .now)
        if elapsed < beat {
            try? await Task.sleep(for: beat - elapsed)
        }

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
    /// no diffing, no knowledge of what the turn did (README.md:303-304).
    private func apply(_ verdict: Verdict) -> (reply: String, undo: (() -> Void)?) {
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
            let previous = ledger
            ledger.closeDoor(door, at: .now, until: until)
            commit()
            Silk.Haptic.tighten()
            let t = Validator.timeOfDay(until, calendar: .current).display
            return ("\(door.name) \(SilkStrings.closedUntil) \(t).",
                    restore(previous))

        case .closeAll(let doors, let until):
            // Every door, one lift, one sentence — and one way back.
            let previous = ledger
            for door in doors {
                ledger.closeDoor(door, at: .now, until: until)
            }
            commit()
            Silk.Haptic.tighten()
            let t = Validator.timeOfDay(until, calendar: .current).display
            return ("\(SilkStrings.everything) \(SilkStrings.closedUntil) \(t).",
                    restore(previous))

        case .grant(let door, let minutes, let relockAt):
            let previous = ledger
            let grant = Grant(door: door, minutes: minutes, issuedAt: .now, expiresAt: relockAt)
            ledger.record(grant)
            commit()
            wall.open(door: door, until: relockAt)
            Silk.Haptic.grant()
            LaunchCatalog.open(doorName: door.name)
            return ("\(door.name) \(SilkStrings.isOpenFor) \(minutes) \(SilkStrings.minutes).",
                    { [weak self] in
                        guard let self else { return }
                        // The re-lock timers were armed for a grant that no
                        // longer exists; disarming them is part of putting
                        // the ledger back.
                        self.wall.stopMonitoring(door: door)
                        self.ledger = previous
                        self.commit()
                    })

        case .ruleChange(let proposed, let polarity):
            if polarity == .unchanged {
                // Nothing moved, so there is no receipt to give — but every
                // branch of the design's reply table says something, and a
                // screen that does not move is indistinguishable from a
                // dropped command. State what is true instead.
                return (receipt(for: policy), nil)
            }
            return enact(proposed, polarity)
        }
    }

    /// One rule change, wherever it was asked — a sentence at the bar or a
    /// wheel on Settings — so the polarity rule cannot be sidestepped by
    /// choosing the door you knock on: a tighten lands now with the way back
    /// offered; a loosening waits for tomorrow, or the key.
    private func enact(_ proposed: PolicyState, _ polarity: Polarity) -> (reply: String, undo: (() -> Void)?) {
        switch polarity {
        case .unchanged:
            return (receipt(for: policy), nil)

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
            return (receipt(for: proposed), { [weak self] in
                guard let self else { return }
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
                self.policy = restored
                if !returning.isEmpty { SharedStore.save(doorSelections: selections) }
                self.commit()
                for door in returning { self.rearmLiveGrant(for: door) }
            })

        case .loosen:
            // Applies at the next day start — or now, with the key. Undo here
            // withdraws the ask and puts back whatever was already waiting.
            let previous = pendingLoosening
            // The baseline travels with the pending: at maturity it is the only
            // way to tell which of the four fields the sentence actually moved.
            // Undo puts back the withdrawn pending's own baseline, not this one.
            let previousBaseline = SharedStore.loadPendingBaseline()
            pendingLoosening = proposed
            SharedStore.save(pendingLoosening: proposed, baseline: policy)
            return (SilkStrings.appliesTomorrow, { [weak self] in
                guard let self else { return }
                self.pendingLoosening = previous
                SharedStore.save(pendingLoosening: previous, baseline: previousBaseline)
            })
        }
    }

    /// The close/grant way back: the prior ledger, restored wholesale.
    private func restore(_ previous: GrantLedger) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            self.ledger = previous
            self.commit()
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

    /// One row per door. Silk has one shared budget and no per-door
    /// allowance, so the honest per-door rule is thinner than the design's
    /// mock data: a door shut for the day rests; every other door draws on
    /// the one pool, and the pool is the allowance it can name.
    var settingsDoors: [SettingsDoorItem] {
        policy.doors.map { door in
            if case .rest = state(of: door) {
                return SettingsDoorItem(name: door.name, value: SilkStrings.closed)
            }
            return SettingsDoorItem(name: door.name,
                                    value: "\(policy.budgetMinutes) \(SilkStrings.minutes)")
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
    /// snapping to the top.
    private static func nearestIndex(to value: Int, in table: [Int]) -> Int {
        table.indices.min { abs(table[$0] - value) < abs(table[$1] - value) } ?? 0
    }

    func pickerTitle(for kind: PickerKind) -> String {
        switch kind {
        case .down: SilkStrings.downHours
        case .budget: SilkStrings.budget
        case .undo: SilkStrings.undo
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
        }
    }

    /// The backdrop tap: commit and close in one gesture. Budget and window
    /// go through `enact` — the same path a sentence takes — so the polarity
    /// rule holds from Settings too: a tighten lands now with Undo on the
    /// toast, a loosening answers "Applies tomorrow." and waits. The undo
    /// window is not a policy, so it commits directly and quietly: the row
    /// reading the new value is its own receipt.
    func commitPicker(_ kind: PickerKind, picks: [Int]) {
        defer { picker = nil }
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
        toasts.show(reply, undo: undo)
    }

    /// A tighten states the balance it leaves, read through the ledger — not the
    /// new budget. Printing the budget put "40 min left today" on screen beside
    /// a hero reading 15, because 25 of those 40 were already spent.
    private func receipt(for proposed: PolicyState) -> String {
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
        // 5:00."). Silk's only per-door rule is a door shut for the day, so
        // that is what it can honestly name — a plain close runs to the day
        // boundary, and that boundary is its deadline.
        for door in policy.doors {
            if case .rest(let until) = state(of: door) {
                let lifts = until ?? DayBoundary.nextDayStart(after: dayStart)
                let t = Validator.timeOfDay(lifts, calendar: .current).display
                s += " \(door.name) \(SilkStrings.closedUntil) \(t)."
                break
            }
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
    private func commit() {
        persist()
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
    /// The undo is surgical: the one door back at its old seat, its one
    /// selection back in the dictionary. The undo window runs up to five
    /// minutes and the editor stays usable under the toast, so a snapshot
    /// restore would silently destroy any door added — or budget moved — in
    /// between.
    func removeDoor(_ door: Door) {
        let removedIndex = policy.doors.firstIndex { $0.id == door.id }
        let removedSelection = SharedStore.loadDoorSelections()[door.id]
        var newPolicy = policy
        newPolicy.doors.removeAll { $0.id == door.id }
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
        now = .now
        wall.reconcile()
        refreshWallStanding()
        applyPendingIfDayTurned()
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
        pendingLoosening = nil
        SharedStore.save(pendingLoosening: nil, baseline: nil)
        // The NFC key will record through the same call when the hardware flow
        // lands.
        SharedStore.recordKeyUse()
        keyLogCache = nil
        commit()
    }

    /// What a parked loosening would actually deliver, merged against what the
    /// policy has become since. Everything on screen reads this rather than the
    /// snapshot: the pending is what was *asked for*, and after a tighten the
    /// two are no longer the same thing.
    private func matured(_ pending: PolicyState) -> PolicyState {
        policy.maturing(pending, parkedAgainst: SharedStore.loadPendingBaseline())
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
        return nil
    }

    func cancelPending() {
        pendingLoosening = nil
        SharedStore.save(pendingLoosening: nil, baseline: nil)
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
            SharedStore.save(pendingLoosening: pending,
                             baseline: SharedStore.loadPendingBaseline())
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
        pendingLoosening = nil
        SharedStore.save(pendingLoosening: nil, baseline: nil)
        // `commit`, not `persist`: the window this just moved decides which
        // doors count as open, so the wall has to be re-applied, and the orphan
        // sweep has to run on this write like every other one that goes through
        // it. At `init` the reconcile on the next line is then redundant rather
        // than harmful — `now` already holds its declaration default there.
        commit()
    }

    private func persist() {
        SharedStore.save(policy: policy)
        SharedStore.save(ledger: ledger)
    }
}
