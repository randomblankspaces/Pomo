import SwiftUI
import AppKit

// MARK: - Bundled theme artwork

enum ThemeMedia {
    private static var cache: [String: NSImage] = [:]

    /// Live-wallpaper videos are kept in Application Support (not the app
    /// bundle) so the app stays small and videos survive reinstalls.
    static var videosDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomo/Videos", isDirectory: true)
    }

    /// 1080p HEVC transcodes for battery saver — same footage, ~¼ the decode.
    static var videosDirectory1080: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomo/Videos-1080", isDirectory: true)
    }

    private static let videoExtensions = ["mp4", "mov", "m4v"]
    private static var videoURLCache: [String: URL?] = [:]

    static func ensureDirectories() {
        for dir in [videosDirectory, videosDirectory1080] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func videoURL(for id: String, lowPower: Bool = false) -> URL? {
        let key = lowPower ? id + "#lp" : id
        if let cached = videoURLCache[key] { return cached }
        var url: URL? = nil
        if lowPower {
            for ext in videoExtensions {
                let lp = videosDirectory1080.appendingPathComponent("vid-\(id).\(ext)")
                if FileManager.default.fileExists(atPath: lp.path) { url = lp; break }
            }
        }
        if url == nil {
            for ext in videoExtensions {
                let external = videosDirectory.appendingPathComponent("vid-\(id).\(ext)")
                if FileManager.default.fileExists(atPath: external.path) { url = external; break }
            }
        }
        if url == nil {
            for ext in videoExtensions {
                if let bundled = Bundle.main.url(forResource: "vid-\(id)", withExtension: ext) {
                    url = bundled; break
                }
            }
        }
        videoURLCache[key] = url
        return url
    }

    static func imageURL(for id: String) -> URL? {
        Bundle.main.url(forResource: "bg-\(id)", withExtension: "jpg")
    }

    static func image(for id: String) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let url = imageURL(for: id), let img = NSImage(contentsOf: url) else { return nil }
        cache[id] = img
        return img
    }

    static func clearVideoCache() {
        videoURLCache.removeAll()
    }

    static func discoverUserVideos() -> [URL] {
        ensureDirectories()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: videosDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { url in
            videoExtensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func generateCustomThemes() {
        let videos = discoverUserVideos()
        var themes: [Theme] = []
        for video in videos {
            let stem = video.deletingPathExtension().lastPathComponent
            let id = stem.hasPrefix("vid-") ? String(stem.dropFirst(4)) : stem
            if Themes.all.contains(where: { $0.id == id }) { continue }
            guard let profile = ColorExtractor.analyzeVideo(at: video) else { continue }
            let name = id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
            themes.append(ThemeGenerator.generate(from: profile, id: id, name: name))
        }
        Themes.custom = themes
    }
}

/// Frosted glass: blurs whatever is behind the window — i.e. the user's own
/// desktop wallpaper shows through.
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The Glass theme backdrop: the user's actual wallpaper, shown as-is.
struct GlassBackground: View {
    @State private var wallpaper: NSImage?

    /// Loads the user's real wallpaper: the saved original if Pomo themed the
    /// desktop, otherwise whatever is currently set. Cached for reuse.
    static var cachedWallpaper: NSImage?
    static func loadWallpaper() -> NSImage? {
        if let cachedWallpaper { return cachedWallpaper }
        var raw: NSImage?
        if let path = ImmersiveMode.savedOriginalWallpaperPath() {
            raw = NSImage(contentsOf: URL(fileURLWithPath: path))
        }
        if raw == nil, let screen = NSScreen.main ?? NSScreen.screens.first,
           let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            raw = NSImage(contentsOf: url)
        }
        guard let raw else { return nil }
        let sized = downsampledToScreen(raw)
        cachedWallpaper = sized
        return sized
    }

    /// Wallpapers ship at 5-6K; the window never shows more than screen pixels.
    /// One-time downsample shrinks the composited texture (and its blurred copy).
    private static func downsampledToScreen(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        let screenPx = CGSize(width: (screen?.frame.width ?? 1728) * scale,
                              height: (screen?.frame.height ?? 1117) * scale)
        // enough pixels to COVER the screen (scaledToFill), aspect preserved
        let s = max(screenPx.width / CGFloat(cg.width), screenPx.height / CGFloat(cg.height))
        guard s < 0.95 else { return image }   // already screen-sized or smaller
        let w = Int(CGFloat(cg.width) * s), h = Int(CGFloat(cg.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }

    /// The calendar card's backdrop, blurred ONCE here instead of a live
    /// .blur() filter pass over the full wallpaper on every composite.
    static var cachedBlurredWallpaper: NSImage?
    static func blurredWallpaper() -> NSImage? {
        if let cachedBlurredWallpaper { return cachedBlurredWallpaper }
        guard let base = loadWallpaper(),
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        // radius matches the old .blur(radius: 9) in points → pixels
        let pxPerPoint = CGFloat(cg.width) / max(base.size.width, 1)
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9.0 * pxPerPoint])
            .cropped(to: ci.extent)
        let ctx = CIContext()
        guard let outCG = ctx.createCGImage(blurred, from: ci.extent) else { return nil }
        let img = NSImage(cgImage: outCG, size: base.size)
        cachedBlurredWallpaper = img
        return img
    }

    var body: some View {
        ZStack {
            if let wallpaper {
                GeometryReader { geo in
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                VisualEffectBlur()   // fallback (e.g. rotating-folder wallpapers)
            }
        }
        .onAppear { wallpaper = Self.loadWallpaper() }
    }
}

/// Clear backdrop blur for Glass-theme cards: renders the same wallpaper the
/// window shows, aligned to the window, blurred, and clipped to this view —
/// a gentle blur with no white/gray material tint.
struct WallpaperBlurPatch: View {
    @State private var wallpaper: NSImage? = GlassBackground.cachedBlurredWallpaper

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            let contentSize = window?.contentView?.bounds.size ?? .zero
            // the backdrop ignores the safe area, so it starts above SwiftUI's
            // global origin by the title-bar height — compensate
            let titlebar = max(0, contentSize.height - (window?.contentLayoutRect.height ?? contentSize.height))

            if let wallpaper, contentSize.width > 0 {
                // .position pins the full-window wallpaper's center explicitly,
                // sidestepping the implicit centering a smaller .frame would add
                Image(nsImage: wallpaper)   // pre-blurred — no live filter pass
                    .resizable()
                    .scaledToFill()
                    .frame(width: contentSize.width, height: contentSize.height)
                    .position(
                        x: contentSize.width / 2 - frame.minX,
                        y: contentSize.height / 2 - (frame.minY + titlebar)
                    )
                    .allowsHitTesting(false)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .clipped()
        .onAppear { wallpaper = GlassBackground.blurredWallpaper() }
    }
}

// MARK: - Themed backdrop views

/// Full themed backdrop: looping live-wallpaper video (with parallax + click
/// ripple) under a readability scrim, topped by the interactive FX layers.
/// Falls back to a still frame, then a plain gradient.
struct ThemeBackground: View {
    let theme: Theme
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var visibility: VisibilityMonitor
    @ObservedObject private var power = PowerMonitor.shared

    private var enabledLayers: [ParticleStyle] {
        theme.fxLayers.filter { engine.state.settings.isFXEnabled(themeID: theme.id, $0) }
    }

    var body: some View {
        let saver = power.saver && engine.state.settings.batterySaverOn
        ZStack {
            if theme.id == "glass" {
                GlassBackground()
                Color.black.opacity(0.16).allowsHitTesting(false)
            } else if let videoURL = ThemeMedia.videoURL(for: theme.id, lowPower: saver) {
                VideoBackground(url: videoURL, parallax: engine.state.settings.parallaxOn)
                scrim
            } else {
                ProceduralBackground(theme: theme)
            }

            InteractiveFX(
                theme: theme,
                layers: enabledLayers,
                interactive: engine.state.settings.pointerFXOn,
                density: engine.state.settings.fxDensityValue,
                sizeScale: engine.state.settings.fxSizeValue,
                paused: !visibility.visible,
                lowPower: saver
            )
        }
        .ignoresSafeArea()
    }

    // keeps the timer readable over busy footage
    private var scrim: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.28), .black.opacity(0.12), .black.opacity(0.42)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [.black.opacity(0.28), .clear],
                center: .center, startRadius: 30, endRadius: 380
            )
        }
        .allowsHitTesting(false)
    }
}
