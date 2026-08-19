import AppIntents
import Foundation
import SilkCore

/// The one verb the outside world can say: Spend(door, minutes). Shortcuts
/// automations (arrive at the gym → spend 30 on Instagram) call this; nothing
/// callable from outside can raise the budget, move the night window, add a
/// door, or extend a live grant. A condition can start a grant; only a number
/// can end one. (docs/market/open-language.md)
///
/// Title, description, parameter titles and the phrase are App Intent metadata
/// — they sit outside `SilkStrings` because they are the system's chrome, not
/// a sentence Silk speaks. Every word this intent *says* is composed in
/// `SpendDialog`.
struct SpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Spend"
    static let description = IntentDescription(
        "Spends minutes from today's budget on one of your apps. The app unlocks now and locks again at a stated time."
    )

    @Parameter(title: "App")
    var doorName: String

    @Parameter(title: "Minutes", inclusiveRange: (1, 300))
    var minutes: Int

    #if DEBUG
    /// The dialog `perform` last spoke. `IntentResult` will not hand the
    /// string back, so tests that assert the spoken sentence read this —
    /// set from the same value that goes into `.result(dialog:)`, so the
    /// two cannot diverge. Test-only; `nonisolated(unsafe)` because
    /// `perform` writes it off the main actor and the suite reads it on.
    nonisolated(unsafe) static var lastDialog = ""

    /// Fired on the grant-record leg, after validate and before the stamped
    /// save. The interleave test writes here so the race is forced rather
    /// than hoped for: the window is otherwise a few microseconds of CPU.
    nonisolated(unsafe) static var beforeGrantSave: (() -> Void)?
    #endif

    /// Idempotency: a repeat invocation inside the same grant window re-reads
    /// the balance instead of debiting again. `.result(opensIntent:)` is
    /// developer-reported to double-invoke under Siri; a double debit would be
    /// catastrophic for the single-currency promise.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let policy = SharedStore.loadPolicy(),
              let door = policy.door(named: doorName) else {
            return answer(SpendDialog.silence)   // unknown door: silence, not an error
        }

        var ledger = SharedStore.loadLedger()
        // `let` since the day-turn sweep moved off this path: nothing between
        // here and the grant save writes the ledger, so the stamp read here is
        // still the one that save must compare against.
        let stamp = SharedStore.ledgerStamp()
        let now = Date()

        // The day-turn sweep USED to run here, and could not stay: at this
        // point the validator has not run, so the intent does not yet know
        // whether this invocation will mint a grant — and it cannot record a
        // day's summary without knowing the wall is real. The sweep now lives
        // on the granted path below, where a schedule has just been armed
        // against a standing wall. Booked cost: a Shortcuts-only user who
        // never opens Silk keeps a slightly larger ledger blob.

        // Idempotent: an active grant on this door is simply restated.
        if let active = ledger.grants.first(where: { $0.doorID == door.id && $0.isActive(at: now) }) {
            let time = Validator.timeOfDay(active.expiresAt, calendar: .current)
            return answer(SpendDialog.restated(door: door.name, until: time))
        }

        // The same validator as the bar: the budget binds here too.
        let verdict = Validator.validate(
            .command(.spend(door: door, minutes: minutes)),
            utterance: "\(doorName) \(minutes)",   // provenance holds by construction
            state: policy, ledger: ledger, now: now
        )

        switch verdict {
        case .grant(let door, let granted, let relockAt):
            // The door does not open unless the re-lock armed. Nothing else
            // wakes this path: Shortcuts performs the intent in a background
            // launch with no scene, the process is suspended the moment
            // `perform` returns, and the opened door is unshielded, so its own
            // shield never renders — a grant recorded here with no schedule
            // behind it keeps Instagram open past 22:00 until Silk is opened
            // by hand. That is the fail-OPEN invariant 4 forbids.
            //
            // Write the ledger first and take the grant back out on failure,
            // rather than arming first, because this ordering has no stale
            // read in it. The only thing that can wake the monitor is the
            // `startMonitoring` inside `arm`, so `intervalDidStart`'s
            // reconcile is causally after the save below and necessarily sees
            // this grant. Arming first would let that reconcile read the
            // ledger a beat before the grant reached it and re-shield a door
            // the dialog has just called open, on the one path with nothing
            // left to correct it.
            //
            // The save itself is stamp-compared: a main-actor write that
            // landed between the load above and this line — the user closing
            // a door at the bar — must survive. A wholesale put of `ledger`
            // would erase it. Reload-merge when the stamp moved; save as-is
            // when it did not. (SharedStore.save(ledger:knownStamp:applying:))
            let grant = Grant(door: door, minutes: granted, issuedAt: now, expiresAt: relockAt)
            #if DEBUG
            Self.beforeGrantSave?()
            #endif
            SharedStore.save(ledger: ledger, knownStamp: stamp, applying: {
                $0.record(grant)
            })

            let (armed, wallIsDown) = await MainActor.run { () -> (Bool, Bool) in
                let wall = WallController()
                guard wall.arm(door: door, until: relockAt) else {
                    // Read on the same hop that failed: the refusal has to
                    // agree with the row Now will show on the next launch.
                    return (false, wall.standing != .up)
                }
                return (true, false)
            }

            guard armed else {
                // `arm` has already disarmed both names, so removing the grant
                // leaves nothing scheduled and nothing granted: no minutes are
                // debited, and the reconcile shields the door again. The
                // rollback is surgical, never a put-back of the pre-grant
                // snapshot: the `await` above is a suspension point, and a
                // ledger write that landed during it — the user closing a door
                // at the bar — must survive this failure path. So reload what
                // stands NOW, take out exactly the grant this intent recorded,
                // and save (stamped, as every ledger write is). That reconcile
                // is also this background launch's one free chance to close a
                // door some earlier expiry left standing open.
                ledger = SharedStore.loadLedger()
                ledger.removeGrant(id: grant.id)
                SharedStore.save(ledger: ledger)
                Wall.reconcile(now: now)
                // "Blocking is off." is said only when it is. Revocation is the
                // likeliest reason a schedule will not take, but the other
                // reasons leave the wall standing, and saying it then would be
                // the same lie inverted — the Shortcut calling blocking dead
                // while Now, which reads authorization and tokens and nothing
                // about schedules, draws it whole. Silk owns no true sentence
                // for a schedule that would not take, so the door stays shut in
                // the same silence an unknown door gets.
                if wallIsDown { return answer(SpendDialog.blockingOff) }
                return answer(SpendDialog.silence)
            }

            Wall.reconcile(now: now)

            // The day-turn sweep, moved here from ahead of the validator. This
            // is the only point where the intent knows both things a record
            // needs: a grant has just been minted, and a schedule armed
            // against a wall that was standing — `arm` cannot succeed
            // otherwise, which is what makes `wallStanding` honest here rather
            // than assumed.
            //
            // Record, then compact, and only compact if every closed day
            // recorded. A background-only user can go days without the app's
            // clock running, so this is the one sweep those days will get; if
            // it cannot summarise them it must not destroy them either.
            let sweepStart = DayBoundary.dayStart(now: now, downHours: policy.downHours)
            let sweepStamp = SharedStore.ledgerStamp()
            let swept = SharedStore.loadLedger()
            if SharedStore.recordClosedDays(upTo: sweepStart,
                                            downHours: policy.downHours,
                                            ledger: swept,
                                            wallStanding: policy.wallEnabled) {
                var compacted = swept
                compacted.compact(dayStart: sweepStart)
                // Written back only when something was dropped — a quiet pass
                // re-encodes nothing — and stamped, as every ledger write is.
                if compacted != swept {
                    SharedStore.save(ledger: swept, knownStamp: sweepStamp,
                                     applying: { $0.compact(dayStart: sweepStart) })
                }
            }

            let time = Validator.timeOfDay(relockAt, calendar: .current)
            return answer(SpendDialog.granted(door: door.name, minutes: granted, until: time))
        case .refuseDownHours(let until):
            return answer(SpendDialog.downHours(until: until))
        case .refuseNothingLeft:
            return answer(SpendDialog.nothingLeft)
        case .refuseDoorClosed(let door, let until):
            // The reason this switch stopped ending in `default:`. A capped-out
            // or hand-closed door answered from a Shortcuts automation with an
            // empty dialog is indistinguishable from success, in the one context
            // with no screen and no thread to correct it. Exhaustive from here
            // on, so the next Verdict is a compile error on this path too.
            let time = Validator.timeOfDay(until, calendar: .current)
            return answer(SpendDialog.doorClosed(door: door.name, until: time))
        case .restated(let door, let until):
            // Unreachable today: the idempotency guard above already restates
            // any active grant on this door before the Validator is called, so
            // this arm never runs. Written out rather than swept into the
            // catch-all below because if that guard is ever narrowed, the answer
            // here must still be the deadline and not an empty dialog.
            let time = Validator.timeOfDay(until, calendar: .current)
            return answer(SpendDialog.restated(door: door.name, until: time))
        case .silence, .refuseSayHowManyMinutes, .refuseSayAmOrPm, .refuseDoorNeedsApp,
             .ruleChange, .close, .closeAll, .status, .downHours:
            // Nothing this intent can produce: it validates one `.spend` and
            // nothing else. Silence rather than a guessed sentence, exactly as
            // an unknown door gets.
            return answer(SpendDialog.silence)
        }
    }

    private func answer(_ spoken: String) -> some IntentResult & ProvidesDialog {
        #if DEBUG
        Self.lastDialog = spoken
        #endif
        return .result(dialog: "\(spoken)")
    }
}

struct SilkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SpendIntent(),
            phrases: ["Spend in \(.applicationName)"],
            shortTitle: "Spend",
            systemImageName: "circle"
        )
    }
}
