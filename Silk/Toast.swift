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

/// What a toast is: words, and whether something can still be taken back.
///
/// The undo *action* lives beside this on ToastCenter. Behaviour inside the
/// value would make the value uncomparable, and this one has to diff — the
/// arrival and the departure are driven by comparing it against nothing.
struct SilkToast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    /// Non-nil only when an Undo rides along, and then it is always
    /// SilkStrings.undo — the toast speaks no words of its own.
    var undoLabel: String? = nil

    var carriesUndo: Bool { undoLabel != nil }
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
    @ObservationIgnored private var undoAction: (() -> Void)?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// Long enough to read; short enough that it is gone before it nags.
    /// (Interactive.html:401 — `undoFn?4500:2200`)
    private static let plainLifetime: Duration = .milliseconds(2200)

    /// Undo buys longer because it asks for a decision, not just a glance.
    /// The prototype's 4.5s stands as the default, but the window is a
    /// setting now — the third row on Settings — so the owner sets it here
    /// and every undo-bearing toast lives exactly that long.
    var undoLifetime: Duration = .milliseconds(4500)

    func show(_ message: String, undo: (() -> Void)? = nil) {
        expiry?.cancel()
        undoAction = undo
        current = SilkToast(message: message,
                            undoLabel: undo == nil ? nil : SilkStrings.undo)

        // Read before the sleep: the lifetime the toast was shown with is the
        // lifetime it gets, even if the setting moves under it.
        let lifetime = undo == nil ? Self.plainLifetime : undoLifetime
        expiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            // A replaced toast cancels its predecessor mid-sleep; the loser
            // must not take the winner off the screen with it.
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// The change is its own receipt. Undo runs and the toast goes at once —
    /// Silk does not confirm a confirmation.
    func performUndo() {
        let action = undoAction
        dismiss()
        action?()
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        undoAction = nil
        current = nil
    }
}

// ============================================================
// The capsule
// ============================================================

/// Ink on paper flips here, and only here. A toast is laid *on* the page, so
/// it takes the opposite ground of whatever it covers — dark on the day paper,
/// light on the night lacquer. (Interactive.html:158, 164)
private struct ToastCapsule: View {
    var toast: SilkToast
    var night: Bool
    var onUndo: () -> Void

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

            if let label = toast.undoLabel {
                Button(action: onUndo) {
                    // Weight 500 is Silk's ceiling — the canon gives it no
                    // bold, and the colour already sets the word apart.
                    Text(label)
                        .font(Silk.sans(13, weight: .medium))
                        .foregroundStyle(night ? Color.toastUndoNight : .toastUndoDay)
                        .contentTransition(.opacity)
                        .contentShape(Rectangle().inset(by: -14))
                }
                .buttonStyle(.plain)                // no system tint on Silk's ground
                .accessibilityIdentifier("silk.toast.undo")
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
            ToastCapsule(toast: toast, night: night) { center.performUndo() }
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
                .onChange(of: toast.message, initial: true) { _, message in
                    AccessibilityNotification.Announcement(message).post()
                }
        }
    }
}

// ============================================================

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

    var body: some View {
        ToastHost(center: center, night: night) {
            VStack(spacing: 20) {
                Spacer()
                ToastCapsule(toast: SilkToast(message: refusal),
                             night: night, onUndo: {})
                ToastCapsule(toast: SilkToast(message: receipt, undoLabel: SilkStrings.undo),
                             night: night, onUndo: {})
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(night ? Silk.lacquer : Silk.paper)
            .contentShape(Rectangle())
            .onTapGesture { center.show(refusal) }
            .onLongPressGesture { center.show(receipt) {} }
        }
    }
}
