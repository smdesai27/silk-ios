import AppIntents
import Foundation
import SilkCore

/// The one verb the outside world can say: Spend(door, minutes). Shortcuts
/// automations (arrive at the gym → spend 30 on Instagram) call this; nothing
/// callable from outside can raise the budget, move the night window, add a
/// door, or extend a live grant. A condition can start a grant; only a number
/// can end one. (docs/market/open-language.md)
struct SpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Spend"
    static let description = IntentDescription(
        "Spends minutes from today's budget on one of your apps. The app unlocks now and locks again at a stated time."
    )

    @Parameter(title: "App")
    var doorName: String

    @Parameter(title: "Minutes", inclusiveRange: (1, 300))
    var minutes: Int

    /// Idempotency: a repeat invocation inside the same grant window re-reads
    /// the balance instead of debiting again. `.result(opensIntent:)` is
    /// developer-reported to double-invoke under Siri; a double debit would be
    /// catastrophic for the single-currency promise.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let policy = SharedStore.loadPolicy(),
              let door = policy.door(named: doorName) else {
            return .result(dialog: "")   // unknown door: silence, not an error
        }

        var ledger = SharedStore.loadLedger()
        let now = Date()

        // Idempotent: an active grant on this door is simply restated.
        if let active = ledger.grants.first(where: { $0.doorID == door.id && $0.isActive(at: now) }) {
            let time = Validator.timeOfDay(active.expiresAt, calendar: .current).display
            return .result(dialog: "\(door.name) · \(SilkStrings.till.lowercased()) \(time)")
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
            // Write the ledger first and put it back on failure, rather than
            // arming first, because this ordering has no stale read in it.
            // The only thing that can wake the monitor is the `startMonitoring`
            // inside `arm`, so `intervalDidStart`'s reconcile is causally after
            // the save below and necessarily sees this grant. Arming first
            // would let that reconcile read the ledger a beat before the grant
            // reached it and re-shield a door the dialog has just called open,
            // on the one path with nothing left to correct it.
            let previous = ledger
            ledger.record(Grant(door: door, minutes: granted, issuedAt: now, expiresAt: relockAt))
            SharedStore.save(ledger: ledger)

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
                // `arm` has already disarmed both names, so putting the ledger
                // back leaves nothing scheduled and nothing granted: no minutes
                // are debited, and the reconcile shields the door again. That
                // reconcile is also this background launch's one free chance to
                // close a door some earlier expiry left standing open.
                ledger = previous
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
                if wallIsDown { return .result(dialog: "\(SilkStrings.blockingOff)") }
                return .result(dialog: "")
            }

            Wall.reconcile(now: now)
            let time = Validator.timeOfDay(relockAt, calendar: .current).display
            return .result(dialog: "\(door.name) · \(granted) · \(SilkStrings.till.lowercased()) \(time)")
        case .refuseDownHours(let until):
            return .result(dialog: "\(SilkStrings.till) \(until.display).")
        case .refuseNothingLeft:
            return .result(dialog: "0 \(SilkStrings.leftToday)")
        default:
            return .result(dialog: "")
        }
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
