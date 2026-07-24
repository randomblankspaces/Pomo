import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

/// Hardware-decoded, seamlessly looping video layer — the live wallpaper.
/// The video itself reacts to the user two ways:
///   • cursor parallax: rendered ~6% oversized and panned opposite the pointer
///   • click ripple: a CIBumpDistortion warps the footage out from the click
struct VideoBackground: NSViewRepresentable {
    let url: URL
    var parallax: Bool = true

    func makeNSView(context: Context) -> LoopingPlayerNSView {
        let view = LoopingPlayerNSView(url: url)
        view.parallaxEnabled = parallax
        return view
    }

    func updateNSView(_ view: LoopingPlayerNSView, context: Context) {
        view.setVideo(url: url)
        view.parallaxEnabled = parallax
    }
}

/// One decode pipeline per video no matter how many layers show it — the
/// in-app background and every wallpaper window share the same AVQueuePlayer
/// (AVPlayerLayer is just a viewport; decoding happens once per player).
final class VideoPlayerPool {
    static let shared = VideoPlayerPool()
    private struct Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        var refs: Int
    }
    private var entries: [URL: Entry] = [:]
    private let lock = NSLock()

    func acquire(_ url: URL) -> AVQueuePlayer {
        lock.lock(); defer { lock.unlock() }
        if var entry = entries[url] {
            entry.refs += 1
            entries[url] = entry
            entry.player.play()
            return entry.player
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        entries[url] = Entry(player: player, looper: looper, refs: 1)
        player.play()
        return player
    }

    func release(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[url] else { return }
        entry.refs -= 1
        if entry.refs <= 0 {
            entry.player.pause()
            entries[url] = nil
        } else {
            entries[url] = entry
        }
    }

    /// Screen asleep / session locked → stop decoding entirely.
    func pauseAll() {
        lock.lock(); defer { lock.unlock() }
        entries.values.forEach { $0.player.pause() }
    }

    func resumeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.values.forEach { $0.player.play() }
    }
}

/// Single switch for "is any video surface actually visible?" — decode runs
/// only when the screen is on AND (app window or wallpaper) can be seen.
@MainActor
final class DecodeGate {
    static let shared = DecodeGate()
    var appVisible = true { didSet { apply() } }
    var wallpaperVisible = true { didSet { apply() } }
    var screenOn = true { didSet { apply() } }

    private func apply() {
        if screenOn && (appVisible || wallpaperVisible) {
            VideoPlayerPool.shared.resumeAll()
        } else {
            VideoPlayerPool.shared.pauseAll()
        }
    }
}

final class LoopingPlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var currentURL: URL?
    private var trackingArea: NSTrackingArea?
    private var rippleObserver: NSObjectProtocol?

    /// Cursor parallax on/off (Settings). Resets the pan when switched off.
    var parallaxEnabled = true {
        didSet {
            guard parallaxEnabled != oldValue else { return }
            updateTrackingAreas()
            guard !parallaxEnabled else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            playerLayer.frame = baseFrame()
            CATransaction.commit()
        }
    }
    /// Wallpaper-layer copies of this view ignore clicks and ripples.
    var receivesRipples = true

    private let overscan: CGFloat = 0.06   // parallax headroom

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        setVideo(url: url)

        rippleObserver = NotificationCenter.default.addObserver(
            forName: .pomoVideoRipple, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.receivesRipples,
                  let x = note.userInfo?["x"] as? CGFloat,
                  let y = note.userInfo?["y"] as? CGFloat else { return }
            self.ripple(at: CGPoint(x: x, y: y))
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if let rippleObserver { NotificationCenter.default.removeObserver(rippleObserver) }
        if let currentURL { VideoPlayerPool.shared.release(currentURL) }
    }

    func setVideo(url: URL) {
        guard url != currentURL else { return }
        if let currentURL { VideoPlayerPool.shared.release(currentURL) }
        currentURL = url
        playerLayer.player = VideoPlayerPool.shared.acquire(url)
    }

    // MARK: layout + parallax

    private func baseFrame() -> CGRect {
        bounds.insetBy(dx: -bounds.width * overscan, dy: -bounds.height * overscan)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = baseFrame()
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard parallaxEnabled else { trackingArea = nil; return }   // no mouse wakeups when off
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var lastParallax = CFAbsoluteTime(0)
    private var lastPoint = CGPoint.zero

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard parallaxEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 30Hz + 2px dead zone: skip redundant layer transactions
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastParallax > 0.033, abs(p.x - lastPoint.x) + abs(p.y - lastPoint.y) > 2 else { return }
        lastParallax = now; lastPoint = p
        guard bounds.width > 0, bounds.height > 0 else { return }
        // -1…1 from center; pan the oversized video the opposite way
        let nx = (p.x / bounds.width - 0.5) * 2
        let ny = (p.y / bounds.height - 0.5) * 2
        let maxShift = CGSize(width: bounds.width * overscan * 0.7,
                              height: bounds.height * overscan * 0.7)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        playerLayer.frame = baseFrame().offsetBy(dx: -nx * maxShift.width, dy: -ny * maxShift.height)
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        playerLayer.frame = baseFrame()
        CATransaction.commit()
    }

    // MARK: click ripple (CI distortion on the video layer)

    private func ripple(at viewPoint: CGPoint) {
        // SwiftUI coords are top-left origin; layers are bottom-left.
        let layerPoint = CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
        let inLayer = layer!.convert(layerPoint, to: playerLayer)

        let bump = CIFilter.bumpDistortion()
        bump.center = CGPoint(x: inLayer.x, y: inLayer.y)
        bump.radius = 1
        bump.scale = 0.42
        let filter = bump as CIFilter
        filter.name = "pomoBump"
        playerLayer.filters = [filter]

        let radiusAnim = CABasicAnimation(keyPath: "filters.pomoBump.inputRadius")
        radiusAnim.fromValue = 40
        radiusAnim.toValue = 420
        radiusAnim.duration = 0.65
        radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scaleAnim = CABasicAnimation(keyPath: "filters.pomoBump.inputScale")
        scaleAnim.fromValue = 0.42
        scaleAnim.toValue = 0.0
        scaleAnim.duration = 0.65
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        playerLayer.add(radiusAnim, forKey: "pomoRippleRadius")
        playerLayer.add(scaleAnim, forKey: "pomoRippleScale")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.playerLayer.filters = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // shared player keeps running for other viewports; nothing to do here
    }
}
