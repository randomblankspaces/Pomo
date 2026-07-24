import SwiftUI
import AppKit
import IOKit.ps

/// Watches AC ↔ battery transitions (and Low Power Mode) so visuals can shed
/// cost while unplugged: 1080p video + gentler FX tick instead of 4K + 30fps.
@MainActor
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()
    /// True on battery power or when Low Power Mode is on.
    @Published private(set) var saver = false

    private init() {
        refresh()
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PowerMonitor.shared.refresh() }
            }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PowerMonitor.shared.refresh() }
        }
    }

    private func refresh() {
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        let new = type == kIOPSBatteryPowerValue || ProcessInfo.processInfo.isLowPowerModeEnabled
        if new != saver { saver = new }
    }
}

/// Turns the main window into a live desktop background: fullscreen,
/// pinned behind every other window, present on all Spaces.
/// The window stays clickable, so you can still hit pause or exit.
@MainActor
final class DesktopMode: ObservableObject {
    @Published var isOn = false

    weak var window: NSWindow?
    private var savedFrame: NSRect?

    init() {
        // Pinned behind everything, the window never surfaces on ⌘-tab.
        // Ride app activation instead: raise while Pomo is the active app,
        // sink back to the desktop layer when the user switches away.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setRaised(true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setRaised(false) }
        }
    }

    private func setRaised(_ raised: Bool) {
        guard isOn, let window else { return }
        if raised {
            // Clicking the wallpaper directly also activates the app — keep it
            // sunk then; only surface for ⌘-tab / Dock style activation.
            if let event = NSApp.currentEvent,
               [.leftMouseDown, .leftMouseUp, .rightMouseDown].contains(event.type),
               window.windowNumber == event.windowNumber { return }
            window.level = .normal
            window.makeKeyAndOrderFront(nil)
        } else {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        }
    }

    func adopt(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
    }

    func toggle() {
        guard let window else { return }
        if isOn { exitDesktop(window) } else { enterDesktop(window) }
        withAnimation(.easeInOut(duration: 0.4)) { isOn.toggle() }
    }

    private func enterDesktop(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        savedFrame = window.frame
        // One notch below normal: behind every app window, above the wallpaper.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false
        setTrafficLights(window, hidden: true)
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    private func exitDesktop(_ window: NSWindow) {
        window.level = .normal
        window.collectionBehavior = []
        window.isMovable = true
        setTrafficLights(window, hidden: false)
        let frame = savedFrame ?? NSRect(x: 200, y: 200, width: 460, height: 700)
        window.setFrame(frame, display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func setTrafficLights(_ window: NSWindow, hidden: Bool) {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }
}

/// Tracks whether the main window is actually visible on screen — animations
/// pause when it's occluded, miniaturized, or closed.
@MainActor
final class VisibilityMonitor: ObservableObject {
    @Published var visible = true
    private weak var window: NSWindow?

    func adopt(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.visible = window.occlusionState.contains(.visible)
            }
        }
        visible = window.occlusionState.contains(.visible)
    }
}

/// Grabs the hosting NSWindow so DesktopMode can drive it.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
