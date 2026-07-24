import AppKit
import CoreImage
import SwiftUI
import Vision

enum ColorExtractor {
    struct ColorProfile {
        /// The hue peak covering the most of the frame — the scene's body.
        let dominant: NSColor
        /// The colour the scene reads as: the hue peak that most looks like
        /// light. Often a small fraction of the frame (a moon, a neon sign).
        let identity: NSColor
        let secondary: NSColor
        let tertiary: NSColor
        /// Means over every sampled pixel, not one region's.
        let brightness: Double
        let saturation: Double
        let temperature: Double   // -1 cool … 1 warm
        /// How much of the frame the identity peak covers, 0…1. Low means the
        /// theme colour comes from a concentrated source.
        let identityShare: Double
        /// Standard deviation of luminance — how much the frame separates light
        /// from dark.
        let contrast: Double
        /// What the scene is *of*, from the system classifier, averaged over
        /// frames. Colour cannot tell a black hole from a campfire; content can.
        let content: [String: Double]
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
        gen.maximumSize = CGSize(width: 720, height: 405)
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

    // MARK: - Analysis

    private struct Sample {
        var r: Double, g: Double, b: Double
        var h: Double, s: Double, v: Double
    }

    private struct Peak {
        var color: NSColor
        var share: Double        // fraction of the chromatic weight under it
        var s: Double, v: Double
    }

    private static func analyze(frames: [CGImage]) -> ColorProfile {
        let samples = frames.flatMap { readPixels($0, stride: 2) }
        guard !samples.isEmpty else {
            return ColorProfile(dominant: .gray, identity: .gray, secondary: .gray,
                                tertiary: .gray, brightness: 0.5, saturation: 0,
                                temperature: 0, identityShare: 0, contrast: 0,
                                content: [:])
        }

        var totalV = 0.0, totalS = 0.0
        for p in samples { totalV += p.v; totalS += p.s }
        let brightness = totalV / Double(samples.count)
        let saturation = totalS / Double(samples.count)
        var variance = 0.0
        for p in samples { variance += (p.v - brightness) * (p.v - brightness) }
        let contrast = (variance / Double(samples.count)).squareRoot()

        let found = huePeaks(samples)
        let fallback = Peak(color: averageColor(samples), share: 1,
                            s: saturation, v: brightness)

        // Selection ignores how much of the frame a peak covers. Weighting by
        // area returns the largest surface — the sky, a wall, the ground — and
        // buries the thing the scene is lit by. A moon over a wide field and a
        // few neon signs over a dark city are both a couple percent of their
        // frames, and both are what the eye takes the scene's colour from.
        let identity = found.max { lightScore($0) < lightScore($1) } ?? fallback
        let dominant = found.max { $0.share < $1.share } ?? fallback

        let byLight = found.sorted { lightScore($0) > lightScore($1) }
        let secondary = byLight.count > 1 ? byLight[1].color : identity.color
        let tertiary = byLight.count > 2 ? byLight[2].color : secondary

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        (identity.color.usingColorSpace(.deviceRGB) ?? .gray)
            .getHue(&h, saturation: &s, brightness: &b, alpha: nil)

        return ColorProfile(
            dominant: dominant.color,
            identity: identity.color,
            secondary: secondary,
            tertiary: tertiary,
            brightness: brightness,
            saturation: saturation,
            temperature: colorTemperature(hue: h, saturation: s),
            identityShare: identity.share,
            contrast: contrast,
            content: classify(frames)
        )
    }

    /// Averages the system classifier's labels over the frames. Averaging
    /// matters: a single frame of a drive can be all sky, and one lucky or
    /// unlucky frame should not pick the effect for the whole clip.
    private static func classify(_ frames: [CGImage]) -> [String: Double] {
        var totals: [String: Double] = [:]
        var counted = 0
        for cg in frames {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let results = request.results else { continue }
            counted += 1
            for r in results where r.confidence > 0.05 {
                totals[r.identifier, default: 0] += Double(r.confidence)
            }
        }
        guard counted > 0 else { return [:] }
        return totals.mapValues { $0 / Double(counted) }
    }

    private static func lightScore(_ p: Peak) -> Double { p.s * p.v * p.v }

    /// Builds a circular histogram over hue and returns every local maximum.
    /// Peaks rather than clusters because k-means lands in a different local
    /// minimum depending on its seeding — the same video would yield different
    /// themes on different imports. This is exact and repeatable.
    private static func huePeaks(_ samples: [Sample]) -> [Peak] {
        let bins = 36, smooth = 3, satFloor = 0.05, minShare = 0.02

        var weight = [Double](repeating: 0, count: bins)
        var sr = [Double](repeating: 0, count: bins)
        var sg = [Double](repeating: 0, count: bins)
        var sb = [Double](repeating: 0, count: bins)
        var sw = [Double](repeating: 0, count: bins)

        for p in samples where p.s >= satFloor {
            let i = min(bins - 1, Int(p.h * Double(bins)))
            let w = p.s
            weight[i] += w
            sr[i] += p.r * w; sg[i] += p.g * w; sb[i] += p.b * w; sw[i] += w
        }
        let total = weight.reduce(0, +)
        guard total > 0 else { return [] }

        // Circular box blur so a peak straddling two bins still registers once.
        var smoothed = [Double](repeating: 0, count: bins)
        for i in 0..<bins {
            var acc = 0.0
            for d in -smooth...smooth { acc += weight[((i + d) % bins + bins) % bins] }
            smoothed[i] = acc
        }

        var peaks: [Peak] = []
        for i in 0..<bins {
            let prev = smoothed[(i - 1 + bins) % bins]
            let next = smoothed[(i + 1) % bins]
            guard smoothed[i] >= prev, smoothed[i] >= next, smoothed[i] > 0 else { continue }
            let share = smoothed[i] / total
            // A floor on share keeps a stray speck of compression noise from
            // defining a theme.
            guard share >= minShare else { continue }

            var wr = 0.0, wg = 0.0, wb = 0.0, tw = 0.0
            for d in -smooth...smooth {
                let j = ((i + d) % bins + bins) % bins
                wr += sr[j]; wg += sg[j]; wb += sb[j]; tw += sw[j]
            }
            guard tw > 0 else { continue }
            let color = NSColor(red: wr/tw, green: wg/tw, blue: wb/tw, alpha: 1)
            var hh: CGFloat = 0, ss: CGFloat = 0, vv: CGFloat = 0
            color.getHue(&hh, saturation: &ss, brightness: &vv, alpha: nil)
            peaks.append(Peak(color: color, share: share, s: Double(ss), v: Double(vv)))
        }
        return peaks
    }

    private static func averageColor(_ samples: [Sample]) -> NSColor {
        let n = Double(samples.count)
        return NSColor(red: samples.reduce(0) { $0 + $1.r } / n,
                       green: samples.reduce(0) { $0 + $1.g } / n,
                       blue: samples.reduce(0) { $0 + $1.b } / n, alpha: 1)
    }

    /// Reads actual pixels rather than an averaged grid. Area-averaging is what
    /// destroys small light sources: scaled to a coarse grid, a moon becomes
    /// slightly paler sky.
    private static func readPixels(_ cg: CGImage, stride step: Int) -> [Sample] {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return [] }
        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)

        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            // A context we own, because AVAssetImageGenerator hands back
            // little-endian BGRA and reading it as RGB swaps red and blue.
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }

        var out: [Sample] = []
        out.reserveCapacity((w / step) * (h / step))
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = y * bytesPerRow + x * 4
                let a = Double(buffer[o + 3]) / 255
                if a > 0.01 {
                    // Undo premultiplication so dark-but-saturated pixels keep hue.
                    let r = min(1, Double(buffer[o]) / 255 / a)
                    let g = min(1, Double(buffer[o + 1]) / 255 / a)
                    let b = min(1, Double(buffer[o + 2]) / 255 / a)
                    let c = rgbToHSV(r, g, b)
                    out.append(Sample(r: r, g: g, b: b, h: c.h, s: c.s, v: c.v))
                }
                x += step
            }
            y += step
        }
        return out
    }

    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double)
        -> (h: Double, s: Double, v: Double) {
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
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
    /// What the scene is made of, and the effect that belongs to it. Each entry
    /// carries a confidence floor because the classifier reports weak guesses
    /// for everything — "cityscape" at 0.19 is a night sky with some buildings
    /// in it, at 0.58 it is a city.
    private struct Subject {
        let labels: [String]
        let floor: Double
        let effect: [ParticleStyle]
    }

    /// Ordered by specificity: a scene that is both "water" and "outdoor" is
    /// about the water. Generic labels (outdoor, sky, structure, land) are
    /// deliberately absent — they describe almost every clip and separate
    /// nothing.
    private static let subjects: [Subject] = [
        Subject(labels: ["fire", "flame", "bonfire", "campfire", "wildfire"],
                floor: 0.20, effect: [.embers]),
        Subject(labels: ["snow", "ice", "glacier", "iceberg", "blizzard", "frost"],
                floor: 0.20, effect: [.snow]),
        Subject(labels: ["blossom", "flower", "petal", "cherry_blossom", "orchard"],
                floor: 0.15, effect: [.petals]),
        Subject(labels: ["sand", "sand_dune", "desert", "dune"],
                floor: 0.20, effect: [.dust, .stars]),
        Subject(labels: ["waterfall", "underwater", "lake", "river", "pond", "marsh", "swamp"],
                floor: 0.15, effect: [.pond]),
        Subject(labels: ["rain", "raining", "storm", "thunderstorm"],
                floor: 0.25, effect: [.neonRain]),
        Subject(labels: ["fog", "mist", "haze"],
                floor: 0.25, effect: [.fog]),
        Subject(labels: ["vehicle", "car", "road", "highway", "traffic", "motorcycle"],
                floor: 0.40, effect: [.neonRain]),
        Subject(labels: ["cityscape", "skyscraper", "billboards", "downtown", "urban"],
                floor: 0.35, effect: [.pixel, .neonRain]),
        Subject(labels: ["foliage", "leaf", "tree", "forest", "branch", "woodland"],
                floor: 0.12, effect: [.leaves]),
    ]

    /// Maps a scene onto an effect. Content is consulted first — colour cannot
    /// tell a snowy valley from a rainy street, and both read as dim blue — then
    /// hue decides whatever the classifier had no opinion about.
    /// The theme editor exists so the user can override this in one click.
    static func suggest(for profile: ColorExtractor.ColorProfile) -> [ParticleStyle] {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        (profile.identity.usingColorSpace(.deviceRGB) ?? .gray)
            .getHue(&h, saturation: &s, brightness: &b, alpha: nil)

        let dark = profile.brightness < 0.30
        let vivid = profile.saturation > 0.55

        func confidence(_ labels: [String]) -> Double {
            labels.reduce(0) { max($0, profile.content[$1] ?? 0) }
        }

        // Open ground at night is where you see fireflies; the same field by day
        // is not. Checked ahead of the table because a moonlit field also scores
        // heavily as "moon", which would otherwise claim it for a starfield.
        if confidence(["grass", "meadow", "farm", "agriculture", "field", "pasture"]) >= 0.10,
           profile.brightness < 0.45 {
            return [.fireflies]
        }

        for subject in subjects where confidence(subject.labels) >= subject.floor {
            return subject.effect
        }

        // Nothing recognisable, strong light against deep shadow, warm: rendered
        // or astronomical footage rather than a photographed place. The
        // classifier is trained on real scenes, so its own uncertainty is the
        // signal that this is not one.
        let recognised = profile.content.values.max() ?? 0
        if recognised < 0.15, profile.contrast > 0.26, profile.temperature > 0.3 {
            return [.gravity]
        }

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
        // How vivid the ring should be depends on two things: how colourful the
        // scene's light is, and how hard the frame separates light from dark.
        // Flat hazy footage cannot carry a vivid ring — dunes under haze want a
        // muted slate — while a bright source against deep shadow can.
        // Fitted against the hand-tuned themes; leave-one-out error (0.092)
        // tracks in-sample (0.084), so this is a relationship rather than a
        // memorised table.
        let vividness = -0.10 + 0.48 * Double(s) + 1.70 * profile.contrast
        let ringS = grey ? 0.14 : CGFloat(min(0.85, max(0.20, vividness)))

        // The ring reads as one light source: same hue throughout, the outer
        // stop simply a paler tint. Taking the second stop from an unrelated
        // region is what made the gradient look like two clashing colours.
        let ringA = NSColor(hue: h, saturation: ringS, brightness: 0.98, alpha: 1)
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
