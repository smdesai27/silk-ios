import UIKit

/// The curated door catalogue: name → how to open it. Keyed on the word the
/// user chose, never on Apple's opaque token — that inversion is what makes
/// "and it opens" possible at all (docs/market/positioning.md §5).
///
/// From Silk's own foreground, `UIApplication.open` takes custom schemes and is
/// explicitly NOT constrained by LSApplicationQueriesSchemes. Universal links
/// are the fallback; if one ever falls through to Safari, Silk's own web shield
/// catches it — the failure fails closed.
enum LaunchCatalog {

    struct Entry {
        let display: String          // brand casing, shown in setup
        let names: [String]          // matchable names, lowercased
        let scheme: String?          // custom scheme, tried first
        let universalLink: String?   // https fallback
    }

    static let entries: [Entry] = [
        .init(display: "Instagram", names: ["instagram", "ig", "insta"], scheme: "instagram://", universalLink: "https://www.instagram.com/"),
        .init(display: "TikTok", names: ["tiktok"], scheme: "snssdk1233://", universalLink: "https://www.tiktok.com/"),
        .init(display: "YouTube", names: ["youtube", "yt"], scheme: "youtube://", universalLink: "https://www.youtube.com/"),
        .init(display: "X", names: ["twitter", "x"], scheme: "twitter://", universalLink: "https://x.com/"),
        .init(display: "Reddit", names: ["reddit"], scheme: "reddit://", universalLink: "https://www.reddit.com/"),
        .init(display: "Snapchat", names: ["snapchat", "snap"], scheme: "snapchat://", universalLink: "https://www.snapchat.com/"),
        .init(display: "Facebook", names: ["facebook", "fb"], scheme: "fb://", universalLink: "https://www.facebook.com/"),
        .init(display: "Threads", names: ["threads"], scheme: "barcelona://", universalLink: "https://www.threads.net/"),
        .init(display: "Pinterest", names: ["pinterest"], scheme: "pinterest://", universalLink: "https://www.pinterest.com/"),
        .init(display: "Twitch", names: ["twitch"], scheme: "twitch://", universalLink: "https://www.twitch.tv/"),
        .init(display: "Netflix", names: ["netflix"], scheme: "nflx://", universalLink: "https://www.netflix.com/"),
        .init(display: "LinkedIn", names: ["linkedin"], scheme: "linkedin://", universalLink: "https://www.linkedin.com/"),
        // Discord and WhatsApp are deliberately absent — no reliable public
        // scheme; absent even from Opener's 244-app catalogue.
    ]

    /// Open the app behind a door name. Best-effort by design: if it misses,
    /// the grant still happened and the wall is still down — the caller shows
    /// the read-back as always and she taps the icon. Never an error.
    @MainActor
    static func open(doorName: String) {
        let key = doorName.lowercased()
        guard let entry = entries.first(where: { $0.names.contains(key) }) else { return }

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

    /// Setup uses this to keep door-naming inside the catalogue, converting
    /// "and it opens" from a courtesy into a guarantee.
    static func knows(_ name: String) -> Bool {
        entries.contains { $0.names.contains(name.lowercased()) }
    }
}
