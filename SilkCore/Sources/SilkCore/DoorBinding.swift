/// The gate between the system picker and a door binding.
///
/// A door maps one name to one app — the shield exception and the launch both
/// lean on that being singular — so a binding selection must be exactly one
/// application token and nothing else: no second app, no category, no web
/// domain. Truncating a plural return to its first token would bind an app
/// the user never singled out, so a plural return binds nothing and asks again.
///
/// Pure counts in, verdict out. FamilyControls types stay in the app layer;
/// the rule itself runs — and is tested — on any platform.
public enum DoorBindingVerdict: Equatable, Sendable {
    /// Exactly one app, nothing else: bind it.
    case bound
    /// Nothing at all: the user backed out. Leave the door unbound, say nothing.
    case cancelled
    /// Anything else — extra apps, a category, a web domain. Do not bind;
    /// show the correction and let the user pick again.
    case retry
}

public enum DoorBinding {
    public static func validate(applications: Int, categories: Int, webDomains: Int) -> DoorBindingVerdict {
        if applications == 1 && categories == 0 && webDomains == 0 { return .bound }
        if applications == 0 && categories == 0 && webDomains == 0 { return .cancelled }
        return .retry
    }
}
