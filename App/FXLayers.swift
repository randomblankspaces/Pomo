import SwiftUI
import AppKit

// Core Animation renderer for the particle FX. Same FXEngine sim; rendering
// is CALayers updated in one CATransaction per tick (render server composites,
// no SwiftUI graph work, no per-frame rasterization) and transient effects are
// fire-and-forget CABasicAnimations diffed off the engine's effect list.

extension ParticleStyle {
    static let caSupported: Set<ParticleStyle> =
        [.pond, .petals, .leaves, .neonRain, .stars, .snow, .fireflies, .dust, .gravity, .pixel,
         .embers, .bokeh, .sparkle, .confetti, .smoke, .lanterns, .feathers, .fog, .geometric,
         .comet, .ripples, .lightning, .aurora]

    /// Light-emitting styles composite additively so they read as glow against
    /// the backdrop instead of flat stickers with muddy alpha edges.
    var emitsLight: Bool {
        switch self {
        case .bokeh, .embers, .fireflies, .sparkle, .lanterns, .stars,
             .comet, .aurora, .lightning, .neonRain, .gravity:
            return true
        default:
            return false
        }
    }
}

struct FXLayerFX: NSViewRepresentable {
    let theme: Theme
    let styles: [ParticleStyle]
    let interactive: Bool
    let density: Double
    let sizeScale: Double
    let paused: Bool
    var lowPower: Bool = false

    func makeNSView(context: Context) -> FXLayerView { FXLayerView(theme: theme, styles: styles) }

    func updateNSView(_ view: FXLayerView, context: Context) {
        view.interactive = interactive
        view.density = density
        view.sizeScale = sizeScale
        view.setPaused(paused)
        view.setLowPower(lowPower)
    }
}

@MainActor
final class FXLayerView: NSView {
    private let theme: Theme
    private let styles: [ParticleStyle]
    private var engines: [FXEngine] = []
    private var particleLayers: [[CALayer]] = []
    private var agentLayers: [[CAShapeLayer]] = []
    private var moundLayers: [CAShapeLayer?] = []      // snow accumulation
    private var horizonLayer: CALayer?                 // gravity cursor ring
    private var lastFXUID = 0
    private var link: CADisplayLink?
    private var tracking: NSTrackingArea?
    private var moundSkip = 0

    var interactive = true
    var density = 1.0
    var sizeScale = 1.0

    init(theme: Theme, styles: [ParticleStyle]) {
        self.theme = theme
        self.styles = styles
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for style in styles {
            engines.append(FXEngine(style: style))
            particleLayers.append([])
            agentLayers.append([])
            moundLayers.append(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setPaused(_ paused: Bool) { link?.isPaused = paused }

    private var lowPower = false
    func setLowPower(_ low: Bool) {
        guard low != lowPower else { return }
        lowPower = low
        applyFrameRate()
    }

    /// Fixed rate at an exact vsync divisor (60Hz panel) so frames land evenly
    /// spaced. Manual elapsed-time gating juddered (alternating 2/3-frame gaps).
    /// Glass runs its slow dust drift at 20fps always — the primary theme
    /// should idle as light as possible, and the motion can't tell.
    private func applyFrameRate() {
        let fps: Float = (lowPower || theme.id == "glass") ? 20 : 30
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        link = l
        applyFrameRate()
        l.add(to: .main, forMode: .common)
    }

    deinit { link?.invalidate() }

    // MARK: input (engine expects top-left origin)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        let p = flip(convert(event.locationInWindow, from: nil))
        engines.forEach { $0.setMouse(p) }
    }

    override func mouseExited(with event: NSEvent) {
        engines.forEach { $0.setMouse(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        let p = flip(convert(event.locationInWindow, from: nil))
        engines.forEach { $0.click(at: p) }
        NotificationCenter.default.post(name: .pomoVideoRipple, object: nil,
                                        userInfo: ["x": p.x, "y": p.y])
    }

    // MARK: tick

    @objc private func tick(_ sender: CADisplayLink) {
        guard bounds.width > 10 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, engine) in engines.enumerated() {
            engine.density = density
            engine.sizeScale = sizeScale
            engine.step(theme: theme, date: Date(), size: bounds.size)
            syncLayers(i, engine: engine)
            applyParticles(i, engine: engine)
            applyAgents(i, engine: engine)
            if styles[i] == .snow { applyMound(i, engine: engine) }
            if styles[i] == .gravity { applyHorizon(engine: engine) }
            for e in engine.fxList where e.uid > lastFXUID {
                lastFXUID = max(lastFXUID, e.uid)
                spawnEffect(e, style: styles[i])
            }
        }
        CATransaction.commit()
    }

    // MARK: layer lifecycle

    private func syncLayers(_ i: Int, engine: FXEngine) {
        let ps = engine.particles
        if particleLayers[i].count != ps.count {
            particleLayers[i].forEach { $0.removeFromSuperlayer() }
            let additive = styles[i].emitsLight
            particleLayers[i] = ps.map { p in
                let l = makeParticleLayer(styles[i], p)
                if additive { l.compositingFilter = "plusL" }
                layer?.addSublayer(l)
                return l
            }
        }
        let ags = engine.agentList
        if agentLayers[i].count != ags.count {
            agentLayers[i].forEach { $0.removeFromSuperlayer() }
            agentLayers[i] = ags.map { _ in
                let l = CAShapeLayer()
                l.fillColor = nil
                l.strokeColor = NSColor.black.withAlphaComponent(0.75).cgColor
                l.lineWidth = 2
                layer?.addSublayer(l)
                return l
            }
        }
    }

    private func makeParticleLayer(_ style: ParticleStyle, _ p: P) -> CALayer {
        switch style {
        case .pond:
            let wHalf = p.size * 0.62, hHalf = p.size * 0.42
            let shape = CAShapeLayer()
            shape.path = CGPath(ellipseIn: CGRect(x: -wHalf, y: -hHalf, width: wHalf * 2, height: hHalf * 2), transform: nil)
            let green = NSColor(Color(hex: FXImages.pondGreens[Int(p.seed * 3.99)]))
            shape.fillColor = green.withAlphaComponent(0.55 + 0.3 * p.z).cgColor
            shape.strokeColor = NSColor(theme.ringB).withAlphaComponent(0.14).cgColor
            shape.lineWidth = 1
            let vein = CAShapeLayer()
            let vp = CGMutablePath()
            vp.move(to: CGPoint(x: -wHalf * 0.85, y: 0)); vp.addLine(to: CGPoint(x: wHalf * 0.85, y: 0))
            vein.path = vp
            vein.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
            vein.lineWidth = 0.8
            shape.addSublayer(vein)
            return shape
        case .petals:
            let half = p.size * 0.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: half))
            path.addQuadCurve(to: CGPoint(x: 0, y: -half), control: CGPoint(x: half * 0.78, y: -half * 0.1))
            path.addQuadCurve(to: CGPoint(x: 0, y: half), control: CGPoint(x: -half * 0.62, y: half * 0.1))
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = NSColor(Color(hex: FXImages.petalPinks[Int(p.seed * 3.99)])).cgColor
            let heart = CAShapeLayer()
            heart.path = CGPath(ellipseIn: CGRect(x: -half * 0.18, y: -half * 0.3, width: half * 0.36, height: half * 0.6), transform: nil)
            heart.fillColor = NSColor.white.withAlphaComponent(0.28).cgColor
            shape.addSublayer(heart)
            return shape
        case .leaves:
            let l = CALayer()
            let glyph = p.seed > 0.55 ? "🍁" : "🍂"
            let img = FXImages.emoji(glyph, size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .neonRain:
            return rainLayer(p)
        case .stars, .dust, .fireflies:
            let l = CALayer()
            let color: Color =
                style == .stars ? (p.seed > 0.86 ? theme.ringB : .white)
                : style == .dust ? theme.ringB
                : (p.seed > 0.5 ? theme.ringA : theme.ringB)
            let img: CGImage = {
                switch style {
                case .fireflies: return FXImages.firefly(NSColor(color), size: p.size)
                case .stars:     return FXImages.star(NSColor(color), size: p.size)
                default:         return FXImages.dustMote(NSColor(color), size: p.size)
                }
            }()
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .gravity:
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: 24, height: max(2, p.size * 2))
            return l   // contents swapped per tick (dot vs streak)
        case .pixel:
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: p.size, height: p.size)
            l.backgroundColor = NSColor(FXImages.pixelPalette(theme)[Int(p.seed * 3.99)]).cgColor
            l.magnificationFilter = .nearest
            return l
        case .snow:
            let l = CALayer()
            let img = FXImages.snowflake(size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .embers:
            let l = CALayer()
            let color = p.seed > 0.5 ? theme.ringA : theme.ringB
            let img = FXImages.ember(NSColor(color), size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            l.anchorPoint = CGPoint(x: 0.5, y: 0.8)
            return l
        case .bokeh:
            let l = CALayer()
            let color = p.seed > 0.6 ? theme.ringA : (p.seed > 0.3 ? theme.ringB : theme.accent)
            let img = FXImages.bokeh(NSColor(color), size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .sparkle:
            let l = CALayer()
            let color: Color = p.seed > 0.5 ? theme.ringA : .white
            let img = FXImages.sparkleFlare(NSColor(color), size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .confetti:
            let l = CALayer()
            let colors: [Color] = [theme.ringA, theme.ringB, theme.accent, .white]
            l.backgroundColor = NSColor(colors[Int(p.seed * 3.99)]).cgColor
            l.bounds = CGRect(x: 0, y: 0, width: p.size * 2.2, height: p.size)
            return l
        case .smoke:
            let l = CALayer()
            let img = FXImages.smokeWisp(NSColor(theme.ringB), size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .lanterns:
            let l = CALayer()
            let color = p.seed > 0.5 ? theme.ringA : theme.ringB
            let img = FXImages.lantern(NSColor(color), size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .feathers:
            let half = p.size * 0.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: half * 1.2))
            path.addQuadCurve(to: CGPoint(x: 0, y: -half * 1.2), control: CGPoint(x: half * 0.5, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: half * 1.2), control: CGPoint(x: -half * 0.3, y: 0))
            let shape = CAShapeLayer()
            shape.path = path
            let featherColor = p.seed > 0.5 ? theme.ringB : .white
            shape.fillColor = NSColor(featherColor).withAlphaComponent(0.55).cgColor
            let shaft = CAShapeLayer()
            let sp = CGMutablePath()
            sp.move(to: CGPoint(x: 0, y: -half)); sp.addLine(to: CGPoint(x: 0, y: half))
            shaft.path = sp
            shaft.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
            shaft.lineWidth = 0.6
            shape.addSublayer(shaft)
            return shape
        case .fog:
            let l = CALayer()
            let img = FXImages.fogWisp(NSColor(theme.ringB), size: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .geometric:
            let shape = CAShapeLayer()
            let s = p.size
            let sides = p.seed > 0.5 ? 6 : 3
            let path = CGMutablePath()
            for k in 0...sides {
                let a = Double(k) / Double(sides) * 6.28
                let pt = CGPoint(x: cos(a) * s, y: sin(a) * s)
                if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            shape.path = path
            shape.strokeColor = NSColor(theme.ringA).withAlphaComponent(0.4).cgColor
            shape.fillColor = NSColor(theme.ringB).withAlphaComponent(0.08).cgColor
            shape.lineWidth = 1
            return shape
        case .comet:
            let l = CALayer()
            let color: Color = p.seed > 0.5 ? theme.ringA : theme.ringB
            let length = 90 + 140 * p.z
            let img = FXImages.cometHead(NSColor(color), length: length, headSize: max(3, p.size * 1.6))
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            l.anchorPoint = CGPoint(x: 0.5, y: 0)  // head at 0 so rotation swings the tail
            return l
        case .ripples, .lightning:
            return CALayer()
        case .aurora:
            let l = CALayer()
            let color = p.seed > 0.5 ? theme.ringA : theme.ringB
            let img = FXImages.streak(NSColor(color), length: p.size, width: 6 + 10 * p.z,
                                      gradient: true, alpha: 0.18)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        default:
            return CALayer()
        }
    }

    private func rainLayer(_ p: P) -> CALayer {
        let len = 10 + 70 * p.z * p.z
        let color: Color = p.seed > 0.66 ? theme.ringB : (p.seed > 0.33 ? theme.ringA : .white)
        let alpha = p.z > 0.7 ? (0.14 + 0.5 * p.z) : (0.10 + 0.35 * p.z)
        let l = CALayer()
        let img = FXImages.streak(NSColor(color), length: len, width: p.size,
                                  gradient: p.z > 0.7, alpha: alpha)
        l.contents = img
        l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
        l.anchorPoint = CGPoint(x: 0.5, y: 0)   // bottom of streak = drop head
        return l
    }

    // MARK: per-tick application

    private func applyParticles(_ i: Int, engine: FXEngine) {
        let style = styles[i]
        let h = bounds.height
        let mouse = engine.mouse
        let center = CGPoint(x: bounds.width / 2, y: h / 2)
        for (j, p) in engine.particles.enumerated() where j < particleLayers[i].count {
            let l = particleLayers[i][j]
            switch style {
            case .pond:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let bob = 1 + 0.06 * sin(p.phase)
                var t = CATransform3DMakeRotation(-p.spin, 0, 0, 1)
                t = CATransform3DScale(t, bob, bob * 0.94, 1)
                l.transform = t
            case .petals:
                l.position = CGPoint(x: p.x, y: h - p.y)
                var alpha = 0.55 + p.seed * 0.4
                if p.stuck > 0 { alpha = min(1, p.stuck) * 0.9 }
                l.opacity = Float(alpha)
                let squash = p.stuck > 0 ? 0.55 : (p.mode == 1 ? 0.5 + 0.5 * abs(sin(p.phase * 2)) : 1.0)
                var t = CATransform3DMakeRotation(-p.spin, 0, 0, 1)
                t = CATransform3DScale(t, squash, 1, 1)
                l.transform = t
            case .leaves:
                l.position = CGPoint(x: p.x, y: h - p.y)
                var alpha = 0.55 + p.seed * 0.4
                if p.stuck > 0 { alpha = min(1, p.stuck) * 0.9 }
                l.opacity = Float(alpha)
                let squash = p.stuck > 0 ? 0.55 : (p.mode == 1 ? 0.5 + 0.5 * abs(sin(p.phase * 2)) : 1.0)
                var t = CATransform3DMakeRotation(-p.spin, 0, 0, 1)
                t = CATransform3DScale(t, 1, squash, 1)
                l.transform = t
            case .neonRain:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let len = 10 + 70 * p.z * p.z
                l.transform = CATransform3DMakeRotation(atan2(-p.vx * 0.02, len), 0, 0, 1)
            case .stars:
                var px = p.x, py = p.y
                if let m = mouse {
                    px -= (m.x - center.x) * 0.012 * p.z
                    py -= (m.y - center.y) * 0.012 * p.z
                }
                l.position = CGPoint(x: px, y: h - py)
                l.opacity = Float((0.3 + 0.7 * abs(sin(p.phase))) * (0.3 + 0.5 * p.z))
            case .snow:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float(0.25 + 0.55 * p.z)
            case .fireflies:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float(0.3 + 0.7 * abs(sin(p.phase * 3)))
            case .dust:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float((0.1 + (0.35 + 0.65 * abs(sin(p.phase * 2))) * 0.3) * p.z * 2.2)
            case .gravity:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let speed = (p.vx * p.vx + p.vy * p.vy).squareRoot()
                let heat = min(1, speed / 260)
                let color = NSColor(heat > 0.55 ? theme.ringB : theme.ringA)
                if speed > 60 {
                    let len = speed * 0.05
                    let img = FXImages.capsule(color)
                    l.contents = img
                    l.bounds = CGRect(x: 0, y: 0, width: len, height: p.size)
                    l.opacity = Float(0.25 + heat * 0.55)
                    l.transform = CATransform3DMakeRotation(atan2(-p.vy, p.vx), 0, 0, 1)
                } else {
                    let img = FXImages.dot(color, radius: p.size)
                    l.contents = img
                    l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
                    l.opacity = Float((0.35 + 0.65 * abs(sin(p.phase))) * (0.3 + 0.5 * p.z))
                    l.transform = CATransform3DIdentity
                }
            case .pixel:
                let g = 2.0 * sizeScale
                l.position = CGPoint(x: (p.x / g).rounded() * g, y: h - (p.y / g).rounded() * g)
                let blink = p.phase.truncatingRemainder(dividingBy: 6.28) > 5.6 ? 0.2 : 1.0
                l.opacity = Float((0.25 + 0.5 * p.z) * blink)
            case .embers:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let flicker = 0.4 + 0.6 * abs(sin(p.phase * 3.5))
                l.opacity = Float(flicker * (0.3 + 0.5 * p.z))
            case .bokeh:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let pulse = 0.78 + 0.22 * sin(p.phase * 0.8)
                // Near/large discs are more defocused, so they read dimmer than
                // the tight far ones — that contrast is what sells the depth.
                let depthFade = 1.0 - 0.45 * p.z
                l.opacity = Float(pulse * depthFade * 0.95)
                let s = 0.95 + 0.1 * sin(p.phase * 0.5)
                l.transform = CATransform3DMakeScale(s, s, 1)
            case .sparkle:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let burst = max(0, sin(p.phase * 2.5))
                l.opacity = Float(burst * burst * 0.9)
                let s = 0.5 + burst * 1.5
                l.transform = CATransform3DMakeScale(s, s, 1)
            case .confetti:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float(0.5 + 0.4 * p.z)
                let squash = 0.3 + 0.7 * abs(sin(p.phase * 2))
                var t = CATransform3DMakeRotation(-p.spin, 0, 0, 1)
                t = CATransform3DScale(t, squash, 1, 1)
                l.transform = t
            case .smoke:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let fade = max(0, 1 - p.age / p.life) * 0.25
                l.opacity = Float(fade)
                let expand = 1 + p.age * 0.15
                l.transform = CATransform3DMakeScale(expand, expand, 1)
            case .lanterns:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let pulse = 0.6 + 0.4 * sin(p.phase * 1.2)
                l.opacity = Float(pulse * 0.7)
            case .feathers:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float(0.4 + p.seed * 0.4)
                let squash = 0.6 + 0.4 * abs(sin(p.phase * 1.5))
                var t = CATransform3DMakeRotation(-p.spin, 0, 0, 1)
                t = CATransform3DScale(t, squash, 1, 1)
                l.transform = t
            case .fog:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let drift = 0.04 + 0.03 * sin(p.phase * 0.3)
                l.opacity = Float(drift)
            case .geometric:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float(0.25 + 0.25 * sin(p.phase))
                l.transform = CATransform3DMakeRotation(p.spin, 0, 0, 1)
            case .comet:
                l.position = CGPoint(x: p.x, y: h - p.y)
                l.opacity = Float(0.4 + 0.4 * p.z)
                l.transform = CATransform3DMakeRotation(atan2(-p.vy, p.vx) - .pi / 2, 0, 0, 1)
            case .aurora:
                l.position = CGPoint(x: p.x, y: h - p.y)
                let wave = 0.15 + 0.15 * sin(p.phase * 0.7)
                l.opacity = Float(wave)
                let sway = sin(p.phase * 0.4) * 0.12
                l.transform = CATransform3DMakeRotation(sway, 0, 0, 1)
            case .ripples, .lightning:
                break
            default: break
            }
        }
    }

    private func applyAgents(_ i: Int, engine: FXEngine) {
        guard styles[i] == .fireflies else { return }
        let h = bounds.height
        let t = CACurrentMediaTime()
        for (j, b) in engine.agentList.enumerated() where j < agentLayers[i].count {
            let l = agentLayers[i][j]
            let flap = sin(b.phase) * b.size * 0.6
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -b.size, y: flap))
            path.addQuadCurve(to: .zero, control: CGPoint(x: -b.size * 0.4, y: -b.size * 0.4))
            path.addQuadCurve(to: CGPoint(x: b.size, y: flap), control: CGPoint(x: b.size * 0.4, y: -b.size * 0.4))
            l.path = path
            l.position = CGPoint(x: b.x, y: h - b.y)
        }
        _ = t
    }

    private func applyMound(_ i: Int, engine: FXEngine) {
        moundSkip += 1
        guard moundSkip % 4 == 0 else { return }   // mound changes slowly
        let accum = engine.snowAccum
        guard accum.contains(where: { $0 > 0.5 }) else { moundLayers[i]?.isHidden = true; return }
        let mound: CAShapeLayer
        if let m = moundLayers[i] { mound = m } else {
            mound = CAShapeLayer()
            mound.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
            layer?.addSublayer(mound)
            moundLayers[i] = mound
        }
        mound.isHidden = false
        let w = bounds.width
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: accum[0]))
        let step = w / Double(accum.count - 1)
        for k in 1..<accum.count {
            let x = Double(k) * step
            path.addQuadCurve(to: CGPoint(x: x, y: accum[k]),
                              control: CGPoint(x: x - step / 2, y: (accum[k - 1] + accum[k]) / 2 + 2))
        }
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        mound.path = path
    }

    private func applyHorizon(engine: FXEngine) {
        if horizonLayer == nil {
            let l = CALayer()
            let img = FXImages.horizonRing(NSColor(theme.accent), inner: NSColor(theme.ringB))
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            layer?.addSublayer(l)
            horizonLayer = l
        }
        if let m = engine.mouse {
            horizonLayer?.isHidden = false
            horizonLayer?.position = CGPoint(x: m.x, y: bounds.height - m.y)
        } else {
            horizonLayer?.isHidden = true
        }
    }

    // MARK: transient effects → one-shot CA animations

    private func spawnEffect(_ e: Effect, style: ParticleStyle) {
        let delay = max(0, -e.age)
        let pos = CGPoint(x: e.x, y: bounds.height - e.y)
        switch e.kind {
        case 0:   // splat (static) or spark (has velocity)
            let moving = abs(e.vx) + abs(e.vy) > 1
            let l = CALayer()
            let img = moving ? FXImages.dot(.white, radius: 1.5 + e.size)
                             : FXImages.splat(seed: e.seed, size: 0.5 + e.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            oneShot(l, at: pos, delay: delay, life: e.life,
                    scaleTo: moving ? 1 : 2.2,
                    moveBy: moving ? CGVector(dx: e.vx * e.life, dy: -e.vy * e.life) : .zero,
                    fadeFrom: moving ? 0.9 : 0.7)
        case 1:   // expanding squashed ring
            let ring = CAShapeLayer()
            let r = 6.0 * max(0.2, e.size)
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r * 0.6, width: r * 2, height: r * 1.2), transform: nil)
            ring.strokeColor = NSColor(theme.ringA).cgColor
            ring.fillColor = nil
            ring.lineWidth = 1.6
            oneShot(ring, at: pos, delay: delay, life: e.life, scaleTo: (6 + 46) / 6, moveBy: .zero, fadeFrom: 0.6)
        case 2:   // lens droplet slides down
            let r = 2.4 + e.size * 2
            let drop = CAShapeLayer()
            drop.path = CGPath(ellipseIn: CGRect(x: -r * 0.7, y: -r, width: r * 1.4, height: r * 2), transform: nil)
            drop.fillColor = NSColor.white.withAlphaComponent(0.18).cgColor
            drop.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
            drop.lineWidth = 0.8
            oneShot(drop, at: pos, delay: delay, life: e.life, scaleTo: 1,
                    moveBy: CGVector(dx: 0, dy: -e.vy * e.life), fadeFrom: 0.5)
        case 3:   // ice crystal
            let l = CALayer()
            let img = FXImages.crystal(size: 4 + 5 * e.size, rotation: e.seed * 6.28)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            oneShot(l, at: pos, delay: delay, life: e.life, scaleTo: 1.4,
                    moveBy: CGVector(dx: 0, dy: -6), fadeFrom: 0.85)
        case 5:   // shooting star
            let streak = CALayer()
            let img = FXImages.streak(.white, length: 52, width: 1.6, gradient: true, alpha: 0.9)
            streak.contents = img
            streak.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            streak.transform = CATransform3DMakeRotation(atan2(-e.vy, e.vx) + .pi / 2, 0, 0, 1)
            oneShot(streak, at: pos, delay: delay, life: e.life, scaleTo: 1,
                    moveBy: CGVector(dx: e.vx * e.life, dy: -e.vy * e.life), fadeFrom: 0.9)
        case 6:   // 8-bit spark with gravity: keyframe parabola
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: e.size, height: e.size)
            l.backgroundColor = NSColor(FXImages.pixelPalette(theme)[Int(e.seed * 3.99)]).cgColor
            l.position = pos
            layer?.addSublayer(l)
            let steps = 12
            let pts: [CGPoint] = (0...steps).map { s in
                let t = e.life * Double(s) / Double(steps)
                return CGPoint(x: e.x + e.vx * t, y: bounds.height - (e.y + e.vy * t + 110 * t * t))
            }
            let move = CAKeyframeAnimation(keyPath: "position")
            let path = CGMutablePath()
            path.move(to: pts[0]); pts.dropFirst().forEach { path.addLine(to: $0) }
            move.path = path
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0; fade.toValue = 0.0
            for a in [move as CAAnimation, fade] {
                a.beginTime = CACurrentMediaTime() + delay
                a.duration = e.life
                a.fillMode = .backwards
            }
            l.add(move, forKey: "m"); l.add(fade, forKey: "f")
            l.opacity = 0
            reap(l, after: delay + e.life)
        default: break
        }
    }

    private func oneShot(_ l: CALayer, at pos: CGPoint, delay: Double, life: Double,
                         scaleTo: Double, moveBy: CGVector, fadeFrom: Double) {
        l.position = pos
        l.opacity = 0
        layer?.addSublayer(l)
        let begin = CACurrentMediaTime() + delay
        var anims: [CAAnimation] = []
        if scaleTo != 1 {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1.0; s.toValue = scaleTo
            anims.append(s)
        }
        if moveBy != .zero {
            let m = CABasicAnimation(keyPath: "position")
            m.fromValue = pos
            m.toValue = CGPoint(x: pos.x + moveBy.dx, y: pos.y + moveBy.dy)
            anims.append(m)
        }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = fadeFrom; f.toValue = 0.0
        anims.append(f)
        for (k, a) in anims.enumerated() {
            a.beginTime = begin
            a.duration = life
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.fillMode = .backwards
            l.add(a, forKey: "a\(k)")
        }
        reap(l, after: delay + life)
    }

    private func reap(_ l: CALayer, after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after + 0.05) { [weak l] in
            l?.removeFromSuperlayer()
        }
    }
}

// MARK: - cached CGImages (all @2x)

@MainActor
enum FXImages {
    static let pondGreens: [UInt32] = [0x2E6B4F, 0x3E8A5F, 0x1F5D4A, 0x4FA97A]
    static let petalPinks: [UInt32] = [0xFFB7D5, 0xFF9EC9, 0xFFD1E3, 0xF78FB8]
    static func pixelPalette(_ theme: Theme) -> [Color] { [theme.ringA, theme.ringB, .white, theme.accent] }

    private static var cache: [String: CGImage] = [:]

    private static func render(_ key: String, _ w: Double, _ h: Double,
                               _ draw: (CGContext) -> Void) -> CGImage {
        if let hit = cache[key] { return hit }
        let ctx = CGContext(data: nil, width: max(2, Int(w * 2)), height: max(2, Int(h * 2)),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        draw(ctx)
        let img = ctx.makeImage()!
        cache[key] = img
        return img
    }

    static func emoji(_ glyph: String, size: Double) -> CGImage {
        let d = size * 1.4
        return render("e\(glyph)\(Int(size * 4))", d, d) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let str = glyph as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: (d - sz.width) / 2, y: (d - sz.height) / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func dot(_ color: NSColor, radius: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "d\(Int(radius * 4))-\(c.description)"
        let d = radius * 2
        return render(key, d, d) { ctx in
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        }
    }

    /// Firefly: three concentric glow rings baked into one image.
    static func glow(_ color: NSColor, core: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "g\(Int(core * 4))-\(c.description)"
        let R = core * 4
        return render(key, R * 2, R * 2) { ctx in
            for (mul, alpha) in [(4.0, 0.08), (2.2, 0.2), (1.0, 0.9)] {
                let r = core * mul
                ctx.setFillColor(c.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: R - r, y: R - r, width: r * 2, height: r * 2))
            }
        }
    }

    static func streak(_ color: NSColor, length: Double, width: Double,
                       gradient: Bool, alpha: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "s\(Int(length))-\(Int(width * 4))-\(gradient)-\(Int(alpha * 100))-\(c.description)"
        let w = max(2, width * 2)
        return render(key, w, length) { ctx in
            if gradient {
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [c.withAlphaComponent(0).cgColor,
                                            c.withAlphaComponent(alpha).cgColor] as CFArray,
                                   locations: [0, 1])!
                ctx.clip(to: CGRect(x: (w - width) / 2, y: 0, width: width, height: length))
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: length), end: CGPoint(x: 0, y: 0), options: [])
            } else {
                ctx.setFillColor(c.withAlphaComponent(alpha).cgColor)
                ctx.fill(CGRect(x: (w - width) / 2, y: 0, width: width, height: length))
            }
        }
    }

    static func capsule(_ color: NSColor) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return render("c-\(c.description)", 24, 4) { ctx in
            ctx.setFillColor(c.cgColor)
            let p = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 24, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(p); ctx.fillPath()
        }
    }

    static func splat(seed: Double, size: Double) -> CGImage {
        let R = 14.0 * size
        return render("sp\(Int(seed * 20))-\(Int(size * 10))", R * 2, R * 2) { ctx in
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: R - 1.6, y: R - 1.6, width: 3.2, height: 3.2))
            for k in 0..<5 {
                let a = seed * 6.28 + Double(k) / 5 * 6.28
                let r = 7.0 * size
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                ctx.fillEllipse(in: CGRect(x: R + cos(a) * r - 1, y: R + sin(a) * r * 0.6 - 1, width: 2, height: 2))
            }
        }
    }

    static func crystal(size: Double, rotation: Double) -> CGImage {
        let R = size + 2
        return render("cr\(Int(size * 4))-\(Int(rotation * 10))", R * 2, R * 2) { ctx in
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            for k in 0..<6 {
                let a = rotation + Double(k) / 6 * 6.28
                ctx.move(to: CGPoint(x: R, y: R))
                ctx.addLine(to: CGPoint(x: R + cos(a) * size, y: R + sin(a) * size))
            }
            ctx.strokePath()
        }
    }

    static func horizonRing(_ outer: NSColor, inner: NSColor) -> CGImage {
        render("hr", 60, 60) { ctx in
            ctx.setStrokeColor((outer.usingColorSpace(.deviceRGB) ?? outer).withAlphaComponent(0.14).cgColor)
            ctx.setLineWidth(8)
            ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: 52, height: 52))
            ctx.setStrokeColor((inner.usingColorSpace(.deviceRGB) ?? inner).withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: CGRect(x: 10, y: 10, width: 40, height: 40))
        }
    }

    // MARK: - Richer particle textures

    /// Defocused lens light: a clean round disc with a gently brighter rim and
    /// a wide falloff halo. Composited additively so it reads as light, not paint.
    static func bokeh(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "bk\(Int(size * 4))-\(c.description)"
        let R = size * 3.2
        return render(key, R * 2, R * 2) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let center = CGPoint(x: R, y: R)

            // Wide, very soft falloff so edges never band
            let halo = CGGradient(colorsSpace: space,
                                  colors: [c.withAlphaComponent(0.22).cgColor,
                                           c.withAlphaComponent(0.06).cgColor,
                                           c.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 0.45, 1])!
            ctx.drawRadialGradient(halo,
                                   startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: R,
                                   options: [])

            // The defocused disc — dim interior with the energy concentrated in
            // a bright rim, feathered at the very edge. This ring-weighted
            // profile is what makes bokeh read as a lens circle of light
            // rather than a solid painted dot.
            let discR = size * 1.5
            let disc = CGGradient(colorsSpace: space,
                                  colors: [c.withAlphaComponent(0.10).cgColor,
                                           c.withAlphaComponent(0.13).cgColor,
                                           c.withAlphaComponent(0.38).cgColor,
                                           c.withAlphaComponent(0.16).cgColor,
                                           c.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 0.66, 0.90, 0.98, 1])!
            ctx.drawRadialGradient(disc,
                                   startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: discR,
                                   options: [])
        }
    }

    /// Bioluminescent firefly: warm-yellow core with green-tinted halo and
    /// a soft outer bloom. Reads as a live insect, not a flat glow.
    static func firefly(_ core: NSColor, size: Double) -> CGImage {
        let key = "ff\(Int(size * 4))-\(core.description)"
        let R = size * 4
        return render(key, R * 2, R * 2) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let cool = NSColor(calibratedRed: 0.6, green: 1.0, blue: 0.55, alpha: 1)
            let outerHalo = CGGradient(colorsSpace: space,
                                       colors: [cool.withAlphaComponent(0.28).cgColor,
                                                cool.withAlphaComponent(0.06).cgColor,
                                                cool.withAlphaComponent(0).cgColor] as CFArray,
                                       locations: [0, 0.55, 1])!
            ctx.drawRadialGradient(outerHalo,
                                   startCenter: CGPoint(x: R, y: R), startRadius: 0,
                                   endCenter: CGPoint(x: R, y: R), endRadius: R,
                                   options: [])
            let warm = core.usingColorSpace(.deviceRGB) ?? core
            let bloom = CGGradient(colorsSpace: space,
                                   colors: [NSColor.white.withAlphaComponent(0.95).cgColor,
                                            warm.withAlphaComponent(0.85).cgColor,
                                            warm.withAlphaComponent(0.25).cgColor,
                                            warm.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 0.3, 0.75, 1])!
            let bR = size * 1.6
            ctx.drawRadialGradient(bloom,
                                   startCenter: CGPoint(x: R, y: R), startRadius: 0,
                                   endCenter: CGPoint(x: R, y: R), endRadius: bR,
                                   options: [])
        }
    }

    /// Rising ember: hot white core, orange body, soft downward trail —
    /// looks like a live coal ejecting from a fire.
    static func ember(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "em\(Int(size * 4))-\(c.description)"
        let W = size * 3
        let H = size * 5
        return render(key, W, H) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            // Downward-tapering trail behind the head
            ctx.saveGState()
            let trailRect = CGRect(x: W / 2 - size * 0.7, y: 0, width: size * 1.4, height: H * 0.75)
            ctx.clip(to: trailRect)
            let trail = CGGradient(colorsSpace: space,
                                   colors: [c.withAlphaComponent(0).cgColor,
                                            c.withAlphaComponent(0.5).cgColor] as CFArray,
                                   locations: [0, 1])!
            ctx.drawLinearGradient(trail,
                                   start: CGPoint(x: W / 2, y: 0),
                                   end: CGPoint(x: W / 2, y: H * 0.75),
                                   options: [])
            ctx.restoreGState()
            // Halo
            let halo = CGGradient(colorsSpace: space,
                                  colors: [c.withAlphaComponent(0.55).cgColor,
                                           c.withAlphaComponent(0.1).cgColor,
                                           c.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 0.6, 1])!
            ctx.drawRadialGradient(halo,
                                   startCenter: CGPoint(x: W / 2, y: H * 0.8), startRadius: 0,
                                   endCenter: CGPoint(x: W / 2, y: H * 0.8), endRadius: size * 2.4,
                                   options: [])
            // Hot core
            let hot = CGGradient(colorsSpace: space,
                                 colors: [NSColor.white.cgColor,
                                          c.withAlphaComponent(0.85).cgColor,
                                          c.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 0.35, 1])!
            ctx.drawRadialGradient(hot,
                                   startCenter: CGPoint(x: W / 2, y: H * 0.8), startRadius: 0,
                                   endCenter: CGPoint(x: W / 2, y: H * 0.8), endRadius: size,
                                   options: [])
        }
    }

    /// Sky lantern: a warm paper-glow envelope, brightest at the flame near its
    /// base and falling off toward the crown. Fully emissive — no dark trim,
    /// which additive compositing would drop anyway.
    static func lantern(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "ln\(Int(size * 4))-\(c.description)"
        let W = size * 5
        let H = size * 6
        return render(key, W, H) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let cx = W / 2
            let flame = CGPoint(x: cx, y: H * 0.34)

            // Ambient bloom around the whole lantern
            let bloom = CGGradient(colorsSpace: space,
                                   colors: [c.withAlphaComponent(0.30).cgColor,
                                            c.withAlphaComponent(0.07).cgColor,
                                            c.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 0.5, 1])!
            ctx.drawRadialGradient(bloom,
                                   startCenter: flame, startRadius: 0,
                                   endCenter: flame, endRadius: W * 0.5,
                                   options: [])

            // Paper envelope: rounded, slightly tapered toward the crown
            let body = CGMutablePath()
            let bw = size * 1.15
            let top = H * 0.60
            let bottom = H * 0.16
            body.move(to: CGPoint(x: cx - bw * 0.72, y: bottom))
            body.addQuadCurve(to: CGPoint(x: cx - bw, y: (top + bottom) / 2),
                              control: CGPoint(x: cx - bw * 1.06, y: bottom + (top - bottom) * 0.22))
            body.addQuadCurve(to: CGPoint(x: cx - bw * 0.55, y: top),
                              control: CGPoint(x: cx - bw * 0.98, y: top - (top - bottom) * 0.16))
            body.addLine(to: CGPoint(x: cx + bw * 0.55, y: top))
            body.addQuadCurve(to: CGPoint(x: cx + bw, y: (top + bottom) / 2),
                              control: CGPoint(x: cx + bw * 0.98, y: top - (top - bottom) * 0.16))
            body.addQuadCurve(to: CGPoint(x: cx + bw * 0.72, y: bottom),
                              control: CGPoint(x: cx + bw * 1.06, y: bottom + (top - bottom) * 0.22))
            body.closeSubpath()

            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            // Lit from the flame at the base, so the underside is hottest
            let paper = CGGradient(colorsSpace: space,
                                   colors: [NSColor.white.withAlphaComponent(0.92).cgColor,
                                            c.withAlphaComponent(0.85).cgColor,
                                            c.withAlphaComponent(0.45).cgColor,
                                            c.withAlphaComponent(0.22).cgColor] as CFArray,
                                   locations: [0, 0.34, 0.72, 1])!
            ctx.drawRadialGradient(paper,
                                   startCenter: flame, startRadius: 0,
                                   endCenter: flame, endRadius: size * 2.6,
                                   options: [])
            ctx.restoreGState()

            // The flame itself — small hot point at the mouth
            let fire = CGGradient(colorsSpace: space,
                                  colors: [NSColor.white.cgColor,
                                           c.withAlphaComponent(0.9).cgColor,
                                           c.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 0.4, 1])!
            ctx.drawRadialGradient(fire,
                                   startCenter: CGPoint(x: cx, y: H * 0.22), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: H * 0.22), endRadius: size * 0.7,
                                   options: [])
        }
    }

    /// 4-point cross-flare sparkle with bright center — reads as a twinkling star.
    static func sparkleFlare(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "sf\(Int(size * 4))-\(c.description)"
        let R = size * 3.5
        return render(key, R * 2, R * 2) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            // Cross flare
            let vFlare = CGGradient(colorsSpace: space,
                                    colors: [c.withAlphaComponent(0).cgColor,
                                             c.withAlphaComponent(0.9).cgColor,
                                             c.withAlphaComponent(0).cgColor] as CFArray,
                                    locations: [0, 0.5, 1])!
            ctx.saveGState()
            ctx.clip(to: CGRect(x: R - size * 0.14, y: 0, width: size * 0.28, height: R * 2))
            ctx.drawLinearGradient(vFlare,
                                   start: CGPoint(x: R, y: 0),
                                   end: CGPoint(x: R, y: R * 2),
                                   options: [])
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: R - size * 0.14, width: R * 2, height: size * 0.28))
            ctx.drawLinearGradient(vFlare,
                                   start: CGPoint(x: 0, y: R),
                                   end: CGPoint(x: R * 2, y: R),
                                   options: [])
            ctx.restoreGState()
            // Bright center bloom
            let bloom = CGGradient(colorsSpace: space,
                                   colors: [NSColor.white.cgColor,
                                            c.withAlphaComponent(0.9).cgColor,
                                            c.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 0.35, 1])!
            ctx.drawRadialGradient(bloom,
                                   startCenter: CGPoint(x: R, y: R), startRadius: 0,
                                   endCenter: CGPoint(x: R, y: R), endRadius: size,
                                   options: [])
        }
    }

    /// Six-branch snowflake shape (baked once per size) — no more identical white circles.
    static func snowflake(size: Double) -> CGImage {
        let key = "sn\(Int(size * 4))"
        let R = size * 2
        return render(key, R * 2, R * 2) { ctx in
            let cx = R, cy = R
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(max(0.6, size * 0.18))
            ctx.setLineCap(.round)
            for k in 0..<6 {
                let a = Double(k) / 6.0 * .pi * 2
                let ex = cx + cos(a) * size
                let ey = cy + sin(a) * size
                ctx.move(to: CGPoint(x: cx, y: cy))
                ctx.addLine(to: CGPoint(x: ex, y: ey))
                // Two little side spurs
                for (t, spurLen) in [(0.55, size * 0.35), (0.8, size * 0.22)] {
                    let bx = cx + cos(a) * size * t
                    let by = cy + sin(a) * size * t
                    let leftA = a + .pi / 3
                    let rightA = a - .pi / 3
                    ctx.move(to: CGPoint(x: bx, y: by))
                    ctx.addLine(to: CGPoint(x: bx + cos(leftA) * spurLen, y: by + sin(leftA) * spurLen))
                    ctx.move(to: CGPoint(x: bx, y: by))
                    ctx.addLine(to: CGPoint(x: bx + cos(rightA) * spurLen, y: by + sin(rightA) * spurLen))
                }
            }
            ctx.strokePath()
            // Center dot
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8))
        }
    }

    /// Twinkling star with 4-point flare + soft round bloom, more elegant than a dot.
    static func star(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "st\(Int(size * 4))-\(c.description)"
        let R = max(2, size * 4)
        return render(key, R * 2, R * 2) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            // Diamond flare (short vertical + horizontal spikes)
            let flare = CGGradient(colorsSpace: space,
                                   colors: [c.withAlphaComponent(0).cgColor,
                                            c.withAlphaComponent(0.75).cgColor,
                                            c.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 0.5, 1])!
            let flareLen = R * 0.9
            ctx.saveGState()
            ctx.clip(to: CGRect(x: R - 0.5, y: R - flareLen, width: 1, height: flareLen * 2))
            ctx.drawLinearGradient(flare,
                                   start: CGPoint(x: R, y: R - flareLen),
                                   end: CGPoint(x: R, y: R + flareLen),
                                   options: [])
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: CGRect(x: R - flareLen, y: R - 0.5, width: flareLen * 2, height: 1))
            ctx.drawLinearGradient(flare,
                                   start: CGPoint(x: R - flareLen, y: R),
                                   end: CGPoint(x: R + flareLen, y: R),
                                   options: [])
            ctx.restoreGState()
            // Bright core
            let core = CGGradient(colorsSpace: space,
                                  colors: [NSColor.white.cgColor,
                                           c.withAlphaComponent(0.75).cgColor,
                                           c.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 0.4, 1])!
            ctx.drawRadialGradient(core,
                                   startCenter: CGPoint(x: R, y: R), startRadius: 0,
                                   endCenter: CGPoint(x: R, y: R), endRadius: size,
                                   options: [])
        }
    }

    /// Wispy elongated fog patch — soft ellipse feathered horizontally.
    static func fogWisp(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "fw\(Int(size * 4))-\(c.description)"
        let W = size * 6
        let H = size * 2.4
        return render(key, W, H) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let g = CGGradient(colorsSpace: space,
                               colors: [c.withAlphaComponent(0).cgColor,
                                        c.withAlphaComponent(0.10).cgColor,
                                        c.withAlphaComponent(0.18).cgColor,
                                        c.withAlphaComponent(0.10).cgColor,
                                        c.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 0.25, 0.5, 0.75, 1])!
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.clip()
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: 0, y: H / 2),
                                   end: CGPoint(x: W, y: H / 2),
                                   options: [])
            ctx.restoreGState()
        }
    }

    /// Wispy smoke curl — soft asymmetric ellipse with warm gradient hint.
    static func smokeWisp(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "sw\(Int(size * 4))-\(c.description)"
        let W = size * 3.5
        let H = size * 4.5
        return render(key, W, H) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let g = CGGradient(colorsSpace: space,
                               colors: [c.withAlphaComponent(0.22).cgColor,
                                        c.withAlphaComponent(0.08).cgColor,
                                        c.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 0.55, 1])!
            // Two overlapping blobs for irregularity
            ctx.drawRadialGradient(g,
                                   startCenter: CGPoint(x: W * 0.45, y: H * 0.55), startRadius: 0,
                                   endCenter: CGPoint(x: W * 0.45, y: H * 0.55), endRadius: W * 0.5,
                                   options: [])
            ctx.drawRadialGradient(g,
                                   startCenter: CGPoint(x: W * 0.6, y: H * 0.35), startRadius: 0,
                                   endCenter: CGPoint(x: W * 0.6, y: H * 0.35), endRadius: W * 0.42,
                                   options: [])
        }
    }

    /// A real comet: bright head + curved tail with hot-white core fading to color.
    static func cometHead(_ color: NSColor, length: Double, headSize: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "cm\(Int(length))-\(Int(headSize * 4))-\(c.description)"
        let W = max(6, headSize * 3.2)
        let H = length
        return render(key, W, H) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let cx = W / 2
            let hx = H
            // Tapered tail as a triangular clip
            ctx.saveGState()
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: cx - headSize * 1.2, y: H))
            tail.addQuadCurve(to: CGPoint(x: cx, y: 0),
                              control: CGPoint(x: cx - headSize * 0.3, y: H * 0.35))
            tail.addQuadCurve(to: CGPoint(x: cx + headSize * 1.2, y: H),
                              control: CGPoint(x: cx + headSize * 0.3, y: H * 0.35))
            tail.closeSubpath()
            ctx.addPath(tail)
            ctx.clip()
            let tailGrad = CGGradient(colorsSpace: space,
                                      colors: [c.withAlphaComponent(0).cgColor,
                                               c.withAlphaComponent(0.15).cgColor,
                                               c.withAlphaComponent(0.55).cgColor,
                                               NSColor.white.withAlphaComponent(0.9).cgColor] as CFArray,
                                      locations: [0, 0.4, 0.85, 1])!
            ctx.drawLinearGradient(tailGrad,
                                   start: CGPoint(x: cx, y: H),
                                   end: CGPoint(x: cx, y: 0),
                                   options: [])
            ctx.restoreGState()
            // Bright head bloom (drawn on top, at bottom of the image which is the leading tip)
            let bloom = CGGradient(colorsSpace: space,
                                   colors: [NSColor.white.cgColor,
                                            c.withAlphaComponent(0.9).cgColor,
                                            c.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 0.35, 1])!
            _ = hx  // unused
            ctx.drawRadialGradient(bloom,
                                   startCenter: CGPoint(x: cx, y: 0), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: 0), endRadius: headSize * 1.4,
                                   options: [])
        }
    }

    /// Small asymmetric dust mote — soft ellipse with subtle rimlight.
    static func dustMote(_ color: NSColor, size: Double) -> CGImage {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let key = "dm\(Int(size * 4))-\(c.description)"
        let W = size * 3.2
        let H = size * 2.2
        return render(key, W, H) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let g = CGGradient(colorsSpace: space,
                               colors: [c.withAlphaComponent(0.6).cgColor,
                                        c.withAlphaComponent(0.15).cgColor,
                                        c.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 0.55, 1])!
            ctx.drawRadialGradient(g,
                                   startCenter: CGPoint(x: W * 0.5, y: H * 0.5), startRadius: 0,
                                   endCenter: CGPoint(x: W * 0.5, y: H * 0.5), endRadius: W * 0.5,
                                   options: [])
            // Rimlight on top-right
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            ctx.fillEllipse(in: CGRect(x: W * 0.6, y: H * 0.32, width: size * 0.35, height: size * 0.35))
        }
    }
}
