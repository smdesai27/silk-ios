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

    /// A door asked for at the bar is answered with the one place a name and an
    /// app are given together. Four words, no hour — nothing here is waiting
    /// for the morning.
    @Test func aDoorAskedForAtTheBarNamesWhereDoorsAreMade() {
        #expect(SilkStrings.addInSettings == "Add it in Settings.")
    }

    /// A selection whose door has left the policy owns nothing. The wall unions
    /// every stored selection with no policy filter, so a door removed by
    /// sentence used to leave its app shielded for good — no row, no grant
    /// path, no Settings entry, and only a wipe to clear it. The String value
    /// stands where a FamilyActivitySelection would: it is the key set that
    /// decides whether an app stays shielded, and the value is beside the rule.
    @Test func aPolicyOwnsOnlyItsOwnDoorsEntries() {
        let reddit = Door(name: "Reddit")
        let tiktok = Door(name: "TikTok")
        let state = PolicyState(budgetMinutes: 40,
                                downHours: DownHours(start: TimeOfDay(hour: 22),
                                                     end: TimeOfDay(hour: 7)),
                                doors: [reddit])
        let store = [reddit.id: "reddit's app", tiktok.id: "a door that left"]
        #expect(state.owned(store) == [reddit.id: "reddit's app"])
    }

    /// A policy with no doors left owns nothing at all — the last removal has
    /// to take the last selection with it, or the wall stands over a Settings
    /// page with nothing on it.
    @Test func theLastDoorLeavingTakesItsSelection() {
        let door = Door(name: "Reddit")
        let empty = PolicyState(budgetMinutes: 40,
                                downHours: DownHours(start: TimeOfDay(hour: 22),
                                                     end: TimeOfDay(hour: 7)),
                                doors: [])
        #expect(empty.owned([door.id: "reddit's app"]).isEmpty)
    }
}
