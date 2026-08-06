import UIKit
import SilkCore

/// The half of the catalogue that needs a running app: opening the thing.
///
/// The data — display, names, scheme, link — moved to SilkCore, where the
/// invariants that make "and it opens" a guarantee can be asserted headlessly
/// (SilkCore/Sources/SilkCore/LaunchCatalog.swift states them;
/// LaunchCatalogTests asserts them). What is left here is the one line that
/// cannot: `UIApplication`, which exists only inside the app.
///
/// Callers are unchanged. `LaunchCatalog.entries`, `LaunchCatalog.knows(_:)`
/// and `LaunchCatalog.open(doorName:)` all still resolve to the same names,
/// because this is an extension of the spine's own enum rather than a second
/// type wearing its name.
extension LaunchCatalog {

    /// Open the app behind a door name. Best-effort by design: if it misses,
    /// the grant still happened and the wall is still down — the caller shows
    /// the read-back as always and she taps the icon. Never an error.
    ///
    /// The fallback carries `.universalLinksOnly` so a miss can never land in
    /// Safari, where Silk's own web shield would have to catch it. An entry
    /// whose link is nil has no second try on purpose — see the entry's own
    /// note in the spine for why writing one down would be a claim the domain's
    /// AASA does not support.
    @MainActor
    static func open(doorName: String) {
        guard let entry = entry(named: doorName) else { return }

        if let scheme = entry.scheme, let url = URL(string: scheme) {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success, let link = entry.universalLink, let fallback = URL(string: link) {
                    UIApplication.shared.open(fallback, options: [.universalLinksOnly: true])
                }
            }
        } else if let link = entry.universalLink, let url = URL(string: link) {
            UIApplication.shared.open(url, options: [.universalLinksOnly: true])
        }
    }
}
