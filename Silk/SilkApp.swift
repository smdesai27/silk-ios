import SwiftUI
import FamilyControls
import SilkCore

@main
struct SilkApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    // Every foreground reconciles: re-lock layer 4, plus the
                    // revocation check (no callback exists for either) — and
                    // catches a day boundary that turned while we were away.
                    if phase == .active {
                        model.foregrounded()
                    }
                    // The attention gate, and the whole of it: a wait advances
                    // while Silk is on screen and stops when it is not.
                    //
                    // `.background` and deliberately not `.inactive`. Silk is
                    // still visible through most of what makes a scene
                    // inactive — a notification banner, a Control Center pull,
                    // a screenshot, a permission alert, the flicker every
                    // launch passes through — and freezing the ink while she is
                    // looking straight at it is indistinguishable from a hang.
                    // A real departure passes through `.inactive` into
                    // `.background` within a few hundred milliseconds, so the
                    // seconds this concedes are sub-noise, and they are
                    // conceded in the direction that cannot read as broken.
                    //
                    // Locking the phone reaches `.background` too, so a wait
                    // does not run on in a pocket.
                    if phase == .background {
                        model.pauseWait()
                    }
                }
        }
    }
}

/// Three pages, three dots: Now, Mirror, Settings — the handoff's order.
///
/// The ground, the atmosphere, the wordmark, the bar, the dots, the thread and
/// the overlays live here rather than on a page: they belong to the app, and
/// the bar in particular has to answer from any of the three.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    /// Hoisted focus: the root dims the stage on it and clears the thread on
    /// blur, through the model's shadow of it (`onChange` below).
    @FocusState private var barFocused: Bool
    /// When the last send happened. iOS resigns a text field on return, and a
    /// resignation right after a send is the keyboard's habit, not the user
    /// leaving — the blur that tears the thread down must be a chosen one.
    @State private var submittedAt: Date = .distantPast
    /// The keyboard's height above the glass, observed rather than taken as a
    /// safe-area inset. See `silkKeyboardHeight(_:)` — this is what lets the
    /// bar's whole travel be one offset on one curve.
    @State private var keyboard: CGFloat = 0

    private var night: Bool { model.isDownHours }

    var body: some View {
        @Bindable var model = model

        ZStack {
            if model.onboarded {
                ToastHost(center: model.toasts, night: night) {
                    ZStack(alignment: .bottom) {
                        Ground(night: night).ignoresSafeArea()
                        Atmosphere(night: night).ignoresSafeArea()

                        // ── Everything the shield covers ──────────────────
                        //
                        // The blur is a subtree modifier, so what it blurs is
                        // decided by structure and nothing else. It used to ride
                        // the pager alone, and the wordmark, the thread, the dots
                        // and the bar were ZStack *siblings* of that pager — so
                        // they stayed razor-sharp behind a veil that is only .92
                        // opaque, and the SILK mark read straight through the
                        // wall. The prototype's `backdrop-filter` sits on an
                        // element at `inset: 0; z-index: 20` and blurs everything
                        // painted beneath it (Silk Mockup.dc.html:187), which is
                        // a stratum, not a sibling. This container is that
                        // stratum's floor: every layer the overlays cover lives
                        // inside it, and the three overlays live outside it.
                        //
                        // The grounds stay outside deliberately. They are smooth
                        // gradients — blurring them changes nothing anyone can
                        // see — and a Gaussian on a full-bleed opaque layer
                        // samples past its own edge, which would fringe the
                        // screen's rim with transparency under a .92 veil.
                        ZStack(alignment: .bottom) {
                            TabView(selection: $model.page) {
                                NowView().tag(0)
                                MirrorView().tag(1)
                                SettingsView(downHours: model.settingsDownHours,
                                             budget: model.settingsBudget,
                                             undo: model.settingsUndo,
                                             doors: model.settingsDoors,
                                             showsAddRow: model.canAddDoor,
                                             night: night,
                                             onTapDownHours: { model.raisePicker(.down) },
                                             onTapBudget: { model.raisePicker(.budget) },
                                             onTapUndo: { model.raisePicker(.undo) },
                                             onTapDoor: { model.editDoor(named: $0) },
                                             onAddDoor: { model.beginAddDoor() })
                                    .tag(2)
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .ignoresSafeArea(edges: .top)
                            // The bar is the only thing meant to move for the keyboard.
                            // Without this the pages lose ~336pt and Mirror's
                            // bottom-anchored footnote jumps hundreds of points.
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                            // The page yields to the conversation: .05, blur 7,
                            // hit-dead, on the one curve (Silk Mockup.dc.html:24-25).
                            .silkStage(dimmed: model.conversation.stageDimmed)

                            // The wordmark, on its own layer: the one thing that never
                            // yields to the conversation (README.md:203-205). It signs
                            // Now and Settings and is hidden on Mirror (README.md:58-60),
                            // crossing on the same curve the pager settles with. The
                            // pages keep an empty seat where it sits, so their columns
                            // hold their spacing under it.
                            //
                            // It yields to the *shield*, though — a wall you can
                            // read the wordmark through is not a wall — which is
                            // why it sits inside this container and outside
                            // `silkStage`. The two are different refusals.
                            VStack {
                                Wordmark(night: night)
                                    .opacity(model.page == 1 ? 0 : 1)
                                    .animation(Silk.motion(0.45), value: model.page)
                                    .padding(.top, 62)
                                Spacer()
                            }
                            .allowsHitTesting(false)
                            .ignoresSafeArea(edges: .top)
                            .ignoresSafeArea(.keyboard, edges: .bottom)

                            // Tap-out: the stage is hit-dead while dimmed, so an
                            // invisible catcher under the thread picks up the tap and
                            // blurs. Blur is the one teardown path — the model clears
                            // the thread on it. The tap is a chosen leave, so it also
                            // closes the refocus grace the return key gets below.
                            //
                            // Mounted on the dim and not on the bar's focus, because
                            // the two came apart when the wait arrived: a wait takes
                            // the keyboard down and the thread deliberately stands
                            // (the turn it will answer is still in flight), so a
                            // conversation can now outlive the focus that started it.
                            // Keyed on `barFocused` this catcher went with the
                            // keyboard, and the answer to a wait — a read-back, or a
                            // refusal that became true while she watched — was left
                            // over a dimmed stage with nothing that would dismiss it.
                            // The model's shadow is written here too, for the same
                            // reason: with the bar already blurred, `onChange` below
                            // has nothing to fire on.
                            if barFocused || model.conversation.stageDimmed {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        submittedAt = .distantPast
                                        barFocused = false
                                        // The keyboard always goes; whether the THREAD
                                        // goes with it is the conversation's own
                                        // decision — `blur()` holds it open while a
                                        // turn is still at "…", so the receipt has
                                        // somewhere to land.
                                        model.conversation.blur()
                                    }
                                    .ignoresSafeArea()
                            }

                            // The thread, over the dimmed stage, under the shield and
                            // the toast.
                            ConversationThread(model: model.conversation, night: night)

                            // Bar and dots, measured from the glass independently — the
                            // CSS positions them absolutely from the same edge (bar
                            // bottom 44, dots bottom 24: _ds_bundle.css:270, 309), and
                            // stacking them put the bar at 83 and the dots at 43.5
                            // because PageDots is a 44pt tap target around a 5pt dot.
                            //
                            // The keyboard is ignored here, like everywhere else on
                            // this stack. It used to be honoured for the bar alone, so
                            // the bar's base lift was a layout change on UIKit's own
                            // ~0.25s curve and this reader re-delivered a shorter
                            // height on every frame of it — which retargeted the 0.45s
                            // rise sixty times a second at a moving mark. The height
                            // this reports is now constant across a keyboard's whole
                            // arrival, the keyboard's own height is observed below, and
                            // the bar sums the two into a single offset on the one
                            // curve. The dots keep their seat at the glass: they are at
                            // .05 and blurred behind a raised keyboard anyway, because
                            // the stage dims on exactly the focus that raises it.
                            GeometryReader { geo in
                                ZStack(alignment: .bottom) {
                                    PageDots(count: 3, index: $model.page, night: night)
                                        .silkStage(dimmed: model.conversation.stageDimmed)
                                        .padding(.bottom, 24 - (44 - 5) / 2)
                                    CommandBar(text: $input,
                                               night: night,
                                               onSubmit: submit,
                                               hasTurns: model.conversation.hasTurns,
                                               containerHeight: geo.size.height,
                                               keyboard: keyboard,
                                               focus: $barFocused)
                                        .padding(.horizontal, 28)
                                        .padding(.bottom, 44)
                                }
                                // The frame is what reaches the glass — `ignoresSafeArea`
                                // only widens the region a view *may* use, and a view
                                // sized to its content stays where the safe area put it.
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            .ignoresSafeArea(.container, edges: .bottom)
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                            .silkKeyboardHeight($keyboard)
                        }
                        // The shield's backdrop-filter: blur(20px) over a ground at
                        // .92/.94 (README.md:181-183). SwiftUI has no backdrop
                        // filter, but the grounds are opaque, so blurring the stage
                        // the shield covers is the same light arriving the same
                        // way. CSS's filter radius *is* the Gaussian sigma —
                        // unlike box-shadow, whose stated blur ApertureView halves
                        // — so 20 ports as 20, unhalved.
                        //
                        // The radius rides the veil's own curve. Snapping it put
                        // the pager fully blurred on the frame the veil was still
                        // transparent, which is the one frame the stage is fully
                        // visible — the pop was at the top of the fade, not hidden
                        // under it. The curve is named here rather than inherited
                        // from the `withAnimation` that raises the shield, so the
                        // blur cannot be left behind by a caller that forgets it;
                        // it is the same 0.45, and this is the only value it is
                        // scoped to.
                        .blur(radius: model.shield == nil ? 0 : 20)
                        .animation(Silk.motion(Silk.Motion.shield), value: model.shield)
                        // The wait's other wall, and the one nobody sees.
                        //
                        // `.accessibilityAddTraits(.isModal)` on the overlay is
                        // what VoiceOver is documented to honour, and it is
                        // still set there — but it did not actually take
                        // siblings out of the tree here, and a UI walk caught
                        // it: with the veil standing, the hero numeral was
                        // still queryable, which means the bar was too. A
                        // VoiceOver user could swipe past the wait, focus the
                        // bar and raise the system keyboard — the one window
                        // the veil cannot cover.
                        //
                        // So the stratum is hidden outright, on the same
                        // container the blur is scoped to, which is by
                        // construction everything the veil covers and nothing
                        // it does not.
                        .accessibilityHidden(model.waiting != nil)

                        // ── The overlay stratum ───────────────────────────
                        //
                        // Above the blur and outside it, so the three overlays
                        // are never blurred by the wall they may stand over.
                        // Their curves are set where they are raised and lowered
                        // — in `AppModel` — and not by an `.animation(_:value:)`
                        // on this stack: that modifier is not scoped to the child
                        // whose value changed, so an overlay's insertion handed
                        // its curve to the pager, both page columns, the bar, the
                        // dots and the thread on the frame the veil went up. That
                        // was the flicker.

                        // The wall a door would meet, raised by tapping its row.
                        // Above the pager, the thread and the bar; below the toast.
                        if let shield = model.shield {
                            ShieldOverlay(title: shield.title, app: shield.app, night: night) {
                                model.dismissShield()
                            }
                            .zIndex(20)
                        }

                        // The wheel picker sits over even the shield
                        // (README.md:154) — and, at 23, over the door editor as
                        // well. Equal zIndex in a ZStack resolves by declaration
                        // order, so while both stood at 22 the editor below drew
                        // on top.
                        //
                        // That used to be harmless because the two could not
                        // coexist. The cap row deletes that invariant: it raises
                        // this wheel from inside the editor. `openCapWheel` now
                        // swaps them in one un-animated frame — see its own note
                        // for why a cross-fade between two .97 veils is the one
                        // thing this handoff may not do.
                        // The wait, over everything. It is the last of the wall
                        // rather than a fourth kind of overlay, and it stands
                        // above the shield for the same reason the shield
                        // stands above the pager: nothing underneath it is
                        // reachable while it is up, including the wheel and the
                        // door editor, neither of which can be raised from
                        // behind it anyway. Its curve is set where it is raised
                        // — `AppModel.raiseWait` — as every overlay's is.
                        if let waiting = model.waiting {
                            WaitOverlay(wait: waiting.wait,
                                        app: waiting.door.name,
                                        night: night)
                                .zIndex(30)
                        }

                        if let kind = model.picker {
                            WheelPickerOverlay(title: model.pickerTitle(for: kind),
                                               columns: model.pickerColumns(for: kind),
                                               night: night) { picks in
                                model.commitPicker(kind, picks: picks)
                            }
                            .transition(.opacity)
                            .zIndex(23)
                        }

                        // The two overlays a Settings doors row can raise — the
                        // same stratum as the wheel, dismissed by their backdrop.
                        //
                        // Two components and not one with a mode, because they
                        // are two different pieces of furniture: a door row
                        // raises the door's own card, the add row raises the
                        // catalogue. The `switch` that used to live inside the
                        // component lives here instead, where the data already
                        // is, and each branch is handed only what it needs — so
                        // neither has to carry `if case .menu` guards over
                        // closures that could not fire.
                        //
                        // The card is a pure value view like SettingsView: it
                        // takes a name, an icon, a finished cap string and four
                        // closures. `settingsCap(for:)` composes the string
                        // through `Caps.settingsValue`, and `doorIcons` is a
                        // stored property so the icon actually refreshes after a
                        // rebind — see its note in AppModel.
                        if let edit = model.doorEdit {
                            switch edit {
                            case .menu(let door):
                                DoorDetailCard(
                                    name: door.name,
                                    icon: model.doorIcons[door.id],
                                    cap: model.settingsCap(for: door),
                                    pending: model.settingsPendingCap(for: door),
                                    night: night,
                                    onCap: { model.openCapWheel(for: door) },
                                    onApplyNow: { model.keyTapped() },
                                    onRebind: { model.rebind(door) },
                                    onRemove: { model.removeDoor(door) },
                                    onClose: { model.closeDoorEdit() })
                                .transition(.opacity)
                                .zIndex(22)
                            case .add:
                                DoorAddOverlay(
                                    available: model.addableDoorNames,
                                    night: night,
                                    onAdd: { model.addDoor(named: $0) },
                                    onClose: { model.closeDoorEdit() })
                                .transition(.opacity)
                                .zIndex(22)
                            }
                        }
                    }
                    // The one animation the stage still stamps whole, and the one
                    // that must be: the day↔night wash is atmosphere, so every
                    // layer crosses together on the 0.8s (canon.md, sanctioned
                    // exceptions). The three overlay curves that used to stand
                    // here moved to their mutation sites in `AppModel`.
                    .animation(Silk.motion(Silk.Motion.crossing), value: night)
                    // The onboarded tree's ONE picker sheet: it serves both the
                    // wall re-arm (Now's row) and a door binding (Settings'
                    // editor) through the model's single request — two picker
                    // presentations in one tree conflict, as OnboardingView
                    // documents. Mounted inside the onboarded branch so it
                    // never coexists with onboarding's own. Silk owns the
                    // sheet, so the one-app rule is enforced by its Done
                    // rather than corrected after the list comes down.
                    .sheet(isPresented: Binding(get: { model.activityPicker != nil },
                                                set: { if !$0 { model.cancelActivityPicking() } })) {
                        if let request = model.activityPicker {
                            AppPickerSheet(
                                mode: {
                                    if case .doorBinding(let door) = request {
                                        return .oneApp(door: door.name)
                                    }
                                    return .extras
                                }(),
                                selection: $model.activitySelection,
                                onCancel: model.cancelActivityPicking,
                                onCommit: model.finishActivityPicking)
                        }
                    }
                }
                // FocusState cannot leave the view, so the model holds its shadow.
                // A blur within a beat of a send is the return key resigning the
                // field, not the user leaving the conversation — refocus and keep
                // the thread; a real tap-out arrives on its own time.
                .onChange(of: barFocused) { _, focused in
                    if !focused, Date.now.timeIntervalSince(submittedAt) < 0.3 {
                        barFocused = true
                        return
                    }
                    // A wait took the keyboard down; that is not her leaving.
                    // The turn the wait will answer is still in flight, and
                    // tearing the thread down here would delete the turn the
                    // grant readback is addressed to — `land` would find no id
                    // and swallow the receipt silently.
                    //
                    if !focused, model.waiting != nil { return }
                    // A turn still at "…" holds the thread open the same way,
                    // one beat earlier — `blur()` is where that rule lives, so
                    // the tap-out catcher above and this path cannot disagree
                    // about it.
                    if focused { model.conversation.focused = true }
                    else { model.conversation.blur() }
                    // The bar is the window the widener needs: focus to return
                    // is seconds, and `prewarm` only costs the tenth of a
                    // millisecond it takes to schedule the load. It is what
                    // keeps the first widened sentence of a session off the
                    // cold path — measured 591 ms warmed against 1650 ms cold.
                    // Cooling on the way out is the other half: a session held
                    // past the conversation is memory kept warm for nobody.
                    let policy = model.policy
                    Task {
                        if focused {
                            await SilkModelParser.shared.prewarm(state: policy)
                        } else {
                            await SilkModelParser.shared.cool()
                        }
                    }
                }
                // The one thing the veil cannot cover. The system keyboard is
                // its own window and draws over every overlay Silk owns, so a
                // wait raised under a live keyboard would ship a full QWERTY on
                // a screen whose whole design is three elements and no words —
                // and every touch in the bottom third would land in a text
                // field nobody can see.
                //
                // `submittedAt` is cleared with it: the refocus grace above
                // exists to survive the return key's own resignation, and it
                // must not fight a resignation Silk asked for.
                .onChange(of: model.waiting != nil) { _, waiting in
                    if waiting {
                        submittedAt = .distantPast
                        barFocused = false
                    }
                }
                .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(Silk.motion(0.45), value: model.onboarded)
        // The status bar and the keyboard are the two things Silk does not
        // draw, and every Silk colour is a literal. Without this a Dark Mode
        // device puts white status-bar text on the day's bare paper — the
        // wordmark starts 62pt down, so there is nothing else up there.
        // Silk's night is a policy, so it drives the appearance too; setup is
        // always paper.
        .preferredColorScheme(model.onboarded && night ? .dark : .light)
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        // Return on an empty bar is not a question, so it gets no answer — the
        // prototype drops it before it becomes a turn (Silk Mockup.dc.html:339).
        guard !text.isEmpty else { return }
        submittedAt = .now
        Task { await model.handle(text) }
    }
}
