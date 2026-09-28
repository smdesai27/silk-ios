import SwiftUI
import SafariServices

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
/// and no screen in the app says so at length. The page does, and setup
/// shows it once on the way to Now.
///
/// **The host:** GitHub Pages on the public repository. The pages are served
/// from the `gh-pages` branch, which holds the site and nothing else —
/// index.html, how.html, privacy.html, support.html and a `.nojekyll`
/// marker — so a change to any page is a commit there and no build. The
/// privacy URL also goes in the App Store Connect version page's Privacy
/// Policy field.
enum SilkLinks {
    static let howItWorks = URL(string: "https://smdesai27.github.io/silk-ios/how.html")!
    static let privacyPolicy = URL(string: "https://smdesai27.github.io/silk-ios/privacy.html")!
    static let support = URL(string: "https://smdesai27.github.io/silk-ios/support.html")!
}

/// The three pages Settings' Info group opens, and the one of them setup
/// shows once. Identifiable so a single `.sheet(item:)` serves all three.
enum InfoPage: String, Identifiable {
    case howItWorks, privacy, support

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .howItWorks: SilkLinks.howItWorks
        case .privacy: SilkLinks.privacyPolicy
        case .support: SilkLinks.support
        }
    }
}

/// Safari, in a sheet inside Silk, so reading a page does not leave the app.
///
/// `SFSafariViewController` and not a web view, for the privacy policy's
/// sake: it loads in Safari's own process, so the policy's "Silk has no
/// network code" stays true. A `WKWebView` would make Silk the thing
/// fetching the page. Offline, Safari draws its own can't-open page; nothing
/// in Silk waits on it.
///
/// Done ends the sheet through the delegate. Safari's own dismissal does not
/// reach a SwiftUI binding, and a binding left set would hold the next page
/// shut.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .done
        safari.delegate = context.coordinator
        return safari
    }

    func updateUIViewController(_ safari: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}
