import AppKit
import CoreImage
import SwiftUI

enum ColorExtractor {
    struct ColorProfile {
        let dominant: NSColor
        let secondary: NSColor
        let tertiary: NSColor
        let brightness: Double
        let saturation: Double
        let temperature: Double   // -1 cool … 1 warm
    }

    static func analyze(_ image: NSImage) -> ColorProfile? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return analyze(cg)
    }

    static func analyzeVideo(at url: URL) -> ColorProfile? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        let time = CMTime(seconds: min(asset.duration.seconds * 0.4, 5), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        return analyze(cg)
    }

    private static func analyze(_ cg: CGImage) -> ColorProfile {
        let colors = sampleGrid(cg, rows: 5, cols: 7)
        let sorted = clusterColors(colors, k: 3)
        let dominant = sorted[0]
        let secondary = sorted.count > 1 ? sorted[1] : dominant
        let tertiary = sorted.count > 2 ? sorted[2] : secondary

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        dominant.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        let temp = colorTemperature(hue: h, saturation: s)

        return ColorProfile(
            dominant: dominant, secondary: secondary, tertiary: tertiary,
            brightness: Double(b), saturation: Double(s), temperature: temp
        )
    }

    /// Redraws the frame into a context whose pixel layout we control, then
    /// reads every cell. Poking the source image's bytes directly is not safe:
    /// AVAssetImageGenerator hands back little-endian BGRA, so a fixed R,G,B
    /// byte order silently swaps red and blue. Scaling to exactly rows×cols
    /// also makes each sample an area average rather than one noisy pixel.
    private static func sampleGrid(_ cg: CGImage, rows: Int, cols: Int) -> [NSColor] {
        guard cg.width > 0, cg.height > 0, rows > 0, cols > 0 else { return [.gray] }

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
        guard ok else { return [.gray] }

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
        return colors.isEmpty ? [.gray] : colors
    }

    private static func clusterColors(_ colors: [NSColor], k: Int) -> [NSColor] {
        struct RGB { var r: CGFloat; var g: CGFloat; var b: CGFloat }
        let rgbs: [RGB] = colors.compactMap { c in
            guard let c = c.usingColorSpace(.deviceRGB) else { return nil }
            return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }
        guard !rgbs.isEmpty else { return [.gray] }

        var centers = (0..<min(k, rgbs.count)).map { rgbs[$0 * rgbs.count / max(1, min(k, rgbs.count))] }
        for _ in 0..<8 {
            var buckets = Array(repeating: [RGB](), count: centers.count)
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
                let n = CGFloat(buckets[i].count)
                centers[i] = RGB(
                    r: buckets[i].reduce(0) { $0 + $1.r } / n,
                    g: buckets[i].reduce(0) { $0 + $1.g } / n,
                    b: buckets[i].reduce(0) { $0 + $1.b } / n
                )
            }
        }
        return centers
            .sorted { ($0.r + $0.g + $0.b) > ($1.r + $1.g + $1.b) }
            .map { NSColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
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
    static func suggest(for profile: ColorExtractor.ColorProfile) -> [ParticleStyle] {
        let t = profile.temperature
        let b = profile.brightness
        let s = profile.saturation

        if b < 0.25 {
            if t > 0.3 { return [.embers] }
            if t < -0.3 { return [.stars] }
            return [.gravity]
        }
        if b < 0.4 {
            if t > 0.4 { return [.fireflies] }
            if t < -0.3 { return [.snow] }
            if s > 0.5 { return [.aurora] }
            return [.dust]
        }
        if b < 0.65 {
            if t > 0.5 { return [.petals] }
            if t > 0.2 { return [.lanterns] }
            if t < -0.4 { return [.neonRain] }
            if t < -0.1 { return [.fog] }
            if s > 0.6 { return [.bokeh] }
            return [.smoke]
        }
        // bright
        if t > 0.4 { return [.confetti] }
        if t > 0.1 { return [.feathers] }
        if t < -0.3 { return [.sparkle] }
        if s > 0.4 { return [.ripples] }
        return [.dust]
    }
}

enum ThemeGenerator {
    static func generate(from profile: ColorExtractor.ColorProfile, id: String, name: String) -> Theme {
        let dom = profile.dominant
        let sec = profile.secondary
        let ter = profile.tertiary

        let bgDark = darken(dom, by: 0.7)
        let bgMid = darken(dom, by: 0.5)
        let bgLight = darken(dom, by: 0.3)

        // Ring and accent carry the theme's color. They sit on a dark backdrop
        // and glow, so they're taken to near-full brightness with moderate
        // saturation — the pastel end, matching how the hand-tuned themes read.
        // Blending toward white instead would wash the hue out to grey.
        let ringA = vivid(sec, saturation: 0.46, brightness: 0.98)
        let ringB = vivid(ter, saturation: 0.24, brightness: 1.0)
        let accent = vivid(sec, saturation: 0.58, brightness: 0.94)

        let isLight = profile.brightness > 0.6
        let textPrimary: Color = isLight ? Color(nsColor: darken(dom, by: 0.8)) : .white
        let textSecondary: Color = isLight
            ? Color(nsColor: darken(dom, by: 0.5)).opacity(0.8)
            : Color(nsColor: brighten(dom, by: 0.4)).opacity(0.7)

        let particles = ParticleSelector.suggest(for: profile)
        let glow = min(1, profile.saturation * 1.5)

        let font: Font.Design = profile.temperature > 0.3 ? .rounded
            : profile.temperature < -0.3 ? .serif : .default

        return Theme(
            id: id, name: name, emoji: emojiFor(profile),
            bg: [Color(nsColor: bgDark), Color(nsColor: bgMid), Color(nsColor: bgLight)],
            ringA: Color(nsColor: ringA), ringB: Color(nsColor: ringB),
            accent: Color(nsColor: accent),
            textPrimary: textPrimary, textSecondary: textSecondary,
            fxLayers: particles, fontDesign: font, glow: glow
        )
    }

    private static func darken(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        return NSColor(
            red: c.redComponent * (1 - amount),
            green: c.greenComponent * (1 - amount),
            blue: c.blueComponent * (1 - amount),
            alpha: 1
        )
    }

    /// Restates a sampled color at a target saturation and brightness, keeping
    /// only its hue. Footage averages toward dark and grey, so the sampled
    /// levels themselves aren't worth preserving — the hue is the signal.
    private static func vivid(_ color: NSColor,
                              saturation: CGFloat,
                              brightness: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // A near-grey sample has an unreliable hue, so stay muted rather than
        // inventing a vivid color the footage never had.
        let target = s < 0.08 ? saturation * 0.4 : saturation
        return NSColor(hue: h,
                       saturation: min(1, target),
                       brightness: min(1, brightness),
                       alpha: 1)
    }

    private static func brighten(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        return NSColor(
            red: min(1, c.redComponent + (1 - c.redComponent) * amount),
            green: min(1, c.greenComponent + (1 - c.greenComponent) * amount),
            blue: min(1, c.blueComponent + (1 - c.blueComponent) * amount),
            alpha: 1
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
