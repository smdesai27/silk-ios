/// The roster rules for the doors group: how many doors there can be, and
/// which catalogue names are still free to become one.
///
/// Settings' door editor leans on both — the add row hides at the maximum, and
/// the add overlay only offers names that are not already doors. Pure name
/// lists in, answers out: FamilyControls and the catalogue itself stay in the
/// app layer, so the rules run — and are tested — on any platform.
public enum DoorRoster {
    /// The existing product rule: at most six doors. Setup enforces the same
    /// number on its chips.
    ///
    /// Named `maxDoors` and not `cap`: a door now carries a daily cap of its
    /// own, and the app's removal-and-undo path has to read a door's cap and
    /// ask `canAdd` within a few lines of each other. One word meaning two
    /// unrelated things, at the site where confusing them is expensive.
    public static let maxDoors = 6

    /// Catalogue names not already claimed by a door, in catalogue order.
    /// `taken` is every spoken form of every door — its name and nothing else
    /// now that `Door.spokenForms` is a one-element list — so a door answering
    /// to "x" keeps the catalogue's "X" off the list too.
    /// Case-insensitive throughout — "instagram" and "Instagram" are one name.
    public static func available(catalog: [String], taken: [String]) -> [String] {
        let taken = Set(taken.map { $0.lowercased() })
        return catalog.filter { !taken.contains($0.lowercased()) }
    }

    /// Whether `name` may become a door: room under `maxDoors`, and no existing
    /// door already answers to it (case-insensitive).
    public static func canAdd(_ name: String, taken: [String], count: Int) -> Bool {
        count < maxDoors && !taken.contains { $0.lowercased() == name.lowercased() }
    }
}
