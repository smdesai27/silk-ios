import Foundation

/// The one address the store requires the app to carry, held in one place.
///
/// App Review Guideline 5.1.1(i) requires the privacy policy to be reachable
/// "within the app in an easily accessible manner" as well as from the
/// listing. It is not a sentence Silk speaks — the row's label is
/// `SilkStrings.privacy` — so it lives here and not in `Strings.swift`. The
/// listing's Support URL is the listing's alone; nothing in the build opens
/// it, so nothing here names it.
///
/// **The host is not yet chosen.** The policy page itself is written and
/// unhosted, kept outside this repository, and the domain below is the
/// placeholder the submission runbook tells you to replace before the
/// archive. A link that 404s is a rejection of its own, so the runbook gates
/// on it.
enum SilkLinks {
    static let privacyPolicy = URL(string: "https://silkapp.example/privacy")!
}
