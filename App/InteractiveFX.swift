import SwiftUI

// MARK: - Interactive FX engine
//
// A real particle simulation (positions, velocities, lifecycles) instead of
// time-parameterized loops. Everything reacts to the screen and the user:
//   • rain falls in 3D and splats on the "glass", leaving sliding droplets
//   • petals sway like pendulums or spiral down, gust away from the cursor
//   • snow swirls around the cursor and accumulates at the bottom edge
//   • fish steer away from the cursor; a shark cruises through periodically
//   • matrix code brightens under the cursor; clicks send a shockwave
//   • clicking empty space bursts petals / splashes / ripples per theme

struct P {          // generic particle
    var x = 0.0, y = 0.0, z = 1.0          // z: 0 far … 1 near
    var vx = 0.0, vy = 0.0
    var spin = 0.0, spinV = 0.0
    var phase = 0.0, freq = 1.0, amp = 0.0
    var size = 1.0
    var mode = 0                            // style-specific variant
    var age = 0.0, life = 1e9
    var impactY = 1e9                       // where a near rain drop hits the glass
    var stuck = 0.0                         // >0: stuck to the glass, melting/sliding
    var seed = 0.0
}

@MainActor private var _fxUID = 0
@MainActor private func nextFXUID() -> Int { _fxUID += 1; return _fxUID }

struct Effect {     // transient: splash, ripple, shockwave, crystal…
    var uid = 0     // set on append (CA renderer diffs new effects by uid)
    var x = 0.0, y = 0.0
    var age = 0.0, life = 0.5
    var kind = 0            // 0 splat, 1 ring, 2 droplet-slide, 3 crystal, 4 zoom-glyph, 5 stardust
    var seed = 0.0
    var vx = 0.0, vy = 0.0
    var size = 1.0
    var ch: Character = "0"
}

struct Agent {      // fish, bats
    var x = 0.0, y = 0.0
    var vx = 0.0, vy = 0.0
    var size = 1.0
    var hue = 0
    var phase = 0.0
}

@MainActor
final class FXEngine {
    let style: ParticleStyle
    var density = 1.0        // particle amount multiplier (Settings)
    var sizeScale = 1.0      // particle size multiplier (Settings)
    private var seededDensity = -1.0
    private var seededSize = -1.0
    private var seeded = false
    private var p: [P] = []
    private var fx: [Effect] = []
    private var agents: [Agent] = []
    private var accum: [Double] = []                 // snow ground buckets
    private var streams: [P] = []                    // matrix columns
    private var lastT: Double = 0
    private var sz = CGSize.zero

    // pointer state
    var mouse: CGPoint? = nil
    private var lastMouse: CGPoint? = nil
    var mouseVel = CGVector(dx: 0, dy: 0)

    // shark
    private var shark = Agent()
    private var sharkActive = false
    private var nextShark = 14.0

    private var clickQueue: [CGPoint] = []
    private var textCache: [String: GraphicsContext.ResolvedText] = [:]

    init(style: ParticleStyle) {
        self.style = style
    }

    // MARK: input

    func setMouse(_ point: CGPoint?) {
        if let point, let last = lastMouse {
            mouseVel = CGVector(dx: (point.x - last.x), dy: (point.y - last.y))
        } else {
            mouseVel = .zero
        }
        lastMouse = point
        mouse = point
    }

    func click(at point: CGPoint) {
        clickQueue.append(point)
        lastClick = point
    }

    private func appendFX(_ effect: Effect) {
        var e = effect
        e.uid = nextFXUID()
        fx.append(e)
    }

    /// CA-layer renderer support: raw state access + one-shot click read.
    var particles: [P] { p }
    var agentList: [Agent] { agents }
    var fxList: [Effect] { fx }
    var snowAccum: [Double] { accum }
    var sharkState: (active: Bool, agent: Agent) { (sharkActive, shark) }
    private(set) var lastClick: CGPoint?
    func takeClick() -> CGPoint? {
        defer { lastClick = nil }
        return lastClick
    }

    // MARK: stepping

    func step(theme: Theme, date: Date, size: CGSize) {
        let t = date.timeIntervalSinceReferenceDate
        var dt = lastT == 0 ? 1.0 / 60 : t - lastT
        lastT = t
        dt = min(dt, 1.0 / 20)   // clamp hiccups
        if !seeded || sz != size || density != seededDensity || sizeScale != seededSize {
            sz = size
            seeded = true
            seededDensity = density
            seededSize = sizeScale
            seed(theme: theme)
        }
        let clicks = clickQueue
        clickQueue.removeAll()
        for c in clicks { applyClick(c, theme: theme) }

        switch style {
        case .neonRain:         stepRain(dt, t)
        case .petals, .leaves:  stepPetals(dt, t)
        case .snow:             stepSnow(dt, t)
        case .bubbles:          stepOcean(dt, t)
        case .pond:             stepPond(dt, t)
        case .matrix:           stepMatrix(dt, t)
        case .stars:            stepStars(dt, t)
        case .fireflies:        stepFireflies(dt, t)
        case .dust:             stepDust(dt, t)
        case .gravity:          stepGravity(dt, t)
        case .pixel:            stepPixel(dt, t)
        case .embers:           stepEmbers(dt, t)
        case .bokeh:            stepBokeh(dt, t)
        case .sparkle:          stepSparkle(dt, t)
        case .confetti:         stepConfetti(dt, t)
        case .smoke:            stepSmoke(dt, t)
        case .aurora:           stepAurora(dt, t)
        case .lanterns:         stepLanterns(dt, t)
        case .feathers:         stepFeathers(dt, t)
        case .ripples:          stepRipples(dt, t)
        case .comet:            stepComet(dt, t)
        case .fog:              stepFog(dt, t)
        case .geometric:        stepGeometric(dt, t)
        case .lightning:        stepLightning(dt, t)
        case .none:             break
        }
        // transient effects age out
        for i in fx.indices { fx[i].age += dt }
        fx.removeAll { $0.age >= $0.life }
        // mouse velocity decays between hover callbacks
        mouseVel = CGVector(dx: mouseVel.dx * 0.86, dy: mouseVel.dy * 0.86)
    }

    private func seed(theme: Theme) {
        p.removeAll(); fx.removeAll(); agents.removeAll(); streams.removeAll()
        let w = sz.width, h = sz.height
        guard w > 10, h > 10 else { return }
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b) }
        func n(_ base: Int) -> Int { max(2, Int(Double(base) * density)) }

        switch style {
        case .neonRain:
            for _ in 0..<n(110) {
                var d = P()
                d.z = r(0.15, 1.0); d.x = r(0, w); d.y = r(-h, h)
                d.vy = 500 + 1100 * d.z * d.z
                d.size = (0.8 + 2.2 * d.z) * sizeScale
                d.impactY = d.z > 0.72 ? r(h * 0.15, h * 0.95) : 1e9
                d.seed = r(0, 1)
                p.append(d)
            }
        case .petals, .leaves:
            for _ in 0..<n(42) { p.append(makePetal(w: w, h: h, atTop: false)) }
        case .snow:
            for _ in 0..<n(80) {
                var f = P()
                f.z = r(0.1, 1.0); f.x = r(0, w); f.y = r(-h, h)
                f.vy = 18 + 60 * f.z; f.amp = r(8, 30); f.freq = r(0.3, 1.0)
                f.phase = r(0, 6.28); f.size = (1 + 2.6 * f.z) * sizeScale; f.seed = r(0, 1)
                p.append(f)
            }
            accum = Array(repeating: 0, count: 48)
        case .bubbles:
            for _ in 0..<n(32) {
                var b = P()
                b.x = r(0, w); b.y = r(0, h); b.z = r(0.2, 1)
                b.vy = -(20 + 50 * b.z); b.amp = r(4, 14); b.freq = r(0.6, 1.6)
                b.phase = r(0, 6.28); b.size = (2.5 + 8 * b.z) * sizeScale; b.seed = r(0, 1)
                p.append(b)
            }
            for i in 0..<max(2, Int(7 * density)) {
                var f = Agent()
                f.x = r(0, w); f.y = r(h * 0.2, h * 0.75)
                f.vx = r(20, 60) * (Bool.random() ? 1 : -1); f.vy = 0
                f.size = r(11, 22) * sizeScale; f.hue = i % 3; f.phase = r(0, 6.28)
                agents.append(f)
            }
            sharkActive = false; nextShark = lastT + r(8, 18)
        case .pond:
            for _ in 0..<n(24) {
                var leaf = P()
                leaf.x = r(0, w); leaf.y = r(0, h); leaf.z = r(0.3, 1)
                leaf.vx = r(-4, 4); leaf.vy = r(-3, 3)
                leaf.spin = r(0, 6.28); leaf.spinV = r(-0.15, 0.15)
                leaf.freq = r(0.4, 1.1); leaf.phase = r(0, 6.28)
                leaf.size = (7 + r(0, 11)) * sizeScale
                leaf.seed = r(0, 1)
                p.append(leaf)
            }
        case .matrix:
            let spacing = 17.0 * sizeScale / max(0.35, density)
            let cols = max(2, Int(w / spacing))
            for c in 0..<cols {
                var s = P()
                s.x = (Double(c) + 0.5) * spacing
                s.y = r(-h, h)
                s.vy = 90 + r(0, 190)
                s.size = 8 + r(0, 10)   // trail length in glyphs
                s.seed = r(0, 1)
                streams.append(s)
            }
        case .stars:
            for _ in 0..<n(110) {
                var s = P()
                s.z = r(0.1, 1.0); s.x = r(0, w); s.y = r(0, h * 0.8)
                s.size = (0.5 + 1.9 * s.z) * sizeScale; s.freq = r(0.4, 2.2); s.phase = r(0, 6.28)
                s.seed = r(0, 1)
                p.append(s)
            }
        case .fireflies:
            for _ in 0..<n(24) {
                var f = P()
                f.x = r(0, w); f.y = r(0, h)
                f.vx = r(-16, 16); f.vy = r(-12, 12)
                f.freq = r(0.5, 1.6); f.phase = r(0, 6.28); f.size = r(1.2, 2.4) * sizeScale
                f.seed = r(0, 1)
                p.append(f)
            }
            for _ in 0..<max(1, Int(3 * density)) {
                var b = Agent()
                b.x = r(0, w); b.y = r(h * 0.05, h * 0.4)
                b.vx = r(30, 70) * (Bool.random() ? 1 : -1); b.vy = 0
                b.size = r(5, 9) * sizeScale; b.phase = r(0, 6.28)
                agents.append(b)
            }
        case .dust:
            for _ in 0..<n(44) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.2, 1)
                d.vx = r(-4, 4); d.vy = r(-3, 3)
                d.freq = r(0.2, 0.7); d.phase = r(0, 6.28); d.size = (0.8 + 2.0 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .gravity:
            for _ in 0..<n(90) {
                var s = P()
                s.x = r(0, w); s.y = r(0, h); s.z = r(0.15, 1)
                s.vx = r(-8, 8); s.vy = r(-6, 6)
                s.freq = r(0.4, 1.8); s.phase = r(0, 6.28)
                s.size = (0.7 + 1.9 * s.z) * sizeScale; s.seed = r(0, 1)
                p.append(s)
            }
        case .pixel:
            for _ in 0..<n(58) {
                var q = P()
                q.x = r(0, w); q.y = r(-h, h); q.z = r(0.2, 1)
                q.vy = 14 + 40 * q.z
                q.freq = r(0.5, 1.4); q.phase = r(0, 6.28)
                q.size = Double(Int(r(1, 3.99))) * 2 * sizeScale   // chunky: 2/4/6 px
                q.seed = r(0, 1)
                p.append(q)
            }
        case .embers:
            for _ in 0..<n(40) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.2, 1)
                d.vx = r(-3, 3); d.vy = -(10 + 30 * d.z)
                d.freq = r(0.3, 1.0); d.phase = r(0, 6.28); d.size = (1 + 2.0 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .bokeh:
            for _ in 0..<n(18) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.3, 1)
                d.vx = r(-3, 3); d.vy = r(-2, 2)
                d.freq = r(0.2, 0.6); d.phase = r(0, 6.28); d.size = (8 + 12 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .sparkle:
            for _ in 0..<n(30) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.2, 1)
                d.vx = r(-1, 1); d.vy = r(-1, 1)
                d.freq = r(1.5, 4.0); d.phase = r(0, 6.28); d.size = (0.6 + 1.2 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .confetti:
            for _ in 0..<n(50) {
                var d = P()
                d.x = r(0, w); d.y = r(-h, h); d.z = r(0.2, 1)
                d.vx = r(-8, 8); d.vy = 20 + 50 * d.z
                d.spin = r(0, 6.28); d.spinV = r(-3.0, 3.0)
                d.freq = r(0.5, 1.4); d.phase = r(0, 6.28); d.size = (2 + 3 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .smoke:
            for _ in 0..<n(25) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.2, 1)
                d.vx = r(-2, 2); d.vy = -(8 + 18 * d.z)
                d.freq = r(0.15, 0.5); d.phase = r(0, 6.28); d.size = (4 + 6 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .aurora:
            for _ in 0..<n(16) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h * 0.33); d.z = r(0.4, 1)
                d.vx = 0; d.vy = 0
                d.freq = r(0.15, 0.4); d.phase = r(0, 6.28)
                d.size = (40 + 80 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .lanterns:
            for _ in 0..<n(12) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.3, 1)
                d.vx = r(-2, 2); d.vy = -(6 + 14 * d.z)
                d.freq = r(0.3, 0.8); d.phase = r(0, 6.28); d.size = (4 + 4 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .feathers:
            for _ in 0..<n(36) {
                var d = P()
                d.z = r(0.25, 1.0); d.x = r(0, w); d.y = r(-h, h)
                d.vy = 14 + 28 * d.z
                d.amp = r(30, 80); d.freq = r(0.3, 0.7)
                d.phase = r(0, 6.28); d.spinV = r(-1.0, 1.0)
                d.size = (9 + r(0, 11)) * (0.6 + 0.4 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .ripples:
            break
        case .comet:
            for _ in 0..<n(6) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.4, 1)
                let a = r(0, 6.28); let sp = r(160, 340)
                d.vx = cos(a) * sp; d.vy = sin(a) * sp
                d.size = (1.0 + 1.5 * d.z) * sizeScale; d.seed = r(0, 1)
                p.append(d)
            }
        case .fog:
            for _ in 0..<n(14) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.2, 1)
                d.vx = r(-1.5, 1.5); d.vy = r(-1, 1)
                d.freq = r(0.05, 0.2); d.phase = r(0, 6.28); d.size = (15 + 25 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .geometric:
            for _ in 0..<n(30) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h); d.z = r(0.2, 1)
                d.vx = r(-4, 4); d.vy = r(-3, 3)
                d.spin = r(0, 6.28); d.spinV = r(-0.6, 0.6)
                d.freq = r(0.2, 0.6); d.phase = r(0, 6.28); d.size = (3 + 5 * d.z) * sizeScale
                d.seed = r(0, 1)
                p.append(d)
            }
        case .lightning:
            for _ in 0..<n(20) {
                var d = P()
                d.x = r(0, w); d.y = r(0, h * 0.7); d.z = r(0.1, 1)
                d.size = (0.5 + 1.5 * d.z) * sizeScale; d.freq = r(0.5, 2.0); d.phase = r(0, 6.28)
                d.seed = r(0, 1)
                p.append(d)
            }
        case .none: break
        }
    }

    private func makePetal(w: Double, h: Double, atTop: Bool, at point: CGPoint? = nil) -> P {
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b) }
        var petal = P()
        petal.mode = r(0, 1) < 0.6 ? 0 : 1          // 0 pendulum sway, 1 spiral
        petal.z = r(0.25, 1.0)
        if let point {
            petal.x = point.x + r(-10, 10); petal.y = point.y + r(-10, 10)
            let a = r(0, 6.28); let sp = r(60, 220)
            petal.vx = cos(a) * sp; petal.vy = sin(a) * sp - 60
        } else {
            petal.x = r(0, w)
            petal.y = atTop ? r(-60, -10) : r(-h, h)
        }
        petal.vy += 26 + 46 * petal.z
        petal.amp = petal.mode == 0 ? r(26, 70) : r(10, 30)   // sway width / spiral radius
        petal.freq = petal.mode == 0 ? r(0.6, 1.2) : r(1.6, 3.2)
        petal.phase = r(0, 6.28)
        petal.spinV = r(-2.4, 2.4)
        petal.size = (9 + r(0, 12)) * (0.6 + 0.4 * petal.z) * sizeScale
        petal.seed = r(0, 1)
        if style == .leaves {   // maple leaves fall heavier and tumble more
            petal.vy += 16
            petal.spinV *= 1.5
            petal.size *= 1.1
        }
        return petal
    }

    private func applyClick(_ c: CGPoint, theme: Theme) {
        let w = sz.width, h = sz.height
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b) }
        switch style {
        case .petals, .leaves:
            for _ in 0..<10 { p.append(makePetal(w: w, h: h, atTop: false, at: c)) }
            if p.count > 70 { p.removeFirst(p.count - 70) }
        case .neonRain:
            appendFX(Effect(x: c.x, y: c.y, life: 0.55, kind: 1, seed: r(0,1), size: 2.2))
            for _ in 0..<10 {
                let a = r(0, 6.28)
                appendFX(Effect(x: c.x + cos(a) * r(4, 30), y: c.y + sin(a) * r(4, 30),
                                 life: r(0.25, 0.45), kind: 0, seed: r(0,1), size: r(0.5, 1.1)))
            }
        case .bubbles:
            for i in 0..<3 {
                appendFX(Effect(x: c.x, y: c.y, age: -Double(i) * 0.12, life: 0.9, kind: 1, seed: r(0,1), size: 1 + Double(i) * 0.8))
            }
            for _ in 0..<6 {
                var b = P()
                b.x = c.x + r(-14, 14); b.y = c.y + r(-6, 6); b.z = r(0.5, 1)
                b.vy = -(60 + r(0, 90)); b.amp = r(4, 10); b.freq = r(1, 2)
                b.size = 2 + r(0, 5); b.seed = r(0, 1)
                p.append(b)
            }
            for i in agents.indices {   // fish dart away
                let dx = agents[i].x - c.x, dy = agents[i].y - c.y
                let d = max(20, (dx * dx + dy * dy).squareRoot())
                if d < 260 { agents[i].vx += dx / d * 190; agents[i].vy += dy / d * 120 }
            }
        case .matrix:
            appendFX(Effect(x: c.x, y: c.y, life: 0.9, kind: 1, seed: r(0,1), size: 3))
            let glyphs = Array("ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘｱ01")
            for _ in 0..<12 {
                var e = Effect(x: c.x + r(-30, 30), y: c.y + r(-30, 30), life: r(0.5, 0.9), kind: 4, seed: r(0,1))
                e.vx = r(-40, 40); e.vy = r(-40, 40); e.size = r(1, 2)
                e.ch = glyphs.randomElement()!
                fx.append(e)
            }
        case .stars:
            var e = Effect(x: c.x, y: c.y, life: 0.8, kind: 5, seed: r(0,1), size: 1)
            e.vx = r(160, 260); e.vy = r(60, 120)
            fx.append(e)
            for _ in 0..<8 {
                var d = Effect(x: c.x, y: c.y, life: r(0.4, 0.8), kind: 0, seed: r(0,1), size: r(0.3, 0.8))
                let a = r(0, 6.28); d.vx = cos(a) * r(20, 70); d.vy = sin(a) * r(20, 70)
                fx.append(d)
            }
        case .snow:
            // a gust: nearby flakes blow away from the click, nothing spawns
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(14, (dx * dx + dy * dy).squareRoot())
                if d < 200 {
                    let force = (200 - d) / 200
                    p[i].vx += dx / d * 340 * force
                    p[i].vy += dy / d * 240 * force
                }
            }
        case .fireflies:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(14, (dx * dx + dy * dy).squareRoot())
                if d < 220 { p[i].vx += dx / d * 260; p[i].vy += dy / d * 260 }
            }
        case .dust:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(10, (dx * dx + dy * dy).squareRoot())
                if d < 130 { p[i].vx += dx / d * 90; p[i].vy += dy / d * 90 }
            }
        case .gravity:
            // supernova: fling captured stardust back out
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(12, (dx * dx + dy * dy).squareRoot())
                if d < 320 {
                    let force = (320 - d) / 320
                    p[i].vx += dx / d * 520 * force
                    p[i].vy += dy / d * 520 * force
                }
            }
            appendFX(Effect(x: c.x, y: c.y, life: 0.7, kind: 1, seed: r(0,1), size: 3.4))
            for _ in 0..<14 {
                var e = Effect(x: c.x, y: c.y, life: r(0.4, 0.9), kind: 0, seed: r(0,1), size: r(0.4, 1.0))
                let a = r(0, 6.28); e.vx = cos(a) * r(60, 200); e.vy = sin(a) * r(60, 200)
                fx.append(e)
            }
        case .pond:
            // a stone dropped in the pond: staggered rings + leaves pushed out
            for i in 0..<3 {
                appendFX(Effect(x: c.x, y: c.y, age: -Double(i) * 0.16, life: 1.1, kind: 1,
                                 seed: r(0, 1), size: 1.2 + Double(i) * 0.9))
            }
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(16, (dx * dx + dy * dy).squareRoot())
                if d < 240 {
                    let force = (240 - d) / 240
                    p[i].vx += dx / d * 150 * force
                    p[i].vy += dy / d * 150 * force
                    p[i].spinV += force * (p[i].seed > 0.5 ? 0.8 : -0.8)
                }
            }
        case .pixel:
            // 8-bit firework
            for _ in 0..<26 {
                var e = Effect(x: c.x, y: c.y, life: r(0.7, 1.3), kind: 6, seed: r(0, 1))
                let a = r(0, 6.28); let sp = r(50, 230)
                e.vx = cos(a) * sp; e.vy = sin(a) * sp - 60
                e.size = Double(Int(r(1, 3.99))) * 2
                fx.append(e)
            }
        case .embers, .smoke, .lanterns, .fog:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(10, (dx * dx + dy * dy).squareRoot())
                if d < 140 { p[i].vx += dx / d * 100; p[i].vy += dy / d * 100 }
            }
        case .bokeh, .geometric:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(12, (dx * dx + dy * dy).squareRoot())
                if d < 180 { p[i].vx += dx / d * 60; p[i].vy += dy / d * 60 }
            }
        case .sparkle:
            for _ in 0..<8 {
                var e = Effect(x: c.x + r(-20, 20), y: c.y + r(-20, 20), life: r(0.3, 0.6), kind: 0, seed: r(0,1), size: r(0.4, 0.9))
                let a = r(0, 6.28); e.vx = cos(a) * r(20, 60); e.vy = sin(a) * r(20, 60)
                fx.append(e)
            }
        case .confetti:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(10, (dx * dx + dy * dy).squareRoot())
                if d < 160 {
                    let force = (160 - d) / 160
                    p[i].vx += dx / d * 200 * force; p[i].vy += dy / d * 160 * force
                    p[i].spinV += force * 6 * (p[i].seed > 0.5 ? 1 : -1)
                }
            }
        case .aurora:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(14, (dx * dx + dy * dy).squareRoot())
                if d < 200 { p[i].vx += dx / d * 40 }
            }
        case .feathers:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(14, (dx * dx + dy * dy).squareRoot())
                if d < 160 {
                    let force = (160 - d) / 160
                    p[i].vx += (mouseVel.dx * 4 + dx / d * 50) * force
                    p[i].vy += (mouseVel.dy * 4 + dy / d * 30) * force
                    p[i].spinV += force * 2 * (p[i].seed > 0.5 ? 1 : -1)
                }
            }
        case .ripples:
            for i in 0..<3 {
                appendFX(Effect(x: c.x, y: c.y, age: -Double(i) * 0.14, life: 1.0, kind: 1,
                                 seed: r(0, 1), size: 1.0 + Double(i) * 0.7))
            }
        case .comet:
            for i in p.indices {
                let dx = p[i].x - c.x, dy = p[i].y - c.y
                let d = max(12, (dx * dx + dy * dy).squareRoot())
                if d < 200 { p[i].vx += dx / d * 180; p[i].vy += dy / d * 180 }
            }
        case .lightning:
            appendFX(Effect(x: c.x, y: c.y, life: 0.4, kind: 1, seed: r(0,1), size: 4.0))
            for _ in 0..<6 {
                var e = Effect(x: c.x + r(-20, 20), y: c.y + r(-20, 20), life: r(0.2, 0.5), kind: 0, seed: r(0,1), size: r(0.5, 1.2))
                let a = r(0, 6.28); e.vx = cos(a) * r(30, 90); e.vy = sin(a) * r(30, 90)
                fx.append(e)
            }
        case .none: break
        }
    }

    // MARK: per-style physics

    private func stepRain(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        let wind = 30 * sin(t * 0.25)
        for i in p.indices {
            var d = p[i]
            var ax = wind * d.z
            if let m = mouse {
                let dx = d.x - m.x
                let dist = abs(dx)
                if dist < 90, d.y > m.y - 160, d.y < m.y + 160 {
                    ax += (dx < 0 ? -1 : 1) * (90 - dist) * 4 * d.z
                }
            }
            d.vx += ax * dt
            d.vx *= 0.98
            d.x += d.vx * dt
            d.y += d.vy * dt
            let len = 10 + 70 * d.z * d.z
            if d.y - len > h || d.y > d.impactY {
                if d.y > d.impactY {
                    // splat on the glass
                    appendFX(Effect(x: d.x, y: d.impactY, life: 0.4, kind: 0,
                                     seed: Double.random(in: 0...1), size: d.z))
                    if fx.count < 90, Double.random(in: 0...1) < 0.3 {
                        var drop = Effect(x: d.x, y: d.impactY, life: Double.random(in: 1.8...3.6),
                                          kind: 2, seed: Double.random(in: 0...1), size: d.z)
                        drop.vy = Double.random(in: 14...36)
                        fx.append(drop)
                    }
                }
                d.x = Double.random(in: 0...w); d.y = Double.random(in: -80 ... -10)
                d.z = Double.random(in: 0.15...1.0)
                d.vy = 500 + 1100 * d.z * d.z
                d.vx = 0
                d.size = (0.8 + 2.2 * d.z) * sizeScale
                d.impactY = d.z > 0.72 ? Double.random(in: h * 0.15...h * 0.95) : 1e9
            }
            p[i] = d
        }
    }

    private func stepPetals(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var petal = p[i]
            petal.age += dt
            if petal.stuck > 0 {
                petal.stuck -= dt
                petal.y += 12 * dt          // slow slide down the glass
                if petal.stuck <= 0 { petal = makePetal(w: w, h: h, atTop: true) }
                p[i] = petal
                continue
            }
            petal.phase += petal.freq * dt
            // gust from cursor motion
            if let m = mouse {
                let dx = petal.x - m.x, dy = petal.y - m.y
                let dist = max(16, (dx * dx + dy * dy).squareRoot())
                if dist < 140 {
                    let force = (140 - dist) / 140
                    petal.vx += (mouseVel.dx * 6 + dx / dist * 60) * force * dt * 8
                    petal.vy += (mouseVel.dy * 6 + dy / dist * 30) * force * dt * 8
                    petal.spinV += force * 4 * dt * (petal.seed > 0.5 ? 1 : -1)
                }
            }
            if petal.mode == 0 {
                // pendulum sway: horizontal oscillation, tilt follows swing
                petal.x += (petal.amp * petal.freq * cos(petal.phase) + petal.vx) * dt * 3
                petal.y += (petal.vy * (0.75 + 0.25 * abs(sin(petal.phase))) ) * dt
                petal.spin = sin(petal.phase) * 0.7 + petal.spinV * 0.15
            } else {
                // spiral: corkscrew descent
                petal.x += (cos(petal.phase) * petal.amp * petal.freq + petal.vx) * dt * 2
                petal.y += (petal.vy + sin(petal.phase) * 14) * dt
                petal.spin += (petal.spinV + 2.2) * dt
            }
            petal.vx *= 0.965; petal.vy = max(petal.vy * 0.995, 20)
            // random chance a near petal sticks to the glass
            if petal.z > 0.85, petal.stuck == 0, Double.random(in: 0...1) < 0.0009 {
                petal.stuck = 1.4
            }
            // settle at the bottom, then recycle
            if petal.y > h - 4 {
                petal.y = h - 4
                petal.vy = 0
                petal.age += dt * 2
                if petal.age.truncatingRemainder(dividingBy: 1000) > 3 || petal.age > 3 {
                    petal = makePetal(w: w, h: h, atTop: true)
                }
            }
            if petal.x < -40 { petal.x = w + 30 }
            if petal.x > w + 40 { petal.x = -30 }
            p[i] = petal
        }
    }

    private func stepSnow(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        let buckets = accum.count
        for i in p.indices {
            var f = p[i]
            if f.stuck > 0 {
                f.stuck -= dt
                f.y += 6 * dt
                if f.stuck <= 0 { f = respawnFlake(w: w) }
                p[i] = f; continue
            }
            f.phase += f.freq * dt
            f.vx *= 0.96; f.vy = min(f.vy + 14 * dt, 18 + 60 * f.z)
            // cursor vortex
            if let m = mouse {
                let dx = f.x - m.x, dy = f.y - m.y
                let dist = max(12, (dx * dx + dy * dy).squareRoot())
                if dist < 130 {
                    let force = (130 - dist) / 130
                    f.vx += (-dy / dist * 130 + dx / dist * 40) * force * dt * 6
                    f.vy += (dx / dist * 90) * force * dt * 4
                }
            }
            f.x += (sin(f.phase) * f.amp * 0.6 + f.vx) * dt * 2.4
            f.y += f.vy * dt
            // glass crystal
            if f.z > 0.88, Double.random(in: 0...1) < 0.0007 {
                appendFX(Effect(x: f.x, y: f.y, life: 1.4, kind: 3, seed: f.seed, size: f.z))
                f = respawnFlake(w: w)
                p[i] = f; continue
            }
            // land on the accumulated snow
            let bucket = min(buckets - 1, max(0, Int(f.x / w * Double(buckets))))
            let ground = h - accum[bucket]
            if f.y >= ground {
                accum[bucket] = min(accum[bucket] + f.size * 0.55, 30)
                // smooth into neighbors
                if bucket > 0 { accum[bucket - 1] = min(accum[bucket - 1] + f.size * 0.2, 30) }
                if bucket < buckets - 1 { accum[bucket + 1] = min(accum[bucket + 1] + f.size * 0.2, 30) }
                f = respawnFlake(w: w)
            }
            if f.x < -20 { f.x = w + 10 }; if f.x > w + 20 { f.x = -10 }
            p[i] = f
        }
        // slow melt
        for i in accum.indices { accum[i] = max(0, accum[i] - dt * 0.35) }
    }

    private func respawnFlake(w: Double) -> P {
        var f = P()
        f.z = Double.random(in: 0.1...1.0); f.x = Double.random(in: 0...w)
        f.y = Double.random(in: -40 ... -6)
        f.vy = 18 + 60 * f.z; f.amp = Double.random(in: 8...30); f.freq = Double.random(in: 0.3...1.0)
        f.phase = Double.random(in: 0...6.28); f.size = (1 + 2.6 * f.z) * sizeScale; f.seed = Double.random(in: 0...1)
        return f
    }

    private func stepOcean(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        // bubbles
        for i in p.indices {
            var b = p[i]
            b.phase += b.freq * dt
            if let m = mouse {
                let dx = b.x - m.x, dy = b.y - m.y
                let dist = max(12, (dx * dx + dy * dy).squareRoot())
                if dist < 110 {
                    let force = (110 - dist) / 110
                    b.vx += dx / dist * 140 * force * dt * 4
                }
            }
            b.vx *= 0.95
            b.x += (sin(b.phase) * b.amp * 0.5 + b.vx) * dt * 2
            b.y += b.vy * dt
            if b.y < -12 {
                appendFX(Effect(x: b.x, y: 8, life: 0.35, kind: 1, seed: b.seed, size: 0.5))
                b.x = Double.random(in: 0...w); b.y = h + Double.random(in: 4...40)
                b.z = Double.random(in: 0.2...1); b.vy = -(20 + 50 * b.z); b.vx = 0
                b.size = (2.5 + 8 * b.z) * sizeScale
            }
            p[i] = b
        }
        // shark lifecycle
        if !sharkActive, lastT > nextShark {
            sharkActive = true
            let fromLeft = Bool.random()
            shark = Agent()
            shark.size = min(w * 0.13, 190)
            shark.x = fromLeft ? -shark.size * 2 : w + shark.size * 2
            shark.y = Double.random(in: h * 0.22...h * 0.6)
            shark.vx = (fromLeft ? 1 : -1) * Double.random(in: 90...130)
            shark.phase = Double.random(in: 0...6.28)
        }
        if sharkActive {
            shark.x += shark.vx * dt
            shark.y += sin(lastT * 0.8 + shark.phase) * 10 * dt
            if shark.x < -shark.size * 2.5 || shark.x > w + shark.size * 2.5 {
                sharkActive = false
                nextShark = lastT + Double.random(in: 16...34)
            }
        }
        // fish steering
        for i in agents.indices {
            var f = agents[i]
            f.phase += dt * 6
            var ax = 0.0, ay = 0.0
            // wander
            ax += sin(lastT * 0.7 + f.phase) * 18
            ay += sin(lastT * 0.5 + f.phase * 1.3) * 12
            // flee cursor
            if let m = mouse {
                let dx = f.x - m.x, dy = f.y - m.y
                let dist = max(18, (dx * dx + dy * dy).squareRoot())
                if dist < 140 {
                    let force = (140 - dist) / 140
                    ax += dx / dist * 480 * force
                    ay += dy / dist * 300 * force
                }
            }
            // flee shark
            if sharkActive {
                let dx = f.x - shark.x, dy = f.y - shark.y
                let dist = max(24, (dx * dx + dy * dy).squareRoot())
                if dist < 220 {
                    let force = (220 - dist) / 220
                    ax += dx / dist * 600 * force
                    ay += dy / dist * 380 * force
                }
            }
            f.vx += ax * dt; f.vy += ay * dt
            // keep a cruising speed, cap panic speed
            let speed = max(10, (f.vx * f.vx + f.vy * f.vy).squareRoot())
            let target = min(max(speed, 34), 260)
            f.vx = f.vx / speed * target
            f.vy = f.vy / speed * target * 0.7
            f.vy *= 0.98
            f.x += f.vx * dt; f.y += f.vy * dt
            // soft vertical bounds, horizontal wrap
            if f.y < h * 0.08 { f.vy += 60 * dt; f.y = max(f.y, h * 0.04) }
            if f.y > h * 0.9 { f.vy -= 60 * dt; f.y = min(f.y, h * 0.95) }
            if f.x < -60 { f.x = w + 50 }; if f.x > w + 60 { f.x = -50 }
            agents[i] = f
        }
    }

    private func stepPond(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var leaf = p[i]
            leaf.phase += leaf.freq * dt
            leaf.spin += leaf.spinV * dt
            // lazy circular current
            leaf.vx += sin(t * 0.08 + leaf.seed * 6.28) * 1.2 * dt
            leaf.vy += cos(t * 0.07 + leaf.seed * 6.28) * 1.2 * dt
            // cursor wake pushes leaves as you sweep over the water
            if let m = mouse {
                let dx = leaf.x - m.x, dy = leaf.y - m.y
                let dist = max(14, (dx * dx + dy * dy).squareRoot())
                if dist < 110 {
                    let force = (110 - dist) / 110
                    leaf.vx += (mouseVel.dx * 5 + dx / dist * 26) * force * dt * 7
                    leaf.vy += (mouseVel.dy * 5 + dy / dist * 26) * force * dt * 7
                    leaf.spinV += force * 0.5 * dt * (leaf.seed > 0.5 ? 1 : -1)
                }
            }
            leaf.vx *= 0.975; leaf.vy *= 0.975
            leaf.spinV *= 0.985
            leaf.x += leaf.vx * dt; leaf.y += leaf.vy * dt
            if leaf.x < -20 { leaf.x = w + 14 }; if leaf.x > w + 20 { leaf.x = -14 }
            if leaf.y < -20 { leaf.y = h + 14 }; if leaf.y > h + 20 { leaf.y = -14 }
            p[i] = leaf
        }
        // ambient raindrop ripples on the water
        if Double.random(in: 0...1) < dt / 2.4 {
            appendFX(Effect(x: Double.random(in: 0...w), y: Double.random(in: 0...h),
                             life: 1.0, kind: 1, seed: Double.random(in: 0...1),
                             size: Double.random(in: 0.4...1.0)))
        }
        // a fast cursor sweep leaves a trail of tiny ripples
        let speed = (mouseVel.dx * mouseVel.dx + mouseVel.dy * mouseVel.dy).squareRoot()
        if let m = mouse, speed > 16, Double.random(in: 0...1) < dt * 6 {
            appendFX(Effect(x: m.x, y: m.y, life: 0.5, kind: 1,
                             seed: Double.random(in: 0...1), size: 0.35))
        }
    }

    private func stepMatrix(_ dt: Double, _ t: Double) {
        let h = sz.height
        for i in streams.indices {
            streams[i].y += streams[i].vy * dt
            if streams[i].y - streams[i].size * 16 > h {
                streams[i].y = Double.random(in: -h * 0.4 ... -20)
                streams[i].vy = 90 + Double.random(in: 0...190)
                streams[i].size = 8 + Double.random(in: 0...10)
                streams[i].seed = Double.random(in: 0...1)
            }
        }
        for i in fx.indices where fx[i].kind == 4 {
            fx[i].x += fx[i].vx * dt
            fx[i].y += fx[i].vy * dt
        }
        // ambient 3D glyph pop
        if Double.random(in: 0...1) < dt * 0.5 {
            let glyphs = Array("ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘｱ01")
            var e = Effect(x: Double.random(in: 0...sz.width), y: Double.random(in: 0...h),
                           life: 1.1, kind: 4, seed: Double.random(in: 0...1))
            e.size = 0.7
            e.ch = glyphs.randomElement()!
            fx.append(e)
        }
    }

    private func stepStars(_ dt: Double, _ t: Double) {
        let w = sz.width
        for i in p.indices {
            p[i].phase += p[i].freq * dt
            p[i].x += (4 + 10 * p[i].z) * dt      // slow parallax drift
            if p[i].x > w + 4 { p[i].x = -4 }
        }
        for i in fx.indices where fx[i].kind == 5 || fx[i].kind == 0 {
            fx[i].x += fx[i].vx * dt
            fx[i].y += fx[i].vy * dt
        }
        // ambient shooting star
        if Double.random(in: 0...1) < dt / 6 {
            var e = Effect(x: Double.random(in: 0...w * 0.7), y: Double.random(in: 0...sz.height * 0.4),
                           life: 0.9, kind: 5, seed: Double.random(in: 0...1), size: 0.8)
            e.vx = Double.random(in: 180...300); e.vy = Double.random(in: 70...130)
            fx.append(e)
        }
    }

    private func stepFireflies(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var f = p[i]
            f.phase += f.freq * dt
            var ax = sin(t * 0.5 + f.seed * 6.28) * 10
            var ay = cos(t * 0.4 + f.seed * 6.28) * 8
            if let m = mouse {
                // gently gather around the cursor, orbiting it
                let dx = m.x - f.x, dy = m.y - f.y
                let dist = max(30, (dx * dx + dy * dy).squareRoot())
                if dist < 240 {
                    let force = (240 - dist) / 240
                    ax += (dx / dist * 60 + -dy / dist * 50) * force
                    ay += (dy / dist * 60 + dx / dist * 50) * force
                }
            }
            f.vx = (f.vx + ax * dt) * 0.985
            f.vy = (f.vy + ay * dt) * 0.985
            f.x += f.vx * dt; f.y += f.vy * dt
            if f.x < -10 { f.x = w + 8 }; if f.x > w + 10 { f.x = -8 }
            if f.y < -10 { f.y = h + 8 }; if f.y > h + 10 { f.y = -8 }
            p[i] = f
        }
        // bats
        for i in agents.indices {
            var b = agents[i]
            b.phase += dt * 9
            if let m = mouse {
                let dy = b.y - m.y
                if abs(b.x - m.x) < 120, abs(dy) < 120 { b.vy += (dy < 0 ? -1 : 1) * 60 * dt }
            }
            b.vy *= 0.98
            b.x += b.vx * dt
            b.y += (sin(lastT * 1.3 + b.phase) * 16 + b.vy) * dt
            if b.x < -60 { b.x = w + 40; b.y = Double.random(in: h * 0.05...h * 0.45) }
            if b.x > w + 60 { b.x = -40; b.y = Double.random(in: h * 0.05...h * 0.45) }
            agents[i] = b
        }
    }

    private func stepDust(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(10, (dx * dx + dy * dy).squareRoot())
                if dist < 120 {
                    let force = (120 - dist) / 120
                    d.vx += (mouseVel.dx * 3 + -dy / dist * 40) * force * dt * 6
                    d.vy += (mouseVel.dy * 3 + dx / dist * 40) * force * dt * 6
                }
            }
            d.vx *= 0.97; d.vy *= 0.97
            d.x += (sin(d.phase) * 6 + d.vx) * dt * 2
            d.y += (cos(d.phase * 0.8) * 5 + d.vy) * dt * 2
            if d.x < -8 { d.x = w + 6 }; if d.x > w + 8 { d.x = -6 }
            if d.y < -8 { d.y = h + 6 }; if d.y > h + 8 { d.y = -6 }
            p[i] = d
        }
    }

    private func stepGravity(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var s = p[i]
            s.phase += s.freq * dt
            // ambient drift
            s.vx += sin(t * 0.2 + s.seed * 6.28) * 3 * dt
            s.vy += cos(t * 0.16 + s.seed * 6.28) * 3 * dt
            // the cursor is a gravity well: pull + tangential swirl = accretion orbit
            if let m = mouse {
                let dx = m.x - s.x, dy = m.y - s.y
                let dist = max(26, (dx * dx + dy * dy).squareRoot())
                if dist < 300 {
                    let g = 46_000 / (dist * dist)          // inverse-square pull
                    let ux = dx / dist, uy = dy / dist
                    s.vx += (ux * g + -uy * g * 0.85) * dt * 4
                    s.vy += (uy * g + ux * g * 0.85) * dt * 4
                }
            }
            // drag keeps orbits stable
            s.vx *= 0.985; s.vy *= 0.985
            s.x += s.vx * dt; s.y += s.vy * dt
            if s.x < -14 { s.x = w + 10 }; if s.x > w + 14 { s.x = -10 }
            if s.y < -14 { s.y = h + 10 }; if s.y > h + 14 { s.y = -10 }
            p[i] = s
        }
    }

    private func stepPixel(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var q = p[i]
            q.phase += q.freq * dt
            if let m = mouse {
                let dx = q.x - m.x, dy = q.y - m.y
                let dist = max(12, (dx * dx + dy * dy).squareRoot())
                if dist < 110 {
                    let force = (110 - dist) / 110
                    q.vx += dx / dist * 130 * force * dt * 5
                    q.vy += dy / dist * 70 * force * dt * 5
                }
            }
            q.vx *= 0.96
            q.x += (sin(q.phase) * 8 + q.vx) * dt * 2
            q.y += (q.vy + 14 + 40 * q.z) * dt * 0.5 + q.vy * dt * 0.5
            if q.y > h + 8 {
                q.x = Double.random(in: 0...w); q.y = Double.random(in: -30 ... -6)
                q.vx = 0; q.vy = 0
                q.z = Double.random(in: 0.2...1)
                q.size = Double(Int.random(in: 1...3)) * 2 * sizeScale
            }
            if q.x < -8 { q.x = w + 6 }; if q.x > w + 8 { q.x = -6 }
            p[i] = q
        }
        // firework sparks fall with gravity
        for i in fx.indices where fx[i].kind == 6 {
            fx[i].vy += 220 * dt
            fx[i].x += fx[i].vx * dt
            fx[i].y += fx[i].vy * dt
        }
    }

    private func stepEmbers(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(10, (dx * dx + dy * dy).squareRoot())
                if dist < 120 {
                    let force = (120 - dist) / 120
                    d.vx += (mouseVel.dx * 3 + dx / dist * 50) * force * dt * 6
                    d.vy += dy / dist * 40 * force * dt * 6
                }
            }
            d.vx *= 0.97; d.vy *= 0.99
            d.vy = min(d.vy, -4)
            d.x += (sin(d.phase) * 6 + d.vx) * dt * 2
            d.y += d.vy * dt
            if d.y < -10 {
                d.x = Double.random(in: 0...w); d.y = h + Double.random(in: 4...20)
                d.vy = -(10 + 30 * d.z); d.vx = 0
            }
            if d.x < -8 { d.x = w + 6 }; if d.x > w + 8 { d.x = -6 }
            p[i] = d
        }
    }

    private func stepBokeh(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(14, (dx * dx + dy * dy).squareRoot())
                if dist < 160 {
                    let force = (160 - dist) / 160
                    d.vx += (mouseVel.dx * 2 + -dy / dist * 20) * force * dt * 4
                    d.vy += (mouseVel.dy * 2 + dx / dist * 20) * force * dt * 4
                }
            }
            d.vx *= 0.99; d.vy *= 0.99
            d.x += (sin(d.phase) * 3 + d.vx) * dt
            d.y += (cos(d.phase * 0.7) * 2 + d.vy) * dt
            if d.x < -d.size { d.x = w + d.size }; if d.x > w + d.size { d.x = -d.size }
            if d.y < -d.size { d.y = h + d.size }; if d.y > h + d.size { d.y = -d.size }
            p[i] = d
        }
    }

    private func stepSparkle(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            d.x += d.vx * dt; d.y += d.vy * dt
            d.vx *= 0.99; d.vy *= 0.99
            if d.x < -4 { d.x = w + 2 }; if d.x > w + 4 { d.x = -2 }
            if d.y < -4 { d.y = h + 2 }; if d.y > h + 4 { d.y = -2 }
            let burst = abs(sin(d.phase))
            if burst < 0.05, Double.random(in: 0...1) < 0.02 {
                d.x = Double.random(in: 0...w); d.y = Double.random(in: 0...h)
                d.phase = Double.random(in: 0...6.28)
            }
            p[i] = d
        }
    }

    private func stepConfetti(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var q = p[i]
            q.phase += q.freq * dt
            q.spin += q.spinV * dt
            if let m = mouse {
                let dx = q.x - m.x, dy = q.y - m.y
                let dist = max(12, (dx * dx + dy * dy).squareRoot())
                if dist < 130 {
                    let force = (130 - dist) / 130
                    q.vx += dx / dist * 120 * force * dt * 5
                    q.vy += dy / dist * 80 * force * dt * 5
                }
            }
            q.vx *= 0.97
            q.x += (sin(q.phase) * 10 + q.vx) * dt * 2
            q.y += q.vy * dt
            if q.y > h + 10 {
                q.x = Double.random(in: 0...w); q.y = Double.random(in: -40 ... -6)
                q.vx = 0; q.vy = 20 + 50 * q.z
                q.spin = Double.random(in: 0...6.28)
            }
            if q.x < -10 { q.x = w + 8 }; if q.x > w + 10 { q.x = -8 }
            p[i] = q
        }
    }

    private func stepSmoke(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            d.age += dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(12, (dx * dx + dy * dy).squareRoot())
                if dist < 130 {
                    let force = (130 - dist) / 130
                    d.vx += (mouseVel.dx * 2 + dx / dist * 30) * force * dt * 5
                }
            }
            d.vx *= 0.98; d.vy *= 0.99
            d.vy = min(d.vy, -3)
            d.x += (sin(d.phase) * 4 + d.vx) * dt * 2
            d.y += d.vy * dt
            if d.y < -d.size * 2 {
                d.x = Double.random(in: 0...w); d.y = h + Double.random(in: 4...20)
                d.vy = -(8 + 18 * d.z); d.vx = 0; d.age = 0
                d.size = (4 + 6 * d.z) * sizeScale
            }
            if d.x < -d.size { d.x = w + d.size }; if d.x > w + d.size { d.x = -d.size }
            p[i] = d
        }
    }

    private func stepAurora(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            let sway = sin(t * 0.3 + d.seed * 6.28) * 40
            if let m = mouse {
                let dx = d.x - m.x
                if abs(dx) < 200 {
                    let force = (200 - abs(dx)) / 200
                    d.vx += (dx < 0 ? -1 : 1) * 20 * force * dt
                }
            }
            d.vx *= 0.96
            d.x += (sway * dt + d.vx * dt)
            d.y = min(d.y, h * 0.33)
            if d.x < -30 { d.x = w + 20 }; if d.x > w + 30 { d.x = -20 }
            p[i] = d
        }
    }

    private func stepLanterns(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(14, (dx * dx + dy * dy).squareRoot())
                if dist < 140 {
                    let force = (140 - dist) / 140
                    d.vx += dx / dist * 60 * force * dt * 5
                    d.vy += dy / dist * 40 * force * dt * 5
                }
            }
            d.vx *= 0.98; d.vy *= 0.99
            d.vy = min(d.vy, -2)
            d.x += (sin(d.phase) * 12 + d.vx) * dt
            d.y += d.vy * dt
            if d.y < -d.size * 2 {
                d.x = Double.random(in: 0...w); d.y = h + Double.random(in: 4...30)
                d.vy = -(6 + 14 * d.z); d.vx = 0
            }
            if d.x < -10 { d.x = w + 8 }; if d.x > w + 10 { d.x = -8 }
            p[i] = d
        }
    }

    private func stepFeathers(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var f = p[i]
            f.phase += f.freq * dt
            if let m = mouse {
                let dx = f.x - m.x, dy = f.y - m.y
                let dist = max(16, (dx * dx + dy * dy).squareRoot())
                if dist < 140 {
                    let force = (140 - dist) / 140
                    f.vx += (mouseVel.dx * 4 + dx / dist * 40) * force * dt * 6
                    f.vy += (mouseVel.dy * 4 + dy / dist * 20) * force * dt * 6
                    f.spinV += force * 2 * dt * (f.seed > 0.5 ? 1 : -1)
                }
            }
            f.x += (f.amp * f.freq * cos(f.phase) * 0.5 + f.vx) * dt * 2
            f.y += (f.vy * (0.8 + 0.2 * abs(sin(f.phase)))) * dt
            f.spin = sin(f.phase) * 0.5 + f.spinV * 0.1
            f.vx *= 0.96; f.vy = max(f.vy * 0.995, 10)
            if f.y > h + 10 {
                f.x = Double.random(in: 0...w); f.y = Double.random(in: -60 ... -10)
                f.vy = 14 + 28 * f.z; f.vx = 0
            }
            if f.x < -40 { f.x = w + 30 }; if f.x > w + 40 { f.x = -30 }
            p[i] = f
        }
    }

    private func stepRipples(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        if Double.random(in: 0...1) < dt / 1.8 {
            appendFX(Effect(x: Double.random(in: 0...w), y: Double.random(in: 0...h),
                             life: 1.2, kind: 1, seed: Double.random(in: 0...1),
                             size: Double.random(in: 0.5...1.4)))
        }
    }

    private func stepComet(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(14, (dx * dx + dy * dy).squareRoot())
                if dist < 180 {
                    d.vx += dx / dist * 200 * dt * 3
                    d.vy += dy / dist * 200 * dt * 3
                }
            }
            d.x += d.vx * dt; d.y += d.vy * dt
            if d.x < -20 || d.x > w + 20 || d.y < -20 || d.y > h + 20 {
                d.x = Double.random(in: 0...w); d.y = Double.random(in: 0...h)
                let a = Double.random(in: 0...6.28); let sp = Double.random(in: 160...340)
                d.vx = cos(a) * sp; d.vy = sin(a) * sp
            }
            p[i] = d
        }
        if Double.random(in: 0...1) < dt / 4 {
            var e = Effect(x: Double.random(in: 0...w * 0.7), y: Double.random(in: 0...h * 0.5),
                           life: 0.8, kind: 5, seed: Double.random(in: 0...1), size: 0.7)
            e.vx = Double.random(in: 150...280); e.vy = Double.random(in: 60...140)
            fx.append(e)
        }
    }

    private func stepFog(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(16, (dx * dx + dy * dy).squareRoot())
                if dist < 160 {
                    let force = (160 - dist) / 160
                    d.vx += (mouseVel.dx * 1.5 + dx / dist * 14) * force * dt * 4
                    d.vy += (mouseVel.dy * 1.5 + dy / dist * 14) * force * dt * 4
                }
            }
            d.vx *= 0.995; d.vy *= 0.995
            d.x += (sin(d.phase) * 2 + d.vx) * dt
            d.y += (cos(d.phase * 0.6) * 1.5 + d.vy) * dt
            if d.x < -d.size { d.x = w + d.size }; if d.x > w + d.size { d.x = -d.size }
            if d.y < -d.size { d.y = h + d.size }; if d.y > h + d.size { d.y = -d.size }
            p[i] = d
        }
    }

    private func stepGeometric(_ dt: Double, _ t: Double) {
        let w = sz.width, h = sz.height
        for i in p.indices {
            var d = p[i]
            d.phase += d.freq * dt
            d.spin += d.spinV * dt
            if let m = mouse {
                let dx = d.x - m.x, dy = d.y - m.y
                let dist = max(12, (dx * dx + dy * dy).squareRoot())
                if dist < 140 {
                    let force = (140 - dist) / 140
                    d.vx += (mouseVel.dx * 2 + -dy / dist * 30) * force * dt * 5
                    d.vy += (mouseVel.dy * 2 + dx / dist * 30) * force * dt * 5
                    d.spinV += force * 1.5 * dt * (d.seed > 0.5 ? 1 : -1)
                }
            }
            d.vx *= 0.98; d.vy *= 0.98
            d.x += (sin(d.phase) * 4 + d.vx) * dt * 2
            d.y += (cos(d.phase * 0.7) * 3 + d.vy) * dt * 2
            if d.x < -8 { d.x = w + 6 }; if d.x > w + 8 { d.x = -6 }
            if d.y < -8 { d.y = h + 6 }; if d.y > h + 8 { d.y = -6 }
            p[i] = d
        }
    }

    private func stepLightning(_ dt: Double, _ t: Double) {
        let w = sz.width
        for i in p.indices {
            p[i].phase += p[i].freq * dt
            p[i].x += (4 + 8 * p[i].z) * dt
            if p[i].x > w + 4 { p[i].x = -4 }
        }
        if Double.random(in: 0...1) < dt / 3.5 {
            appendFX(Effect(x: Double.random(in: 0...w), y: Double.random(in: 0...sz.height * 0.4),
                             life: 0.3, kind: 1, seed: Double.random(in: 0...1), size: Double.random(in: 2...5)))
        }
    }

    // MARK: drawing

    func draw(theme: Theme, ctx: GraphicsContext, size: CGSize) {
        switch style {
        case .neonRain:         drawRain(theme, ctx)
        case .petals, .leaves:  drawPetals(theme, ctx)
        case .snow:             drawSnow(theme, ctx)
        case .bubbles:          drawOcean(theme, ctx)
        case .pond:             drawPond(theme, ctx)
        case .matrix:           drawMatrix(theme, ctx)
        case .stars:            drawStars(theme, ctx)
        case .fireflies:        drawFireflies(theme, ctx)
        case .dust:             drawDust(theme, ctx)
        case .gravity:          drawGravity(theme, ctx)
        case .pixel:            drawPixel(theme, ctx)
        case .embers:           drawEmbers(theme, ctx)
        case .bokeh:            drawBokeh(theme, ctx)
        case .sparkle:          drawSparkle(theme, ctx)
        case .confetti:         drawConfetti(theme, ctx)
        case .smoke:            drawSmoke(theme, ctx)
        case .aurora:           drawAurora(theme, ctx)
        case .lanterns:         drawLanterns(theme, ctx)
        case .feathers:         drawFeathers(theme, ctx)
        case .ripples:          break
        case .comet:            drawComet(theme, ctx)
        case .fog:              drawFog(theme, ctx)
        case .geometric:        drawGeometric(theme, ctx)
        case .lightning:        drawLightning(theme, ctx)
        case .none: break
        }
        drawEffects(theme, ctx)
    }

    private func drawGravity(_ theme: Theme, _ ctx: GraphicsContext) {
        for s in p {
            let speed = (s.vx * s.vx + s.vy * s.vy).squareRoot()
            let heat = min(1, speed / 260)                    // fast = hot
            let color = heat > 0.55 ? theme.ringB : theme.ringA
            let twinkle = 0.35 + 0.65 * abs(sin(s.phase))
            if speed > 60 {
                // motion streak, like matter being dragged into orbit
                var streak = Path()
                streak.move(to: CGPoint(x: s.x - s.vx * 0.05, y: s.y - s.vy * 0.05))
                streak.addLine(to: CGPoint(x: s.x, y: s.y))
                ctx.stroke(streak, with: .color(color.opacity(0.25 + heat * 0.55)), lineWidth: s.size)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - s.size, y: s.y - s.size, width: s.size * 2, height: s.size * 2)),
                         with: .color(color.opacity(twinkle * (0.3 + 0.5 * s.z))))
            }
        }
        // faint event-horizon ring around the cursor
        if let m = mouse {
            ctx.stroke(Path(ellipseIn: CGRect(x: m.x - 26, y: m.y - 26, width: 52, height: 52)),
                       with: .color(theme.accent.opacity(0.14)), lineWidth: 8)
            ctx.stroke(Path(ellipseIn: CGRect(x: m.x - 20, y: m.y - 20, width: 40, height: 40)),
                       with: .color(theme.ringB.opacity(0.25)), lineWidth: 1.2)
        }
    }

    private func drawPixel(_ theme: Theme, _ ctx: GraphicsContext) {
        let palette: [Color] = [theme.ringA, theme.ringB, .white, theme.accent]
        for q in p {
            // snap to a chunky grid for the retro look
            let gx = (q.x / 2).rounded() * 2
            let gy = (q.y / 2).rounded() * 2
            let color = palette[Int(q.seed * 3.99)]
            let blink = q.phase.truncatingRemainder(dividingBy: 6.28) > 5.6 ? 0.2 : 1.0
            ctx.fill(Path(CGRect(x: gx, y: gy, width: q.size, height: q.size)),
                     with: .color(color.opacity((0.25 + 0.5 * q.z) * blink)))
        }
    }

    private func drawRain(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let len = 10 + 70 * d.z * d.z
            let color = d.seed > 0.66 ? theme.ringB : (d.seed > 0.33 ? theme.ringA : Color.white)
            var streak = Path()
            streak.move(to: CGPoint(x: d.x - d.vx * 0.02, y: d.y - len))
            streak.addLine(to: CGPoint(x: d.x, y: d.y))
            if d.z > 0.7 {
                // near drops keep the fading-tail gradient
                ctx.stroke(streak, with: .linearGradient(
                    Gradient(colors: [color.opacity(0), color.opacity(0.14 + 0.5 * d.z)]),
                    startPoint: CGPoint(x: d.x, y: d.y - len), endPoint: CGPoint(x: d.x, y: d.y)),
                    lineWidth: d.size)
            } else {
                // distant drops: flat stroke, indistinguishable at that size, far cheaper
                ctx.stroke(streak, with: .color(color.opacity(0.10 + 0.35 * d.z)), lineWidth: d.size)
            }
        }
    }

    private static let petalPinks: [UInt32] = [0xFFB7D5, 0xFF9EC9, 0xFFD1E3, 0xF78FB8]

    private func drawPetals(_ theme: Theme, _ ctx: GraphicsContext) {
        for petal in p {
            var c = ctx
            c.translateBy(x: petal.x, y: petal.y)
            c.rotate(by: .radians(petal.spin))
            let squash = petal.stuck > 0 ? 0.55 : (petal.mode == 1 ? 0.5 + 0.5 * abs(sin(petal.phase * 2)) : 1.0)
            var alpha = 0.55 + petal.seed * 0.4
            if petal.stuck > 0 { alpha = min(1, petal.stuck) * 0.9 }
            c.opacity = alpha
            if style == .leaves {
                c.scaleBy(x: 1, y: squash)
                let glyph = petal.seed > 0.55 ? "🍁" : "🍂"
                // cache resolved emoji per (glyph, size) — text shaping every
                // frame for 40 leaves was pure waste
                let key = "\(glyph)\(Int(petal.size * 4))"
                let resolved: GraphicsContext.ResolvedText
                if let hit = textCache[key] {
                    resolved = hit
                } else {
                    resolved = ctx.resolve(Text(verbatim: glyph).font(.system(size: petal.size)))
                    textCache[key] = resolved
                }
                c.draw(resolved, at: .zero)
            } else {
                // a single petal: pointed teardrop, flutter via width squash
                c.scaleBy(x: squash, y: 1)
                let half = petal.size * 0.5
                var shape = Path()
                shape.move(to: CGPoint(x: 0, y: -half))
                shape.addQuadCurve(to: CGPoint(x: 0, y: half),
                                   control: CGPoint(x: half * 0.78, y: half * 0.1))
                shape.addQuadCurve(to: CGPoint(x: 0, y: -half),
                                   control: CGPoint(x: -half * 0.62, y: -half * 0.1))
                let pink = Color(hex: Self.petalPinks[Int(petal.seed * 3.99)])
                c.fill(shape, with: .color(pink))
                // pale heart of the petal
                c.fill(Path(ellipseIn: CGRect(x: -half * 0.18, y: -half * 0.3, width: half * 0.36, height: half * 0.6)),
                       with: .color(.white.opacity(0.28)))
            }
        }
    }

    private static let pondGreens: [UInt32] = [0x2E6B4F, 0x3E8A5F, 0x1F5D4A, 0x4FA97A]

    private func drawPond(_ theme: Theme, _ ctx: GraphicsContext) {
        for leaf in p {
            var c = ctx
            c.translateBy(x: leaf.x, y: leaf.y)
            c.rotate(by: .radians(leaf.spin))
            let bob = 1 + 0.06 * sin(leaf.phase)
            c.scaleBy(x: bob, y: bob * 0.94)
            let green = Color(hex: Self.pondGreens[Int(leaf.seed * 3.99)])
            let wHalf = leaf.size * 0.62, hHalf = leaf.size * 0.42
            c.fill(Path(ellipseIn: CGRect(x: -wHalf, y: -hHalf, width: wHalf * 2, height: hHalf * 2)),
                   with: .color(green.opacity(0.55 + 0.3 * leaf.z)))
            // vein + notch so it reads as a leaf, not a blob
            var vein = Path()
            vein.move(to: CGPoint(x: -wHalf * 0.85, y: 0))
            vein.addLine(to: CGPoint(x: wHalf * 0.85, y: 0))
            c.stroke(vein, with: .color(.black.opacity(0.18)), lineWidth: 0.8)
            // faint water highlight around the floating edge
            c.stroke(Path(ellipseIn: CGRect(x: -wHalf, y: -hHalf, width: wHalf * 2, height: hHalf * 2)),
                     with: .color(theme.ringB.opacity(0.14)), lineWidth: 1)
        }
    }

    private func drawSnow(_ theme: Theme, _ ctx: GraphicsContext) {
        for f in p {
            ctx.fill(Path(ellipseIn: CGRect(x: f.x - f.size, y: f.y - f.size, width: f.size * 2, height: f.size * 2)),
                     with: .color(.white.opacity(0.25 + 0.55 * f.z)))
        }
        // accumulated snow mound along the bottom
        let w = sz.width, h = sz.height
        guard accum.contains(where: { $0 > 0.5 }) else { return }
        var mound = Path()
        mound.move(to: CGPoint(x: 0, y: h))
        mound.addLine(to: CGPoint(x: 0, y: h - accum.first!))
        let step = w / Double(accum.count - 1)
        for i in 1..<accum.count {
            let x = Double(i) * step
            let midX = x - step / 2
            mound.addQuadCurve(to: CGPoint(x: x, y: h - accum[i]),
                               control: CGPoint(x: midX, y: h - (accum[i - 1] + accum[i]) / 2 - 2))
        }
        mound.addLine(to: CGPoint(x: w, y: h))
        mound.closeSubpath()
        ctx.fill(mound, with: .color(.white.opacity(0.55)))
    }

    private func drawOcean(_ theme: Theme, _ ctx: GraphicsContext) {
        for b in p {
            ctx.stroke(Path(ellipseIn: CGRect(x: b.x - b.size, y: b.y - b.size, width: b.size * 2, height: b.size * 2)),
                       with: .color(.white.opacity(0.16 + 0.3 * b.z)), lineWidth: 1.1)
            ctx.fill(Path(ellipseIn: CGRect(x: b.x - b.size * 0.35, y: b.y - b.size * 0.55, width: b.size * 0.4, height: b.size * 0.4)),
                     with: .color(.white.opacity(0.3)))
        }
        // shark silhouette
        if sharkActive {
            var c = ctx
            c.translateBy(x: shark.x, y: shark.y)
            c.scaleBy(x: shark.vx > 0 ? 1 : -1, y: 1)
            let s = shark.size
            let ink = Color.black.opacity(0.5)
            var body = Path()
            body.move(to: CGPoint(x: -s, y: 0))
            body.addQuadCurve(to: CGPoint(x: s * 0.7, y: -s * 0.04), control: CGPoint(x: -s * 0.1, y: -s * 0.34))
            body.addQuadCurve(to: CGPoint(x: -s, y: 0), control: CGPoint(x: -s * 0.1, y: s * 0.26))
            c.fill(body, with: .color(ink))
            var fin = Path()   // dorsal
            fin.move(to: CGPoint(x: -s * 0.18, y: -s * 0.2))
            fin.addLine(to: CGPoint(x: s * 0.02, y: -s * 0.48))
            fin.addLine(to: CGPoint(x: s * 0.16, y: -s * 0.18))
            fin.closeSubpath()
            c.fill(fin, with: .color(ink))
            let wag = sin(lastT * 4 + shark.phase) * s * 0.12
            var tail = Path()
            tail.move(to: CGPoint(x: -s * 0.94, y: 0))
            tail.addLine(to: CGPoint(x: -s * 1.3, y: -s * 0.3 + wag))
            tail.addLine(to: CGPoint(x: -s * 1.22, y: s * 0.16 + wag * 0.5))
            tail.closeSubpath()
            c.fill(tail, with: .color(ink))
        }
        // fish
        let palette: [(Color, Color)] = [
            (Color(hex: 0xFF7043), .white), (Color(hex: 0x4FC3F7), Color(hex: 0x0288D1)), (Color(hex: 0xFFD54F), Color(hex: 0xF57F17)),
        ]
        for f in agents {
            var c = ctx
            c.translateBy(x: f.x, y: f.y)
            c.scaleBy(x: f.vx > 0 ? 1 : -1, y: 1)
            let (body, accent) = palette[f.hue]
            let len = f.size
            c.fill(Path(ellipseIn: CGRect(x: -len / 2, y: -len * 0.22, width: len, height: len * 0.44)), with: .color(body.opacity(0.9)))
            let wag = sin(f.phase) * len * 0.12
            var tail = Path()
            tail.move(to: CGPoint(x: -len * 0.42, y: 0))
            tail.addLine(to: CGPoint(x: -len * 0.72, y: -len * 0.2 + wag))
            tail.addLine(to: CGPoint(x: -len * 0.72, y: len * 0.2 + wag))
            tail.closeSubpath()
            c.fill(tail, with: .color(body.opacity(0.75)))
            c.fill(Path(roundedRect: CGRect(x: -len * 0.05, y: -len * 0.2, width: len * 0.1, height: len * 0.4), cornerRadius: 2),
                   with: .color(accent.opacity(0.85)))
            c.fill(Path(ellipseIn: CGRect(x: len * 0.28, y: -len * 0.07, width: len * 0.08, height: len * 0.08)),
                   with: .color(.black.opacity(0.85)))
        }
    }

    private static let matrixGlyphs = Array("ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘｱﾎﾃﾏｹﾒｴｶｷﾑﾕﾗｾﾈｽﾀﾇ0123456789")

    private func drawMatrix(_ theme: Theme, _ ctx: GraphicsContext) {
        let glyphSize = 13.0 * sizeScale
        for s in streams {
            let trail = Int(s.size)
            for r in 0..<trail {
                let y = s.y - Double(r) * (glyphSize + 3)
                guard y > -20, y < sz.height + 20 else { continue }
                let flicker = Int((lastT * 7).rounded()) &+ Int(s.x) &* 31 &+ r &* 7
                let ch = Self.matrixGlyphs[abs(flicker) % Self.matrixGlyphs.count]
                let fade = 1.0 - Double(r) / Double(trail)
                var boost = 0.0
                if let m = mouse {
                    let dx = s.x - m.x, dy = y - m.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    if dist < 110 { boost = (110 - dist) / 110 * 0.6 }
                }
                let color: Color = r == 0 ? Color(hex: 0xD8FFE9) : theme.accent
                ctx.draw(
                    Text(String(ch)).font(.system(size: glyphSize + boost * 3, weight: .semibold, design: .monospaced))
                        .foregroundColor(color.opacity(min(1, 0.12 + fade * 0.7 + boost))),
                    at: CGPoint(x: s.x, y: y)
                )
            }
        }
    }

    private func drawStars(_ theme: Theme, _ ctx: GraphicsContext) {
        // cursor parallax: layers shift opposite the pointer for depth
        let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let offset = mouse.map { CGVector(dx: ($0.x - center.x), dy: ($0.y - center.y)) } ?? .zero
        for s in p {
            let px = s.x - offset.dx * 0.012 * s.z
            let py = s.y - offset.dy * 0.012 * s.z
            let twinkle = 0.3 + 0.7 * abs(sin(s.phase))
            let color = s.seed > 0.86 ? theme.ringB : .white
            ctx.fill(Path(ellipseIn: CGRect(x: px - s.size, y: py - s.size, width: s.size * 2, height: s.size * 2)),
                     with: .color(color.opacity(twinkle * (0.3 + 0.5 * s.z))))
        }
    }

    private func drawFireflies(_ theme: Theme, _ ctx: GraphicsContext) {
        for f in p {
            let pulse = 0.3 + 0.7 * abs(sin(f.phase * 3))
            let color = f.seed > 0.5 ? theme.ringA : theme.ringB
            for (mul, alpha) in [(4.0, 0.08), (2.2, 0.2), (1.0, 0.9)] {
                let radius = f.size * mul
                ctx.fill(Path(ellipseIn: CGRect(x: f.x - radius, y: f.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(color.opacity(alpha * pulse)))
            }
        }
        for b in agents {
            var c = ctx
            c.translateBy(x: b.x, y: b.y)
            let flap = sin(b.phase) * b.size * 0.6
            var bat = Path()
            bat.move(to: CGPoint(x: -b.size, y: -flap))
            bat.addQuadCurve(to: .zero, control: CGPoint(x: -b.size * 0.4, y: b.size * 0.4))
            bat.addQuadCurve(to: CGPoint(x: b.size, y: -flap), control: CGPoint(x: b.size * 0.4, y: b.size * 0.4))
            c.stroke(bat, with: .color(.black.opacity(0.75)), lineWidth: 2)
        }
    }

    private func drawDust(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let pulse = 0.35 + 0.65 * abs(sin(d.phase * 2))
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - d.size, y: d.y - d.size, width: d.size * 2, height: d.size * 2)),
                     with: .color(theme.ringB.opacity((0.1 + pulse * 0.3) * d.z)))
        }
    }

    private func drawEmbers(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let flicker = 0.4 + 0.6 * abs(sin(d.phase * 3))
            let color = d.seed > 0.5 ? Color(hex: 0xFF6B2B) : Color(hex: 0xFF9840)
            for (mul, alpha) in [(3.0, 0.06), (1.6, 0.2), (1.0, 0.8)] {
                let radius = d.size * mul
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - radius, y: d.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(color.opacity(alpha * flicker * d.z)))
            }
        }
    }

    private func drawBokeh(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let pulse = 0.7 + 0.3 * sin(d.phase)
            let color = d.seed > 0.6 ? theme.ringA : (d.seed > 0.3 ? theme.ringB : .white)
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - d.size, y: d.y - d.size, width: d.size * 2, height: d.size * 2)),
                     with: .color(color.opacity(0.06 + 0.08 * pulse * d.z)))
            ctx.stroke(Path(ellipseIn: CGRect(x: d.x - d.size, y: d.y - d.size, width: d.size * 2, height: d.size * 2)),
                       with: .color(color.opacity(0.12 + 0.1 * pulse * d.z)), lineWidth: 1.2)
        }
    }

    private func drawSparkle(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let burst = abs(sin(d.phase))
            let alpha = burst * burst * (0.4 + 0.6 * d.z)
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - d.size, y: d.y - d.size, width: d.size * 2, height: d.size * 2)),
                     with: .color(.white.opacity(alpha)))
            if burst > 0.8 {
                let cross = d.size * 3
                var h = Path(); h.move(to: CGPoint(x: d.x - cross, y: d.y)); h.addLine(to: CGPoint(x: d.x + cross, y: d.y))
                var v = Path(); v.move(to: CGPoint(x: d.x, y: d.y - cross)); v.addLine(to: CGPoint(x: d.x, y: d.y + cross))
                ctx.stroke(h, with: .color(.white.opacity(alpha * 0.4)), lineWidth: 0.6)
                ctx.stroke(v, with: .color(.white.opacity(alpha * 0.4)), lineWidth: 0.6)
            }
        }
    }

    private func drawConfetti(_ theme: Theme, _ ctx: GraphicsContext) {
        let palette: [Color] = [theme.ringA, theme.ringB, .white, theme.accent]
        for q in p {
            var c = ctx
            c.translateBy(x: q.x, y: q.y)
            c.rotate(by: .radians(q.spin))
            let squash = 0.4 + 0.6 * abs(sin(q.phase * 2))
            c.scaleBy(x: squash, y: 1)
            let color = palette[Int(q.seed * 3.99)]
            c.fill(Path(CGRect(x: -q.size * 0.5, y: -q.size, width: q.size, height: q.size * 2)),
                   with: .color(color.opacity(0.5 + 0.4 * q.z)))
        }
    }

    private func drawSmoke(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let expand = 1.0 + d.age * 0.08
            let radius = d.size * expand
            let fade = max(0, 1.0 - d.age * 0.06)
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - radius, y: d.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(theme.ringB.opacity(0.04 + 0.06 * d.z * fade)))
        }
    }

    private func drawAurora(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let sway = sin(d.phase) * 0.15
            var c = ctx
            c.translateBy(x: d.x, y: d.y)
            c.rotate(by: .radians(sway))
            let w = 6.0 + 4.0 * d.z
            let h = d.size
            let color = d.seed > 0.5 ? theme.ringA : theme.ringB
            c.fill(Path(CGRect(x: -w * 0.5, y: -h * 0.5, width: w, height: h)),
                   with: .color(color.opacity(0.06 + 0.08 * d.z)))
        }
    }

    private func drawLanterns(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let pulse = 0.6 + 0.4 * sin(d.phase)
            let color = d.seed > 0.5 ? Color(hex: 0xFFAA33) : Color(hex: 0xFF7733)
            for (mul, alpha) in [(3.0, 0.05), (1.8, 0.15), (1.0, 0.6)] {
                let rx = d.size * mul, ry = d.size * mul * 1.3
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - rx, y: d.y - ry, width: rx * 2, height: ry * 2)),
                         with: .color(color.opacity(alpha * pulse * d.z)))
            }
        }
    }

    private func drawFeathers(_ theme: Theme, _ ctx: GraphicsContext) {
        for f in p {
            var c = ctx
            c.translateBy(x: f.x, y: f.y)
            c.rotate(by: .radians(f.spin))
            let squash = 0.5 + 0.5 * abs(sin(f.phase * 1.5))
            c.scaleBy(x: squash, y: 1)
            let half = f.size * 0.5
            var shape = Path()
            shape.move(to: CGPoint(x: 0, y: -half))
            shape.addQuadCurve(to: CGPoint(x: 0, y: half),
                               control: CGPoint(x: half * 0.65, y: half * 0.1))
            shape.addQuadCurve(to: CGPoint(x: 0, y: -half),
                               control: CGPoint(x: -half * 0.5, y: -half * 0.1))
            let color = f.seed > 0.5 ? theme.ringA : theme.ringB
            c.fill(shape, with: .color(color.opacity(0.4 + 0.4 * f.z)))
            var vein = Path()
            vein.move(to: CGPoint(x: 0, y: -half * 0.8))
            vein.addLine(to: CGPoint(x: 0, y: half * 0.8))
            c.stroke(vein, with: .color(.white.opacity(0.2)), lineWidth: 0.6)
        }
    }

    private func drawComet(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let speed = (d.vx * d.vx + d.vy * d.vy).squareRoot()
            let trailLen = min(0.08, speed * 0.0003)
            var trail = Path()
            trail.move(to: CGPoint(x: d.x - d.vx * trailLen, y: d.y - d.vy * trailLen))
            trail.addLine(to: CGPoint(x: d.x, y: d.y))
            ctx.stroke(trail, with: .linearGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(0.6 + 0.3 * d.z)]),
                startPoint: CGPoint(x: d.x - d.vx * trailLen, y: d.y - d.vy * trailLen),
                endPoint: CGPoint(x: d.x, y: d.y)), lineWidth: d.size)
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - d.size, y: d.y - d.size, width: d.size * 2, height: d.size * 2)),
                     with: .color(.white.opacity(0.8)))
        }
    }

    private func drawFog(_ theme: Theme, _ ctx: GraphicsContext) {
        for d in p {
            let pulse = 0.8 + 0.2 * sin(d.phase)
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - d.size, y: d.y - d.size, width: d.size * 2, height: d.size * 2)),
                     with: .color(theme.ringB.opacity(0.02 + 0.03 * pulse * d.z)))
        }
    }

    private func drawGeometric(_ theme: Theme, _ ctx: GraphicsContext) {
        let palette: [Color] = [theme.ringA, theme.ringB, theme.accent]
        for d in p {
            var c = ctx
            c.translateBy(x: d.x, y: d.y)
            c.rotate(by: .radians(d.spin))
            let color = palette[Int(d.seed * 2.99)]
            let half = d.size * 0.5
            c.stroke(Path(CGRect(x: -half, y: -half, width: d.size, height: d.size)),
                     with: .color(color.opacity(0.2 + 0.3 * d.z)), lineWidth: 1)
        }
    }

    private func drawLightning(_ theme: Theme, _ ctx: GraphicsContext) {
        for s in p {
            let twinkle = 0.3 + 0.7 * abs(sin(s.phase))
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - s.size, y: s.y - s.size, width: s.size * 2, height: s.size * 2)),
                     with: .color(.white.opacity(twinkle * (0.3 + 0.5 * s.z))))
        }
    }

    private func drawEffects(_ theme: Theme, _ ctx: GraphicsContext) {
        for e in fx {
            guard e.age >= 0 else { continue }
            let progress = min(1, e.age / e.life)
            switch e.kind {
            case 0: // splat: central blob + spikes
                let radius = (3 + 9 * progress) * (0.5 + e.size)
                let alpha = (1 - progress) * 0.7
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1.6, y: e.y - 1.6, width: 3.2, height: 3.2)),
                         with: .color(.white.opacity(alpha)))
                for k in 0..<5 {
                    let a = e.seed * 6.28 + Double(k) / 5 * 6.28
                    let sx = e.x + cos(a) * radius, sy = e.y + sin(a) * radius * 0.6
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - 1, y: sy - 1, width: 2, height: 2)),
                             with: .color(.white.opacity(alpha * 0.8)))
                }
            case 1: // expanding ring
                let radius = (6 + 46 * progress) * e.size
                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - radius, y: e.y - radius * 0.6, width: radius * 2, height: radius * 1.2)),
                           with: .color(theme.ringA.opacity((1 - progress) * 0.6)), lineWidth: 1.6)
            case 2: // lens droplet sliding down the glass
                let y = e.y + e.vy * e.age
                let alpha = (1 - progress) * 0.5
                let radius = 2.4 + e.size * 2
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - radius * 0.7, y: y - radius, width: radius * 1.4, height: radius * 2)),
                         with: .color(.white.opacity(alpha * 0.35)))
                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - radius * 0.7, y: y - radius, width: radius * 1.4, height: radius * 2)),
                           with: .color(.white.opacity(alpha)), lineWidth: 0.8)
            case 3: // ice crystal on the glass
                let alpha = (1 - progress) * 0.85
                let arm = (4 + 5 * e.size) * (0.6 + 0.4 * progress)
                var c = ctx
                c.translateBy(x: e.x, y: e.y + progress * 6)
                c.rotate(by: .radians(e.seed * 6.28))
                for k in 0..<6 {
                    var armPath = Path()
                    armPath.move(to: .zero)
                    let a = Double(k) / 6 * 6.28
                    armPath.addLine(to: CGPoint(x: cos(a) * arm, y: sin(a) * arm))
                    c.stroke(armPath, with: .color(.white.opacity(alpha)), lineWidth: 1)
                }
            case 4: // matrix glyph zooming toward the viewer
                let scale = 1 + progress * 3 * e.size
                let alpha = (1 - progress) * 0.9
                ctx.draw(Text(String(e.ch)).font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent.opacity(alpha)),
                    at: CGPoint(x: e.x, y: e.y))
            case 5: // shooting star
                let x = e.x + e.vx * e.age, y = e.y + e.vy * e.age
                var trail = Path()
                trail.move(to: CGPoint(x: x - e.vx * 0.25, y: y - e.vy * 0.25))
                trail.addLine(to: CGPoint(x: x, y: y))
                ctx.stroke(trail, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity((1 - progress) * 0.9)]),
                    startPoint: CGPoint(x: x - e.vx * 0.25, y: y - e.vy * 0.25), endPoint: CGPoint(x: x, y: y)),
                    lineWidth: 1.6)
            case 6: // 8-bit firework spark
                let palette: [Color] = [theme.ringA, theme.ringB, .white, theme.accent]
                let gx = (e.x / 2).rounded() * 2
                let gy = (e.y / 2).rounded() * 2
                ctx.fill(Path(CGRect(x: gx, y: gy, width: e.size, height: e.size)),
                         with: .color(palette[Int(e.seed * 3.99)].opacity(1 - progress)))
            default: break
            }
        }
    }
}

// MARK: - View

extension Notification.Name {
    /// Tells the video layer to run a ripple distortion at a point (view coords).
    static let pomoVideoRipple = Notification.Name("PomoVideoRipple")
}

/// Holds one engine per active FX layer, created lazily.
@MainActor
private final class FXStack {
    private var engines: [ParticleStyle: FXEngine] = [:]

    func engine(for style: ParticleStyle) -> FXEngine {
        if let existing = engines[style] { return existing }
        let fresh = FXEngine(style: style)
        engines[style] = fresh
        return fresh
    }

    func forEachActive(_ layers: [ParticleStyle], _ body: (FXEngine) -> Void) {
        for style in layers { body(engine(for: style)) }
    }
}

struct InteractiveFX: View {
    let theme: Theme
    let layers: [ParticleStyle]
    let interactive: Bool
    var density: Double = 1.0
    var sizeScale: Double = 1.0
    var paused: Bool = false
    var lowPower: Bool = false

    @State private var stack = FXStack()

    /// Fast motion (rain, sparks, orbits) needs 30fps; drifting ambience is
    /// indistinguishable at 24.
    private var frameInterval: Double {
        if lowPower { return 1.0 / 20 }
        return layers.contains { $0 == .neonRain || $0 == .pixel || $0 == .gravity } ? 1.0 / 30 : 1.0 / 24
    }

    /// Sky region above the dune crest — Mojave particles render only here,
    /// so sand and stars stay behind the dune instead of floating over it.
    private func duneSky(_ size: CGSize) -> Path {
        let w = size.width, h = size.height
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: h * 0.44))
        for step in 1...24 {
            let x = w * Double(step) / 24
            let crest = h * (0.44 - 0.14 * sin(.pi * Double(step) / 24))
            path.addLine(to: CGPoint(x: x, y: crest))
        }
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        return path
    }

    var body: some View {
        if !layers.isEmpty, ParticleStyle.caSupported.isSuperset(of: layers) {
            // CA-layer renderer: same sim, same visuals, ~zero SwiftUI cost
            FXLayerFX(theme: theme, styles: layers, interactive: interactive,
                      density: density, sizeScale: sizeScale, paused: paused,
                      lowPower: lowPower)
                .id(theme.id)   // rebuild layers on theme switch
        } else {
            canvasBody
        }
    }

    private var canvasBody: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
            Canvas { ctx, size in
                var context = ctx
                if theme.id == "desert" {
                    context.clip(to: duneSky(size))
                }
                stack.forEachActive(layers) { engine in
                    engine.density = density
                    engine.sizeScale = sizeScale
                    engine.step(theme: theme, date: timeline.date, size: size)
                    engine.draw(theme: theme, ctx: context, size: size)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard interactive else { return }
            switch phase {
            case .active(let point):
                stack.forEachActive(layers) { $0.setMouse(point) }
            case .ended:
                stack.forEachActive(layers) { $0.setMouse(nil) }
            }
        }
        .gesture(
            SpatialTapGesture().onEnded { value in
                guard interactive else { return }
                stack.forEachActive(layers) { $0.click(at: value.location) }
                NotificationCenter.default.post(
                    name: .pomoVideoRipple, object: nil,
                    userInfo: ["x": value.location.x, "y": value.location.y]
                )
            }
        )
    }
}
