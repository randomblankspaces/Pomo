import SwiftUI
import AppKit

/// Restores the user's own wallpaper when Pomo quits; halts video decode
/// while the screen sleeps or the session is locked.
final class PomoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeMedia.ensureDirectories()
        // Stored themes carry the user's own edits, so publish those rather
        // than re-deriving a palette from the footage on every launch.
        MainActor.assumeIsolated {
            CustomThemeStore.shared.publish()
            CustomThemeStore.shared.adoptOrphanedVideos()
        }
        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DecodeGate.shared.screenOn = false }
        }
        wsc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DecodeGate.shared.screenOn = true }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DecodeGate.shared.screenOn = false }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DecodeGate.shared.screenOn = true }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ImmersiveMode.restoreWallpapers()
        ImmersiveMode.restoreAccent()
    }
}

@main
struct PomoApp: App {
    @NSApplicationDelegateAdaptor(PomoAppDelegate.self) private var appDelegate
    @StateObject private var engine = PomoEngine()
    @StateObject private var spotify = SpotifyController()
    @StateObject private var desktopMode = DesktopMode()
    @StateObject private var immersive = ImmersiveMode()
    @StateObject private var habits = HabitStore()
    @StateObject private var habitEdit = HabitEditState()
    @StateObject private var visibility = VisibilityMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(spotify)
                .environmentObject(desktopMode)
                .environmentObject(immersive)
                .environmentObject(habits)
                .environmentObject(habitEdit)
                .environmentObject(visibility)
                .frame(minWidth: 400, minHeight: 600)
                .background(WindowAccessor {
                    desktopMode.adopt($0)
                    visibility.adopt($0)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 460, height: 700)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(desktopMode.isOn ? "Exit Desktop Mode" : "Enter Desktop Mode") {
                    desktopMode.toggle()
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
