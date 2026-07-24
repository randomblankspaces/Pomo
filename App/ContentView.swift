import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var desktopMode: DesktopMode
    @EnvironmentObject var immersive: ImmersiveMode
    @EnvironmentObject var habitStore: HabitStore
    @EnvironmentObject var visibility: VisibilityMonitor
    @EnvironmentObject var spotify: SpotifyController
    @State private var showSettings = false
    @AppStorage("habitPanelsOn") private var showHabits = false

    var theme: Theme { engine.theme }

    var body: some View {
        ZStack {
            ThemeBackground(theme: theme)

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                modePills
                    .padding(.top, 18)

                GeometryReader { geo in
                    // grows the whole arrangement on big windows/fullscreen
                    let scale: CGFloat = min(1.9, max(1.0, geo.size.width / 1360))
                    let ringMax = max(desktopMode.isOn ? 480 : 340, 380 * scale)
                    let panelsOn = showHabits && geo.size.width >= 980
                    let sideWidth = max(300, (geo.size.width - ringMax - 120) / 2)

                    // ZStack: the timer is its own centered layer and NEVER
                    // moves; panels overlay the sides and adapt around it.
                    ZStack {
                        VStack(spacing: 0) {
                            TimerRing(scale: max(1, ringMax / 340))
                                .frame(maxWidth: ringMax, maxHeight: ringMax)
                                .padding(.horizontal, 20)

                            sessionDots
                                .padding(.top, 22)

                            controls
                                .padding(.top, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                        if panelsOn {
                            HStack(spacing: 0) {
                                HabitLeftPanel(scale: scale)
                                    .frame(width: 340 * scale)
                                    .frame(width: sideWidth, alignment: .center)
                                    .frame(maxHeight: .infinity)
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                Spacer(minLength: ringMax)
                                HabitRightPanel(scale: min(scale, sideWidth / 500))
                                    .frame(width: sideWidth, alignment: .center)
                                    .frame(maxHeight: .infinity)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                SpotifyBar()
                    .frame(maxWidth: desktopMode.isOn ? 560 : .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, desktopMode.isOn ? 40 : 16)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: theme.id)
        .onChange(of: engine.state.settings.themeID) { _, newID in
            immersive.applyIfEnabled(Themes.theme(newID))
        }
        .onAppear { immersive.applyIfEnabled(theme) }
        .onChange(of: visibility.visible) { _, on in
            spotify.appVisible = on
            DecodeGate.shared.appVisible = on
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
        }
    }

    // MARK: Header — theme menu + settings

    private var header: some View {
        HStack {
            Menu {
                ForEach(Themes.all) { t in
                    Button {
                        engine.setTheme(t.id)
                    } label: {
                        HStack {
                            Text("\(t.emoji) \(t.name)")
                            if t.id == theme.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                if !Themes.custom.isEmpty {
                    Divider()
                    ForEach(Themes.custom) { t in
                        Button {
                            engine.setTheme(t.id)
                        } label: {
                            HStack {
                                Text("\(t.emoji) \(t.name)")
                                if t.id == theme.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(theme.emoji)
                    Text(theme.name)
                        .font(.system(size: 12, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.08)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            HStack(spacing: 16) {
                IconButton(
                    systemName: desktopMode.isOn
                        ? "arrow.down.right.and.arrow.up.left"
                        : "desktopcomputer",
                    size: 14, theme: theme
                ) {
                    desktopMode.toggle()
                }
                .help(desktopMode.isOn ? "Exit desktop mode (⌘D)" : "Become the desktop background (⌘D)")

                IconButton(systemName: "square.grid.2x2.fill", size: 14, theme: theme) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showHabits.toggle()
                    }
                }
                .help(showHabits ? "Hide habit tracker" : "Show habit tracker")

                IconButton(systemName: "gearshape.fill", size: 14, theme: theme) {
                    showSettings = true
                }
            }
        }
    }

    // MARK: Mode pills

    private var modePills: some View {
        HStack(spacing: 8) {
            ForEach(PomoMode.allCases, id: \.self) { mode in
                let selected = engine.state.mode == mode
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        engine.switchMode(mode)
                    }
                } label: {
                    Text(mode.shortTitle)
                        .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(selected ? theme.accent.opacity(0.32) : .white.opacity(0.05))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? theme.accent.opacity(0.7) : .clear, lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Session dots

    private var sessionDots: some View {
        let total = max(1, engine.state.settings.sessionsUntilLongBreak)
        let done = engine.state.completedFocusSessions % total
        return HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < done ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.white.opacity(0.15)))
                    .frame(width: 7, height: 7)
                    .shadow(color: i < done ? theme.accent.opacity(0.8) : .clear, radius: 4)
            }
            Text("\(engine.state.completedFocusSessions)")
                .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 6)
                .monospacedDigit()
        }
    }

    // MARK: Transport controls

    private var controls: some View {
        HStack(spacing: 26) {
            IconButton(systemName: "arrow.counterclockwise", size: 16, theme: theme) {
                withAnimation { engine.reset() }
            }
            .help("Reset")

            PlayPauseButton()

            IconButton(systemName: "forward.end.fill", size: 16, theme: theme) {
                withAnimation { engine.skip() }
            }
            .help("Skip to next phase")
        }
    }
}

// MARK: - The big play/pause button

struct PlayPauseButton: View {
    @EnvironmentObject var engine: PomoEngine
    @State private var hovering = false

    var theme: Theme { engine.theme }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { engine.toggle() }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.ringA, theme.ringB],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: theme.accent.opacity(0.45 * theme.glow + 0.15), radius: hovering ? 18 : 10)

                Image(systemName: engine.state.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: engine.state.isRunning ? 0 : 2)
            }
            .scaleEffect(hovering ? 1.07 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.space, modifiers: [])
    }
}

// MARK: - Timer ring

struct TimerRing: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var visibility: VisibilityMonitor
    var scale: CGFloat = 1

    var theme: Theme { engine.theme }

    var body: some View {
        // 10fps: breathe steps stay sub-pixel at ring size, digits flip 1/s.
        // Time comes from the timeline — no engine publishes drive this view.
        TimelineView(.animation(
            minimumInterval: engine.state.isRunning ? 0.1 : 0.5,
            paused: !visibility.visible
        )) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let remaining = engine.state.currentRemaining(at: timeline.date)
            let progress = engine.state.progress(at: timeline.date)
            let breathe = engine.state.isRunning && engine.state.settings.breathingOn
                ? 1 + 0.012 * sin(t * 1.8) : 1.0
            let glowPulse = engine.state.isRunning ? 0.6 + 0.4 * abs(sin(t * 1.2)) : 0.35

            ZStack {
                // Track
                Circle()
                    .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round))

                // Progress arc
                Circle()
                    .trim(from: 0, to: max(0.0001, progress))
                    .stroke(
                        AngularGradient(
                            colors: [theme.ringA, theme.ringB, theme.ringA],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: theme.accent.opacity(theme.glow * glowPulse), radius: 12)
                    .animation(.linear(duration: 0.3), value: progress)

                // Orbiting comet at the arc tip
                if engine.state.isRunning {
                    GeometryReader { geo in
                        let radius = min(geo.size.width, geo.size.height) / 2
                        let angle = progress * 2 * .pi - .pi / 2
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                            .shadow(color: theme.ringB, radius: 6)
                            .position(
                                x: geo.size.width / 2 + cos(angle) * radius,
                                y: geo.size.height / 2 + sin(angle) * radius
                            )
                    }
                }

                // Center readout
                VStack(spacing: 6 * scale) {
                    Text(pomoFormat(remaining))
                        .font(.system(size: 58 * scale, weight: .bold, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy(duration: 0.25), value: Int(remaining))
                        .shadow(color: theme.accent.opacity(0.5 * theme.glow), radius: 16)
                        .monospacedDigit()

                    Text(engine.state.mode.title)
                        .font(.system(size: 12 * scale, weight: .bold, design: theme.fontDesign))
                        .tracking(4)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(10)
            .scaleEffect(breathe)
            .aspectRatio(1, contentMode: .fit)
        }
    }
}
