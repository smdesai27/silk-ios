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
                            if barFocused {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        submittedAt = .distantPast
                                        barFocused = false
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
                            // `.container` and not `.all` — the keyboard must still
                            // lift the bar when the bar is what you are using; the
                            // GeometryReader therefore measures glass-to-glass, or
                            // glass-to-keyboard when one is up, which is exactly the
                            // space the bar's rise is computed against.
                            GeometryReader { geo in
                                ZStack(alignment: .bottom) {
                                    PageDots(count: 3, index: $model.page, night: night)
                                        .silkStage(dimmed: model.conversation.stageDimmed)
                                        .padding(.bottom, 24 - (44 - 5) / 2)
                                    CommandBar(text: $input,
                                               night: night,
                                               onSubmit: submit,
                                               hasTurns: model.conversation.hasTurns,
                                               rise: CommandBar.riseDistance(in: geo.size.height),
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
                        }
                        // The shield's backdrop-filter: blur(20px) over a ground at
                        // .92/.94 (README.md:181-183). SwiftUI has no backdrop
                        // filter, but the grounds are opaque, so blurring the stage
                        // the shield covers is the same light arriving the same
                        // way. CSS's filter radius *is* the Gaussian sigma —
                        // unlike box-shadow, whose stated blur ApertureView halves
                        // — so 20 ports as 20, unhalved. The radius itself snaps:
                        // animating it re-renders the whole pager offscreen every
                        // frame, and the veil's own fade is what the eye reads.
                        .blur(radius: model.shield == nil ? 0 : 20)
                        .animation(nil, value: model.shield)

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
                        if let kind = model.picker {
                            WheelPickerOverlay(title: model.pickerTitle(for: kind),
                                               columns: model.pickerColumns(for: kind),
                                               night: night) { picks in
                                model.commitPicker(kind, picks: picks)
                            }
                            .transition(.opacity)
                            .zIndex(23)
                        }

                        // The door editor — the same overlay stratum as the
                        // wheel: raised by a door row or the add row on
                        // Settings, dismissed by its backdrop.
                        if let edit = model.doorEdit {
                            DoorEditOverlay(
                                mode: {
                                    switch edit {
                                    case .menu(let door): .menu(doorName: door.name)
                                    case .add: .add(available: model.addableDoorNames)
                                    }
                                }(),
                                night: night,
                                onRebind: { if case .menu(let door) = edit { model.rebind(door) } },
                                onCap: { if case .menu(let door) = edit { model.openCapWheel(for: door) } },
                                onRemove: { if case .menu(let door) = edit { model.removeDoor(door) } },
                                onAdd: { model.addDoor(named: $0) },
                                onClose: { model.closeDoorEdit() })
                            .transition(.opacity)
                            .zIndex(22)
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
                    model.conversation.focused = focused
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
