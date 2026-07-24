import SwiftUI
import AppKit

// MARK: - Controller

final class SpotifyController: ObservableObject {
    @Published var isInstalled = false
    @Published var isSpotifyRunning = false
    @Published var isPlaying = false
    @Published var track = ""
    @Published var artist = ""
    @Published var permissionDenied = false

    static let focusPlaylists: [(name: String, emoji: String, uri: String)] = [
        ("Lofi Beats", "🎧", "spotify:playlist:37i9dQZF1DWWQRwui0ExPn"),
        ("Deep Focus", "🧠", "spotify:playlist:37i9dQZF1DWZeKCadgRdKQ"),
        ("Peaceful Piano", "🎹", "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"),
        ("Jazz Vibes", "🎷", "spotify:playlist:37i9dQZF1DX0SM0LYsmbMT"),
    ]

    private let queue = DispatchQueue(label: "pomo.spotify", qos: .utility)
    private var pollTimer: Timer?
    /// Window visibility gate: hidden UI polls 10× less often.
    var appVisible = true
    private var pollCount = 0

    init() {
        isInstalled = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.spotify.client"
        ) != nil
        refresh()
        // Event-driven: Spotify broadcasts every play/pause/track change —
        // instant updates, no osascript forks. 60s poll kept as safety net.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let info = note.userInfo else { return }
            self.isSpotifyRunning = true
            self.isPlaying = (info["Player State"] as? String) == "Playing"
            if let name = info["Name"] as? String { self.track = name }
            if let artist = info["Artist"] as? String { self.artist = artist }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        pollTimer?.tolerance = 10
    }

    // MARK: Commands

    func playPause() { command("playpause") }
    func nextTrack() { command("next track") }
    func previousTrack() { command("previous track") }

    func play(uri: String) {
        queue.async { [weak self] in
            self?.runScript("tell application \"Spotify\" to open location \"\(uri)\"")
            Thread.sleep(forTimeInterval: 0.8)
            self?.runScript("tell application \"Spotify\" to play")
            self?.refresh()
        }
    }

    /// Re-probe after the user grants access (or to trigger the consent prompt).
    func retryPermission() {
        DispatchQueue.main.async { self.permissionDenied = false }
        queue.async { [weak self] in
            self?.runScript("tell application \"Spotify\" to player state as string")
            self?.refresh()
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.spotify.client"
        ) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func command(_ cmd: String) {
        queue.async { [weak self] in
            self?.runScript("tell application \"Spotify\" to \(cmd)")
            Thread.sleep(forTimeInterval: 0.15)
            self?.refresh()
        }
    }

    /// Run a script on the serial queue, surfacing permission errors.
    @discardableResult
    private func runScript(_ script: String) -> String? {
        let result = Self.osascript(script)
        if result.deniedByTCC {
            DispatchQueue.main.async { self.permissionDenied = true }
        } else if result.output != nil {
            DispatchQueue.main.async { self.permissionDenied = false }
        }
        return result.output
    }

    // MARK: State polling

    func refresh() {
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).isEmpty
        if !running {
            DispatchQueue.main.async {
                self.isSpotifyRunning = false
                self.isPlaying = false
                self.track = ""
                self.artist = ""
            }
            return
        }
        // Don't spam Apple events (and TCC) while access is denied.
        if permissionDenied { return }
        queue.async { [weak self] in
            guard let self, !self.isRefreshing else { return }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            let script = """
            tell application "Spotify"
                set info to (player state as string)
                try
                    set info to info & "|||" & (name of current track) & "|||" & (artist of current track)
                end try
                return info
            end tell
            """
            let output = self.runScript(script) ?? ""
            let parts = output.components(separatedBy: "|||")
            DispatchQueue.main.async {
                self.isSpotifyRunning = true
                if !parts.isEmpty, !output.isEmpty {
                    self.isPlaying = parts.first == "playing"
                    self.track = parts.count > 1 ? parts[1] : ""
                    self.artist = parts.count > 2 ? parts[2] : ""
                }
            }
        }
    }

    private var isRefreshing = false

    /// Runs osascript with a hard watchdog so a hung Apple event can never
    /// back up the command queue. AppleScript-level timeout keeps Spotify
    /// queries snappy; the process kill is the last resort.
    private static func osascript(
        _ script: String, watchdogSeconds: Double = 8
    ) -> (output: String?, deniedByTCC: Bool) {
        let wrapped = "with timeout of 4 seconds\n\(script)\nend timeout"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", wrapped]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return (nil, false)
        }
        if done.wait(timeout: .now() + watchdogSeconds) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        let out = String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        // -1743: "Not authorized to send Apple events"
        let denied = err.contains("1743") || err.localizedCaseInsensitiveContains("not authorized")
        if process.terminationStatus != 0 { return (nil, denied) }
        return (out, denied)
    }
}

// MARK: - Player bar UI

struct SpotifyBar: View {
    @EnvironmentObject var spotify: SpotifyController
    @EnvironmentObject var engine: PomoEngine

    var theme: Theme { engine.theme }

    var body: some View {
        HStack(spacing: 12) {
            // Animated equalizer / note icon
            EqualizerIcon(active: spotify.isPlaying, color: theme.accent)
                .frame(width: 22, height: 18)

            if !spotify.isInstalled {
                Text("Spotify not installed")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            } else if spotify.permissionDenied {
                Text("Pomo needs permission to control Spotify")
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                Spacer()
                Button("Settings") { spotify.openAutomationSettings() }
                    .buttonStyle(PillButtonStyle(theme: theme))
                Button("Retry") { spotify.retryPermission() }
                    .buttonStyle(PillButtonStyle(theme: theme))
            } else if !spotify.isSpotifyRunning {
                Text("Spotify is closed")
                    .font(.system(size: 12, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Open") { spotify.openSpotify() }
                    .buttonStyle(PillButtonStyle(theme: theme))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spotify.track.isEmpty ? "Nothing playing" : spotify.track)
                        .font(.system(size: 12, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if !spotify.artist.isEmpty {
                        Text(spotify.artist)
                            .font(.system(size: 10, design: theme.fontDesign))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    IconButton(systemName: "backward.fill", size: 11, theme: theme) {
                        spotify.previousTrack()
                    }
                    IconButton(
                        systemName: spotify.isPlaying ? "pause.fill" : "play.fill",
                        size: 14, theme: theme
                    ) {
                        spotify.playPause()
                    }
                    IconButton(systemName: "forward.fill", size: 11, theme: theme) {
                        spotify.nextTrack()
                    }
                }
            }

            if spotify.isInstalled {
                Menu {
                    Section("Focus Playlists") {
                        ForEach(SpotifyController.focusPlaylists, id: \.uri) { playlist in
                            Button("\(playlist.emoji) \(playlist.name)") {
                                spotify.play(uri: playlist.uri)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

/// Tiny animated equalizer bars that dance while music plays.
struct EqualizerIcon: View {
    let active: Bool
    let color: Color

    var body: some View {
        EqualizerBars(active: active, color: color)
    }
}

private struct EqualizerBars: View {
    let active: Bool
    let color: Color

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 2.5) {
                    ForEach(0..<4, id: \.self) { i in
                        let h: CGFloat = 5 + 13 * abs(sin(t * (2.4 + Double(i) * 0.7) + Double(i) * 1.3))
                        // scaleEffect, not .frame(height:): a per-tick frame
                        // change dirtied the WHOLE window's layout 20×/s
                        // (10-25% CPU while music played)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .frame(width: 3, height: 18)
                            .scaleEffect(x: 1, y: h / 18, anchor: .bottom)
                    }
                }
                .frame(height: 18, alignment: .bottom)
            }
        } else {
            // static bars when nothing is playing — no animation clock at all
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: 3, height: 4)
                }
            }
        }
    }
}

struct IconButton: View {
    let systemName: String
    let size: CGFloat
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(hovering ? theme.accent : theme.textPrimary)
                .scaleEffect(hovering ? 1.2 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.accent.opacity(configuration.isPressed ? 0.5 : 0.3)))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
