import Foundation
import SilkCore
import FamilyControls
import ManagedSettings

/// The App Group bridge between the app and its three extensions.
/// Everything the shield needs to render — and everything the monitor needs to
/// re-lock — must be readable from here, inside a 6 MB extension.
public enum SharedStore {
    public static let appGroup = "group.com.sanildesai.silk"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    private enum Key {
        static let policy = "silk.policy"
        static let ledger = "silk.ledger"
        static let wallSelection = "silk.wall.selection"       // FamilyActivitySelection (the extras)
        static let doorSelections = "silk.door.selections"     // [UUID: FamilyActivitySelection]
        static let attempts = "silk.attempts"                  // [Date] shield renders
        static let pendingLoosening = "silk.pending"           // PolicyState applying tomorrow
        static let pendingProposedAt = "silk.pending.at"       // when it was asked for
        static let firstRunAt = "silk.firstrun"                // days before it have no score
        static let keyJournal = "silk.key.journal"             // [Date] — every exception spent
        static let undoSeconds = "silk.undo.seconds"           // the take-it-back window
    }

    /// Debug/QA only: wipe everything so onboarding runs again.
    public static func wipeAll() {
        // silk.key.code / silk.key.placement / silk.proposal are dead keys
        // from the retired key step and proposal card; wiped so upgraded QA
        // installs carry nothing forward.
        for key in ["silk.policy", "silk.ledger", "silk.wall.selection", "silk.door.selections",
                    "silk.attempts", "silk.pending", "silk.pending.at",
                    "silk.proposal", "silk.firstrun",
                    "silk.key.code", "silk.key.placement", "silk.key.journal",
                    "silk.undo.seconds"] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - The key

    /// The key journal: every exception spent, in order. Mirror's footnote
    /// reads the count and the last date ("⚿ 1 · Jul 12"); nothing else does.
    /// The physical key isn't built yet, so today the only writer is the
    /// in-app "Tap your key." path — when NFC lands it records here too, and
    /// the footnote needs no new wiring.
    public static func recordKeyUse(at now: Date = Date()) {
        var uses = decode([Date].self, key: Key.keyJournal) ?? []
        uses.append(now)
        encode(uses, key: Key.keyJournal)
    }

    public static func keyJournal() -> (count: Int, last: Date?) {
        let uses = decode([Date].self, key: Key.keyJournal) ?? []
        return (uses.count, uses.last)
    }

    // MARK: - The undo window

    /// How long a change can be taken back, in seconds. It is a setting now
    /// (the third row on Settings), so it lives beside the other persisted
    /// values — but not inside PolicyState: the polarity engine orders
    /// budgets, windows and doors by strictness, and the undo window is not
    /// a strictness, it is a courtesy.
    public static func loadUndoSeconds() -> Int {
        let stored = defaults.integer(forKey: Key.undoSeconds)
        return stored > 0 ? stored : 60
    }

    public static func save(undoSeconds: Int) {
        defaults.set(undoSeconds, forKey: Key.undoSeconds)
    }

    // MARK: - Policy

    public static func loadPolicy() -> PolicyState? {
        decode(PolicyState.self, key: Key.policy)
    }

    public static func save(policy: PolicyState) {
        encode(policy, key: Key.policy)
    }

    // MARK: - Ledger

    public static func loadLedger() -> GrantLedger {
        decode(GrantLedger.self, key: Key.ledger) ?? GrantLedger()
    }

    public static func save(ledger: GrantLedger) {
        encode(ledger, key: Key.ledger)
    }

    // MARK: - Pending loosening (applies at next day start, or on key tap)

    public static func loadPendingLoosening() -> PolicyState? {
        decode(PolicyState.self, key: Key.pendingLoosening)
    }

    /// When the loosening was asked for. Without it there is nothing a day
    /// boundary can be compared against, and "applies tomorrow" becomes
    /// "applies on the next launch".
    public static func loadPendingProposedAt() -> Date? {
        defaults.object(forKey: Key.pendingProposedAt) as? Date
    }

    public static func save(pendingLoosening: PolicyState?, proposedAt: Date = .now) {
        if let p = pendingLoosening {
            encode(p, key: Key.pendingLoosening)
            defaults.set(proposedAt, forKey: Key.pendingProposedAt)
        } else {
            defaults.removeObject(forKey: Key.pendingLoosening)
            defaults.removeObject(forKey: Key.pendingProposedAt)
        }
    }

    // MARK: - Mirror

    /// Stamped once. A day before it has no score — the week band draws it bare
    /// rather than inferring a perfect day from an absence of attempts.
    public static func firstRun() -> Date {
        if let d = defaults.object(forKey: Key.firstRunAt) as? Date { return d }
        let now = Date()
        defaults.set(now, forKey: Key.firstRunAt)
        return now
    }

    // MARK: - Screen Time selections

    public static func loadWallSelection() -> FamilyActivitySelection? {
        decode(FamilyActivitySelection.self, key: Key.wallSelection)
    }

    public static func save(wallSelection: FamilyActivitySelection) {
        encode(wallSelection, key: Key.wallSelection)
    }

    public static func loadDoorSelections() -> [UUID: FamilyActivitySelection] {
        decode([UUID: FamilyActivitySelection].self, key: Key.doorSelections) ?? [:]
    }

    public static func save(doorSelections: [UUID: FamilyActivitySelection]) {
        encode(doorSelections, key: Key.doorSelections)
    }

    /// Every application token any door names. What the wall covers is this
    /// union plus the extras in the wall selection.
    public static func doorApplicationTokens() -> Set<ApplicationToken> {
        loadDoorSelections().values.reduce(into: Set<ApplicationToken>()) {
            $0.formUnion($1.applicationTokens)
        }
    }

    /// All application tokens belonging to doors that should be open now.
    public static func openDoorTokens(at now: Date = Date()) -> Set<ApplicationToken> {
        guard let policy = loadPolicy() else { return [] }
        let ledger = loadLedger()
        let dayStart = DayBoundary.dayStart(now: now, downHours: policy.downHours)
        let openIDs = ledger.openDoors(at: now, dayStart: dayStart)
        let selections = loadDoorSelections()
        var tokens = Set<ApplicationToken>()
        for id in openIDs {
            if let sel = selections[id] {
                tokens.formUnion(sel.applicationTokens)
            }
        }
        return tokens
    }

    // MARK: - Attempts (shield renders; Mirror's chart)

    /// Records a shield render. Renders within 60s of the last one count as
    /// the same attempt (docs/market/gaps.md #9) — otherwise the Sunday
    /// equation inflates into a scold.
    public static func recordAttempt(at now: Date = Date()) {
        var attempts = decode([Date].self, key: Key.attempts) ?? []
        if let last = attempts.last, now.timeIntervalSince(last) < 60 { return }
        attempts.append(now)
        if attempts.count > 2000 { attempts.removeFirst(attempts.count - 2000) }
        encode(attempts, key: Key.attempts)
    }

    public static func attempts(since: Date) -> [Date] {
        (decode([Date].self, key: Key.attempts) ?? []).filter { $0 >= since }
    }

    // MARK: - Codable plumbing

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The single wall. One store, one policy — Apple's engineers are explicit
/// that multiple ManagedSettingsStore instances cannot relax each other.
public enum Wall {
    /// Stores with the same name share settings (documented), so a fresh
    /// instance per call is the same wall — and Sendable-clean under Swift 6.
    public static var store: ManagedSettingsStore {
        ManagedSettingsStore(named: .init("silk.wall"))
    }

    /// Reconcile the wall against the ledger. Idempotent, callable from any
    /// process — the app on foreground, the monitor on intervalDidEnd, the
    /// shield extensions on every render/tap. Fail-closed: if state can't be
    /// read, the wall goes up whole.
    public static func reconcile(now: Date = Date()) {
        guard let policy = SharedStore.loadPolicy(), policy.wallEnabled else {
            // No configuration yet: nothing to enforce.
            return
        }
        // The wall is apps only: every door's tokens plus the extras (the
        // wall selection — apps blocked without a name or launch entry).
        // A nil selection is an empty one, not an unconfigured wall; the
        // doors alone can carry the whole policy.
        let extras = SharedStore.loadWallSelection() ?? FamilyActivitySelection()
        let blocked = SharedStore.doorApplicationTokens().union(extras.applicationTokens)
        let exceptions = SharedStore.openDoorTokens(at: now)
        let store = Self.store

        store.shield.applications = blocked.subtracting(exceptions)
        // Categories are gone from the model. Nil-ing them here clears stale
        // category shields on upgraded installs — and retires the documented
        // device-verify risk that a category shield overrides per-app
        // unshielding: there is no category layer left to override anything.
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil

        // Web domains never open with a grant (docs/market/gaps.md #2).
        store.shield.webDomains = extras.webDomainTokens.isEmpty ? nil : extras.webDomainTokens
    }
}
