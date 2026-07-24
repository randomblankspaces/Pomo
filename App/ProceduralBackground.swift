import SwiftUI

/// Rich themed scenes rendered from SwiftUI shapes — replaces flat gradients
/// for themes that ship without a video. Each scene composes reusable
/// primitives (skylines, moons, mountains, aurora ribbons, prisms, fog banks)
/// with theme-specific colors so nothing feels templated.
struct ProceduralBackground: View {
    let theme: Theme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                LinearGradient(colors: theme.bg, startPoint: .top, endPoint: .bottom)
                sceneLayer(for: theme.id, in: size)
                LinearGradient(
                    colors: [.black.opacity(0.12), .clear, .black.opacity(0.28)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .drawingGroup(opaque: true)
    }

    @ViewBuilder
    private func sceneLayer(for id: String, in size: CGSize) -> some View {
        switch id {
        case "campfire":     CampfireScene(theme: theme, size: size)
        case "citynight":    CityNightScene(theme: theme, size: size)
        case "crystal":      CrystalCaveScene(theme: theme, size: size)
        case "carnival":     CarnivalScene(theme: theme, size: size)
        case "misty":        MistyPeaksScene(theme: theme, size: size)
        case "northernlights": AuroraScene(theme: theme, size: size)
        case "lanternfest":  LanternFestScene(theme: theme, size: size)
        case "downy":        SoftCloudsScene(theme: theme, size: size)
        case "rainywindow":  RainyWindowScene(theme: theme, size: size)
        case "meteorshower": MeteorShowerScene(theme: theme, size: size)
        case "deepfog":      DeepFogScene(theme: theme, size: size)
        case "sacred":       SacredGeometryScene(theme: theme, size: size)
        case "thunderstorm": ThunderstormScene(theme: theme, size: size)
        case "ocean":        DeepOceanScene(theme: theme, size: size)
        default:             DefaultDuskScene(theme: theme, size: size)
        }
    }
}

// MARK: - Deterministic pseudo-random (no per-frame churn)

private struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 32) & 0xFFFFFF) / Double(0xFFFFFF)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
}

// MARK: - Shared primitives

/// Bright disc with soft glow halo — a moon or fire source.
private struct MoonDisc: View {
    var color: Color
    var glow: Color
    var radius: CGFloat
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [glow.opacity(0.55), glow.opacity(0.28), glow.opacity(0.08), .clear],
                    center: .center, startRadius: radius * 0.4, endRadius: radius * 3.2))
                .frame(width: radius * 6, height: radius * 6)
            Circle()
                .fill(RadialGradient(
                    colors: [color, color.opacity(0.94), color.opacity(0.7)],
                    center: UnitPoint(x: 0.42, y: 0.42),
                    startRadius: 1, endRadius: radius))
                .frame(width: radius * 2, height: radius * 2)
        }
    }
}

/// Scatter of tiny stars using seeded random so they're stable across frames.
private struct StarField: View {
    var seed: UInt64
    var count: Int
    var color: Color
    var maxSize: CGFloat = 2.2
    var body: some View {
        Canvas { ctx, size in
            var rng = Seeded(seed)
            for _ in 0..<count {
                let x = rng.next() * size.width
                let y = rng.next() * size.height * 0.85
                let r = rng.range(0.4, Double(maxSize))
                let a = rng.range(0.32, 1.0)
                let path = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                ctx.fill(path, with: .color(color.opacity(a)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Layered mountain / hill silhouette using cubic-Bezier peaks.
private struct MountainLayer: Shape {
    var baseline: CGFloat            // 0…1, fraction of height where hills sit
    var amplitude: CGFloat           // 0…1, height variance
    var seed: UInt64
    var peaks: Int = 6
    var jaggedness: CGFloat = 0.4

    func path(in rect: CGRect) -> Path {
        var rng = Seeded(seed)
        var p = Path()
        let baseY = rect.height * baseline
        let step = rect.width / CGFloat(peaks - 1)
        p.move(to: CGPoint(x: -1, y: rect.height + 1))
        p.addLine(to: CGPoint(x: -1, y: baseY))
        var prev = CGPoint(x: -step * 0.5, y: baseY + rect.height * amplitude * (rng.next() - 0.5))
        for i in 0..<peaks {
            let x = step * CGFloat(i)
            let peak = baseY - rect.height * amplitude * (0.4 + 0.6 * rng.next())
            let midY = (prev.y + peak) / 2 + rect.height * amplitude * 0.05 * (rng.next() - 0.5)
            let ctrl1 = CGPoint(x: prev.x + step * (0.35 + jaggedness * 0.2 * rng.next()), y: midY)
            let ctrl2 = CGPoint(x: x - step * (0.35 + jaggedness * 0.2 * rng.next()), y: peak)
            p.addCurve(to: CGPoint(x: x, y: peak), control1: ctrl1, control2: ctrl2)
            prev = CGPoint(x: x, y: peak)
        }
        p.addLine(to: CGPoint(x: rect.width + 1, y: prev.y))
        p.addLine(to: CGPoint(x: rect.width + 1, y: rect.height + 1))
        p.closeSubpath()
        return p
    }
}

/// City skyline silhouette — rectangular buildings with occasional spires.
private struct CitySkyline: Shape {
    var baseline: CGFloat
    var seed: UInt64
    var buildings: Int = 18
    var maxHeight: CGFloat = 0.42

    func path(in rect: CGRect) -> Path {
        var rng = Seeded(seed)
        var p = Path()
        let baseY = rect.height * baseline
        let stepBase = rect.width / CGFloat(buildings)
        p.move(to: CGPoint(x: -1, y: rect.height + 1))
        p.addLine(to: CGPoint(x: -1, y: baseY))
        var x: CGFloat = 0
        while x < rect.width {
            let w = stepBase * CGFloat(rng.range(0.6, 1.6))
            let h = rect.height * maxHeight * CGFloat(rng.range(0.35, 1.0))
            let top = baseY - h
            let hasSpire = rng.next() > 0.82
            let midStep = rng.next() > 0.6 ? rect.height * 0.05 * CGFloat(rng.next()) : 0
            p.addLine(to: CGPoint(x: x, y: top + midStep))
            if hasSpire {
                let spireW = min(w * 0.18, 10)
                p.addLine(to: CGPoint(x: x + w / 2 - spireW / 2, y: top + midStep))
                p.addLine(to: CGPoint(x: x + w / 2, y: top - h * 0.25))
                p.addLine(to: CGPoint(x: x + w / 2 + spireW / 2, y: top + midStep))
            }
            p.addLine(to: CGPoint(x: x + w, y: top + midStep))
            p.addLine(to: CGPoint(x: x + w, y: baseY))
            x += w
        }
        p.addLine(to: CGPoint(x: rect.width + 1, y: baseY))
        p.addLine(to: CGPoint(x: rect.width + 1, y: rect.height + 1))
        p.closeSubpath()
        return p
    }
}

/// A single glowing window in a city silhouette.
private struct CityWindows: View {
    var seed: UInt64
    var baseline: CGFloat
    var accent: Color
    var count: Int

    var body: some View {
        Canvas { ctx, size in
            var rng = Seeded(seed)
            for _ in 0..<count {
                let x = rng.next() * size.width
                let y = size.height * baseline - rng.range(4, size.height * 0.4)
                let s = rng.range(1.2, 2.6)
                let warmth = rng.next()
                let base = warmth > 0.5 ? Color(hex: 0xFFC96A) : accent
                let path = Path(CGRect(x: x, y: y, width: s, height: s))
                ctx.fill(path, with: .color(base.opacity(rng.range(0.4, 0.95))))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - City Night

private struct CityNightScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        let moonR = min(size.width, size.height) * 0.11
        ZStack {
            // Sky glow band above skyline
            LinearGradient(
                colors: [theme.accent.opacity(0.0), theme.accent.opacity(0.14), theme.accent.opacity(0.28)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: size.height * 0.55)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .blur(radius: 40)

            StarField(seed: 42, count: 90, color: .white.opacity(0.9))

            MoonDisc(color: Color(hex: 0xFFE6B0), glow: theme.ringA, radius: moonR)
                .offset(x: size.width * 0.28, y: -size.height * 0.28)

            // Far skyline
            CitySkyline(baseline: 0.78, seed: 11, buildings: 22, maxHeight: 0.28)
                .fill(Color(hex: 0x0B1024).opacity(0.75))
            CityWindows(seed: 111, baseline: 0.78, accent: theme.accent, count: 60)

            // Front skyline
            CitySkyline(baseline: 0.92, seed: 21, buildings: 14, maxHeight: 0.44)
                .fill(Color.black.opacity(0.92))
            CityWindows(seed: 211, baseline: 0.92, accent: theme.accent, count: 90)
        }
        .clipped()
    }
}

// MARK: - Campfire

private struct CampfireScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Deep-warm vignette dark corners
            RadialGradient(
                colors: [.clear, .clear, .black.opacity(0.6)],
                center: UnitPoint(x: 0.5, y: 0.85),
                startRadius: 20, endRadius: size.width * 0.75
            )

            // Main fire glow rising from bottom-center
            RadialGradient(
                colors: [
                    Color(hex: 0xFFDDA6).opacity(0.85),
                    Color(hex: 0xFF9F4A).opacity(0.55),
                    Color(hex: 0xB63A18).opacity(0.28),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.92),
                startRadius: 20, endRadius: size.width * 0.55
            )

            // Warm ceiling light
            RadialGradient(
                colors: [Color(hex: 0xFF6B2C).opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0.6),
                startRadius: 40, endRadius: size.width * 0.5
            )

            // Cast log silhouettes at bottom
            LogPile(size: size)
                .fill(Color(hex: 0x0E0503))

            // Rising heat smoke curl
            SmokeCurl(seed: 9)
                .fill(Color(hex: 0xF7C67A).opacity(0.05))
                .frame(width: size.width * 0.5, height: size.height * 0.7)
                .offset(y: -size.height * 0.15)
                .blur(radius: 30)
        }
        .clipped()
    }
}

private struct LogPile: Shape {
    var size: CGSize
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cy = rect.height * 0.94
        let logs: [(CGFloat, CGFloat, CGFloat)] = [
            (rect.width * 0.5, rect.width * 0.30, 12),
            (rect.width * 0.44, rect.width * 0.26, 10),
            (rect.width * 0.56, rect.width * 0.26, 10),
        ]
        for (cx, w, h) in logs {
            p.addRoundedRect(
                in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                cornerSize: CGSize(width: h / 2, height: h / 2)
            )
        }
        return p
    }
}

private struct SmokeCurl: Shape {
    var seed: UInt64
    func path(in rect: CGRect) -> Path {
        var rng = Seeded(seed)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        var y = rect.maxY
        var x = rect.midX
        while y > 0 {
            let nx = x + CGFloat(rng.range(-40, 40))
            let ny = y - CGFloat(rng.range(30, 60))
            p.addQuadCurve(to: CGPoint(x: nx, y: ny), control: CGPoint(x: (x + nx) / 2 + 30, y: (y + ny) / 2))
            x = nx; y = ny
        }
        return p.strokedPath(StrokeStyle(lineWidth: 40, lineCap: .round))
    }
}

// MARK: - Crystal Cave

private struct CrystalCaveScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Cool blue haze
            RadialGradient(
                colors: [theme.accent.opacity(0.32), theme.accent.opacity(0.08), .clear],
                center: UnitPoint(x: 0.5, y: 0.5),
                startRadius: 40, endRadius: size.width * 0.6
            )

            // Ceiling crystals hanging down
            ForEach(0..<7, id: \.self) { i in
                CrystalShape(inverted: false)
                    .fill(LinearGradient(
                        colors: [theme.ringA.opacity(0.55), theme.ringB.opacity(0.25), .clear],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: crystalW(i), height: crystalH(i, top: true))
                    .position(x: crystalX(i), y: crystalH(i, top: true) / 2 - 20)
                    .blur(radius: 0.4)
            }

            // Floor crystals rising
            ForEach(0..<6, id: \.self) { i in
                CrystalShape(inverted: true)
                    .fill(LinearGradient(
                        colors: [.clear, theme.ringA.opacity(0.35), theme.ringB.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: crystalW(i + 10), height: crystalH(i, top: false))
                    .position(x: crystalX(i + 3), y: size.height - crystalH(i, top: false) / 2 + 20)
                    .blur(radius: 0.4)
            }

            // Inner luminous fog
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: UnitPoint(x: 0.5, y: 0.55),
                startRadius: 10, endRadius: size.width * 0.35
            )
            .blur(radius: 20)
        }
        .clipped()
    }
    private func crystalX(_ i: Int) -> CGFloat {
        var rng = Seeded(UInt64(i) &* 2654435761)
        return CGFloat(rng.next()) * size.width
    }
    private func crystalW(_ i: Int) -> CGFloat {
        var rng = Seeded(UInt64(i) &* 40507 &+ 7)
        return CGFloat(rng.range(30, 90))
    }
    private func crystalH(_ i: Int, top: Bool) -> CGFloat {
        var rng = Seeded(UInt64(i) &* 179426549 &+ (top ? 3 : 9))
        return size.height * CGFloat(rng.range(0.25, 0.55))
    }
}

private struct CrystalShape: Shape {
    var inverted: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if inverted {
            p.move(to: CGPoint(x: rect.midX, y: 0))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.35))
            p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.1, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX - rect.width * 0.1, y: rect.maxY))
            p.addLine(to: CGPoint(x: 0, y: rect.height * 0.35))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.65))
            p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.1, y: 0))
            p.addLine(to: CGPoint(x: rect.midX - rect.width * 0.1, y: 0))
            p.addLine(to: CGPoint(x: 0, y: rect.height * 0.65))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Carnival

private struct CarnivalScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Radial festive glow at bottom
            RadialGradient(
                colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.1), .clear],
                center: UnitPoint(x: 0.5, y: 0.85),
                startRadius: 30, endRadius: size.width * 0.7
            )

            // Warm sunset-band above the "stage"
            LinearGradient(
                colors: [Color(hex: 0xFF7EB0).opacity(0.3), Color(hex: 0xFFCC66).opacity(0.25), .clear],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: size.height * 0.6)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .blur(radius: 40)

            // Big tent silhouette center
            BigTop(size: size)
                .fill(LinearGradient(
                    colors: [Color(hex: 0xC02060), Color(hex: 0x5C0930)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: size.width * 0.65, height: size.height * 0.55)
                .position(x: size.width / 2, y: size.height * 0.78)

            // Stripes on tent
            TentStripes(size: size)
                .fill(Color(hex: 0xFFF3D6).opacity(0.72))
                .frame(width: size.width * 0.65, height: size.height * 0.55)
                .position(x: size.width / 2, y: size.height * 0.78)

            // Bunting lights at top
            BuntingLights(count: 30, colors: [
                Color(hex: 0xFFDA5E), Color(hex: 0xFF6EB0), Color(hex: 0x5EE0C8), Color(hex: 0x9F7EFF)
            ])
            .frame(height: 40)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, size.height * 0.18)
        }
        .clipped()
    }
}

private struct BigTop: Shape {
    var size: CGSize
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // dome + spire
        let spireH = rect.height * 0.24
        p.move(to: CGPoint(x: rect.minX, y: rect.height))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.5))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: spireH * 0.05),
            control: CGPoint(x: rect.width * 0.25, y: rect.height * 0.05)
        )
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.5),
            control: CGPoint(x: rect.width * 0.75, y: rect.height * 0.05)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.height))
        p.closeSubpath()
        return p
    }
}

private struct TentStripes: Shape {
    var size: CGSize
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let stripes = 9
        for i in 0..<stripes where i.isMultiple(of: 2) {
            let x1 = rect.width * CGFloat(i) / CGFloat(stripes)
            let x2 = rect.width * CGFloat(i + 1) / CGFloat(stripes)
            var sub = Path()
            sub.move(to: CGPoint(x: x1, y: rect.height))
            sub.addLine(to: CGPoint(x: x1 + rect.width * 0.02, y: rect.height * 0.5))
            sub.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.height * 0.05),
                control: CGPoint(x: rect.width * 0.3, y: rect.height * 0.1)
            )
            sub.addQuadCurve(
                to: CGPoint(x: x2 + rect.width * 0.02, y: rect.height * 0.5),
                control: CGPoint(x: rect.width * 0.7, y: rect.height * 0.1)
            )
            sub.addLine(to: CGPoint(x: x2, y: rect.height))
            sub.closeSubpath()
            p.addPath(sub)
        }
        return p
    }
}

private struct BuntingLights: View {
    let count: Int
    let colors: [Color]
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for i in 0..<count {
                    let t = Double(i) / Double(count - 1)
                    let x = t * size.width
                    let dip = sin(t * .pi) * 22
                    let y: CGFloat = 6 + dip
                    let c = colors[i % colors.count]
                    let path = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    // glow
                    ctx.blendMode = .plusLighter
                    ctx.fill(path, with: .color(c.opacity(0.9)))
                }
            }
        }
    }
}

// MARK: - Misty Peaks

private struct MistyPeaksScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Cool haze
            LinearGradient(
                colors: [Color(hex: 0x2F3947).opacity(0.6), Color(hex: 0x556378).opacity(0.4), .clear],
                startPoint: .top, endPoint: .bottom
            )

            // Distant softest peaks
            MountainLayer(baseline: 0.62, amplitude: 0.28, seed: 3, peaks: 7, jaggedness: 0.5)
                .fill(Color(hex: 0x3E4A5C).opacity(0.65))
                .blur(radius: 2)

            // Middle peaks with snow caps
            MountainLayer(baseline: 0.75, amplitude: 0.32, seed: 17, peaks: 6, jaggedness: 0.7)
                .fill(Color(hex: 0x293240).opacity(0.9))

            // Snow lighting on mid peaks (top strip)
            MountainLayer(baseline: 0.75, amplitude: 0.32, seed: 17, peaks: 6, jaggedness: 0.7)
                .stroke(Color(hex: 0xE8EEF6).opacity(0.55), lineWidth: 1.4)
                .mask(
                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: size.height * 0.55)
                    .frame(maxHeight: .infinity, alignment: .top)
                )

            // Front peaks — darker, jagged
            MountainLayer(baseline: 0.9, amplitude: 0.24, seed: 33, peaks: 4, jaggedness: 0.9)
                .fill(Color(hex: 0x141A22).opacity(0.98))

            // Low fog bank
            LinearGradient(
                colors: [.clear, Color(hex: 0xC4CED8).opacity(0.35), Color(hex: 0xC4CED8).opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: size.height * 0.35)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .blur(radius: 30)
        }
        .clipped()
    }
}

// MARK: - Northern Lights

private struct AuroraScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            StarField(seed: 77, count: 140, color: .white.opacity(0.9))

            // Layered ribbons (green-teal + violet)
            AuroraRibbon(phase: 0.0, wavelength: 380, amplitude: 90, seed: 5)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x40D8B0).opacity(0.0), Color(hex: 0x40D8B0).opacity(0.85), Color(hex: 0x40D8B0).opacity(0.0)],
                    startPoint: .top, endPoint: .bottom))
                .blur(radius: 20)
                .frame(height: size.height * 0.6)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: size.height * 0.05)

            AuroraRibbon(phase: 0.4, wavelength: 260, amplitude: 130, seed: 23)
                .fill(LinearGradient(
                    colors: [.clear, Color(hex: 0x76F0D4).opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom))
                .blur(radius: 22)
                .frame(height: size.height * 0.55)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: size.height * 0.12)

            AuroraRibbon(phase: 0.9, wavelength: 500, amplitude: 60, seed: 91)
                .fill(LinearGradient(
                    colors: [.clear, Color(hex: 0xB06EFF).opacity(0.5), .clear],
                    startPoint: .top, endPoint: .bottom))
                .blur(radius: 28)
                .frame(height: size.height * 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: size.height * 0.18)

            // Dark distant mountain silhouette at bottom
            MountainLayer(baseline: 0.92, amplitude: 0.18, seed: 4, peaks: 8, jaggedness: 0.8)
                .fill(Color.black.opacity(0.92))
        }
        .clipped()
    }
}

private struct AuroraRibbon: Shape {
    var phase: Double
    var wavelength: CGFloat
    var amplitude: CGFloat
    var seed: UInt64
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var rng = Seeded(seed)
        let baseY = rect.height * 0.55
        let step: CGFloat = 20
        var topPoints: [CGPoint] = []
        var bottomPoints: [CGPoint] = []
        var x: CGFloat = -50
        while x < rect.width + 50 {
            let s = sin(Double(x) / Double(wavelength) * .pi * 2 + phase * .pi * 2)
            let noise = rng.range(-0.3, 0.3)
            let center = baseY + amplitude * CGFloat(s + noise) * 0.5
            let thickness = amplitude * 0.9 + amplitude * 0.2 * CGFloat(sin(Double(x) / 130 + phase))
            topPoints.append(CGPoint(x: x, y: center - thickness))
            bottomPoints.append(CGPoint(x: x, y: center + thickness))
            x += step
        }
        p.move(to: topPoints[0])
        for pt in topPoints.dropFirst() { p.addLine(to: pt) }
        for pt in bottomPoints.reversed() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

// MARK: - Lantern Festival

private struct LanternFestScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Warm night gradient
            RadialGradient(
                colors: [Color(hex: 0x5C1808).opacity(0.6), .clear],
                center: UnitPoint(x: 0.5, y: 0.9), startRadius: 20, endRadius: size.width * 0.8
            )

            // Distant temple/rooftop silhouettes
            TempleSilhouette(size: size)
                .fill(Color.black.opacity(0.85))
                .frame(width: size.width, height: size.height * 0.45)
                .frame(maxHeight: .infinity, alignment: .bottom)

            // Floating lanterns
            LanternField(size: size, count: 26, ringA: theme.ringA, accent: theme.accent)
        }
        .clipped()
    }
}

private struct TempleSilhouette: Shape {
    var size: CGSize
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = rect.height
        let w = rect.width

        // Ground line with two soft rises
        p.move(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.86))
        p.addQuadCurve(to: CGPoint(x: w * 0.34, y: h * 0.82),
                       control: CGPoint(x: w * 0.16, y: h * 0.74))
        p.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.85),
                       control: CGPoint(x: w * 0.5, y: h * 0.78))
        p.addQuadCurve(to: CGPoint(x: w, y: h * 0.9),
                       control: CGPoint(x: w * 0.84, y: h * 0.8))
        p.addLine(to: CGPoint(x: w, y: h))
        p.closeSubpath()

        // Pagodas sit on top of the ground as their own closed subpaths, so
        // tier widths scale with the frame instead of drifting into spikes.
        p.addPath(pagoda(centerX: w * 0.26, baseY: h * 0.82,
                         tiers: 3, tierH: h * 0.15, widest: w * 0.15))
        p.addPath(pagoda(centerX: w * 0.72, baseY: h * 0.86,
                         tiers: 2, tierH: h * 0.13, widest: w * 0.11))
        return p
    }

    /// A tiered pagoda: each level is a body block capped by a wide flared roof
    /// that overhangs on both sides, narrowing as it rises.
    private func pagoda(centerX: CGFloat, baseY: CGFloat,
                        tiers: Int, tierH: CGFloat, widest: CGFloat) -> Path {
        var p = Path()
        for tier in 0..<tiers {
            let t = CGFloat(tier)
            let shrink = 1.0 - t * 0.22
            let bodyW = widest * 0.52 * shrink
            let roofW = widest * shrink
            let top = baseY - tierH * (t + 1)
            let bottom = baseY - tierH * t

            // Body
            p.addRect(CGRect(x: centerX - bodyW / 2, y: top, width: bodyW, height: bottom - top))

            // Flared roof — upturned eaves
            var roof = Path()
            let eaveY = top + tierH * 0.2
            roof.move(to: CGPoint(x: centerX - roofW / 2, y: eaveY))
            roof.addQuadCurve(to: CGPoint(x: centerX, y: top - tierH * 0.12),
                              control: CGPoint(x: centerX - roofW * 0.22, y: top - tierH * 0.02))
            roof.addQuadCurve(to: CGPoint(x: centerX + roofW / 2, y: eaveY),
                              control: CGPoint(x: centerX + roofW * 0.22, y: top - tierH * 0.02))
            roof.addLine(to: CGPoint(x: centerX + roofW * 0.36, y: eaveY + tierH * 0.1))
            roof.addLine(to: CGPoint(x: centerX - roofW * 0.36, y: eaveY + tierH * 0.1))
            roof.closeSubpath()
            p.addPath(roof)
        }
        // Finial spire on top
        let topY = baseY - tierH * CGFloat(tiers)
        p.addRect(CGRect(x: centerX - widest * 0.02, y: topY - tierH * 0.28,
                         width: widest * 0.04, height: tierH * 0.28))
        return p
    }
}

private struct LanternField: View {
    let size: CGSize
    let count: Int
    let ringA: Color
    let accent: Color
    var body: some View {
        Canvas { ctx, s in
            var rng = Seeded(7)
            for _ in 0..<count {
                let x = rng.next() * s.width
                let y = rng.next() * s.height * 0.75
                let r = rng.range(4, 12)
                let warmth = rng.next()
                let c = warmth > 0.4 ? Color(hex: 0xFFB84D) : Color(hex: 0xFFDD88)
                // Halo
                let halo = Path(ellipseIn: CGRect(x: x - r * 4, y: y - r * 4, width: r * 8, height: r * 8))
                ctx.blendMode = .plusLighter
                ctx.fill(halo, with: .radialGradient(
                    Gradient(colors: [c.opacity(0.55), c.opacity(0.1), .clear]),
                    center: CGPoint(x: x, y: y),
                    startRadius: r,
                    endRadius: r * 4
                ))
                // Body
                let body = Path(ellipseIn: CGRect(x: x - r, y: y - r * 1.2, width: r * 2, height: r * 2.4))
                ctx.fill(body, with: .color(c.opacity(0.95)))
            }
        }
    }
}

// MARK: - Soft Clouds

private struct SoftCloudsScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Pastel dawn wash
            LinearGradient(
                colors: [
                    Color(hex: 0x2A2740).opacity(0.6),
                    Color(hex: 0x8A6C9E).opacity(0.35),
                    Color(hex: 0xEBB4C4).opacity(0.25)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Soft cloud shapes
            ForEach(0..<7, id: \.self) { i in
                CloudShape()
                    .fill(cloudColor(i))
                    .frame(width: cloudSize(i).width, height: cloudSize(i).height)
                    .position(cloudPos(i))
                    .blur(radius: cloudBlur(i))
            }

            // Sun / soft light source top-right
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: 0xFFE8F0).opacity(0.75), Color(hex: 0xFFE8F0).opacity(0.2), .clear],
                    center: .center, startRadius: 20, endRadius: size.width * 0.35))
                .frame(width: size.width * 0.5, height: size.width * 0.5)
                .offset(x: size.width * 0.3, y: -size.height * 0.3)
        }
        .clipped()
    }
    private func cloudSize(_ i: Int) -> CGSize {
        var rng = Seeded(UInt64(i) &* 11);
        return CGSize(width: size.width * CGFloat(rng.range(0.35, 0.8)),
                      height: size.height * CGFloat(rng.range(0.15, 0.28)))
    }
    private func cloudPos(_ i: Int) -> CGPoint {
        var rng = Seeded(UInt64(i) &* 43 &+ 5);
        return CGPoint(x: CGFloat(rng.next()) * size.width, y: CGFloat(rng.next()) * size.height * 0.85)
    }
    private func cloudColor(_ i: Int) -> Color {
        [Color(hex: 0xF3E4EC), Color(hex: 0xE8D4EE), Color(hex: 0xFCECD4), Color(hex: 0xE0DCF6)][i % 4].opacity(0.35)
    }
    private func cloudBlur(_ i: Int) -> CGFloat { CGFloat(20 + i * 4) }
}

private struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midY = rect.height * 0.55
        p.move(to: CGPoint(x: rect.width * 0.05, y: midY))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.2, y: midY - rect.height * 0.28),
                       control: CGPoint(x: rect.width * 0.1, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.45, y: midY - rect.height * 0.42),
                       control: CGPoint(x: rect.width * 0.3, y: -rect.height * 0.1))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.7, y: midY - rect.height * 0.3),
                       control: CGPoint(x: rect.width * 0.6, y: -rect.height * 0.05))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.92, y: midY - rect.height * 0.1),
                       control: CGPoint(x: rect.width * 0.85, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.95, y: midY + rect.height * 0.3),
                       control: CGPoint(x: rect.width, y: midY))
        p.addLine(to: CGPoint(x: rect.width * 0.05, y: midY + rect.height * 0.3))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.05, y: midY),
                       control: CGPoint(x: 0, y: midY + rect.height * 0.1))
        p.closeSubpath()
        return p
    }
}

// MARK: - Rainy Window

private struct RainyWindowScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // City glow behind rain
            RadialGradient(
                colors: [Color(hex: 0x8EC8E8).opacity(0.2), .clear],
                center: UnitPoint(x: 0.4, y: 0.5),
                startRadius: 20, endRadius: size.width * 0.5
            )

            // Blurred city lights
            Canvas { ctx, s in
                var rng = Seeded(88)
                for _ in 0..<40 {
                    let x = rng.next() * s.width
                    let y = rng.range(0.3, 0.75) * s.height
                    let r = rng.range(6, 18)
                    let c = rng.next() > 0.6
                        ? Color(hex: 0xFFC96A)
                        : Color(hex: 0x8EC8E8)
                    let path = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    ctx.blendMode = .plusLighter
                    ctx.fill(path, with: .color(c.opacity(0.35)))
                }
            }
            .blur(radius: 12)

            // Water droplets running down
            Canvas { ctx, s in
                var rng = Seeded(21)
                for _ in 0..<160 {
                    let x = rng.next() * s.width
                    let y = rng.next() * s.height
                    let len = rng.range(4, 22)
                    let w = rng.range(0.6, 1.8)
                    let path = Path(CGRect(x: x, y: y, width: w, height: len))
                    ctx.fill(path, with: .color(Color(hex: 0xB0D8F0).opacity(rng.range(0.15, 0.6))))
                }
                for _ in 0..<50 {
                    let x = rng.next() * s.width
                    let y = rng.next() * s.height
                    let r = rng.range(2, 4.5)
                    let path = Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2))
                    ctx.fill(path, with: .color(Color(hex: 0xE8F4FF).opacity(rng.range(0.25, 0.55))))
                }
            }
        }
        .clipped()
    }
}

// MARK: - Meteor Shower

private struct MeteorShowerScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Purple-black nebula haze
            RadialGradient(
                colors: [Color(hex: 0x2A1858).opacity(0.4), Color(hex: 0x0A0C1A).opacity(0.2), .clear],
                center: UnitPoint(x: 0.25, y: 0.35), startRadius: 40, endRadius: size.width * 0.7
            )
            RadialGradient(
                colors: [Color(hex: 0x461E48).opacity(0.3), .clear],
                center: UnitPoint(x: 0.75, y: 0.6), startRadius: 40, endRadius: size.width * 0.6
            )

            // Dense stars
            StarField(seed: 4242, count: 260, color: .white, maxSize: 2.6)

            // Occasional bright stars with tiny cross flare
            Canvas { ctx, s in
                var rng = Seeded(9)
                for _ in 0..<8 {
                    let x = rng.next() * s.width
                    let y = rng.range(0.05, 0.85) * s.height
                    let r: CGFloat = CGFloat(rng.range(2, 4))
                    ctx.blendMode = .plusLighter
                    let center = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    ctx.fill(center, with: .color(.white))
                    let flareLen: CGFloat = r * 6
                    let hFlare = Path(CGRect(x: x - flareLen, y: y - 0.6, width: flareLen * 2, height: 1.2))
                    let vFlare = Path(CGRect(x: x - 0.6, y: y - flareLen, width: 1.2, height: flareLen * 2))
                    ctx.fill(hFlare, with: .color(.white.opacity(0.7)))
                    ctx.fill(vFlare, with: .color(.white.opacity(0.7)))
                }
            }

            // Meteor streaks (baked into the background — motion is provided by particle FX)
            Canvas { ctx, s in
                var rng = Seeded(1337)
                for _ in 0..<3 {
                    let sx = rng.next() * s.width
                    let sy = rng.range(0.05, 0.4) * s.height
                    let len = rng.range(120, 220)
                    let angle = rng.range(0.4, 0.65)
                    let ex = sx + len * cos(angle)
                    let ey = sy + len * sin(angle)
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: sx, y: sy))
                    stroke.addLine(to: CGPoint(x: ex, y: ey))
                    ctx.blendMode = .plusLighter
                    ctx.stroke(stroke, with: .linearGradient(
                        Gradient(colors: [.clear, .white.opacity(0.7), Color(hex: 0xFFD488).opacity(0.9)]),
                        startPoint: CGPoint(x: sx, y: sy),
                        endPoint: CGPoint(x: ex, y: ey)
                    ), lineWidth: 1.8)
                }
            }
        }
        .clipped()
    }
}

// MARK: - Deep Fog

private struct DeepFogScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Base cool grey
            LinearGradient(
                colors: [Color(hex: 0x191C22), Color(hex: 0x2A2D34), Color(hex: 0x3E4148)],
                startPoint: .top, endPoint: .bottom
            )

            // Distant shape hint
            MountainLayer(baseline: 0.65, amplitude: 0.18, seed: 61, peaks: 5, jaggedness: 0.4)
                .fill(Color(hex: 0x353942).opacity(0.5))
                .blur(radius: 8)

            MountainLayer(baseline: 0.78, amplitude: 0.15, seed: 62, peaks: 6, jaggedness: 0.6)
                .fill(Color(hex: 0x282C33).opacity(0.7))
                .blur(radius: 4)

            // Layered fog bands
            ForEach(0..<5, id: \.self) { i in
                LinearGradient(
                    colors: [.clear, Color(hex: 0xB0B8C8).opacity(fogAlpha(i)), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: fogBandH(i))
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, fogBandY(i))
                .blur(radius: 30)
            }

            // Bottom mist floor
            LinearGradient(
                colors: [.clear, Color(hex: 0xC8CFD8).opacity(0.35), Color(hex: 0xD4DAE2).opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: size.height * 0.4)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .blur(radius: 50)
        }
        .clipped()
    }
    private func fogBandH(_ i: Int) -> CGFloat { size.height * (0.06 + Double(i) * 0.03) }
    private func fogBandY(_ i: Int) -> CGFloat { size.height * (0.08 + Double(i) * 0.14) }
    private func fogAlpha(_ i: Int) -> Double { 0.22 + Double(i) * 0.05 }
}

// MARK: - Sacred Geometry

private struct SacredGeometryScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Cosmic haze
            RadialGradient(
                colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.08), .clear],
                center: .center, startRadius: 40, endRadius: size.width * 0.55
            )
            .blur(radius: 30)

            // Concentric mandala pattern
            let center = CGPoint(x: size.width / 2, y: size.height * 0.48)
            let baseR = min(size.width, size.height) * 0.24

            // Radiating spokes
            SpokesShape(count: 24)
                .stroke(theme.ringA.opacity(0.28), lineWidth: 1)
                .frame(width: baseR * 3, height: baseR * 3)
                .position(center)

            // Flower of Life circles
            FlowerOfLife(rings: 3)
                .stroke(theme.ringB.opacity(0.55), lineWidth: 1.1)
                .frame(width: baseR * 2.1, height: baseR * 2.1)
                .position(center)

            // Inner triangle overlay
            Triangle()
                .stroke(theme.ringA.opacity(0.7), lineWidth: 1.3)
                .frame(width: baseR * 1.35, height: baseR * 1.35)
                .position(center)
            Triangle()
                .rotation(.degrees(180))
                .stroke(theme.ringB.opacity(0.7), lineWidth: 1.3)
                .frame(width: baseR * 1.35, height: baseR * 1.35)
                .position(center)

            // Outer ring
            Circle()
                .stroke(theme.ringA.opacity(0.55), lineWidth: 2)
                .frame(width: baseR * 2.8, height: baseR * 2.8)
                .position(center)

            // Diamond dots at ring
            Canvas { ctx, s in
                let count = 12
                let cx = s.width / 2
                let cy = s.height * 0.48
                let r = baseR * 1.4
                for i in 0..<count {
                    let angle = Double(i) / Double(count) * .pi * 2 - .pi / 2
                    let x = cx + r * cos(angle)
                    let y = cy + r * sin(angle)
                    let path = Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
                    ctx.fill(path, with: .color(theme.accent.opacity(0.85)))
                }
            }
        }
        .clipped()
    }
}

private struct SpokesShape: Shape {
    var count: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let angle = Double(i) / Double(count) * .pi * 2
            let x = center.x + radius * cos(angle)
            let y = center.y + radius * sin(angle)
            p.move(to: center)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }
}

private struct FlowerOfLife: Shape {
    var rings: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / (Double(rings) * 2 + 2)
        p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        for ring in 1...rings {
            let count = ring * 6
            let dist = r * CGFloat(ring)
            for i in 0..<count {
                let angle = Double(i) / Double(count) * .pi * 2
                let cx = center.x + dist * cos(angle)
                let cy = center.y + dist * sin(angle)
                p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        }
        return p
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Thunderstorm

private struct ThunderstormScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Deep base night gradient
            LinearGradient(
                colors: [Color(hex: 0x080910), Color(hex: 0x121424), Color(hex: 0x1E2036)],
                startPoint: .top, endPoint: .bottom
            )

            // Cloud layers
            ForEach(0..<4, id: \.self) { i in
                CloudMass(seed: UInt64(i) &* 419)
                    .fill(cloudFill(i))
                    .frame(width: size.width * 1.2, height: size.height * 0.5)
                    .offset(x: cloudOffX(i), y: cloudOffY(i))
                    .blur(radius: CGFloat(20 + i * 6))
            }

            // Distant static lightning silhouette (subtle)
            LightningBolt()
                .stroke(LinearGradient(
                    colors: [Color(hex: 0xC8B8FF).opacity(0.85), Color(hex: 0xFFFFFF).opacity(0.7), Color(hex: 0xC8B8FF).opacity(0.3)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 2.5)
                .frame(width: size.width * 0.6, height: size.height * 0.7)
                .position(x: size.width * 0.6, y: size.height * 0.42)
                .shadow(color: Color(hex: 0xC8B8FF).opacity(0.6), radius: 12)
                .opacity(0.35)

            // Low cloud shadow near horizon
            LinearGradient(
                colors: [.clear, Color(hex: 0x08090E).opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: size.height * 0.35)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipped()
    }
    private func cloudFill(_ i: Int) -> Color {
        [Color(hex: 0x1F1F35), Color(hex: 0x161A2C), Color(hex: 0x0F1220), Color(hex: 0x22243A)][i % 4].opacity(0.75)
    }
    private func cloudOffX(_ i: Int) -> CGFloat { [-40, 60, 20, -80][i % 4] }
    private func cloudOffY(_ i: Int) -> CGFloat { size.height * [-0.35, -0.28, -0.42, -0.20][i % 4] }
}

private struct CloudMass: Shape {
    var seed: UInt64
    func path(in rect: CGRect) -> Path {
        var rng = Seeded(seed)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        var x: CGFloat = 0
        let step = rect.width / 8
        while x < rect.width {
            let peak = CGFloat(rng.range(0.15, 0.85)) * rect.height
            p.addQuadCurve(
                to: CGPoint(x: x + step, y: peak),
                control: CGPoint(x: x + step * 0.5, y: peak - rect.height * 0.2)
            )
            x += step
        }
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

private struct LightningBolt: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.width * 0.5, y: 0))
        p.addLine(to: CGPoint(x: rect.width * 0.35, y: rect.height * 0.28))
        p.addLine(to: CGPoint(x: rect.width * 0.55, y: rect.height * 0.35))
        p.addLine(to: CGPoint(x: rect.width * 0.3, y: rect.height * 0.65))
        p.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.height * 0.72))
        p.addLine(to: CGPoint(x: rect.width * 0.2, y: rect.height))
        return p
    }
}

// MARK: - Deep Ocean

private struct DeepOceanScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            // Depth gradient (bright at top, ink at bottom)
            LinearGradient(
                colors: [
                    Color(hex: 0x86E0FF).opacity(0.35),
                    Color(hex: 0x1C6EA8),
                    Color(hex: 0x0A2A48),
                    Color(hex: 0x040E1C),
                    Color(hex: 0x02050C)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // God rays from surface
            Canvas { ctx, s in
                var rng = Seeded(555)
                for _ in 0..<9 {
                    let sx = rng.next() * s.width
                    let bottomOffset = rng.range(-100, 100)
                    let ex = sx + bottomOffset
                    let ey = s.height * rng.range(0.55, 0.85)
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: sx, y: -10))
                    stroke.addLine(to: CGPoint(x: ex, y: ey))
                    ctx.blendMode = .plusLighter
                    ctx.stroke(stroke, with: .linearGradient(
                        Gradient(colors: [Color(hex: 0xB4EEFF).opacity(0.32), .clear]),
                        startPoint: CGPoint(x: sx, y: -10),
                        endPoint: CGPoint(x: ex, y: ey)
                    ), lineWidth: CGFloat(rng.range(40, 90)))
                }
            }
            .blur(radius: 15)

            // Surface caustics wavy band top
            Canvas { ctx, s in
                var rng = Seeded(7777)
                for _ in 0..<40 {
                    let x = rng.next() * s.width
                    let y = rng.range(0.02, 0.12) * s.height
                    let w = rng.range(20, 60)
                    let path = Path(CGRect(x: x, y: y, width: w, height: 1))
                    ctx.fill(path, with: .color(Color(hex: 0xD8F4FF).opacity(rng.range(0.25, 0.7))))
                }
            }
            .blur(radius: 1)

            // Distant whale silhouette
            WhaleShape()
                .fill(Color.black.opacity(0.55))
                .frame(width: size.width * 0.28, height: size.height * 0.11)
                .position(x: size.width * 0.72, y: size.height * 0.62)
                .blur(radius: 1.2)

            // Kelp silhouettes at floor
            KelpFrond(seed: 3, sway: 12)
                .stroke(Color(hex: 0x022A1E).opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 60, height: size.height * 0.45)
                .position(x: size.width * 0.15, y: size.height * 0.82)
            KelpFrond(seed: 8, sway: -10)
                .stroke(Color(hex: 0x022A1E).opacity(0.55), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 50, height: size.height * 0.38)
                .position(x: size.width * 0.85, y: size.height * 0.85)
            KelpFrond(seed: 15, sway: 8)
                .stroke(Color(hex: 0x011E15).opacity(0.75), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .frame(width: 70, height: size.height * 0.5)
                .position(x: size.width * 0.5, y: size.height * 0.8)
        }
        .clipped()
    }
}

private struct WhaleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Body
        p.move(to: CGPoint(x: rect.width * 0.05, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.9, y: rect.midY - rect.height * 0.05),
                       control: CGPoint(x: rect.width * 0.4, y: -rect.height * 0.3))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.05, y: rect.midY + rect.height * 0.35),
                       control: CGPoint(x: rect.width * 0.4, y: rect.height * 0.9))
        // Tail
        p.move(to: CGPoint(x: rect.width * 0.85, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 1.0, y: rect.midY - rect.height * 0.4))
        p.addLine(to: CGPoint(x: rect.width * 1.0, y: rect.midY + rect.height * 0.4))
        p.closeSubpath()
        return p
    }
}

private struct KelpFrond: Shape {
    var seed: UInt64
    var sway: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var rng = Seeded(seed)
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        var y = rect.maxY
        var x = rect.midX
        while y > 0 {
            let nx = x + sway * CGFloat(rng.range(-0.5, 1.2))
            let ny = y - CGFloat(rng.range(20, 40))
            p.addQuadCurve(to: CGPoint(x: nx, y: ny), control: CGPoint(x: (x + nx) / 2 + sway, y: (y + ny) / 2))
            x = nx; y = ny
        }
        return p
    }
}

// MARK: - Fallback dusk (unknown themes)

private struct DefaultDuskScene: View {
    let theme: Theme
    let size: CGSize
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [theme.accent.opacity(0.35), .clear],
                center: UnitPoint(x: 0.5, y: 0.85),
                startRadius: 20, endRadius: size.width * 0.7
            )
            MountainLayer(baseline: 0.85, amplitude: 0.22, seed: 44, peaks: 6, jaggedness: 0.6)
                .fill(Color.black.opacity(0.9))
        }
        .clipped()
    }
}
