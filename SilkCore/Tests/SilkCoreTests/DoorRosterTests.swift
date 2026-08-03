import Testing
@testable import SilkCore

// MARK: - DoorRoster: the cap and the dedupe behind Settings' door editing

/// The rules the door editor leans on: at most six doors, names deduped
/// case-insensitively against every spoken form a door answers to, and an
/// add list that only offers what is genuinely free. The overlay itself
/// needs a simulator; the arithmetic does not.
@Suite struct DoorRosterTests {
    @Test func capIsSix() {
        #expect(DoorRoster.cap == 6)
        #expect(DoorRoster.canAdd("Reddit", taken: [], count: 5))
        #expect(!DoorRoster.canAdd("Reddit", taken: [], count: 6))
    }

    /// "instagram" and "Instagram" are one name — a duplicate in any casing
    /// never joins.
    @Test func dedupeIsCaseInsensitive() {
        #expect(!DoorRoster.canAdd("Instagram", taken: ["instagram"], count: 1))
        #expect(!DoorRoster.canAdd("INSTAGRAM", taken: ["Instagram"], count: 1))
        #expect(DoorRoster.canAdd("TikTok", taken: ["instagram"], count: 1))
    }

    /// The add list is the catalogue minus every name already spoken for, in
    /// catalogue order.
    @Test func availableExcludesTakenNames() {
        let catalog = ["Instagram", "TikTok", "YouTube", "X"]
        #expect(DoorRoster.available(catalog: catalog, taken: ["tiktok"])
                == ["Instagram", "YouTube", "X"])
        #expect(DoorRoster.available(catalog: catalog, taken: [])
                == catalog)
        #expect(DoorRoster.available(catalog: catalog,
                                     taken: ["instagram", "tiktok", "youtube", "x"]).isEmpty)
    }

    /// A door's aliases hold its seats too: a door answering to "x" keeps the
    /// catalogue's "X" off the list, however the door itself is spelled.
    @Test func aliasesCountAsTaken() {
        let door = Door(name: "Twitter", aliases: ["x"])
        #expect(DoorRoster.available(catalog: ["X", "Reddit"],
                                     taken: door.spokenForms) == ["Reddit"])
        #expect(!DoorRoster.canAdd("X", taken: door.spokenForms, count: 1))
    }

    /// The editor's action reads in plain words; "rebind" stays internal
    /// vocabulary (DoorBinding), never a sentence on screen.
    @Test func changeAppIsPlainWords() {
        #expect(SilkStrings.rebind == "Change app")
    }
}
