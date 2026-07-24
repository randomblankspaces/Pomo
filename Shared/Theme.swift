import SwiftUI

enum ParticleStyle: String, CaseIterable {
    case petals, leaves, neonRain, matrix, stars, bubbles, snow, fireflies, dust, gravity, pixel, pond
    case embers, bokeh, sparkle, confetti, smoke, aurora, lanterns, feathers, ripples, comet, fog, geometric, lightning
    case none

    var displayName: String {
        switch self {
        case .petals:    return "Sakura Petals"
        case .leaves:    return "Autumn Leaves"
        case .neonRain:  return "3D Rain"
        case .matrix:    return "Code Rain"
        case .stars:     return "Starfield"
        case .bubbles:   return "Ripples & Fish"
        case .snow:      return "Snowfall"
        case .fireflies: return "Fireflies"
        case .dust:      return "Sand Drift"
        case .gravity:   return "Gravity Well"
        case .pixel:     return "8-bit Pixels"
        case .pond:      return "Pond Leaves & Ripples"
        case .embers:    return "Embers"
        case .bokeh:     return "Bokeh Lights"
        case .sparkle:   return "Sparkle"
        case .confetti:  return "Confetti"
        case .smoke:     return "Smoke Wisps"
        case .aurora:    return "Aurora"
        case .lanterns:  return "Lanterns"
        case .feathers:  return "Feathers"
        case .ripples:   return "Water Ripples"
        case .comet:     return "Comet Trails"
        case .fog:       return "Fog"
        case .geometric: return "Geometric"
        case .lightning:  return "Lightning"
        case .none:      return "None"
        }
    }

    static let allVisible: [ParticleStyle] = allCases.filter { $0 != .none }
}

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let bg: [Color]          // gradient stops — widget background + fallbacks
    let ringA: Color         // ring gradient start
    let ringB: Color         // ring gradient end
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let fxLayers: [ParticleStyle]   // every layer individually toggleable
    let fontDesign: Font.Design
    let glow: Double         // 0...1 neon glow intensity

    /// Legacy single-style accessor (widget snapshot / fallbacks).
    var particles: ParticleStyle { fxLayers.first ?? .none }

    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum Themes {
    static let all: [Theme] = [
        Theme(
            id: "sakura", name: "Sakura Moon", emoji: "🌸",
            bg: [Color(hex: 0x1D1030), Color(hex: 0x3D1C4E), Color(hex: 0x6E3A6E)],
            ringA: Color(hex: 0xFF9ECD), ringB: Color(hex: 0xFFE3F2),
            accent: Color(hex: 0xFF7EB6),
            textPrimary: .white, textSecondary: Color(hex: 0xE8C9DC),
            fxLayers: [.petals], fontDesign: .rounded, glow: 0.9
        ),
        Theme(
            id: "initiald", name: "Initial D", emoji: "🚗",
            bg: [Color(hex: 0x14100C), Color(hex: 0x2A2118), Color(hex: 0x4A3520)],
            ringA: Color(hex: 0xFFC65C), ringB: Color(hex: 0xFFEDC2),
            accent: Color(hex: 0xF5A623),
            textPrimary: Color(hex: 0xFFF6E3), textSecondary: Color(hex: 0xCBA76A),
            fxLayers: [.neonRain], fontDesign: .rounded, glow: 0.75
        ),
        Theme(
            id: "swamp", name: "Swamp Spirit", emoji: "🐈‍⬛",
            bg: [Color(hex: 0x061E1B), Color(hex: 0x0C3B33), Color(hex: 0x14544A)],
            ringA: Color(hex: 0x3EF0C5), ringB: Color(hex: 0xBDF5E4),
            accent: Color(hex: 0x2EE8B0),
            textPrimary: Color(hex: 0xE7FFF7), textSecondary: Color(hex: 0x8FCDBB),
            fxLayers: [.pond], fontDesign: .rounded, glow: 0.8
        ),
        Theme(
            id: "irithyll", name: "Boreal Valley", emoji: "❄️",
            bg: [Color(hex: 0x0C141D), Color(hex: 0x1B2C3B), Color(hex: 0x2E4658)],
            ringA: Color(hex: 0x9FD9E8), ringB: Color(hex: 0xE4F6FC),
            accent: Color(hex: 0x7FC4DC),
            textPrimary: Color(hex: 0xEDF7FB), textSecondary: Color(hex: 0x9BB8C6),
            fxLayers: [.snow], fontDesign: .serif, glow: 0.6
        ),
        Theme(
            id: "meadow", name: "Moonlit Meadow", emoji: "🌕",
            bg: [Color(hex: 0x0D1B20), Color(hex: 0x1B3238), Color(hex: 0x2E4B48)],
            ringA: Color(hex: 0xF2E8A8), ringB: Color(hex: 0xFFFBE0),
            accent: Color(hex: 0xD8CC7A),
            textPrimary: Color(hex: 0xFBFFEF), textSecondary: Color(hex: 0xAEC4A8),
            fxLayers: [.fireflies], fontDesign: .rounded, glow: 0.7
        ),
        Theme(
            id: "synthwave", name: "Neon Sunset", emoji: "🌆",
            bg: [Color(hex: 0x1C0A38), Color(hex: 0x481458), Color(hex: 0x8A1D5E)],
            ringA: Color(hex: 0xFF4ECD), ringB: Color(hex: 0xFFB65C),
            accent: Color(hex: 0xFF2EA8),
            textPrimary: Color(hex: 0xFFF0FA), textSecondary: Color(hex: 0xE393C8),
            fxLayers: [.stars], fontDesign: .monospaced, glow: 1.0
        ),
        Theme(
            id: "desert", name: "Mojave Night", emoji: "🏜️",
            bg: [Color(hex: 0x0D1830), Color(hex: 0x1B2C4E), Color(hex: 0x33476E)],
            ringA: Color(hex: 0x9FB4D8), ringB: Color(hex: 0xEDF2FC),
            accent: Color(hex: 0x7E96C8),
            textPrimary: Color(hex: 0xF0F4FD), textSecondary: Color(hex: 0x9AA9C8),
            fxLayers: [.dust, .stars], fontDesign: .default, glow: 0.45
        ),
        Theme(
            id: "autumn", name: "Autumn Shrine", emoji: "⛩️",
            bg: [Color(hex: 0x2A1210), Color(hex: 0x592214), Color(hex: 0x8E3A1C)],
            ringA: Color(hex: 0xFF8A4C), ringB: Color(hex: 0xFFD9A0),
            accent: Color(hex: 0xFF6B35),
            textPrimary: Color(hex: 0xFFF3E8), textSecondary: Color(hex: 0xDCA282),
            fxLayers: [.leaves], fontDesign: .serif, glow: 0.8
        ),
        Theme(
            id: "blackhole", name: "Event Horizon", emoji: "🕳️",
            bg: [Color(hex: 0x0A0605), Color(hex: 0x1C110A), Color(hex: 0x3A2312)],
            ringA: Color(hex: 0xFFB65C), ringB: Color(hex: 0xFFF0DC),
            accent: Color(hex: 0xFF9E3D),
            textPrimary: Color(hex: 0xFFF7EC), textSecondary: Color(hex: 0xC9A57E),
            fxLayers: [.gravity], fontDesign: .rounded, glow: 1.0
        ),
        Theme(
            id: "glass", name: "Glass", emoji: "🫧",
            bg: [Color(hex: 0x23252B), Color(hex: 0x2E3138), Color(hex: 0x3A3E47)],
            ringA: Color(hex: 0xFFFFFF), ringB: Color(hex: 0xB9C2CE),
            accent: Color(hex: 0xD6DEE8),
            textPrimary: Color(hex: 0xF5F7FA), textSecondary: Color(hex: 0xA9B2BD),
            fxLayers: [.dust], fontDesign: .rounded, glow: 0.35
        ),
        Theme(
            id: "pixelcity", name: "Pixel City", emoji: "🕹️",
            bg: [Color(hex: 0x1E2230), Color(hex: 0x2E3448), Color(hex: 0x424A66)],
            ringA: Color(hex: 0xFF7EB6), ringB: Color(hex: 0x6EE8D8),
            accent: Color(hex: 0xFF6FA8),
            textPrimary: Color(hex: 0xF2F4FC), textSecondary: Color(hex: 0xA6AEC8),
            fxLayers: [.pixel, .neonRain], fontDesign: .monospaced, glow: 0.7
        ),
        Theme(
            id: "campfire", name: "Campfire", emoji: "🔥",
            bg: [Color(hex: 0x1A0A04), Color(hex: 0x3D1608), Color(hex: 0x5E2812)],
            ringA: Color(hex: 0xFF6B2C), ringB: Color(hex: 0xFFD485),
            accent: Color(hex: 0xFF8C42),
            textPrimary: Color(hex: 0xFFF3E6), textSecondary: Color(hex: 0xD4A06A),
            fxLayers: [.embers], fontDesign: .rounded, glow: 0.85
        ),
        Theme(
            id: "citynight", name: "City Night", emoji: "🌃",
            bg: [Color(hex: 0x0A0E1A), Color(hex: 0x161D30), Color(hex: 0x242D48)],
            ringA: Color(hex: 0xFFD066), ringB: Color(hex: 0xFF8EC4),
            accent: Color(hex: 0xFFBE4D),
            textPrimary: Color(hex: 0xF8F4FF), textSecondary: Color(hex: 0xA0A8C4),
            fxLayers: [.bokeh], fontDesign: .default, glow: 0.65
        ),
        Theme(
            id: "crystal", name: "Crystal Cave", emoji: "💎",
            bg: [Color(hex: 0x0B0F1E), Color(hex: 0x1A2340), Color(hex: 0x2B3860)],
            ringA: Color(hex: 0xAFE4FF), ringB: Color(hex: 0xFFFFFF),
            accent: Color(hex: 0x8ED4F0),
            textPrimary: Color(hex: 0xF0F8FF), textSecondary: Color(hex: 0x8FAEC8),
            fxLayers: [.sparkle], fontDesign: .serif, glow: 0.75
        ),
        Theme(
            id: "carnival", name: "Carnival", emoji: "🎪",
            bg: [Color(hex: 0x1C0824), Color(hex: 0x3A1248), Color(hex: 0x5C2068)],
            ringA: Color(hex: 0xFF5EAE), ringB: Color(hex: 0x5EFFB4),
            accent: Color(hex: 0xFF4DA0),
            textPrimary: Color(hex: 0xFFF2FA), textSecondary: Color(hex: 0xD4A0C8),
            fxLayers: [.confetti], fontDesign: .rounded, glow: 0.9
        ),
        Theme(
            id: "misty", name: "Misty Peaks", emoji: "🏔️",
            bg: [Color(hex: 0x141820), Color(hex: 0x222830), Color(hex: 0x343A44)],
            ringA: Color(hex: 0xC8D4E0), ringB: Color(hex: 0xF0F4FA),
            accent: Color(hex: 0xA8B8CC),
            textPrimary: Color(hex: 0xF5F7FA), textSecondary: Color(hex: 0x8A96A8),
            fxLayers: [.smoke], fontDesign: .default, glow: 0.3
        ),
        Theme(
            id: "northernlights", name: "Northern Lights", emoji: "🌌",
            bg: [Color(hex: 0x040812), Color(hex: 0x0C1428), Color(hex: 0x182040)],
            ringA: Color(hex: 0x4AECC8), ringB: Color(hex: 0xB06EFF),
            accent: Color(hex: 0x40D8B0),
            textPrimary: Color(hex: 0xE8FFF8), textSecondary: Color(hex: 0x7ABCA8),
            fxLayers: [.aurora, .stars], fontDesign: .serif, glow: 0.85
        ),
        Theme(
            id: "lanternfest", name: "Lantern Festival", emoji: "🏮",
            bg: [Color(hex: 0x1A0808), Color(hex: 0x361414), Color(hex: 0x522020)],
            ringA: Color(hex: 0xFF9944), ringB: Color(hex: 0xFFE088),
            accent: Color(hex: 0xFF7722),
            textPrimary: Color(hex: 0xFFF8EE), textSecondary: Color(hex: 0xD4A878),
            fxLayers: [.lanterns], fontDesign: .rounded, glow: 0.8
        ),
        Theme(
            id: "downy", name: "Soft Clouds", emoji: "🪶",
            bg: [Color(hex: 0x1A1D28), Color(hex: 0x282D3C), Color(hex: 0x3A4054)],
            ringA: Color(hex: 0xE8D8F0), ringB: Color(hex: 0xFFF0F8),
            accent: Color(hex: 0xD4C0E0),
            textPrimary: Color(hex: 0xFCF8FF), textSecondary: Color(hex: 0xA8A0B8),
            fxLayers: [.feathers], fontDesign: .rounded, glow: 0.4
        ),
        Theme(
            id: "rainywindow", name: "Rainy Window", emoji: "🌧️",
            bg: [Color(hex: 0x101418), Color(hex: 0x1C2228), Color(hex: 0x2A3238)],
            ringA: Color(hex: 0x8EC8E8), ringB: Color(hex: 0xD0E8F8),
            accent: Color(hex: 0x6EB0D8),
            textPrimary: Color(hex: 0xF0F6FA), textSecondary: Color(hex: 0x88A0B0),
            fxLayers: [.ripples, .neonRain], fontDesign: .default, glow: 0.5
        ),
        Theme(
            id: "meteorshower", name: "Meteor Shower", emoji: "☄️",
            bg: [Color(hex: 0x06080E), Color(hex: 0x10141E), Color(hex: 0x1C2030)],
            ringA: Color(hex: 0xFFD488), ringB: Color(hex: 0xFFFFFF),
            accent: Color(hex: 0xFFCC66),
            textPrimary: Color(hex: 0xFFF8EE), textSecondary: Color(hex: 0x8890A8),
            fxLayers: [.comet, .stars], fontDesign: .monospaced, glow: 0.7
        ),
        Theme(
            id: "deepfog", name: "Deep Fog", emoji: "🌫️",
            bg: [Color(hex: 0x14161C), Color(hex: 0x1E2028), Color(hex: 0x2A2C34)],
            ringA: Color(hex: 0xB0B8C8), ringB: Color(hex: 0xE0E4EC),
            accent: Color(hex: 0x9CA4B8),
            textPrimary: Color(hex: 0xF0F2F6), textSecondary: Color(hex: 0x7A8090),
            fxLayers: [.fog], fontDesign: .serif, glow: 0.2
        ),
        Theme(
            id: "sacred", name: "Sacred Geometry", emoji: "🔮",
            bg: [Color(hex: 0x0E0A18), Color(hex: 0x1C1630), Color(hex: 0x2C2448)],
            ringA: Color(hex: 0xC890FF), ringB: Color(hex: 0x90D8FF),
            accent: Color(hex: 0xB478F0),
            textPrimary: Color(hex: 0xF4F0FF), textSecondary: Color(hex: 0x9888C0),
            fxLayers: [.geometric], fontDesign: .monospaced, glow: 0.6
        ),
        Theme(
            id: "thunderstorm", name: "Thunderstorm", emoji: "⛈️",
            bg: [Color(hex: 0x08090E), Color(hex: 0x14161E), Color(hex: 0x22242E)],
            ringA: Color(hex: 0xE8E0FF), ringB: Color(hex: 0xFFFFFF),
            accent: Color(hex: 0xC8B8FF),
            textPrimary: Color(hex: 0xF6F4FF), textSecondary: Color(hex: 0x8884A8),
            fxLayers: [.lightning, .neonRain], fontDesign: .default, glow: 0.9
        ),
        Theme(
            id: "ocean", name: "Deep Ocean", emoji: "🐋",
            bg: [Color(hex: 0x020810), Color(hex: 0x061828), Color(hex: 0x0A2840)],
            ringA: Color(hex: 0x40C8FF), ringB: Color(hex: 0x00E8B0),
            accent: Color(hex: 0x30B8F0),
            textPrimary: Color(hex: 0xE8F8FF), textSecondary: Color(hex: 0x5898B8),
            fxLayers: [.bubbles, .dust], fontDesign: .rounded, glow: 0.6
        ),
    ]

    static var custom: [Theme] = []
    static var allIncludingCustom: [Theme] { all + custom }

    static func theme(_ id: String) -> Theme {
        allIncludingCustom.first { $0.id == id } ?? all[0]
    }
}
