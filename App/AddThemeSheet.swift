import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Drop-a-video-get-a-theme flow. The video is copied into Application
/// Support, sampled for its palette, and turned into an editable theme.
struct AddThemeSheet: View {
    let theme: Theme
    var onFinished: (String) -> Void       // new theme id

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CustomThemeStore.shared

    @State private var isTargeted = false
    @State private var stage: Stage = .waiting
    @State private var themeName = ""
    @State private var errorText: String?

    private enum Stage: Equatable {
        case waiting
        case importing(String)     // status line
        case done(String)          // theme id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)

            Group {
                switch stage {
                case .waiting:              dropZone
                case .importing(let status): progress(status)
                case .done(let id):         success(id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(width: 520, height: 420)
        .background(background)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Add Theme")
                .font(.system(size: 15, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .foregroundStyle(isTargeted ? theme.accent : theme.textSecondary.opacity(0.4))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isTargeted ? theme.accent.opacity(0.10) : .white.opacity(0.03))
                    )

                VStack(spacing: 12) {
                    Image(systemName: isTargeted ? "arrow.down.circle.fill" : "film.stack")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(isTargeted ? theme.accent : theme.textSecondary)

                    Text(isTargeted ? "Release to import" : "Drop a video here")
                        .font(.system(size: 14, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)

                    Text("MP4, MOV, or M4V")
                        .font(.system(size: 11, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }

            HStack(spacing: 8) {
                Rectangle().fill(theme.textSecondary.opacity(0.2)).frame(height: 1)
                Text("or")
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                Rectangle().fill(theme.textSecondary.opacity(0.2)).frame(height: 1)
            }

            Button("Choose Video…") { chooseFile() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Progress / success

    private func progress(_ status: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(status)
                .font(.system(size: 13, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func success(_ id: String) -> some View {
        let created = store.theme(id: id)
        return VStack(spacing: 16) {
            Text(created?.emoji ?? "🎬").font(.system(size: 44))

            VStack(spacing: 6) {
                Text("Theme created")
                    .font(.system(size: 15, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                Text("Colors and particles were picked from your video. You can change them any time in Settings.")
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }

            TextField("Theme name", text: $themeName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commitName(id) }

            if let created {
                HStack(spacing: 8) {
                    swatch(Color(hexString: created.ringAHex))
                    swatch(Color(hexString: created.ringBHex))
                    swatch(Color(hexString: created.accentHex))
                    Text(created.particles.map(\.displayName).joined(separator: " + "))
                        .font(.system(size: 10, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.leading, 4)
                }
            }

            Button("Use This Theme") {
                commitName(id)
                onFinished(id)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        }
    }

    private func swatch(_ c: Color) -> some View {
        Circle()
            .fill(c)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: theme.bg, startPoint: .top, endPoint: .bottom)
            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
    }

    // MARK: Import

    private func commitName(_ id: String) {
        let trimmed = themeName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.rename(id: id, to: trimmed)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importVideo(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let ext = url.pathExtension.lowercased()
            guard ["mp4", "mov", "m4v"].contains(ext) else {
                Task { @MainActor in errorText = "That file isn’t a supported video format." }
                return
            }
            Task { @MainActor in importVideo(url) }
        }
        return true
    }

    private func importVideo(_ source: URL) {
        errorText = nil
        let id = uniqueID(from: source)
        stage = .importing("Copying video…")

        Task.detached(priority: .userInitiated) {
            do {
                let dest = try await copy(source, id: id)
                await MainActor.run { stage = .importing("Reading colors…") }

                guard let profile = ColorExtractor.analyzeVideo(at: dest) else {
                    await MainActor.run {
                        stage = .waiting
                        errorText = "Couldn’t read any frames from that video."
                    }
                    return
                }

                let name = Self.prettyName(from: source)
                let generated = ThemeGenerator.generate(from: profile, id: id, name: name)

                await MainActor.run {
                    CustomThemeStore.shared.add(CustomTheme(from: generated))
                    ThemeMedia.clearVideoCache()
                    themeName = name
                    stage = .done(id)
                }
            } catch {
                await MainActor.run {
                    stage = .waiting
                    errorText = "Couldn’t import that video: \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated func copy(_ source: URL, id: String) async throws -> URL {
        ThemeMedia.ensureDirectories()
        let ext = source.pathExtension.lowercased()
        let dest = ThemeMedia.videosDirectory.appendingPathComponent("vid-\(id).\(ext)")

        // Security-scoped access is required for files dragged from outside
        // the sandbox container.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Slug from the filename, uniquified so importing two videos with the
    /// same name doesn't clobber the first theme.
    private func uniqueID(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "theme" : base

        let taken = Set(Themes.all.map(\.id)).union(store.themes.map(\.id))
        if !taken.contains(stem) { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    private static func prettyName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .capitalized
    }
}
