import SwiftUI
import WidgetKit
import UserNotifications
import AppKit

@MainActor
final class PomoEngine: ObservableObject {
    @Published var state: PomoState

    private var timer: Timer?
    private var widgetReload: DispatchWorkItem?

    var theme: Theme { Themes.theme(state.settings.themeID) }
    var remaining: TimeInterval { state.currentRemaining(at: Date()) }
    var progress: Double { state.progress(at: Date()) }

    init() {
        state = PomoStore.load()
        state.normalize()
        persist(reloadWidgets: true)
        syncTimer()
        observeDarwinChanges()
        requestNotificationPermission()
        resetSessionsIfNewDay()
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetSessionsIfNewDay() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromStore() }
        }
    }

    // MARK: Controls

    func toggle() { mutate { $0.toggle() } }
    func reset()  { mutate { $0.reset() } }
    func skip()   { mutate { $0.skip() } }
    func switchMode(_ mode: PomoMode) { mutate { $0.switchMode(to: mode) } }

    func updateSettings(_ transform: (inout PomoSettings) -> Void) {
        mutate { state in
            let wasIdleAtFull = !state.isRunning && abs(state.remaining - state.currentDuration) < 1
            transform(&state.settings)
            // If the timer is sitting idle at a full phase, adopt the new duration.
            if wasIdleAtFull { state.remaining = state.currentDuration }
        }
    }

    func setTheme(_ id: String) {
        mutate { $0.settings.themeID = id }
    }

    private func mutate(_ transform: (inout PomoState) -> Void) {
        transform(&state)
        persist(reloadWidgets: true)
        syncTimer()
    }

    // MARK: Ticking

    /// The tick only exists to catch phase rollover — an idle timer needs no
    /// clock at all, so stop it entirely (zero wakeups) until running again.
    private func syncTimer() {
        if state.isRunning {
            startTicking()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.1   // let the system coalesce wakeups
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        // No publishes here: the ring's own TimelineView drives the visible
        // countdown. This tick only detects phase rollover.
        guard state.isRunning else { return }
        let current = Date()
        guard let end = state.endDate, end <= current else { return }
        let finishedMode = state.mode
        state.normalize(now: current)
        persist(reloadWidgets: true)
        syncTimer()
        celebrate(finished: finishedMode)
    }

    private func celebrate(finished: PomoMode) {
        if state.settings.soundOn {
            NSSound(named: finished == .focus ? "Glass" : "Ping")?.play()
        }
        let content = UNMutableNotificationContent()
        content.title = finished == .focus ? "Focus session complete! 🍅" : "Break's over!"
        content.body = finished == .focus
            ? "Time for a \(state.mode == .longBreak ? "long" : "short") break."
            : "Back to focus — you've got this."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Persistence & cross-process sync

    private func persist(reloadWidgets: Bool) {
        PomoStore.save(state)
        guard reloadWidgets else { return }
        // debounce: settings-slider drags fired dozens of reloads/sec into chronod
        widgetReload?.cancel()
        let work = DispatchWorkItem { WidgetCenter.shared.reloadAllTimelines() }
        widgetReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func reloadFromStore() {
        var fresh = PomoStore.load()
        fresh.normalize()
        if fresh != state { state = fresh }
        syncTimer()   // widget may have started/stopped the timer
    }

    private func observeDarwinChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let engine = Unmanaged<PomoEngine>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in engine.reloadFromStore() }
        }, PomoStore.changeNote as CFString, nil, .deliverImmediately)
    }

    /// Session dots / 🍅 count are a daily stat — zero them at midnight.
    private func resetSessionsIfNewDay() {
        let today = HabitStore.dateKey()
        let key = "pomo.sessionDay"
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(today, forKey: key)
        guard last != nil, last != today, state.completedFocusSessions != 0 else { return }
        state.completedFocusSessions = 0
        persist(reloadWidgets: true)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
