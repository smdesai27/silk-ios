import ManagedSettings
import Foundation
import SilkCore

/// One button, one meaning: acknowledged. The wall never grants from here —
/// the only way to a grant is to open Silk and ask.
final class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // Every tap is a wake; every wake reconciles (re-lock layer 4).
        Wall.reconcile()
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        Wall.reconcile()
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        Wall.reconcile()
        completionHandler(.close)
    }
}
