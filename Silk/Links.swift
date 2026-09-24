import Foundation

/// The two addresses the store requires the app to carry, held in one place.
///
/// App Review Guideline 5.1.1(i) requires the privacy policy to be reachable
/// "within the app in an easily accessible manner" as well as from the
/// listing. It is not a sentence Silk speaks — the row's label is
/// `SilkStrings.privacy` — so it lives here and not in `Strings.swift`. The
/// support page is the other one: Guideline 1.5 asks that "your app and its
/// Support URL include an easy way to contact you", so Settings carries a row
/// for it beside the privacy row.
///
/// **The host:** GitHub Pages on the public repository. The pages are served
/// from the `gh-pages` branch, which holds the site and nothing else —
/// index.html, privacy.html, support.html and a `.nojekyll` marker — so a
/// change to the policy is a commit there and no build. The privacy URL also
/// goes in the App Store Connect version page's Privacy Policy field.
enum SilkLinks {
    static let privacyPolicy = URL(string: "https://smdesai27.github.io/silk-ios/privacy.html")!
    static let support = URL(string: "https://smdesai27.github.io/silk-ios/support.html")!
}
