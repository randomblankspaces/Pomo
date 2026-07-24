import SwiftUI
import AppKit

/// User-created themes: one per imported video. The video itself lives in
/// Application Support; this store holds the palette and FX choices so any
/// edits the user makes survive relaunch instead of being re-derived from
/// the footage every time.
@MainActor
final class CustomThemeStore: ObservableObject {
    static let shared = CustomThemeStore()

    @Published private(set) var themes: [CustomTheme] = []

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomo/themes.json")
    }

    private init() {
        load()
    }

    // MARK: Reading

    var isEmpty: Bool { themes.isEmpty }

    func theme(id: String) -> CustomTheme? { themes.first { $0.id == id } }

    /// Push the store into the global `Themes.custom` list the rest of the app reads.
    func publish() {
        Themes.custom = themes.map(\.resolved)
    }

    // MARK: Mutating

    func add(_ theme: CustomTheme) {
        themes.removeAll { $0.id == theme.id }
        themes.append(theme)
        save()
    }

    func update(_ theme: CustomTheme) {
        guard let i = themes.firstIndex(where: { $0.id == theme.id }) else { return }
        themes[i] = theme
        save()
    }

    func rename(id: String, to name: String) {
        guard var t = theme(id: id) else { return }
        t.name = name
        update(t)
    }

    func setParticles(id: String, _ styles: [ParticleStyle]) {
        guard var t = theme(id: id) else { return }
        t.particleStyles = styles.map(\.rawValue)
        update(t)
    }

    func setAccent(id: String, _ color: Color) {
        guard var t = theme(id: id) else { return }
        t.accentHex = color.hexString
        update(t)
    }

    func setRing(id: String, a: Color, b: Color) {
        guard var t = theme(id: id) else { return }
        t.ringAHex = a.hexString
        t.ringBHex = b.hexString
        update(t)
    }

    func setEmoji(id: String, _ emoji: String) {
        guard var t = theme(id: id) else { return }
        t.emoji = emoji
        update(t)
    }

    /// Removes the theme and its imported video files.
    func delete(id: String) {
        guard let t = theme(id: id) else { return }
        themes.removeAll { $0.id == id }
        save()
        for dir in [ThemeMedia.videosDirectory, ThemeMedia.videosDirectory1080] {
            for ext in ["mp4", "mov", "m4v"] {
                let url = dir.appendingPathComponent("vid-\(t.id).\(ext)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        ThemeMedia.clearVideoCache()
    }

    /// Picks up videos copied straight into the Videos folder (rather than
    /// imported through the sheet) and turns each into a theme. Runs off the
    /// main actor since decoding a frame per video is slow.
    func adoptOrphanedVideos() {
        let known = Set(themes.map(\.id)).union(Themes.all.map(\.id))
        let candidates = ThemeMedia.discoverUserVideos().compactMap { url -> (String, URL)? in
            let stem = url.deletingPathExtension().lastPathComponent
            let id = stem.hasPrefix("vid-") ? String(stem.dropFirst(4)) : stem
            return known.contains(id) ? nil : (id, url)
        }
        guard !candidates.isEmpty else { return }

        Task.detached(priority: .utility) {
            var made: [CustomTheme] = []
            for (id, url) in candidates {
                guard let profile = ColorExtractor.analyzeVideo(at: url) else { continue }
                let name = id
                    .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
                    .capitalized
                made.append(CustomTheme(from: ThemeGenerator.generate(from: profile, id: id, name: name)))
            }
            guard !made.isEmpty else { return }
            await MainActor.run {
                for t in made { CustomThemeStore.shared.add(t) }
            }
        }
    }

    /// Re-runs color analysis on the theme's video and overwrites the palette,
    /// discarding manual color edits.
    func reanalyze(id: String) {
        guard var t = theme(id: id),
              let video = ThemeMedia.videoURL(for: t.id),
              let profile = ColorExtractor.analyzeVideo(at: video) else { return }
        let fresh = ThemeGenerator.generate(from: profile, id: t.id, name: t.name)
        t.applyPalette(from: fresh)
        update(t)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([CustomTheme].self, from: data) else { return }
        themes = decoded
    }

    private func save() {
        publish()
        guard let data = try? JSONEncoder().encode(themes) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

// MARK: - Model

/// Codable mirror of `Theme`. Colors are hex strings so the palette can be
/// edited and round-tripped without depending on SwiftUI's Color encoding.
struct CustomTheme: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var emoji: String
    var bgHex: [String]
    var ringAHex: String
    var ringBHex: String
    var accentHex: String
    var textPrimaryHex: String
    var textSecondaryHex: String
    var particleStyles: [String]
    var fontDesignRaw: String
    var glow: Double

    /// Builds the runtime `Theme` the renderer consumes.
    var resolved: Theme {
        Theme(
            id: id,
            name: name,
            emoji: emoji,
            bg: bgHex.map { Color(hexString: $0) },
            ringA: Color(hexString: ringAHex),
            ringB: Color(hexString: ringBHex),
            accent: Color(hexString: accentHex),
            textPrimary: Color(hexString: textPrimaryHex),
            textSecondary: Color(hexString: textSecondaryHex),
            fxLayers: particleStyles.compactMap { ParticleStyle(rawValue: $0) },
            fontDesign: Self.design(from: fontDesignRaw),
            glow: glow
        )
    }

    var particles: [ParticleStyle] {
        particleStyles.compactMap { ParticleStyle(rawValue: $0) }
    }

    /// Seeds a custom theme from a freshly generated one.
    init(from theme: Theme) {
        id = theme.id
        name = theme.name
        emoji = theme.emoji
        bgHex = theme.bg.map(\.hexString)
        ringAHex = theme.ringA.hexString
        ringBHex = theme.ringB.hexString
        accentHex = theme.accent.hexString
        textPrimaryHex = theme.textPrimary.hexString
        textSecondaryHex = theme.textSecondary.hexString
        particleStyles = theme.fxLayers.map(\.rawValue)
        fontDesignRaw = Self.raw(from: theme.fontDesign)
        glow = theme.glow
    }

    /// Overwrites only the generated palette, keeping the user's name/emoji.
    mutating func applyPalette(from theme: Theme) {
        bgHex = theme.bg.map(\.hexString)
        ringAHex = theme.ringA.hexString
        ringBHex = theme.ringB.hexString
        accentHex = theme.accent.hexString
        textPrimaryHex = theme.textPrimary.hexString
        textSecondaryHex = theme.textSecondary.hexString
        particleStyles = theme.fxLayers.map(\.rawValue)
        fontDesignRaw = Self.raw(from: theme.fontDesign)
        glow = theme.glow
    }

    private static func raw(from d: Font.Design) -> String {
        switch d {
        case .rounded:    return "rounded"
        case .serif:      return "serif"
        case .monospaced: return "monospaced"
        default:          return "default"
        }
    }

    private static func design(from raw: String) -> Font.Design {
        switch raw {
        case "rounded":    return .rounded
        case "serif":      return .serif
        case "monospaced": return .monospaced
        default:           return .default
        }
    }
}

// MARK: - Color hex bridging

extension Color {
    /// "RRGGBB" — drops alpha, which themes never vary.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    init(hexString: String) {
        let cleaned = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        let value = UInt32(cleaned, radix: 16) ?? 0
        self.init(hex: value)
    }
}
