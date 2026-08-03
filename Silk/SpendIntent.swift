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
            ledger.record(Grant(door: door, minutes: granted, issuedAt: now, expiresAt: relockAt))
            SharedStore.save(ledger: ledger)
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
