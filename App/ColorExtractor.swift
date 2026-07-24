import AppKit
import CoreImage
import SwiftUI

enum ColorExtractor {
    struct ColorProfile {
        /// The largest cluster — what most of the frame is actually made of.
        let dominant: NSColor
        /// The colour the scene *reads* as: the cluster carrying the most
        /// chroma across the most area. This is the theme's identity, and it is
        /// usually neither the biggest nor the brightest region.
        let identity: NSColor
        let secondary: NSColor
        let tertiary: NSColor
        /// Population-weighted means over every sample, not one cluster's.
        let brightness: Double
        let saturation: Double
        let temperature: Double   // -1 cool … 1 warm
    }

    static func analyze(_ image: NSImage) -> ColorProfile? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return analyze(frames: [cg])
    }

    /// Samples several frames spread through the clip. One frame is a poor
    /// stand-in for a whole video — a fade, a dark shot, or a single bright
    /// flash would otherwise define the entire palette.
    static func analyzeVideo(at url: URL) -> ColorProfile? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }

        let frames = [0.15, 0.35, 0.55, 0.75].compactMap { fraction -> CGImage? in
            let t = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            return try? gen.copyCGImage(at: t, actualTime: nil)
        }
        guard !frames.isEmpty else { return nil }
        return analyze(frames: frames)
    }

    private static func analyze(frames: [CGImage]) -> ColorProfile {
        // 12×16 over four frames. A coarser grid averages small but defining
        // regions into their surroundings; a finer one costs time without
        // moving the result, measured against the hand-tuned themes.
        let samples = frames.flatMap { sampleGrid($0, rows: 12, cols: 16) }
        guard !samples.isEmpty else {
            return ColorProfile(dominant: .gray, identity: .gray, secondary: .gray,
                                tertiary: .gray, brightness: 0.5, saturation: 0,
                                temperature: 0)
        }

        let clusters = clusterColors(samples, k: 6)

        // Ranked by luminance for the secondary/tertiary tints, but note that
        // none of the three headline colours below come from this ordering.
        let byLuminance = clusters
            .map(\.color)
            .sorted { luminance($0) > luminance($1) }

        let dominant = clusters.max { $0.count < $1.count }?.color ?? byLuminance[0]
        let identity = identityColor(clusters)

        // Scene-wide averages. Taking these from one cluster would report a
        // specular highlight as the brightness of the whole scene.
        var totalB = 0.0, totalS = 0.0
        for c in samples {
            let v = hsb(c)
            totalB += Double(v.b)
            totalS += Double(v.s)
        }
        let brightness = totalB / Double(samples.count)
        let saturation = totalS / Double(samples.count)

        let id = hsb(identity)
        return ColorProfile(
            dominant: dominant,
            identity: identity,
            secondary: byLuminance.count > 1 ? byLuminance[1] : dominant,
            tertiary: byLuminance.count > 2 ? byLuminance[2] : dominant,
            brightness: brightness,
            saturation: saturation,
            temperature: colorTemperature(hue: id.h, saturation: id.s)
        )
    }

    /// Picks the cluster that gives the scene its character. Chroma alone would
    /// latch onto a vivid speck and coverage alone onto a grey wall, so both are
    /// weighted — `sqrt` on the count keeps a large drab region from dominating
    /// while still discounting a few stray pixels. Brightness gets a small say
    /// because a colour has to be visible to define the mood.
    private static func identityColor(_ clusters: [(color: NSColor, count: Int)]) -> NSColor {
        guard let best = clusters.max(by: { a, b in score(a) < score(b) }) else { return .gray }
        return best.color
    }

    private static func score(_ entry: (color: NSColor, count: Int)) -> Double {
        let v = hsb(entry.color)
        return Double(v.s) * sqrt(Double(entry.count)) * (0.4 + Double(v.b))
    }

    private static func hsb(_ color: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        guard let c = color.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (h, s, b)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.deviceRGB) else { return 0 }
        return c.redComponent + c.greenComponent + c.blueComponent
    }

    /// Redraws the frame into a context whose pixel layout we control, then
    /// reads every cell. Poking the source image's bytes directly is not safe:
    /// AVAssetImageGenerator hands back little-endian BGRA, so a fixed R,G,B
    /// byte order silently swaps red and blue. Scaling to exactly rows×cols
    /// also makes each sample an area average rather than one noisy pixel.
    private static func sampleGrid(_ cg: CGImage, rows: Int, cols: Int) -> [NSColor] {
        guard cg.width > 0, cg.height > 0, rows > 0, cols > 0 else { return [] }

        let bytesPerRow = cols * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * rows)

        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: cols, height: rows,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            return true
        }
        guard ok else { return [] }

        var colors: [NSColor] = []
        colors.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let o = r * bytesPerRow + c * 4
                let a = CGFloat(buffer[o + 3]) / 255
                guard a > 0.01 else { continue }
                // Undo premultiplication so dark-but-saturated pixels keep hue.
                colors.append(NSColor(
                    red: min(1, CGFloat(buffer[o]) / 255 / a),
                    green: min(1, CGFloat(buffer[o + 1]) / 255 / a),
                    blue: min(1, CGFloat(buffer[o + 2]) / 255 / a),
                    alpha: 1
                ))
            }
        }
        return colors
    }

    /// k-means over the samples. Returns each centre with its population — the
    /// caller needs the counts to tell a large region from an incidental one.
    private static func clusterColors(_ colors: [NSColor], k: Int)
        -> [(color: NSColor, count: Int)] {
        struct RGB { var r: CGFloat; var g: CGFloat; var b: CGFloat }
        let rgbs: [RGB] = colors.compactMap { c in
            guard let c = c.usingColorSpace(.deviceRGB) else { return nil }
            return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }
        guard !rgbs.isEmpty else { return [(.gray, 1)] }

        let n = min(k, rgbs.count)
        var centers = (0..<n).map { rgbs[$0 * rgbs.count / max(1, n)] }
        var buckets = Array(repeating: [RGB](), count: centers.count)

        for _ in 0..<12 {
            buckets = Array(repeating: [RGB](), count: centers.count)
            for c in rgbs {
                var best = 0
                var bestD = Double.infinity
                for (i, center) in centers.enumerated() {
                    let d = pow(c.r - center.r, 2) + pow(c.g - center.g, 2) + pow(c.b - center.b, 2)
                    if Double(d) < bestD { bestD = Double(d); best = i }
                }
                buckets[best].append(c)
            }
            for i in centers.indices where !buckets[i].isEmpty {
                let count = CGFloat(buckets[i].count)
                centers[i] = RGB(
                    r: buckets[i].reduce(0) { $0 + $1.r } / count,
                    g: buckets[i].reduce(0) { $0 + $1.g } / count,
                    b: buckets[i].reduce(0) { $0 + $1.b } / count
                )
            }
        }

        return centers.indices.map {
            (NSColor(red: centers[$0].r, green: centers[$0].g, blue: centers[$0].b, alpha: 1),
             buckets[$0].count)
        }
    }

    private static func colorTemperature(hue: CGFloat, saturation: CGFloat) -> Double {
        guard saturation > 0.08 else { return 0 }
        // warm: reds/oranges/yellows (hue 0-0.17, 0.9-1.0)
        // cool: blues/cyans (hue 0.5-0.72)
        if hue < 0.17 || hue > 0.9 { return Double(saturation) * 0.9 }
        if hue < 0.22 { return Double(saturation) * 0.6 }   // yellow-warm
        if hue > 0.45 && hue < 0.75 { return -Double(saturation) * 0.8 }  // cool
        return 0
    }

    static func nearestAccent(_ color: NSColor) -> (id: Int, highlight: String) {
        guard let c = color.usingColorSpace(.deviceRGB) else { return (4, "0.698039 0.843137 1.000000 Blue") }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        if s < 0.08 { return (-1, "0.847059 0.847059 0.862745 Graphite") }
        let accents: [(id: Int, hueRange: ClosedRange<CGFloat>, highlight: String)] = [
            (0, 0.95...1.0,  "1.000000 0.749020 0.823529 Pink"),     // red (wraps)
            (0, 0.0...0.04,  "1.000000 0.749020 0.823529 Pink"),     // red
            (1, 0.04...0.12, "1.000000 0.874510 0.701961 Orange"),
            (2, 0.12...0.2,  "1.000000 0.937255 0.690196 Yellow"),
            (3, 0.2...0.42,  "0.752941 0.964706 0.678431 Green"),
            (4, 0.42...0.72, "0.698039 0.843137 1.000000 Blue"),
            (5, 0.72...0.82, "0.968627 0.831373 1.000000 Purple"),
            (6, 0.82...0.95, "1.000000 0.749020 0.823529 Pink"),
        ]
        for a in accents where a.hueRange.contains(h) { return (a.id, a.highlight) }
        return (4, "0.698039 0.843137 1.000000 Blue")
    }
}

import AVFoundation

enum ParticleSelector {
    /// Maps the scene's identity hue and mood onto an effect. Colour can only
    /// carry so much: a snowy valley and a rainy street both read as dim blue,
    /// and nothing in a histogram distinguishes a black hole from a campfire at
    /// night. This aims for a defensible match, and the theme editor exists so
    /// the user can override it in one click.
    static func suggest(for profile: ColorExtractor.ColorProfile) -> [ParticleStyle] {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        (profile.identity.usingColorSpace(.deviceRGB) ?? .gray)
            .getHue(&h, saturation: &s, brightness: &b, alpha: nil)

        let dark = profile.brightness < 0.30
        let vivid = profile.saturation > 0.55

        switch h {
        case ..<0.03, 0.97...:                       // red
            return dark ? [.embers] : [.leaves]
        case 0.03..<0.12:                            // orange
            if dark { return vivid ? [.embers] : [.lanterns] }
            return [.leaves]
        case 0.12..<0.19:                            // amber / gold
            return dark ? [.lanterns] : [.dust]
        case 0.19..<0.30:                            // yellow-green
            return dark ? [.fireflies] : [.petals]
        case 0.30..<0.44:                            // green
            return dark ? [.fireflies] : [.pond]
        case 0.44..<0.53:                            // teal
            return vivid ? [.pond] : [.fog]
        case 0.53..<0.60:                            // cyan-blue
            return s < 0.45 ? [.snow] : [.ripples]
        case 0.60..<0.70:                            // blue
            if vivid && dark { return [.neonRain] }
            return dark ? [.dust, .stars] : [.dust]
        case 0.70..<0.80:                            // indigo / violet
            return [.stars]
        case 0.80..<0.87:                            // purple
            return vivid ? [.aurora] : [.smoke]
        default:                                     // magenta / pink
            // Electric magenta is a neon-lit scene; soft pink is blossom.
            // Same hue band, opposite moods, so saturation decides.
            return vivid ? [.stars] : [.petals]
        }
    }
}

enum ThemeGenerator {
    static func generate(from profile: ColorExtractor.ColorProfile, id: String, name: String) -> Theme {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        (profile.identity.usingColorSpace(.deviceRGB) ?? .gray)
            .getHue(&h, saturation: &s, brightness: &b, alpha: nil)

        // A near-grey identity has no trustworthy hue, so stay muted rather than
        // inventing a colour the footage never had.
        let grey = s < 0.08
        // Saturation measured on a dark colour overstates how colourful it
        // looks — a near-black navy reads as 0.7 saturated but the eye sees
        // muted. Scaling by the sample's own brightness corrects for that.
        let corrected = s * (0.40 + 0.60 * b) + 0.16
        let ringS = grey ? 0.14 : min(0.80, max(0.22, corrected))

        // The ring reads as one light source: same hue throughout, the outer
        // stop simply a paler tint. Taking the second stop from an unrelated
        // cluster is what made the gradient look like two clashing colours.
        let ringA = NSColor(hue: h, saturation: ringS, brightness: 0.97, alpha: 1)
        let ringB = NSColor(hue: h, saturation: ringS * 0.32, brightness: 1.0, alpha: 1)
        // The accent is the ring pushed slightly deeper so it stays legible
        // against it. The step is small on purpose — overshooting turns a
        // slate-blue theme's accent into a lurid royal blue.
        let accent = NSColor(hue: h, saturation: min(0.80, ringS * 1.15),
                             brightness: 0.94, alpha: 1)

        // Backgrounds are three steps up the same hue. Darkening a sampled
        // colour instead would inherit whatever grey the footage averaged to.
        let bgS = grey ? 0.10 : min(0.72, max(0.30, s * 0.9))
        let bg = [0.16, 0.30, 0.45].map {
            Color(nsColor: NSColor(hue: h, saturation: bgS, brightness: $0, alpha: 1))
        }

        let isLight = profile.brightness > 0.6
        let textPrimary: Color = isLight
            ? Color(nsColor: NSColor(hue: h, saturation: bgS, brightness: 0.12, alpha: 1))
            : .white
        let textSecondary: Color = isLight
            ? Color(nsColor: NSColor(hue: h, saturation: bgS * 0.8, brightness: 0.32, alpha: 1))
            : Color(nsColor: NSColor(hue: h, saturation: ringS * 0.45, brightness: 0.82, alpha: 1))

        let particles = ParticleSelector.suggest(for: profile)
        let glow = min(1, max(0.3, profile.saturation * 1.4))

        let font: Font.Design = profile.temperature > 0.3 ? .rounded
            : profile.temperature < -0.3 ? .serif : .default

        return Theme(
            id: id, name: name, emoji: emojiFor(profile),
            bg: bg,
            ringA: Color(nsColor: ringA), ringB: Color(nsColor: ringB),
            accent: Color(nsColor: accent),
            textPrimary: textPrimary, textSecondary: textSecondary,
            fxLayers: particles, fontDesign: font, glow: glow
        )
    }

    private static func emojiFor(_ profile: ColorExtractor.ColorProfile) -> String {
        let t = profile.temperature
        let b = profile.brightness
        if t > 0.5 && b < 0.3 { return "🔥" }
        if t > 0.3 { return "🌅" }
        if t < -0.4 && b < 0.4 { return "❄️" }
        if t < -0.2 { return "🌊" }
        if b > 0.7 { return "☀️" }
        if b < 0.2 { return "🌑" }
        return "🎨"
    }
}
