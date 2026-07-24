import SwiftUI

/// "Add Theme" affordance in the theme grid. In `prominent` mode it's the
/// first-run call to action and draws an arrow pointing at itself.
struct AddThemeTile: View {
    let theme: Theme
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var nudge = false

    var body: some View {
        VStack(spacing: 8) {
            if prominent {
                // Points down at the button below it.
                Image(systemName: "arrow.down")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.red)
                    .offset(y: nudge ? 4 : -4)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: nudge)
                    .onAppear { nudge = true }
            }

            Button(action: action) {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                            .foregroundStyle(prominent ? .red : theme.textSecondary.opacity(0.5))
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.white.opacity(hovering ? 0.10 : 0.04))
                            )
                            .frame(height: 44)

                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(prominent ? .red : theme.textSecondary)
                    }
                    Text("Add Theme")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(prominent ? .red : .white.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(5)
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// Edits a user theme's palette and particle layers after import.
struct ThemeEditorSheet: View {
    let themeID: String
    let uiTheme: Theme

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CustomThemeStore.shared
    @EnvironmentObject var engine: PomoEngine

    private var custom: CustomTheme? { store.theme(id: themeID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)

            if let custom {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        preview(custom)
                        nameRow(custom)
                        colorRow(custom)
                        particleGrid(custom)
                        resetRow
                    }
                    .padding(20)
                }
            } else {
                Text("This theme no longer exists.")
                    .foregroundStyle(uiTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 460, height: 560)
        .background(
            ZStack {
                LinearGradient(colors: uiTheme.bg, startPoint: .top, endPoint: .bottom)
                Color.black.opacity(0.25)
            }
            .ignoresSafeArea()
        )
    }

    private var header: some View {
        HStack {
            Text("Edit Theme")
                .font(.system(size: 15, weight: .semibold, design: uiTheme.fontDesign))
                .foregroundStyle(uiTheme.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(uiTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func preview(_ ct: CustomTheme) -> some View {
        let t = ct.resolved
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: t.bg, startPoint: .top, endPoint: .bottom))
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    LinearGradient(colors: [t.ringA, t.ringB], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 60, height: 60)
            Text(t.emoji).font(.system(size: 18))
        }
        .frame(height: 110)
    }

    private func nameRow(_ ct: CustomTheme) -> some View {
        HStack(spacing: 10) {
            TextField("Emoji", text: Binding(
                get: { ct.emoji },
                set: { store.setEmoji(id: themeID, String($0.prefix(2))) }
            ))
            .frame(width: 54)
            .multilineTextAlignment(.center)

            TextField("Theme name", text: Binding(
                get: { ct.name },
                set: { store.rename(id: themeID, to: $0) }
            ))
        }
        .textFieldStyle(.roundedBorder)
    }

    private func colorRow(_ ct: CustomTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("COLORS")
            HStack(spacing: 18) {
                picker("Ring start", Binding(
                    get: { Color(hexString: ct.ringAHex) },
                    set: { store.setRing(id: themeID, a: $0, b: Color(hexString: ct.ringBHex)) }
                ))
                picker("Ring end", Binding(
                    get: { Color(hexString: ct.ringBHex) },
                    set: { store.setRing(id: themeID, a: Color(hexString: ct.ringAHex), b: $0) }
                ))
                picker("Accent", Binding(
                    get: { Color(hexString: ct.accentHex) },
                    set: { store.setAccent(id: themeID, $0) }
                ))
            }
        }
    }

    private func picker(_ title: String, _ binding: Binding<Color>) -> some View {
        VStack(spacing: 5) {
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            Text(title)
                .font(.system(size: 9, design: uiTheme.fontDesign))
                .foregroundStyle(uiTheme.textSecondary)
        }
    }

    private func particleGrid(_ ct: CustomTheme) -> some View {
        let active = Set(ct.particles)
        return VStack(alignment: .leading, spacing: 10) {
            label("PARTICLES")
            Text("Pick up to two. Auto-chosen from your video.")
                .font(.system(size: 10, design: uiTheme.fontDesign))
                .foregroundStyle(uiTheme.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(ParticleStyle.allVisible, id: \.rawValue) { style in
                    let on = active.contains(style)
                    Button {
                        toggle(style, in: ct)
                    } label: {
                        Text(style.displayName)
                            .font(.system(size: 10, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? Color.black : uiTheme.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(on ? uiTheme.accent : .white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resetRow: some View {
        Button {
            store.reanalyze(id: themeID)
        } label: {
            Label("Re-read colors from video", systemImage: "arrow.clockwise")
                .font(.system(size: 11, design: uiTheme.fontDesign))
        }
        .buttonStyle(.bordered)
        .tint(uiTheme.accent)
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold))
            .tracking(2.5)
            .foregroundStyle(uiTheme.textSecondary)
    }

    /// Keeps at most two layers, dropping the oldest when a third is added.
    private func toggle(_ style: ParticleStyle, in ct: CustomTheme) {
        var styles = ct.particles
        if let i = styles.firstIndex(of: style) {
            styles.remove(at: i)
        } else {
            styles.append(style)
            if styles.count > 2 { styles.removeFirst() }
        }
        store.setParticles(id: themeID, styles)
        if engine.theme.id == themeID {
            engine.setTheme(themeID)   // force the renderer to rebuild layers
        }
    }
}

// Lets `.sheet(item:)` drive off a plain theme-id string.
extension String: @retroactive Identifiable {
    public var id: String { self }
}
