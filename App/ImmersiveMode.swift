import SwiftUI
import AppKit
import Combine

/// Borderless, click-through windows pinned at the wallpaper layer — one per
/// screen — playing the theme's video. This is how the desktop background
/// becomes the actual looping video (macOS's wallpaper API only takes images).
@MainActor
final class LiveWallpaper {
    static let shared = LiveWallpaper()
    private var windows: [NSWindow] = []
    private(set) var currentURL: URL?

    private var occlusionObservers: [NSObjectProtocol] = []

    private func refreshVisibility() {
        DecodeGate.shared.wallpaperVisible =
            windows.contains { $0.occlusionState.contains(.visible) }
    }

    func show(url: URL) {
        guard url != currentURL || windows.isEmpty else { return }
        close()
        currentURL = url
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.ignoresMouseEvents = true          // clicks fall through to Finder
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            let video = LoopingPlayerNSView(url: url)
            video.parallaxEnabled = false
            video.receivesRipples = false
            window.contentView = video
            window.orderBack(nil)
            windows.append(window)
            occlusionObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshVisibility() }
            })
        }
        refreshVisibility()
    }

    func close() {
        occlusionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        occlusionObservers.removeAll()
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        currentURL = nil
        DecodeGate.shared.wallpaperVisible = false
    }
}

/// Syncs the Mac itself to the current theme: renders the scene as a
/// wallpaper image, sets it on every display, and switches to dark mode.
@MainActor
final class ImmersiveMode: ObservableObject {
    private static let enabledKey = "immersive.enabled"
    private static let originalsKey = "immersive.originalWallpapers"
    private static let appliedKey = "immersive.applied"
    private static let originalAccentKey = "immersive.originalAccent"     // 999 = key was absent (default blue/multicolor)
    private static let originalHighlightKey = "immersive.originalHighlight" // "" = absent

    /// macOS accent color ids: -1 graphite, 0 red, 1 orange, 2 yellow,
    /// 3 green, 4 blue, 5 purple, 6 pink.
    private static let accentByTheme: [String: (id: Int, highlight: String)] = [
        "sakura":    (6, "1.000000 0.749020 0.823529 Pink"),
        "initiald":  (1, "1.000000 0.874510 0.701961 Orange"),
        "swamp":     (3, "0.752941 0.964706 0.678431 Green"),
        "irithyll":  (4, "0.698039 0.843137 1.000000 Blue"),
        "meadow":    (2, "1.000000 0.937255 0.690196 Yellow"),
        "synthwave": (6, "1.000000 0.749020 0.823529 Pink"),
        "desert":    (-1, "0.847059 0.847059 0.862745 Graphite"),
        "autumn":    (1, "1.000000 0.874510 0.701961 Orange"),
        "blackhole": (1, "1.000000 0.874510 0.701961 Orange"),
        "pixelcity": (5, "0.968627 0.831373 1.000000 Purple"),
    ]

    private static func autoAccent(for theme: Theme) -> (id: Int, highlight: String)? {
        if let known = accentByTheme[theme.id] { return known }
        guard let accentNS = NSColor(theme.accent).usingColorSpace(.deviceRGB) else { return nil }
        return ColorExtractor.nearestAccent(accentNS)
    }
    private static let artVersion = 2   // bump when scene art changes to bust the wallpaper cache
    private static let snapshotTime = 100.6   // a pretty moment in each scene's animation cycle

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published var lastApplied: String? = nil

    private var powerSub: AnyCancellable?

    init() {
        // Opt-out toggle, on by default — the whole point is immersion.
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        // Launch self-heal: if immersion is off but a Pomo still is on the
        // desktop (crash residue), put the user's wallpaper back. The glass
        // apply path handles the enabled case.
        if !enabled { Self.restoreWallpapers() }
        // Battery saver: swap the live-wallpaper video 4K↔1080p on plug/unplug
        // so the app layer and wallpaper always share ONE decode pipeline.
        powerSub = PowerMonitor.shared.$saver
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] saverNow in
                MainActor.assumeIsolated {
                    guard let self, self.enabled, let id = self.lastApplied,
                          id != "glass" else { return }
                    let low = saverNow && PomoStore.load().settings.batterySaverOn
                    if let video = ThemeMedia.videoURL(for: id, lowPower: low) {
                        LiveWallpaper.shared.show(url: video)
                    }
                }
            }
    }

    func applyIfEnabled(_ theme: Theme) {
        guard enabled, lastApplied != theme.id else { return }
        apply(theme)
    }

    func apply(_ theme: Theme) {
        // Glass is built around the user's own wallpaper — leave the desktop,
        // wallpaper, and accent exactly as they are.
        if theme.id == "glass" {
            LiveWallpaper.shared.close()
            Self.restoreWallpapers()
            Self.restoreAccent()
            lastApplied = theme.id
            return
        }
        saveOriginalsIfNeeded()
        setWallpapers(theme)   // still image behind everything, as the fallback
        let low = PowerMonitor.shared.saver && PomoStore.load().settings.batterySaverOn
        if let video = ThemeMedia.videoURL(for: theme.id, lowPower: low) {
            LiveWallpaper.shared.show(url: video)   // the real deal: live video desktop
        } else {
            LiveWallpaper.shared.close()
        }
        setSystemDarkMode()
        applyAccent(theme)
        lastApplied = theme.id
    }

    // MARK: System accent color

    private func applyAccent(_ theme: Theme) {
        guard let accent = Self.autoAccent(for: theme) else { return }
        saveOriginalAccentIfNeeded()
        Self.writeAccent(id: accent.id, highlight: accent.highlight)
    }

    private func saveOriginalAccentIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.originalAccentKey) == nil else { return }
        let current = CFPreferencesCopyValue(
            "AppleAccentColor" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? Int
        let highlight = CFPreferencesCopyValue(
            "AppleHighlightColor" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
        UserDefaults.standard.set(current ?? 999, forKey: Self.originalAccentKey)
        UserDefaults.standard.set(highlight ?? "", forKey: Self.originalHighlightKey)
    }

    /// Writes the global accent and broadcasts the same notification System
    /// Settings posts, so running apps pick the color up live.
    private static func writeAccent(id: Int?, highlight: String?) {
        CFPreferencesSetValue(
            "AppleAccentColor" as CFString, id.map { $0 as CFNumber },
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesSetValue(
            "AppleHighlightColor" as CFString, highlight as CFString?,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleColorPreferencesChangedNotification"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    static func restoreAccent() {
        guard let saved = UserDefaults.standard.object(forKey: originalAccentKey) as? Int else { return }
        let highlight = UserDefaults.standard.string(forKey: originalHighlightKey) ?? ""
        writeAccent(id: saved == 999 ? nil : saved, highlight: highlight.isEmpty ? nil : highlight)
        UserDefaults.standard.removeObject(forKey: originalAccentKey)
        UserDefaults.standard.removeObject(forKey: originalHighlightKey)
    }

    // MARK: Wallpaper

    private func setWallpapers(_ theme: Theme) {
        // The bundled curated artwork, copied out of the app bundle so the
        // wallpaper survives app updates. (Every theme ships a still; the old
        // procedural-scene fallback renderer was removed with SceneArt.)
        guard let src = ThemeMedia.imageURL(for: theme.id) else { return }
        let dst = wallpaperDirectory().appendingPathComponent("wall-\(theme.id).jpg")
        if !FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(dst, for: screen, options: [:])
        }
        UserDefaults.standard.set(true, forKey: Self.appliedKey)
    }

    private func wallpaperDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomo/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Restore

    /// The wallpaper the user had before Pomo touched anything (if saved).
    static func savedOriginalWallpaperPath() -> String? {
        (UserDefaults.standard.array(forKey: originalsKey) as? [String])?.first(where: { !$0.isEmpty })
    }

    private func saveOriginalsIfNeeded() {
        guard UserDefaults.standard.array(forKey: Self.originalsKey) == nil else { return }
        // Never record Pomo's own art as the user's "original" — a mid-cycle
        // save could otherwise restore a theme still back onto the desktop.
        let paths = NSScreen.screens.map { screen -> String in
            let p = NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? ""
            return p.contains("/Pomo/Wallpapers/") ? "" : p
        }
        guard paths.contains(where: { !$0.isEmpty }) else { return }
        UserDefaults.standard.set(paths, forKey: Self.originalsKey)
    }

    func restoreOriginalWallpaper() {
        LiveWallpaper.shared.close()
        Self.restoreWallpapers()
        Self.restoreAccent()
        lastApplied = nil
    }

    /// Puts the user's original wallpaper back. Safe to call from app
    /// termination — static, synchronous, no instance state needed.
    /// Self-heals: if a screen still shows Pomo art (crash, missed restore),
    /// it is restored even when the applied flag was already cleared.
    static func restoreWallpapers() {
        let saved = (UserDefaults.standard.array(forKey: originalsKey) as? [String]) ?? []
        let fallback = "/System/Library/CoreServices/DefaultDesktop.heic"
        let applied = UserDefaults.standard.bool(forKey: appliedKey)
        for (i, screen) in NSScreen.screens.enumerated() {
            let current = NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? ""
            let pomoOwned = current.contains("/Pomo/Wallpapers/")
            guard applied || pomoOwned else { continue }
            var path = i < saved.count && !saved[i].isEmpty ? saved[i] : (saved.first(where: { !$0.isEmpty }) ?? "")
            if path.isEmpty || path.contains("/Pomo/Wallpapers/")
                || !FileManager.default.fileExists(atPath: path) { path = fallback }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
        UserDefaults.standard.set(false, forKey: appliedKey)
    }

    // MARK: System appearance

    /// All Pomo themes are dark — switch the Mac to match.
    /// Triggers a one-time "control System Events" permission prompt.
    private func setSystemDarkMode() {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to true"
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = Pipe()
            try? process.run()
        }
    }
}
