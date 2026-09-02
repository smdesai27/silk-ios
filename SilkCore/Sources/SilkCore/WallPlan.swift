import Foundation

/// A read of a persisted blob, in three states rather than two.
///
/// Why a decode has three outcomes and not two. `try?` collapses "never
/// configured" and "configured, and the blob would not decode" into the same
/// nil, and the wall reads that nil as "nothing to enforce" and returns. Shield
/// settings persist across processes, so returning does not RAISE the wall — it
/// FREEZES it, with whatever grant exception was live still standing. That is
/// fail-OPEN on the one code path README rule 4 names, and it is why the
/// corrupt case has to be tellable from the absent one at the call site.
///
/// In Core and not beside the `UserDefaults` reader that produces it, because
/// the decision below is written against it and the decision is the half that
/// has to be testable off-device.
public enum Decoded<T> {
    case absent          // no data at the key: never configured
    case value(T)
    case corrupt         // data present, decode threw

    /// The value an enforcer may act on, with the absent key filled in by the
    /// empty value the caller nominates — and `nil` for the corrupt one, which
    /// is the state no default can stand in for. Reading a corrupt blob as
    /// empty is precisely the fail-open `WallPlan.plan` refuses below.
    public func orEmpty(_ empty: @autoclosure () -> T) -> T? {
        switch self {
        case .absent: return empty()
        case .value(let v): return v
        case .corrupt: return nil
        }
    }

    /// Present and unreadable — the state the caller logs and the plan refuses
    /// to write over.
    public var isCorrupt: Bool {
        if case .corrupt = self { return true }
        return false
    }

    public func map<U>(_ transform: (T) -> U) -> Decoded<U> {
        switch self {
        case .absent: return .absent
        case .value(let v): return .value(transform(v))
        case .corrupt: return .corrupt
        }
    }
}

/// What the wall should be, decided from what could be read — and nothing else.
///
/// The decision half of `Wall.reconcile`, lifted out of the process that owns
/// the `ManagedSettingsStore` so it can be run against every state the store
/// can be in without a device, a Screen Time authorization, or a shield
/// extension to render it. `reconcile` keeps exactly the part that cannot be
/// tested off-device: three decodes in, one write out.
///
/// Generic over the token so Core never sees `ApplicationToken` — an opaque
/// FamilyControls type that cannot cross into a Linux build. Tokens are
/// compared and unioned here and nothing else, so `Hashable` is the whole
/// requirement, and `Int` stands in for one perfectly in the tests.
public enum WallPlan {
    /// The three things a reconcile may do. Note that two of them are writes
    /// and one is a refusal: `leaveUntouched` is not "no change to make", it is
    /// "this process cannot say what the wall should be, and a wrong write
    /// here opens a door".
    public enum Plan<Token: Hashable>: Equatable {
        /// Write nothing. Whatever shield stands, stands.
        case leaveUntouched
        /// The user switched the wall off: clear every setting in the store.
        case clearAll
        /// Shield exactly these tokens.
        case shield(Set<Token>)
    }

    /// - Parameters:
    ///   - policy: `silk.policy`, three ways.
    ///   - extras: the wall selection's app tokens — apps blocked without a
    ///     name or launch entry of their own.
    ///   - doors: each door's app tokens, by door id.
    ///   - openDoors: the tokens belonging to doors that should be open now.
    ///     A closure and not a value because answering it needs the ledger and
    ///     the established day, which the caller already holds — and because it
    ///     must not be asked at all on the paths that refuse to write.
    public static func plan<Token: Hashable>(
        policy: Decoded<PolicyState>,
        extras: Decoded<Set<Token>>,
        doors: Decoded<[UUID: Set<Token>]>,
        openDoors: (PolicyState, [UUID: Set<Token>]) -> Set<Token>
    ) -> Plan<Token> {
        // The wall is apps only: every door's tokens plus the extras. An
        // ABSENT selection is an empty one, not an unconfigured wall; the
        // doors alone can carry the whole policy.
        //
        // A CORRUPT one is neither, and is why both keys arrive here as
        // `Decoded` rather than as the sets the storage loaders hand out
        // (those end in `?? FamilyActivitySelection()` and `?? [:]`, which is
        // right for a caller about to overwrite the blob with a picker and
        // wrong for the one caller enforcing it). Swallowing a decode failure
        // into an empty set makes `.shield([])` — a torn-down wall — out of a
        // key this process simply could not read, from ANY process, including
        // a shield render. FamilyControls tokens are opaque OS-versioned
        // blobs, so the realistic case is an iOS upgrade making
        // `silk.door.selections` unreadable while the policy still decodes
        // perfectly: the one shape where a readable policy and an unreadable
        // selection meet. The corrupt-policy branch below already refuses to
        // write an empty union for exactly this reason; it is the same
        // refusal, and README rule 4 makes no exception for the key that
        // happens to hold the tokens.
        //
        // Asked AFTER the policy's first two answers, because both are owed
        // regardless of what the selections say — and never asked at all on
        // those two paths.
        func readable() -> (blocked: Set<Token>, doors: [UUID: Set<Token>])? {
            guard let extraTokens = extras.orEmpty([]),
                  let doorTokens = doors.orEmpty([:]) else { return nil }
            return (doorTokens.values.reduce(into: extraTokens) { $0.formUnion($1) }, doorTokens)
        }

        switch policy {
        case .absent:
            // No configuration yet: nothing to enforce.
            return .leaveUntouched

        case .corrupt:
            // A policy that will not decode is a policy this process cannot
            // reason about, and leaving the wall alone would leave the shield
            // frozen exactly as the last reconcile left it — every live grant
            // exception still standing, for as long as the blob stays
            // unreadable. Nor can the grants be honoured: which of them are
            // still running is readable without the policy (`Grant.isActive`
            // takes no `dayStart` at all), but whether a hand-close has already
            // RETRACTED one is decided by `isClosed`, against a `dayStart`
            // derived from `policy.downHours` — the value that would not
            // decode. Honouring the grants without the closes would honour
            // precisely the exceptions the user revoked. So shield the full
            // union with NO exceptions — `openDoors` is not even called — and
            // let the next good read hand the minutes back.
            //
            // `wallEnabled` is inside the blob too, so it cannot be consulted
            // either. Shielding a user who had turned the wall off is a
            // visible, recoverable wrong; leaving a door open is the one this
            // rule forbids.
            //
            // Which is also why an empty union is a refusal to write rather
            // than a wall of nothing. An unreadable selection no longer
            // arrives here disguised as an empty one — `union()` turns that
            // case back at the door, for every policy and not just this one —
            // but an empty union under a policy this process cannot read is
            // still a second input it cannot reason about, and writing it
            // would tear down the whole standing shield: fail-open, on the
            // path this branch exists to keep closed.
            guard let read = readable(), !read.blocked.isEmpty else { return .leaveUntouched }
            return .shield(read.blocked)

        case .value(let policy):
            guard policy.wallEnabled else {
                // Off has to mean DOWN, and down means writing it. Leaving the
                // wall alone left `shield.applications` holding exactly what
                // the last enabled reconcile put there, and nothing else in
                // Silk clears it — so the wall the user switched off stayed up
                // for good, every later reconcile taking this branch and
                // returning again.
                //
                // The shape of the bug from outside: she turns the wall off,
                // the door stays shut anyway, she deletes Silk to be rid of
                // it. The shield settings survive the delete; the extension
                // that renders them does not. So iOS draws its own default
                // over the app — "TikTok is restricted." — with no Screen Time
                // restriction anywhere to explain it and no app left that
                // could take it down. That is the factory-reset review in
                // docs/market/gaps.md #5, reached from inside a working
                // install.
                //
                // This is not the fail-closed rule bending. Rule 4 governs
                // state that cannot be READ — the corrupt branch above. Here
                // the policy decoded and said off. Obeying it is the ledger
                // being the truth.
                //
                // Decided before the selections are consulted, and so still
                // owed when one of them is corrupt: off means down whatever
                // the token blobs say, and there is nothing in an unreadable
                // selection that could argue for keeping a shield the user
                // switched off. Fail-closed governs the doors, not the switch.
                return .clearAll
            }
            guard let read = readable() else { return .leaveUntouched }
            return .shield(read.blocked.subtracting(openDoors(policy, read.doors)))
        }
    }
}
