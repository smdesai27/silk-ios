import Foundation

/// The addresses the app opens, held in one place: the two the store
/// requires, and the page that says how Silk works.
///
/// App Review Guideline 5.1.1(i) requires the privacy policy to be reachable
/// "within the app in an easily accessible manner" as well as from the
/// listing. It is not a sentence Silk speaks — the row's label is
/// `SilkStrings.privacy` — so it lives here and not in `Strings.swift`. The
/// support page is the other one: Guideline 1.5 asks that "your app and its
/// Support URL include an easy way to contact you", so Settings carries a row
/// for it beside the privacy row. The third is Silk's own: a new install
/// does not know a blocked app opens from Silk, by a sentence, after a wait,
/// and no screen in the app says so at length. The page does.
///
/// **The host:** GitHub Pages on the public repository. The pages are served
/// from the `gh-pages` branch, which holds the site and nothing else —
/// index.html, how.html, privacy.html, support.html and a `.nojekyll`
/// marker — so a change to any page is a commit there and no build. The
/// privacy URL also
/// goes in the App Store Connect version page's Privacy Policy field.
enum SilkLinks {
    static let howItWorks = URL(string: "https://smdesai27.github.io/silk-ios/how.html")!
    static let privacyPolicy = URL(string: "https://smdesai27.github.io/silk-ios/privacy.html")!
    static let support = URL(string: "https://smdesai27.github.io/silk-ios/support.html")!
}
