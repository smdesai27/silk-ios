import Foundation
import Testing

// MARK: - The app targets' stamp read order
//
// UserDefaults has no compare-and-swap; the stamp is the proof-of-read the
// writers agree on, and the proof only works read stamp-first (the doctrine
// on `DayLog.recordClosedDays`, pinned at runtime by
// `TheGateCannotEraseAWriteItDidNotSee`). The app-target read sites —
// `SpendIntent.perform()` pairing its load with the grant save's compare,
// `AppModel.init()` seeding the cache `persist`/`syncLedgerIfStale` trust —
// obey the same law, but live outside this package: no `swift test` harness
// can run them without a simulator. So the ORDER itself is pinned here,
// textually, against the sources: in each file the first
// `SharedStore.ledgerStamp()` read must precede the first
// `SharedStore.loadLedger()` read. Read the other way, a write landing
// between the two seats a pre-write blob under a post-write stamp, the later
// compare "passes", and the wholesale save erases the other process's write
// — a close from the bar, or a Siri grant, gone.
//
// A textual pin is deliberately blunt: it cannot prove the compare uses the
// stamp it read, only that no one quietly re-inverts the two reads. That is
// the regression that happened, so that is what it pins.

@Suite struct TheAppReadsTheStampBeforeTheBlobItProves {

    /// SilkCoreTests/…/StampReadOrderTests.swift → repo root is four hops up.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SilkCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SilkCore
            .deletingLastPathComponent()   // repo root
    }

    private func assertStampFirst(in file: String,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(file),
                                encoding: .utf8)
        guard let stamp = source.range(of: "SharedStore.ledgerStamp()"),
              let blob = source.range(of: "SharedStore.loadLedger()") else {
            Issue.record("\(file) no longer reads both the stamp and the ledger",
                         sourceLocation: sourceLocation)
            return
        }
        #expect(stamp.lowerBound < blob.lowerBound,
                "\(file): the first ledger load precedes the first stamp read — the proof-of-read is inverted, and a write landing between the two reads will be erased by the next stamp-compared save",
                sourceLocation: sourceLocation)
    }

    @Test func spendIntentReadsTheStampBeforeTheLedgerItGrantsAgainst() throws {
        // perform()'s load/stamp pair is the first of each in the file; the
        // sweep further down was already stamp-first (and stays covered by
        // this same first-occurrence pin only through the pair above it).
        try assertStampFirst(in: "Silk/SpendIntent.swift")
    }

    @Test func appModelSeedsItsStampCacheBeforeLoadingTheLedger() throws {
        // init()'s pair is the first of each in the file. Blob-first there
        // desyncs the cache permanently: syncLedgerIfStale never reloads,
        // and the first persist writes the stale copy over a Siri grant.
        try assertStampFirst(in: "Silk/AppModel.swift")
    }
}
