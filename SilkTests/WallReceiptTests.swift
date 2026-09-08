import Testing
import Foundation
import FamilyControls
@testable import Silk
@testable import SilkCore

// THE RECONCILE'S RECEIPT.
//
// `Wall.reconcile` returns a `Reconciled` — the policy, the door selections and
// the ledger it happened to read on its way to a verdict — so the one caller
// that needs the same three blobs does not decode them a second time. That
// caller is the shield's subtitle path, inside a 6 MB extension, in front of
// the frame the user is waiting on.
//
// The receipt is only worth having if it is HONEST about the paths that read
// nothing. `WallPlanTests` in the spine owns which plan comes out of which
// combination of blobs; what it cannot own is the receipt, because the receipt
// is assembled here, over the real `UserDefaults` suite, from reads the pure
// function never makes. Two of its three fields are optional precisely so the
// refusing paths can say "not read" rather than "empty" — and a receipt that
// answered `GrantLedger()` on a path that never loaded the ledger would hand
// the shield a blank ledger to render minutes from.
//
// Hosted by the app, so `SharedStore` resolves against the real App Group;
// `.serialized` over a non-parallel target, and every test starts from a wipe,
// because that state is global to the process.

@Suite(.serialized) @MainActor struct TheReconcileReportsWhatItActuallyRead {

    /// Not a policy any decoder can read. Written as raw bytes on purpose:
    /// `loadPolicyDecoded` distinguishes ABSENT from CORRUPT, and the whole
    /// fail-closed branch hangs on that distinction, so the fixture has to
    /// produce corrupt rather than merely missing.
    private static let garbage = Data("{ not a policy }".utf8)

    /// A policy this process cannot read takes the refusing path, and the
    /// receipt says so in three places at once.
    ///
    /// `policy` is nil because `Decoded.corrupt` collapses to the same nil the
    /// plain loader gives. `ledger` is nil because `WallPlan.plan` never calls
    /// `openDoors` on this arm — there is nothing to except a door from when
    /// the day boundary cannot be derived — and the receipt reports the read it
    /// did not make instead of inventing one.
    ///
    /// **And the migration flag is the sharp one.** `Wall.reconcile` clears the
    /// legacy category shields once per install and then marks the store as
    /// migrated; the mark is set only after the app layer has been written, on
    /// the one path that wrote it. A process that returned before writing has
    /// migrated nothing and must not be able to claim it did — because the flag
    /// it would leave says "already cleared" to every later reconcile, and the
    /// legacy category shield may be the whole wall an unreadable install still
    /// has. Setting it here would be the fail-open this file's subject exists
    /// to forbid, arriving through a bookkeeping line.
    @Test func aPolicyThatWillNotDecodeReadsNoLedgerAndClaimsNoMigration() {
        SharedStore.wipeAll()
        SharedStore.defaults.set(Self.garbage, forKey: "silk.policy")
        #expect(SharedStore.loadPolicy() == nil, "the fixture's blob decoded after all")
        #expect(SharedStore.categoryShieldsMigrated == false,
                "the wipe left the migration flag standing")

        let receipt = Wall.reconcile()

        #expect(receipt.policy == nil,
                "the receipt handed back a policy off a blob that would not decode")
        #expect(receipt.ledger == nil,
                "the receipt claims a ledger read the refusing path never made — the shield would render minutes off a ledger nobody loaded")
        #expect(receipt.doors.isEmpty)
        #expect(SharedStore.categoryShieldsMigrated == false,
                "a reconcile that wrote no wall marked the install migrated: the next readable reconcile will skip the one-shot clear, and a legacy category shield stays up with nothing left that can take it down")
    }

    /// And the readable path, which is the other half: a policy that decodes
    /// and a door selection beside it, and the receipt carries every read.
    ///
    /// The ledger is the one to watch. It is nil above and non-nil here from
    /// the SAME field, which is what makes the optional mean something — the
    /// shield can tell "the reconcile refused to write" from "the reconcile
    /// wrote, and here is what it read" without asking a second question.
    @Test func aReadablePolicyCarriesThePolicyTheDoorsAndTheLedger() {
        SharedStore.wipeAll()
        let door = Door(name: "Instagram")
        SharedStore.save(policy: PolicyState(budgetMinutes: 40,
                                             downHours: nightWellClearOfNow(),
                                             doors: [door]))
        // An empty selection is still a selection: the door is bound, it simply
        // shields nothing on a simulator that cannot hand out real tokens. What
        // the receipt has to carry is the KEY — the shield finds the door an app
        // belongs to by looking this map up, and an empty map means no subtitle.
        SharedStore.save(doorSelections: [door.id: FamilyActivitySelection()])

        let receipt = Wall.reconcile()

        #expect(receipt.policy != nil,
                "the receipt dropped a policy that decoded perfectly")
        #expect(receipt.policy?.doors.first?.id == door.id,
                "the receipt carried a policy that is not the one in the store")
        #expect(receipt.doors[door.id] != nil,
                "the receipt dropped the door selections — the shield has no way to say which door an app belongs to")
        #expect(receipt.ledger != nil,
                "the receipt reports no ledger read on a path that computed the open doors from one")
    }

    /// The migration flag on the path that DOES write, so the assertion above
    /// is a fact about the refusal and not about a flag nothing ever sets.
    ///
    /// Without this the corrupt-policy test passes against a `Wall.reconcile`
    /// that never marks anything at all — which would be a different defect
    /// with the same green tick.
    @Test func aReconcileThatWritesTheWallMarksTheMigration() {
        SharedStore.wipeAll()
        SharedStore.save(policy: PolicyState(budgetMinutes: 40,
                                             downHours: nightWellClearOfNow(),
                                             doors: [Door(name: "Instagram")]))
        #expect(SharedStore.categoryShieldsMigrated == false,
                "the wipe left the migration flag standing")

        _ = Wall.reconcile()

        #expect(SharedStore.categoryShieldsMigrated,
                "a readable reconcile never cleared the legacy category shields, so no install upgraded past them")
    }
}
