import SwiftUI
import FamilyControls
import SilkCore

/// Setup — the only long moment in the product. Three steps, then never again.
/// (docs/market/user-flows.md, Flow 0)
///
///   1  permission — Screen Time access, one line of why
///   2  apps       — pick 1–6 from the catalogue; "Other apps" for the rest
///   3  limits     — one budget, one night window
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Step: Int, CaseIterable {
        case permission, apps, limits
    }

    @State private var step: Step = {
        #if DEBUG
        // Debug hook for headless QA: launch with `-silkStep N` (0–2).
        if let i = UserDefaults.standard.string(forKey: "silkStep").flatMap(Int.init),
           let s = Step(rawValue: i) {
            return s
        }
        #endif
        return .permission
    }()

    // Collected state
    /// One picker presentation at a time; two .familyActivityPicker modifiers
    /// on one view conflict.
    private enum PickerRequest: Equatable { case extras, door(String) }

    /// The extras: apps blocked but not named — anything outside the launch
    /// catalogue. They shield; they have no chip and no launch entry.
    @State private var wallSelection = FamilyActivitySelection()
    @State private var pickerRequest: PickerRequest?
    /// A chip tapped for the first time, still waiting for its app. If the
    /// sheet is cancelled the name goes back with it: a named door with no app
    /// is the half-state the old flow left behind, and cancelling should read
    /// as nothing having happened.
    @State private var provisionalDoorKey: String?
    @State private var doorNames: [String] = []
    @State private var doorSelections: [String: FamilyActivitySelection] = [:]
    @State private var bindingSelection = FamilyActivitySelection()
    @State private var budget = 40
    /// The night window's seats. Debug hook for headless QA: `-silkDownStart H`
    /// / `-silkDownEnd H` move the window — an evening test run against the
    /// real 10 PM sees its grants clamped to the approaching edge, and no
    /// assertion survives the wall clock.
    @State private var downStart: TimeOfDay = {
        #if DEBUG
        if let h = UserDefaults.standard.string(forKey: "silkDownStart").flatMap(Int.init) {
            return TimeOfDay(hour: h)
        }
        #endif
        return TimeOfDay(hour: 22)
    }()
    @State private var downEnd: TimeOfDay = {
        #if DEBUG
        if let h = UserDefaults.standard.string(forKey: "silkDownEnd").flatMap(Int.init) {
            return TimeOfDay(hour: h)
        }
        #endif
        return TimeOfDay(hour: 7)
    }()

    /// The step's own natural height, measured. See `body`.
    @State private var columnHeight: CGFloat = 0

    var body: some View {
        // The same defence NowView and SettingsView mount, for the same reason:
        // a step taller than the screen must scale uniformly rather than run off
        // the bottom where nothing says it exists. Silk has nothing to scroll.
        //
        // The catalogue is what made setup need it. `appChips` renders one chip
        // per entry through `FlowLayout`, whose `sizeThatFits` reads
        // `proposal.width` and ignores `proposal.height` — it reports its ideal
        // and cannot be compressed — and the 96pt spacer above is a fixed frame
        // that does not collapse. Measured at Silk.sans(14) with the chips'
        // 16pt padding and 10pt spacing inside the 307pt content width: on a
        // 375×667 iPhone SE, twelve entries wrap to four rows and the step has
        // 104pt of slack, and seventeen wrap to six rows and it is 4pt short
        // before a single chip is picked. Picking chips makes it worse, not
        // better — a bound chip grows by its 15pt app icon and its 6pt gap, so
        // six bound doors take a seventh row and the step is 90pt short. Even a
        // 375×812 phone goes 9pt short there.
        //
        // WHAT IS MEASURED AND WHAT IS COMPUTED. NowView and SettingsView
        // hand-count their columns because their rows are uniform 52pt. A chip
        // row count is a function of text metrics, so it cannot be hand-counted
        // without restating SwiftUI's own text measurement and drifting from it
        // at the wrap boundary. The column reports its natural height instead
        // and the scale is computed from that — one frame at scale 1 before the
        // first measurement lands, then exact. `scaleEffect` is a render
        // transform and changes no layout, so the measurement it feeds cannot
        // move it: there is no loop here.
        GeometryReader { geo in
            let usable = geo.size.height - Self.footReserve
            let scale = min(1, usable / max(1, columnHeight))
            column
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
                .scaleEffect(scale, anchor: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // The OK button keeps its seat at the foot rather than riding a Spacer:
        // a column that scales must not be able to push it off, and the reserve
        // above is this seat measured.
        .overlay(alignment: .bottom) {
            advance
                .padding(.bottom, 60)
        }
        .animation(Silk.motion(0.45), value: step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Silk.paper.ignoresSafeArea())
        // Silk's sheet, with Apple's list inside it. One sheet for both
        // requests — two picker presentations in one tree conflict — and the
        // instruction now rides above the list instead of being buried by it.
        .sheet(isPresented: Binding(get: { pickerRequest != nil },
                                    set: { if !$0 { cancelPicking() } })) {
            if let request = pickerRequest {
                AppPickerSheet(
                    mode: request == .extras
                        ? .extras
                        : .oneApp(door: displayName(doorKey(of: request) ?? "")),
                    selection: request == .extras ? $wallSelection : $bindingSelection,
                    onCancel: cancelPicking,
                    onCommit: commitPicking)
            }
        }
    }

    /// The OK button's own seat, held at the foot: 44pt of button and the 60pt
    /// beneath it. NowView and SettingsView reserve their chrome the same way.
    private static let footReserve: CGFloat = 104

    /// The step, top-anchored under its 96pt. Fixed vertically so it reports
    /// the height it wants rather than the height it is offered — the offer is
    /// the thing being checked.
    private var column: some View {
        VStack(spacing: 0) {
            // The 96pt seat, held by a clear box rather than a Spacer — under
            // `fixedSize` a Spacer's ideal height is a question it does not have
            // to answer the same way twice, and NowView and SettingsView hold
            // their own seats exactly this way.
            Color.clear.frame(height: 96)
            content
                .id(step)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func doorKey(of request: PickerRequest) -> String? {
        if case .door(let key) = request { return key }
        return nil
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .permission:
            prompt(SilkStrings.setupPermission)

        case .apps:
            VStack(spacing: 28) {
                prompt(SilkStrings.setupPickApps)
                appChips
            }

        case .limits:
            VStack(spacing: 36) {
                prompt(SilkStrings.howManyMinutesADay)
                budgetSlider
                VStack(spacing: 10) {
                    Text(SilkStrings.lockedOvernight)
                        .font(Silk.sans(12.5))
                        .foregroundStyle(Silk.inkAlpha(0.71))
                    aperture
                }
            }
        }
    }

    private func prompt(_ text: String) -> some View {
        Text(text)
            .font(Silk.serif(21))
            .multilineTextAlignment(.center)
            .foregroundStyle(Silk.inkAlpha(0.92))
            .padding(.horizontal, 46)
    }

    private func summaryLine(_ text: String) -> some View {
        Text(text)
            .font(Silk.serif(15))
            .monospacedDigit()
            .foregroundStyle(Silk.inkAlpha(0.73))
    }

    // MARK: - Apps (step 2)

    /// The curated catalogue — naming an app only from names Silk knows how to
    /// open converts "and it opens" from a courtesy into a guarantee. The
    /// quiet path below the chips blocks everything else by token alone.
    private var appChips: some View {
        let names = LaunchCatalog.entries.map(\.display)
        return VStack(spacing: 14) {
            FlowLayout(spacing: 10) {
                ForEach(names, id: \.self) { name in
                    chip(name)
                }
            }
            .padding(.horizontal, 34)
            Button {
                pickerRequest = .extras
            } label: {
                Text(SilkStrings.otherApps)
                    .font(Silk.sans(14))
                    .foregroundStyle(Silk.inkAlpha(0.67))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("silk.setup.other")
            if let summary = appsSummary {
                summaryLine(summary)
                    .transition(.opacity)
            }
        }
        .animation(Silk.motion(0.35), value: appsSummary)
    }

    /// Names for the named, a count for the rest — never a bare number alone
    /// unless numbers are all there is.
    private var appsSummary: String? {
        // An unfinished name says so here as well as on its chip: this line is
        // where the eye goes to check the step, and the OK it explains is dead.
        if let waiting = unboundNames.first {
            return SilkStrings.findAndTap(displayName(waiting))
        }
        var parts = doorNames.map(displayName)
        let extras = wallSelection.applicationTokens.count
        if extras > 0 { parts.append("\(extras) more") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func chip(_ name: String) -> some View {
        let key = name.lowercased()
        let selected = doorNames.contains(key)
        let token = doorSelections[key]?.applicationTokens.first
        return Button {
            toggleDoor(key)
        } label: {
            HStack(spacing: 6) {
                // Apple's own icon for the app that actually got bound — the
                // 6pt leaf dot said "something is behind this" and nothing
                // more, so a wrong pick was invisible until the wall behaved
                // strangely. The icon is the proof.
                if let token {
                    Label(token)
                        .labelStyle(.iconOnly)
                        .frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(displayName(key))
                    .font(Silk.sans(14, weight: selected ? .medium : .regular))
                // Named but not yet bound: the step is not finished, and the
                // chip is the only place that can say so.
                if selected, token == nil {
                    Circle().fill(Silk.paperAlpha(0.45)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .accessibilityIdentifier("chip.\(displayName(name.lowercased()))")
            .background(
                Capsule().fill(selected ? Silk.inkAlpha(0.92) : .clear)
            )
            .overlay(
                Capsule().stroke(Silk.inkAlpha(selected ? 0 : 0.14), lineWidth: 1)
            )
            .foregroundStyle(selected ? Silk.paper : Silk.inkAlpha(0.79))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The fill says chosen to the eye; the trait says it to VoiceOver.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func displayName(_ key: String) -> String {
        LaunchCatalog.entries.first { $0.names.contains(key) }?.display ?? key.capitalized
    }

    /// A chip tap. Selecting a name always opens its sheet — first time to bind
    /// it, later to change which app it points at. Deselecting is the chip's
    /// own gesture and never opens anything.
    private func toggleDoor(_ key: String) {
        if doorNames.contains(key) {
            if doorSelections[key] == nil {
                // Named, still unbound: the tap is a second try at binding,
                // not a deselect. Deselecting an unbound chip would be the
                // only way to leave the step half-done.
                openBinding(for: key, provisional: true)
            } else {
                doorNames.removeAll { $0 == key }
                doorSelections[key] = nil
            }
        } else if doorNames.count < DoorRoster.maxDoors {
            doorNames.append(key)
            openBinding(for: key, provisional: true)
        }
    }

    /// The sheet opens on the tap, not two seconds after it. The reading beat
    /// existed to buy time for a line the sheet was about to cover; the line
    /// now lives inside the sheet, so there is nothing to read ahead of.
    private func openBinding(for key: String, provisional: Bool) {
        provisionalDoorKey = provisional && doorSelections[key] == nil ? key : nil
        bindingSelection = doorSelections[key] ?? FamilyActivitySelection()
        pickerRequest = .door(key)
    }

    /// Done. The sheet only enables it on a verdict of exactly one app, so the
    /// validation here is the same rule stated twice on purpose: the gate the
    /// user sees, and the gate the data passes.
    private func commitPicking() {
        defer { pickerRequest = nil; provisionalDoorKey = nil }
        guard let request = pickerRequest else { return }
        switch request {
        case .door(let key):
            guard DoorBinding.validate(applications: bindingSelection.applicationTokens.count,
                                       categories: bindingSelection.categoryTokens.count,
                                       webDomains: bindingSelection.webDomainTokens.count) == .bound
            else { return }
            doorSelections[key] = bindingSelection
        case .extras:
            // The wall is apps only, but the system list still offers
            // categories. One kept here would be stored and never enforced.
            wallSelection.categoryTokens = []
        }
    }

    /// Cancel, or a swipe down. A name that has never had an app goes back with
    /// the sheet — cancelling should read as nothing having happened, and a
    /// named door with no app behind it is exactly the half-state that made the
    /// old flow confusing. An existing binding is left alone.
    private func cancelPicking() {
        if let key = provisionalDoorKey, doorSelections[key] == nil {
            doorNames.removeAll { $0 == key }
        }
        provisionalDoorKey = nil
        pickerRequest = nil
    }

    // MARK: - Limits (step 3)

    /// One number, one slider. The numeral is the reading; the slider is the
    /// control — 5-minute stops so every reachable value is one a person
    /// would actually say.
    private var budgetSlider: some View {
        VStack(spacing: 16) {
            Text("\(budget)")
                .font(Silk.serif(44))
                .monospacedDigit()
                .frame(height: 44)              // line-height: 1
                .foregroundStyle(Silk.inkAlpha(0.92))
                // The slider below speaks the value; one voice is enough.
                .accessibilityHidden(true)
            Slider(value: Binding(get: { Double(budget) },
                                  set: { budget = Int($0) }),
                   in: 10...120, step: 5)
                .tint(Silk.inkAlpha(0.70))
                .frame(width: 234)
                .accessibilityLabel(Text(SilkStrings.howManyMinutesADay))
                .accessibilityValue(Text("\(budget) \(SilkStrings.minutes)"))
                .accessibilityIdentifier("silk.setup.budget")
        }
    }

    /// The night window, as the aperture: a recessed pane holding the times.
    ///
    /// Setup is the one place the aperture is a control rather than a reading
    /// (Aperture.prompt.md), so the pane is the real component with the label
    /// left empty and the wheels laid over it. Painting a flat approximation
    /// here is how it ended up with a colour that exists nowhere in the tokens.
    private var aperture: some View {
        ZStack {
            // An empty pane is scenery here; the wheels over it are the control.
            ApertureView(text: "", night: false)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text("☾").font(Silk.serif(13))
                    .accessibilityHidden(true)
                timeWheel(binding: $downStart, spoken: "\(SilkStrings.lockedOvernight) start")
                Text("–").font(Silk.serif(13.5))
                    .accessibilityHidden(true)
                timeWheel(binding: $downEnd, spoken: "\(SilkStrings.lockedOvernight) end")
            }
            .foregroundStyle(Silk.duskBlue)
        }
        .frame(width: 234, height: 56)
    }

    private func timeWheel(binding: Binding<TimeOfDay>, spoken: String) -> some View {
        let date = Binding<Date>(
            get: {
                Calendar.current.date(bySettingHour: binding.wrappedValue.hour,
                                      minute: binding.wrappedValue.minute,
                                      second: 0, of: .now) ?? .now
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                binding.wrappedValue = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
        )
        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .tint(Silk.duskBlue)
            .scaleEffect(0.9)
            // Two bare time pickers side by side need telling apart.
            .accessibilityLabel(Text(spoken))
    }

    // MARK: - Advance

    /// Named but unbound doors, which are the one thing the apps step will not
    /// carry forward. A door is a name and an app; a name alone parses and
    /// launches but can never be excepted from the wall, so it looks broken
    /// later for a reason nothing on screen explains. Better to finish it here.
    private var unboundNames: [String] {
        doorNames.filter { doorSelections[$0] == nil }
    }

    private var canAdvance: Bool {
        switch step {
        case .permission:
            return true
        case .apps:
            #if targetEnvironment(simulator)
            // The simulator's Screen Time list is non-functional, so nothing
            // can bind here and requiring it would strand every QA run.
            return true
            #else
            guard unboundNames.isEmpty else { return false }
            return !doorNames.isEmpty || !wallSelection.applicationTokens.isEmpty
            #endif
        case .limits:
            return true
        }
    }

    private var advance: some View {
        Button {
            Task { await next() }
        } label: {
            Text(SilkStrings.ok)
                .font(Silk.sans(15, weight: .medium))
                .foregroundStyle(Silk.paper)
                .frame(width: 120, height: 44)
                .background(Capsule().fill(Silk.inkAlpha(canAdvance ? 0.92 : 0.16)))
        }
        .buttonStyle(.plain)
        .disabled(!canAdvance)
        .animation(Silk.motion(0.35), value: canAdvance)
        .accessibilityIdentifier("silk.setup.ok")
    }

    private func next() async {
        switch step {
        case .permission:
            #if targetEnvironment(simulator)
            // requestAuthorization can suspend indefinitely on the simulator;
            // never let it gate the flow there. Fire and forget.
            Task { _ = await model.wall.requestAuthorization() }
            step = .apps
            #else
            if await model.wall.requestAuthorization() {
                step = .apps
            }
            #endif

        case .apps:
            step = .limits

        case .limits:
            let doors = doorNames.map { Door(name: displayName($0)) }
            var selections: [UUID: FamilyActivitySelection] = [:]
            for door in doors {
                if let sel = doorSelections[door.name.lowercased()] {
                    selections[door.id] = sel
                }
            }
            model.completeSetup(
                doors: doors,
                doorSelections: selections,
                wallSelection: wallSelection,
                budget: budget,
                downHours: DownHours(start: downStart, end: downEnd)
            )
        }
    }
}

/// A minimal flow layout for the app chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
