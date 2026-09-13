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
/// **The host:** GitHub Pages on the public repository. The page is served
/// from the `gh-pages` branch, which holds the two site files and nothing
/// else, so a change to the policy is a commit there and no build. The same
/// URL goes in the App Store Connect version page's Privacy Policy field.
enum SilkLinks {
    static let privacyPolicy = URL(string: "https://smdesai27.github.io/silk-ios/privacy.html")!
}
