import SwiftUI
import SilkCore
import FamilyControls

/// Now: see what's left today; open or close a door; talk to Silk.
///
/// There is no aperture here. The down-hours window used to sit under the hero as
/// a glass pill; it was explored in six placements and taken off this screen
/// entirely. Its time now lives on Settings, and Now's only signal is the
/// greeting — which names the down-hours start once the evening reaches it.
///
/// The bar and the dots are pinned to the glass by the root: they belong to the
/// app, not to either page.
struct NowView: View {
    @Environment(AppModel.self) private var model

    private var night: Bool { model.isDownHours }

    var body: some View {
        // Six doors at the specified spacing overflow a small screen, so the
        // column scales uniformly rather than clipping rows off the bottom
        // where nothing says they exist. Silk has nothing to scroll.
        GeometryReader { geo in
            // The chrome is measured from the glass; this page is not — the pager
            // only ignores the top inset, so the reader's region already stops at
            // the bottom safe-area edge. Reserving the full 96 here would count
            // that inset twice and scale every token down to dodge a collision
            // that isn't there.
            let reserve = max(0, Self.chromeReserve - geo.safeAreaInsets.bottom)
            let usable = geo.size.height - reserve
            let scale = min(1, usable / max(1, columnHeight))
            column
                .scaleEffect(scale, anchor: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(Silk.motion(0.45), value: pendingSummary)
                .animation(Silk.motion(0.45), value: model.wallDown)
        }
        // The re-arm picker (docs/market/gaps.md #5) used to be presented
        // here; it moved to the root when Settings' door editor arrived —
        // the onboarded tree carries exactly one .familyActivityPicker,
        // serving both requests through the model's ActivityPickerRequest.
    }

    /// Bar bottom 44 + bar height 52.
    private static let chromeReserve: CGFloat = 96

    /// What the pending row will actually say, or nil when it will draw nothing.
    /// The reservation below, the animation above and the row itself all ask
    /// this one question: keying the first two on `pendingLoosening != nil`
    /// reserved 62pt for a row that the summary had already taken away. Rare
    /// before caps and ordinary with them — park a cap raise, then lower that
    /// cap before the boundary, and the merge delivers nothing while the pending
    /// waits.
    ///
    /// Asking it three times a body pass costs nothing: the merge runs against a
    /// baseline the model holds in memory, not against an App Group read and a
    /// JSON decode. (It did, briefly, and `columnHeight` re-runs on every
    /// GeometryReader layout.)
    private var pendingSummary: String? {
        model.pendingLoosening.flatMap { model.pendingSummary($0) }
    }

    /// 62 + wordmark 13 + 32 + greeting 25 + 22 + hero 232 + 40, then 52 a door.
    private var columnHeight: CGFloat {
        let fixed: CGFloat = 62 + 13 + 32 + 25 + 22 + 232 + 40
        let pending: CGFloat = pendingSummary == nil ? 0 : 62
        let wall: CGFloat = model.wallDown ? 62 : 0
        return fixed + pending + wall + CGFloat(model.policy.doors.count) * 52
    }

    private var column: some View {
        VStack(spacing: 0) {
            // The wordmark's seat, held empty: the mark itself lives on the
            // root's own layer now — the one thing that never yields to the
            // conversation (handoff README.md:203-205) — and the column keeps
            // its 13pt so nothing below it moves.
            Color.clear.frame(height: 13)
                .padding(.top, 62)
            greeting
                .padding(.top, 32)
            hero
                .padding(.top, 22)
            wallRow
            pendingRow
            doors
                .padding(.top, 40)          // the aperture's old slot, closed up
        }
    }

    /// Silk speaks here — always serif, always a complete sentence with a period.
    /// The exception is ☾, which is not a sentence: during down hours there is
    /// nothing to say, and the glyph says it.
    private var greeting: some View {
        Text(model.greeting)
            .font(Silk.serif(21))
            .tracking(Silk.track(-0.005, 21))
            .foregroundStyle(night ? Silk.paperAlpha(0.82) : Silk.inkAlpha(0.90))
    }

    /// One number owns the screen. The stroke is the budget — spent time is bare
    /// paper, and that holds at night too: the current design keeps the minutes on
    /// the hero after dark and moves ☾ into the greeting, so a full ring beside a
    /// numeral reading 10 would be two claims about the same thing. Only the
    /// colour crosses into night.
    private var hero: some View {
        ZStack {
            EnsoView(fraction: model.fractionRemaining,
                     color: night ? Silk.duskBlue : Silk.leaf)
                .frame(width: 232, height: 232)

            // line-height: 1 — SwiftUI hands Text its font's full line box, so
            // without a frame clamped to the point size the label falls away.
            VStack(spacing: 8) {
                Text("\(model.remainingMinutes)")
                    .font(Silk.serif(92))
                    .tracking(Silk.track(-0.045, 92))
                    .frame(height: 92)
                    .foregroundStyle(night ? Silk.paperAlpha(0.92) : Silk.ink)
                    // The stroke around it eases the same change over 450ms —
                    // `EnsoView.motion` is `Silk.motion(0.45)` — and the numeral
                    // hard-cut, so the two halves of one hero disagreed about
                    // whether anything had happened: the ring was still crossing
                    // while the number had already arrived.
                    //
                    // `.opacity` and not the numeric roll. The face is
                    // `monospacedDigit`, deliberately, so that a counting budget
                    // cannot shift width; a roll animates each digit vertically
                    // past its neighbours, which at 92pt is the largest motion
                    // on the screen and undoes the reason the digits are tabular.
                    .contentTransition(.opacity)
                    .animation(Silk.motion(0.45), value: model.remainingMinutes)
                    // VoiceOver reads the pair as one element — "40, min left
                    // today". The unit rides as the value so the numeral keeps
                    // its own label, which the UI tests match by.
                    .accessibilityValue(Text(SilkStrings.minLeftToday))
                Text(SilkStrings.minLeftToday)
                    .font(Silk.sans(12.5))
                    .tracking(Silk.track(0.015, 12.5))
                    .foregroundStyle(night ? Silk.paperAlpha(0.64) : Silk.inkAlpha(0.71))
                    // Already spoken above, as the numeral's value.
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 232)
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
    }

    /// Blocking's truth (docs/market/gaps.md #5): revoked in Settings, or a new
    /// phone whose restored tokens no longer shield. One sentence, one action —
    /// the ensō above stays honest about the budget, this row is honest about
    /// blocking. Same idiom as the pending row below it.
    @ViewBuilder
    private var wallRow: some View {
        if model.wallDown {
            HStack(spacing: 4) {
                Text(SilkStrings.blockingOff)
                    .font(Silk.sans(15))
                    .tracking(Silk.track(-0.005, 15))
                    .foregroundStyle(night ? Silk.paperAlpha(0.61) : Silk.inkAlpha(0.78))
                Spacer()
                Button {
                    model.raiseWall()
                } label: {
                    Text(SilkStrings.turnItOn)
                        .font(Silk.serif(12.5))
                        .tracking(Silk.track(0.015, 12.5))
                        .foregroundStyle(night ? Silk.paperAlpha(0.64) : Silk.inkAlpha(0.67))
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("silk.wall.raise")
            }
            .padding(.horizontal, 46)
            .padding(.top, 18)
            .transition(.opacity)
        }
    }

    /// The pending loosening: what tomorrow holds, and the one way to have it
    /// sooner. It borrows the door row's idiom — sans for the label, serif for the
    /// numeral — and "Apply now." is a sentence Silk speaks, so it is serif.
    @ViewBuilder
    private var pendingRow: some View {
        // A nil summary means the merge would deliver nothing — every field the
        // sentence proposed has been overtaken by a tighten since. The row goes
        // with it, and so does the key button: an offer that cannot be honoured
        // is worse than no offer, and tapping it would spend the key on a no-op.
        if let summary = pendingSummary {
            HStack(spacing: 4) {
                Text(SilkStrings.tomorrow)
                    .font(Silk.sans(15))
                    .tracking(Silk.track(-0.005, 15))
                    .foregroundStyle(night ? Silk.paperAlpha(0.61) : Silk.inkAlpha(0.78))
                // Name what actually moved. A loosening can be a shorter night
                // or a door's own ceiling as readily as a bigger budget, and
                // printing the budget then advertised the one thing unchanged.
                //
                // A cap summary carries a door name, so this is the first thing
                // in the row that is user data and can be long. The worst case
                // is the CLEARING form, not the numeric one: "Instagram no cap"
                // is 16 characters to "Instagram 60"'s 12, about 105pt of serif
                // 14 inside the 283pt this row has on a 375pt device. (120 is
                // the widest number the layout is sized against — the cap wheel
                // tops out at 60, so it is a bound and not a reachable string.)
                // `columnHeight` reserves a flat 62pt, so a second line would
                // collide with the door column rather than push it down.
                Text(summary)
                    .font(Silk.serif(14))
                    .lineLimit(1)
                    .foregroundStyle(night ? Silk.paperAlpha(0.56) : Silk.inkAlpha(0.70))
                Spacer()
                Button {
                    model.keyTapped()
                } label: {
                    Text(SilkStrings.applyNow)
                        .font(Silk.serif(12.5))
                        .tracking(Silk.track(0.015, 12.5))
                        .foregroundStyle(night ? Silk.paperAlpha(0.64) : Silk.inkAlpha(0.67))
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The one control on this row, and until now the only button in
                // the app with no name in the accessibility tree — so the round
                // trip that ends here (park a loosening, come and have it early)
                // could not be walked at all. Outside the label and on the
                // button, exactly as `silk.wall.raise` above it carries its own:
                // under `.plain` the Button is a real element, and the walks
                // match it as a button.
                .accessibilityIdentifier("silk.pending.apply")
            }
            .padding(.horizontal, 46)
            .padding(.top, 18)
            .transition(.opacity)
        }
    }

    /// Tapping any door raises its shield — the wall it would meet, previewed.
    private var doors: some View {
        VStack(spacing: 0) {
            ForEach(model.policy.doors) { door in
                let state = model.state(of: door)
                Button {
                    model.raiseShield(for: door)
                } label: {
                    DoorRow(name: door.name,
                            time: state.displayTime(now: model.now),
                            state: state.rowState,
                            night: night,
                            showsRule: door.id != model.policy.doors.last?.id)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SilkPressStyle())
                // One spoken element per door: name, state, deadline. The
                // label sits on the button, not on the row — the inner texts
                // stay in the hierarchy for the UI tests to match.
                .accessibilityLabel(Text(doorLabel(name: door.name, state: state)))
            }
        }
        .padding(.horizontal, 46)
    }

    /// "Reddit, open till 4:52" — the row's own strings, spoken in one breath.
    /// The dot and the rule say nothing.
    private func doorLabel(name: String, state: DoorState) -> String {
        let word = switch state {
        case .open: SilkStrings.open
        case .live: SilkStrings.inUse
        case .rest: SilkStrings.closed
        }
        guard var time = state.displayTime(now: model.now) else { return "\(name), \(word)" }
        if time.hasPrefix("\u{00B7} ") { time.removeFirst(2) }
        return "\(name), \(word) \(time)"
    }
}

private extension DoorState {
    /// The model and the row share the design's vocabulary, so this is an
    /// identity — which is the point. When they disagreed, a shut door wore the
    /// in-play costume.
    var rowState: DoorRowState {
        switch self {
        case .open: .open
        case .live: .live
        case .rest: .rest
        }
    }
}
