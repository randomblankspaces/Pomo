import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var immersive: ImmersiveMode
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CustomThemeStore.shared

    @State private var showAddTheme = false
    @State private var editingThemeID: String?
    @State private var showPresets = false

    var theme: Theme { engine.theme }
    var settings: PomoSettings { engine.state.settings }

    var body: some View {
        ZStack {
            LinearGradient(colors: theme.bg, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Settings")
                        .font(.system(size: 20, weight: .bold, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    IconButton(systemName: "xmark.circle.fill", size: 18, theme: theme) {
                        dismiss()
                    }
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        themeSection
                        presetSection
                        durationSection
                        effectsSection
                        particleSection
                        behaviorSection
                        immersiveSection
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(22)
        }
        .frame(width: 420, height: 560)
        .sheet(isPresented: $showAddTheme) {
            AddThemeSheet(theme: theme) { newID in
                withAnimation(.easeInOut(duration: 0.6)) { engine.setTheme(newID) }
            }
        }
        .sheet(item: $editingThemeID) { id in
            ThemeEditorSheet(themeID: id, uiTheme: theme)
        }
    }

    // MARK: Durations

    private var durationSection: some View {
        SettingsCard(title: "DURATIONS", theme: theme) {
            DurationRow(
                label: "Focus", emoji: "🍅", range: 1...120,
                value: Binding(
                    get: { settings.focusMinutes },
                    set: { v in engine.updateSettings { $0.focusMinutes = v } }
                ), theme: theme
            )
            DurationRow(
                label: "Short break", emoji: "☕️", range: 1...45,
                value: Binding(
                    get: { settings.shortBreakMinutes },
                    set: { v in engine.updateSettings { $0.shortBreakMinutes = v } }
                ), theme: theme
            )
            DurationRow(
                label: "Long break", emoji: "🌙", range: 5...90,
                value: Binding(
                    get: { settings.longBreakMinutes },
                    set: { v in engine.updateSettings { $0.longBreakMinutes = v } }
                ), theme: theme
            )

            HStack {
                Text("Sessions until long break")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Stepper(
                    value: Binding(
                        get: { settings.sessionsUntilLongBreak },
                        set: { v in engine.updateSettings { $0.sessionsUntilLongBreak = v } }
                    ),
                    in: 2...8
                ) {
                    Text("\(settings.sessionsUntilLongBreak)")
                        .font(.system(size: 13, weight: .bold, design: theme.fontDesign))
                        .foregroundStyle(theme.accent)
                        .frame(minWidth: 18)
                }
            }
        }
    }

    // MARK: Behavior

    private var behaviorSection: some View {
        SettingsCard(title: "BEHAVIOR", theme: theme) {
            Toggle(isOn: Binding(
                get: { settings.autoStartNext },
                set: { v in engine.updateSettings { $0.autoStartNext = v } }
            )) {
                Text("Auto-start next phase")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(theme.accent)

            Toggle(isOn: Binding(
                get: { settings.soundOn },
                set: { v in engine.updateSettings { $0.soundOn = v } }
            )) {
                Text("Completion sound")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(theme.accent)

            Toggle(isOn: Binding(
                get: { settings.breathingOn },
                set: { v in engine.updateSettings { $0.breathing = v } }
            )) {
                Text("Timer breathing")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(theme.accent)

            Toggle(isOn: Binding(
                get: { settings.batterySaverOn },
                set: { v in engine.updateSettings { $0.batterySaver = v } }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Battery saver")
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Text("Unplugged: 1080p video, gentler effects")
                        .font(.system(size: 9.5, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.accent)
        }
    }

    // MARK: Effects — per-layer FX toggles for the current theme

    private var effectsSection: some View {
        SettingsCard(title: "EFFECTS · \(theme.name.uppercased())", theme: theme) {
            ForEach(theme.fxLayers, id: \.rawValue) { layer in
                Toggle(isOn: Binding(
                    get: { settings.isFXEnabled(themeID: theme.id, layer) },
                    set: { on in
                        engine.updateSettings { $0.setFX(themeID: theme.id, layer, enabled: on) }
                    }
                )) {
                    Text(layer.displayName)
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(theme.accent)
            }

            Divider().overlay(Color.white.opacity(0.1))

            VStack(spacing: 4) {
                HStack {
                    Text("Particle amount")
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(String(format: "%.1f×", settings.fxDensityValue))
                        .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                        .foregroundStyle(theme.accent)
                }
                Slider(value: Binding(
                    get: { settings.fxDensityValue },
                    set: { v in engine.updateSettings { $0.fxDensity = v } }
                ), in: 0.2...2.5, step: 0.1)
                .tint(theme.accent)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Particle size")
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(String(format: "%.1f×", settings.fxSizeValue))
                        .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                        .foregroundStyle(theme.accent)
                }
                Slider(value: Binding(
                    get: { settings.fxSizeValue },
                    set: { v in engine.updateSettings { $0.fxSize = v } }
                ), in: 0.5...2.0, step: 0.1)
                .tint(theme.accent)
            }

            Divider().overlay(Color.white.opacity(0.1))

            Toggle(isOn: Binding(
                get: { settings.pointerFXOn },
                set: { on in engine.updateSettings { $0.pointerFX = on } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("React to cursor & clicks")
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Text("Gusts, ripples, gravity wells, fleeing fish…")
                        .font(.system(size: 10, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.accent)

            Toggle(isOn: Binding(
                get: { settings.parallaxOn },
                set: { on in engine.updateSettings { $0.parallax = on } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background follows cursor")
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Text("Parallax pan of the video as you move the mouse")
                        .font(.system(size: 10, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.accent)
        }
    }

    // MARK: Immersive

    private var immersiveSection: some View {
        SettingsCard(title: "IMMERSIVE", theme: theme) {
            Toggle(isOn: Binding(
                get: { immersive.enabled },
                set: { on in
                    immersive.enabled = on
                    if on { immersive.apply(theme) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Mac wallpaper & dark mode")
                        .font(.system(size: 12, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    Text("Your desktop picture becomes the theme's scene")
                        .font(.system(size: 10, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.accent)

            HStack {
                Button("Apply now") { immersive.apply(theme) }
                    .buttonStyle(PillButtonStyle(theme: theme))
                Button("Restore my wallpaper") { immersive.restoreOriginalWallpaper() }
                    .buttonStyle(PillButtonStyle(theme: theme))
            }
        }
    }

    // MARK: Theme grid

    private var particleSection: some View {
        SettingsCard(title: "PARTICLE STYLE", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Override the auto-selected particle effect")
                    .font(.system(size: 10, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)

                let current = settings.particleOverride(for: theme.id)
                let options: [ParticleStyle?] = [nil] + ParticleStyle.allVisible
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, style in
                        let selected = style == current
                        Button {
                            engine.updateSettings { $0.setParticleOverride(themeID: theme.id, style) }
                        } label: {
                            Text(style?.displayName ?? "Auto")
                                .font(.system(size: 10, weight: selected ? .bold : .medium, design: theme.fontDesign))
                                .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected ? theme.accent.opacity(0.3) : .white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(selected ? theme.accent.opacity(0.6) : .clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var themeSection: some View {
        SettingsCard(title: "MY THEMES", theme: theme) {
            if store.isEmpty {
                emptyThemeState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(store.themes) { ct in
                        ThemeSwatch(t: ct.resolved, selected: ct.id == theme.id) {
                            withAnimation(.easeInOut(duration: 0.6)) { engine.setTheme(ct.id) }
                        }
                        .contextMenu {
                            Button("Edit…") { editingThemeID = ct.id }
                            Button("Re-read Colors from Video") { store.reanalyze(id: ct.id) }
                            Divider()
                            Button("Delete", role: .destructive) { deleteTheme(ct.id) }
                        }
                    }
                    AddThemeTile(theme: theme) { showAddTheme = true }
                }

                Text("Right-click a theme to edit its colors and particles.")
                    .font(.system(size: 10, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                    .padding(.top, 2)
            }
        }
    }

    /// First-run state: nothing but the call to action.
    private var emptyThemeState: some View {
        VStack(spacing: 14) {
            Text("No themes yet")
                .font(.system(size: 13, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textPrimary)

            Text("Drop in a video and Pomo builds a theme from it — colors, ring, and particles picked to match.")
                .font(.system(size: 11, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            AddThemeTile(theme: theme, prominent: true) { showAddTheme = true }
                .frame(width: 150)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var presetSection: some View {
        SettingsCard(title: "BUILT-IN PRESETS", theme: theme) {
            DisclosureGroup(isExpanded: $showPresets) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(Themes.all) { t in
                        ThemeSwatch(t: t, selected: t.id == theme.id) {
                            withAnimation(.easeInOut(duration: 0.6)) { engine.setTheme(t.id) }
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("\(Themes.all.count) themes without video")
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
            }
            .tint(theme.accent)
        }
    }

    private func deleteTheme(_ id: String) {
        let wasSelected = theme.id == id
        store.delete(id: id)
        if wasSelected {
            engine.setTheme(store.themes.first?.id ?? Themes.all[0].id)
        }
    }
}

// MARK: - Pieces

struct SettingsCard<Content: View>: View {
    let title: String
    let theme: Theme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(3)
                .foregroundStyle(theme.textSecondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

struct DurationRow: View {
    let label: String
    let emoji: String
    let range: ClosedRange<Double>
    @Binding var value: Double
    let theme: Theme

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(emoji) \(label)")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(Int(value)) min")
                    .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(theme.accent)
            }
            Slider(value: $value, in: range, step: 1)
                .tint(theme.accent)
        }
    }
}

struct ThemeSwatch: View {
    let t: Theme
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: t.bg, startPoint: .top, endPoint: .bottom))
                        .frame(height: 44)
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            LinearGradient(colors: [t.ringA, t.ringB], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                    Text(t.emoji).font(.system(size: 10)).offset(y: 0)
                }
                Text(t.name)
                    .font(.system(size: 10, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? t.ringA : .white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.1 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? t.ringA : .clear, lineWidth: 1.5)
            )
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
