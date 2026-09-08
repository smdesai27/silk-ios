import SwiftUI
import SilkCore

// The toast: every refusal, and every change still worth taking back. A "no"
// weighs less than a decision, so it never earns a line on the page — it
// arrives, it is read, it leaves, and the page is unchanged.
// (CARDS.md, Principles: "Refusals are toast-weight" · Interactive.html:157-165, 393-402)

/// Undo is leaf lifted until it reads on ink, and pine shadow when it sits on
/// linen — deliberately not leaf itself: the page owns the screen's one pop, so
/// a toast borrows a cousin. The night value is a real token; the day one is
/// the single hue the toast introduces, and it exists nowhere else.
/// (Interactive.html:162 #9FC08F, :165 #4A5A50 = tokens/color.css:19 pine-shadow)
private extension Color {
    static let toastUndoDay = Color(red: 0.624, green: 0.753, blue: 0.561)    // #9FC08F
    static let toastUndoNight = Color(red: 0.290, green: 0.353, blue: 0.314)  // #4A5A50
}

// ============================================================
// The value
// ============================================================

/// What a toast is: words, and the one thing that can still be done about them.
///
/// The action itself lives beside this on ToastCenter. Behaviour inside the
/// value would make the value uncomparable, and this one has to diff — the
/// arrival and the departure are driven by comparing it against nothing.
///
/// The label used to be synthesized from `SilkStrings.undo` whenever an action
/// existed, and the value could not carry another word. That made the toast a
/// liar in the one place it speaks after a Settings commit: a parked loosening's
/// only affordance read "Undo" while meaning "withdraw the ask I just made", and
/// the thing the user actually wanted — have it now — was two page-swipes away
/// on a row she had no reason to look for. So the word is carried, not assumed.
struct SilkToast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    /// Non-nil only when an action rides along: `SilkStrings.undo` for a change
    /// that can be taken back, `SilkStrings.applyNow` for one that is waiting for
    /// tomorrow. The toast still speaks no words of its own — both come from the
    /// string table, and the caller chooses which.
    var actionLabel: String? = nil
    /// The action's name in the accessibility tree, chosen by the caller for the
    /// same reason the label is: the two buttons do opposite things and a walk
    /// has to be able to tell them apart. `silk.toast.undo` is unchanged and
    /// stays the default, so every walk that matches on it still does.
    var actionID: String = "silk.toast.undo"
}

// ============================================================
// The center
// ============================================================

/// One toast, one timer, one depth. A newer refusal replaces the current one
/// instead of stacking beneath it: a stack would be a feed, and Silk has no
/// feed. Replacing also cancels the pending dismissal, so the words you can
/// still read are always the words with time left on them.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: SilkToast?

    /// Kept out of the observed value on purpose (see SilkToast).
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// Long enough to read; short enough that it is gone before it nags.
    /// (Interactive.html:401 — `undoFn?4500:2200`)
    private static let plainLifetime: Duration = .milliseconds(2200)

    /// An action buys longer because it asks for a decision, not just a glance.
    /// The prototype's 4.5s stands as the default, but the window is a
    /// setting now — the third row on Settings — so the owner sets it here
    /// and every action-bearing toast lives exactly that long. It is the undo
    /// window's own number, and the second thing it now bounds — "Apply now."
    /// — deserves it for the identical reason: it is a decision on screen, and
    /// the receipt is the only place it is offered at the point of the gesture.
    var undoLifetime: Duration = .milliseconds(4500)

    /// The general form: words, one labelled action, and the name that action
    /// answers to. Both callers below fold into this.
    func show(_ message: String, label: String, id: String, action: @escaping () -> Void) {
        show(message, toast: SilkToast(message: message, actionLabel: label, actionID: id),
             action: action)
    }

    /// The undo-bearing form, unchanged at every call site that had it: the word
    /// is `SilkStrings.undo` and the identifier is `silk.toast.undo`.
    func show(_ message: String, undo: (() -> Void)? = nil) {
        show(message,
             toast: SilkToast(message: message,
                              actionLabel: undo == nil ? nil : SilkStrings.undo),
             action: undo)
    }

    private func show(_ message: String, toast: SilkToast, action: (() -> Void)?) {
        expiry?.cancel()
        self.action = action
        current = toast

        // Read before the sleep: the lifetime the toast was shown with is the
        // lifetime it gets, even if the setting moves under it. Under
        // VoiceOver an action-bearing toast lives three times as long: the
        // announcement is the only way its Undo is found, and it is found by
        // ear, after the message, at speech pace.
        var lifetime = action == nil ? Self.plainLifetime : undoLifetime
        if action != nil, UIAccessibility.isVoiceOverRunning { lifetime *= 3 }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            // A replaced toast cancels its predecessor mid-sleep; the loser
            // must not take the winner off the screen with it.
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// The change is its own receipt. The action runs and the toast goes at
    /// once — Silk does not confirm a confirmation. True of both words it can
    /// carry: an undone change reads itself back off the row, and a loosening
    /// applied by the key lands on the row the same instant.
    func performAction() {
        let action = self.action
        dismiss()
        action?()
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        action = nil
        current = nil
    }
}

// ============================================================
// The capsule
// ============================================================

/// Ink on paper flips here, and only here. A toast is laid *on* the page, so
/// it takes the opposite ground of whatever it covers — dark on the day paper,
/// light on the night ground. (Interactive.html:158, 164)
///
/// So the night pill wears `Silk.linen` and `Silk.ink`, the DAY cloth, and that
/// is not an oversight left over from the slate: the flip is the whole design of
/// this component, and it is the one surface in Silk that a night token would
/// spoil. `Silk.Night.linen` is for surfaces raised off the night ground; this
/// one is laid over it, face down.
///
/// **It may not wrap and it may not truncate** — `.lineLimit(1)` plus
/// `.fixedSize(horizontal: true, …)` means an over-long capsule grows past the
/// glass and clips rather than folding. The widest thing it can now be asked to
/// say is a parked ceiling clearing on the longest name in the launch catalogue:
/// "Tomorrow: Instagram no cap", 26 characters, beside "Apply now."
///
/// Measured rather than estimated. The walk lays out "Tomorrow: Reddit no cap"
/// with the key beside it and reads back **285.2pt** including this view's 36pt
/// of padding; "Instagram" is 22pt wider than "Reddit" at this font, so the worst
/// case is **307pt of the 375** on the narrowest device Silk supports, with 68 to
/// spare. Silk's fonts are fixed size, so Dynamic Type cannot widen it.
///
/// Door names come from the catalogue and nowhere else (`addDoor` is only reached
/// from the add overlay's chips and setup's; the bar's `.addDoor` is refused with
/// "Add it in Settings."), so nine characters is a bound and not a hope — and
/// `ParkedReceiptTests` walks every catalogue entry against it, so a thirteenth
/// name long enough to crowd the glass fails in the spine rather than on a phone.
private struct ToastCapsule: View {
    var toast: SilkToast
    var night: Bool
    var onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {                       // .undo margin-left:12px (Interactive.html:162)
            Text(toast.message)
                .font(Silk.sans(13, weight: .medium))
                // Refusals are time-statements; tabular so a replacement can
                // swap "5:00" for "9:00" without the sentence shifting.
                .monospacedDigit()
                .contentTransition(.opacity)
                .foregroundStyle(night ? Silk.ink : Silk.paper)
                .accessibilityIdentifier("silk.toast")

            if let label = toast.actionLabel {
                Button(action: onAction) {
                    // Weight 500 is Silk's ceiling — the canon gives it no
                    // bold, and the colour already sets the word apart.
                    Text(label)
                        .font(Silk.sans(13, weight: .medium))
                        .foregroundStyle(night ? Color.toastUndoNight : .toastUndoDay)
                        .contentTransition(.opacity)
                        .contentShape(Rectangle().inset(by: -14))
                }
                .buttonStyle(.plain)                // no system tint on Silk's ground
                .accessibilityIdentifier(toast.actionID)
            }
        }
        .lineLimit(1)
        // white-space:nowrap — a refusal that needs two lines is not a refusal.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 10)                     // padding:10px 18px (Interactive.html:159)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(night ? Silk.linen : Silk.ink)
        )
    }
}

// ============================================================
// The host
// ============================================================

/// Wrap the pager in this once, at the root. Anything inside can reach the
/// center from the environment and say a thing; only the root decides where
/// the words land and which ground they land on.
struct ToastHost<Content: View>: View {
    var center: ToastCenter
    /// Night is the down-hours window handed down by the container — never the
    /// system appearance. The toast inverts against it, so it must be told.
    var night: Bool
    var content: Content

    init(center: ToastCenter, night: Bool, @ViewBuilder content: () -> Content) {
        self.center = center
        self.night = night
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .environment(center)

            // The toast takes the short end of the 350–450ms band — it is an
            // aside, not a state change (Interactive.html:159, `.4s`).
            //
            // Scoped to this layer and no wider: ToastHost wraps the whole app,
            // and a toast almost always arrives in the same transaction as the
            // change it reports, so on the ZStack the .4s would be lent to the
            // ensō and the doors moving underneath it.
            //
            // Replacement is a text change on the same view, not a second
            // toast: nothing re-enters, and the depth stays one.
            toastLayer
                .animation(Silk.motion(Silk.Motion.toast), value: center.current)
        }
        // The host fills whatever it is given: a toast arriving must not resize
        // the page under it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = center.current {
            ToastCapsule(toast: toast, night: night) { center.performAction() }
                .padding(.top, 58)                  // top:58px (Interactive.html:158)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // 58 is measured from the glass, not from the safe area —
                // the toast sits over the status bar's own margin.
                .ignoresSafeArea()
                // Hidden, it rests 14pt high; it arrives by falling into
                // place and leaves the way it came.
                // (Interactive.html:158, 161 — translate(-50%,-14px) → 0)
                .transition(.offset(y: -14).combined(with: .opacity))
                .zIndex(30)                         // z-index:30 (Interactive.html:160)
                // A toast lives seconds and never takes focus, so its words
                // are announced. Replacement is a text change on the same
                // view, which is why this keys on the message, not appearance.
                // The action is part of what is announced: "Reddit 20 min.
                // Undo." — without it the one control on the toast was never
                // spoken before it expired.
                .onChange(of: toast.message, initial: true) { _, message in
                    let spoken = toast.actionLabel.map { "\(message) \($0)" } ?? message
                    AccessibilityNotification.Announcement(spoken).post()
                }
        }
    }
}

// ============================================================

#if DEBUG
#Preview {
    HStack(spacing: 0) {
        ToastGallery(night: false)
        ToastGallery(night: true)
    }
}

/// Both grounds, both weights. The stills are frozen capsules because a live
/// toast shows itself for 2.2 seconds — tap the ground to watch the real one
/// arrive, replace itself, and leave.
private struct ToastGallery: View {
    var night: Bool
    @State private var center = ToastCenter()

    /// Every word here is composed from the string table plus user data: the
    /// component adds no sentence of its own, and neither does its preview.
    private let refusal = "0 \(SilkStrings.leftToday)"
    private let receipt = "\(SilkStrings.tomorrow) 60"
    /// The widest capsule the app can produce: the longest catalogue name, the
    /// clearing form of a ceiling, and a second control beside it. It is in the
    /// gallery so the one thing that would break this component — a message that
    /// runs off the glass — is looked at every time anyone opens the file.
    private let widest = "\(SilkStrings.tomorrow) Instagram \(SilkStrings.noCap.lowercased())"

    var body: some View {
        ToastHost(center: center, night: night) {
            VStack(spacing: 20) {
                Spacer()
                ToastCapsule(toast: SilkToast(message: refusal),
                             night: night, onAction: {})
                ToastCapsule(toast: SilkToast(message: receipt,
                                              actionLabel: SilkStrings.undo),
                             night: night, onAction: {})
                ToastCapsule(toast: SilkToast(message: widest,
                                              actionLabel: SilkStrings.applyNow,
                                              actionID: "silk.toast.apply"),
                             night: night, onAction: {})
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(night ? Silk.Night.ground : Silk.paper)
            .contentShape(Rectangle())
            .onTapGesture { center.show(refusal) }
            .onLongPressGesture {
                center.show(widest, label: SilkStrings.applyNow,
                            id: "silk.toast.apply", action: {})
            }
        }
    }
}
#endif
