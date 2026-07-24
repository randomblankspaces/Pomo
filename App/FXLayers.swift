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
            particleLayers[i] = ps.map { p in
                let l = makeParticleLayer(styles[i], p)
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
            let img = style == .fireflies
                ? FXImages.glow(NSColor(color), core: p.size)
                : FXImages.dot(NSColor(color), radius: p.size)
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
            let img = FXImages.dot(.white, radius: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .embers:
            let l = CALayer()
            let color = p.seed > 0.5 ? theme.ringA : theme.ringB
            let img = FXImages.glow(NSColor(color), core: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .bokeh:
            let l = CALayer()
            let color = p.seed > 0.6 ? theme.ringA : (p.seed > 0.3 ? theme.ringB : theme.accent)
            let img = FXImages.glow(NSColor(color).withAlphaComponent(0.35), core: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .sparkle:
            let l = CALayer()
            let img = FXImages.dot(.white, radius: p.size)
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
            let img = FXImages.glow(NSColor(theme.ringB).withAlphaComponent(0.12), core: p.size)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            return l
        case .lanterns:
            let l = CALayer()
            let color = p.seed > 0.5 ? theme.ringA : theme.ringB
            let img = FXImages.glow(NSColor(color), core: p.size)
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
            let img = FXImages.glow(NSColor(theme.ringB).withAlphaComponent(0.06), core: p.size)
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
            let img = FXImages.streak(NSColor(color), length: 30 + 40 * p.z, width: p.size,
                                      gradient: true, alpha: 0.7)
            l.contents = img
            l.bounds = CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2)
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
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
                let pulse = 0.6 + 0.4 * sin(p.phase * 0.8)
                l.opacity = Float(pulse * 0.35)
                let s = 0.9 + 0.2 * sin(p.phase * 0.5)
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
}
