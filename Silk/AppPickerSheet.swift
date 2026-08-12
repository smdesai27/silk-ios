import SwiftUI
import FamilyControls
import ManagedSettings
import SilkCore

/// Silk's sheet, with Apple's list inside it.
///
/// `FamilyActivityPicker` is a plain `View`, not only a modifier, so the
/// instruction does not have to be shouted before the sheet and then buried by
/// it — it sits above the list the whole time the list is on screen, and Silk
/// owns the Done that ends the moment.
///
/// That ownership is the whole design. Apple offers no way to make its list
/// single-select or to filter it to one app, so a door's one-app rule cannot be
/// enforced inside the list; it has to be enforced at the boundary. Done stays
/// dead until the pick is exactly one app, which turns the old flow's
/// after-the-fact correction ("just one — tap Instagram again") into a mistake
/// that cannot be made. The footer names the app Apple itself would name, so a
/// wrong pick is visible before it is committed rather than silent after.
struct AppPickerSheet: View {

    /// What is being picked. The rule differs, so the copy and the gate do too:
    /// a named door is exactly one app, the extras pile is deliberately plural.
    enum Mode: Equatable {
        /// A named door — one name, one app. The shield exception and the
        /// launch both lean on that being singular.
        case oneApp(door: String)
        /// Blocked without a name. Plural is correct here, and saying so out
        /// loud is what keeps the one-app rule from reading as arbitrary.
        case extras
    }

    var mode: Mode
    @Binding var selection: FamilyActivitySelection
    var onCancel: () -> Void
    var onCommit: () -> Void

    /// Simulator only. Apple's picker returns an empty list without real
    /// Screen Time authorization, so on a simulator there is nothing to tap
    /// and none of this — the gate, the correction, the proof — can be seen.
    /// These rows stand in for Apple's list and drive the same counts the real
    /// selection drives, so every state below is reachable. They cannot mint
    /// `ApplicationToken`s (the type is opaque by design), so nothing binds
    /// here — exactly as nothing bound here before.
    #if targetEnvironment(simulator)
    @State private var standInApps: Set<String> = []
    @State private var standInCategories: Set<String> = []
    private static let standInCatalogue =
        ["Facebook", "Instagram", "Messages", "Reddit", "Snapchat", "TikTok", "X", "YouTube"]
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .background(Silk.paper.ignoresSafeArea())
    }

    // MARK: - Silk's chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Silk.serif(26))
                .foregroundStyle(Silk.inkAlpha(0.94))
            Text(say)
                .font(Silk.sans(13.5))
                .foregroundStyle(Silk.inkAlpha(0.73))
            Text(why)
                .font(Silk.sans(12))
                .foregroundStyle(Silk.inkAlpha(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("silk.picker.header")
    }

    /// Apple's band. Ruled off top and bottom because it is not Silk's — the
    /// seam is honest, and it is what makes the paper above and below read as
    /// the part that stays.
    @ViewBuilder
    private var list: some View {
        #if targetEnvironment(simulator)
        standInList
        #else
        FamilyActivityPicker(selection: $selection)
            .overlay(alignment: .top) { hairline }
            .overlay(alignment: .bottom) { hairline }
        #endif
    }

    private var hairline: some View {
        Rectangle().fill(Silk.inkAlpha(0.10)).frame(height: 1)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            status
            Button(SilkStrings.cancel, action: onCancel)
                .font(Silk.sans(14))
                .foregroundStyle(Silk.inkAlpha(0.70))
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("silk.picker.cancel")
            Button(action: onCommit) {
                Text(SilkStrings.done)
                    .font(Silk.sans(14, weight: .medium))
                    .foregroundStyle(Silk.paper)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(Capsule().fill(Silk.inkAlpha(canCommit ? 0.92 : 0.16)))
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .animation(Silk.motion(0.35), value: canCommit)
            .accessibilityIdentifier("silk.picker.done")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// The proof. One app shows the icon and name Apple itself would show, so
    /// what is about to be bound is legible before Done is available at all.
    @ViewBuilder
    private var status: some View {
        HStack(spacing: 7) {
            if case .some(let token) = soleToken {
                Label(token).labelStyle(SoleAppLabelStyle())
            } else {
                // A correction is not a colour. Silk rations its pops to one
                // per screen and lets words carry state (DoorRow uses weight
                // the same way), so the only shift here is contrast: a
                // correction is darker than a neutral count, and the Done
                // going dead beside it is the louder signal anyway.
                Text(statusText)
                    .font(Silk.sans(12.5, weight: needsAnswer ? .medium : .regular))
                    .foregroundStyle(Silk.inkAlpha(needsAnswer ? 0.82 : 0.72))
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("silk.picker.status")
        .accessibilityLabel(Text(soleAppSpoken ?? statusText))
    }

    // MARK: - The gate

    private var counts: (apps: Int, categories: Int, domains: Int) {
        #if targetEnvironment(simulator)
        (standInApps.count, standInCategories.count, 0)
        #else
        (selection.applicationTokens.count,
         selection.categoryTokens.count,
         selection.webDomainTokens.count)
        #endif
    }

    /// A named door runs the same verdict the parser's binding always ran; the
    /// extras take any number of apps and no categories.
    private var canCommit: Bool {
        let c = counts
        switch mode {
        case .oneApp:
            return DoorBinding.validate(applications: c.apps,
                                        categories: c.categories,
                                        webDomains: c.domains) == .bound
        case .extras:
            return c.apps >= 1 && c.categories == 0 && c.domains == 0
        }
    }

    /// The one token, when there is exactly one and the mode wants one — the
    /// only case where Apple's own label is the right thing to render.
    private var soleToken: ApplicationToken? {
        guard case .oneApp = mode, counts.apps == 1, counts.categories == 0 else { return nil }
        #if targetEnvironment(simulator)
        return nil          // no real token exists here; the text path speaks
        #else
        return selection.applicationTokens.first
        #endif
    }

    private var soleAppSpoken: String? {
        soleToken == nil ? nil : title
    }

    /// Whether the line is asking for something rather than reporting. Nothing
    /// picked yet is not a correction — it is the resting state.
    private var needsAnswer: Bool {
        let c = counts
        if c.categories > 0 || c.domains > 0 { return true }
        if case .oneApp = mode, c.apps > 1 { return true }
        return false
    }

    private var statusText: String {
        let c = counts
        switch mode {
        case .oneApp:
            if c.categories > 0 || c.domains > 0 { return SilkStrings.categoryNotADoor }
            if c.apps == 0 { return SilkStrings.nothingPickedYet }
            if c.apps == 1 {
                #if targetEnvironment(simulator)
                return standInApps.first ?? SilkStrings.nothingPickedYet
                #else
                return SilkStrings.nothingPickedYet
                #endif
            }
            return SilkStrings.pickedTapToRemove(c.apps)
        case .extras:
            if c.categories > 0 || c.domains > 0 { return SilkStrings.categoriesDropped }
            return c.apps == 0 ? SilkStrings.nothingPickedYet : SilkStrings.appsPicked(c.apps)
        }
    }

    // MARK: - Copy

    private var title: String {
        switch mode {
        case .oneApp(let door): door
        case .extras: SilkStrings.otherApps
        }
    }

    private var say: String {
        switch mode {
        case .oneApp(let door): SilkStrings.findAndTap(door)
        case .extras: SilkStrings.pickAsMany
        }
    }

    private var why: String {
        switch mode {
        case .oneApp: SilkStrings.iosWontSay
        case .extras: SilkStrings.extrasStayShut
        }
    }

    // MARK: - Stand-in list (simulator only)

    #if targetEnvironment(simulator)
    private var standInList: some View {
        ScrollView {
            VStack(spacing: 0) {
                standInGroup(SilkStrings.apps)
                ForEach(Self.standInCatalogue, id: \.self) { name in
                    standInRow(name, picked: standInApps.contains(name)) {
                        if standInApps.contains(name) { standInApps.remove(name) }
                        else { standInApps.insert(name) }
                    }
                }
                standInGroup("Categories")
                ForEach(["Social", "Entertainment"], id: \.self) { name in
                    standInRow(name, picked: standInCategories.contains(name)) {
                        if standInCategories.contains(name) { standInCategories.remove(name) }
                        else { standInCategories.insert(name) }
                    }
                }
            }
        }
        .background(Color.white)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
    }

    private func standInGroup(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11.5))
            .tracking(0.5)
            .foregroundStyle(Color(white: 0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .background(Color(white: 0.95))
    }

    private func standInRow(_ name: String, picked: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.86))
                    .frame(width: 26, height: 26)
                    .overlay(Text(String(name.prefix(1)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(white: 0.35)))
                Text(name)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.11))
                Spacer(minLength: 8)
                Circle()
                    .strokeBorder(picked ? Color.clear : Color(white: 0.78), lineWidth: 1.5)
                    .background(Circle().fill(picked ? Color.accentColor : .clear))
                    .frame(width: 21, height: 21)
                    .overlay {
                        if picked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("silk.picker.row.\(name)")
        .accessibilityAddTraits(picked ? .isSelected : [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(white: 0.90)).frame(height: 0.5).padding(.leading, 51)
        }
    }
    #endif
}

/// Apple's label, sized and coloured for Silk's footer: the real icon at a
/// row's scale, the real name in Silk's caption voice.
private struct SoleAppLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .frame(width: 19, height: 19)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            configuration.title
                .font(Silk.sans(12.5))
                .foregroundStyle(Silk.inkAlpha(0.79))
        }
    }
}
