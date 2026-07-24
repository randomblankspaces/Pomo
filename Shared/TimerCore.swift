import Foundation

// MARK: - Model

enum PomoMode: String, Codable, CaseIterable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: return "FOCUS"
        case .shortBreak: return "SHORT BREAK"
        case .longBreak: return "LONG BREAK"
        }
    }

    var shortTitle: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long Break"
        }
    }
}

struct PomoSettings: Codable, Equatable {
    var focusMinutes: Double = 25
    var shortBreakMinutes: Double = 5
    var longBreakMinutes: Double = 15
    var sessionsUntilLongBreak: Int = 4
    var autoStartNext: Bool = false
    var soundOn: Bool = true
    var themeID: String = "sakura"
    // Optional so state saved by older versions still decodes.
    var disabledFX: [String]? = nil      // entries: "<themeID>.<styleRawValue>"
    var particleOverrides: [String: String]? = nil  // themeID -> ParticleStyle.rawValue
    var pointerFX: Bool? = nil           // master cursor/click reactivity switch
    var parallax: Bool? = nil            // background follows the cursor
    var fxDensity: Double? = nil         // particle amount multiplier
    var fxSize: Double? = nil            // particle size multiplier
    var breathing: Bool? = nil           // ring breathing pulse while running
    var batterySaver: Bool? = nil        // shed visual cost while on battery

    var batterySaverOn: Bool { batterySaver ?? true }
    var breathingOn: Bool { breathing ?? true }
    var pointerFXOn: Bool { pointerFX ?? true }
    var parallaxOn: Bool { parallax ?? true }
    var fxDensityValue: Double { fxDensity ?? 1.0 }
    var fxSizeValue: Double { fxSize ?? 1.0 }

    func isFXEnabled(themeID: String, _ style: ParticleStyle) -> Bool {
        !(disabledFX ?? []).contains("\(themeID).\(style.rawValue)")
    }

    mutating func setFX(themeID: String, _ style: ParticleStyle, enabled: Bool) {
        let key = "\(themeID).\(style.rawValue)"
        var list = disabledFX ?? []
        if enabled {
            list.removeAll { $0 == key }
        } else if !list.contains(key) {
            list.append(key)
        }
        disabledFX = list
    }

    func particleOverride(for themeID: String) -> ParticleStyle? {
        guard let raw = particleOverrides?[themeID] else { return nil }
        return ParticleStyle(rawValue: raw)
    }

    mutating func setParticleOverride(themeID: String, _ style: ParticleStyle?) {
        var map = particleOverrides ?? [:]
        if let style {
            map[themeID] = style.rawValue
        } else {
            map.removeValue(forKey: themeID)
        }
        particleOverrides = map.isEmpty ? nil : map
    }
}

struct PomoState: Codable, Equatable {
    var mode: PomoMode = .focus
    var isRunning: Bool = false
    var endDate: Date? = nil                 // valid while running
    var remaining: TimeInterval = 25 * 60    // valid while paused
    var completedFocusSessions: Int = 0
    var settings = PomoSettings()
}

// MARK: - Transitions (shared by app + widget intents)

extension PomoState {
    func duration(for mode: PomoMode) -> TimeInterval {
        switch mode {
        case .focus: return settings.focusMinutes * 60
        case .shortBreak: return settings.shortBreakMinutes * 60
        case .longBreak: return settings.longBreakMinutes * 60
        }
    }

    var currentDuration: TimeInterval { duration(for: mode) }

    func currentRemaining(at now: Date = Date()) -> TimeInterval {
        if isRunning, let end = endDate { return max(0, end.timeIntervalSince(now)) }
        return remaining
    }

    func progress(at now: Date = Date()) -> Double {
        let d = currentDuration
        guard d > 0 else { return 0 }
        return min(1, max(0, 1 - currentRemaining(at: now) / d))
    }

    /// Roll over any phases that finished while nobody was looking.
    /// Returns true if at least one phase completed.
    @discardableResult
    mutating func normalize(now: Date = Date()) -> Bool {
        var completedAny = false
        var guardCounter = 0
        while isRunning, let end = endDate, end <= now, guardCounter < 64 {
            completePhase(at: end)
            completedAny = true
            guardCounter += 1
        }
        return completedAny
    }

    mutating func start(now: Date = Date()) {
        if remaining <= 0 { remaining = currentDuration }
        endDate = now.addingTimeInterval(remaining)
        isRunning = true
    }

    mutating func pause(now: Date = Date()) {
        remaining = currentRemaining(at: now)
        isRunning = false
        endDate = nil
    }

    mutating func toggle(now: Date = Date()) {
        normalize(now: now)
        if isRunning { pause(now: now) } else { start(now: now) }
    }

    mutating func reset() {
        // resetting an untouched timer also clears the session counter
        let wasIdleAtFull = !isRunning && abs(remaining - currentDuration) < 1
        isRunning = false
        endDate = nil
        remaining = currentDuration
        if wasIdleAtFull { completedFocusSessions = 0 }
    }

    mutating func skip(now: Date = Date()) {
        normalize(now: now)
        completePhase(at: now, countSession: mode == .focus)
    }

    mutating func switchMode(to newMode: PomoMode) {
        mode = newMode
        isRunning = false
        endDate = nil
        remaining = duration(for: newMode)
    }

    mutating func completePhase(at date: Date, countSession: Bool = true) {
        if mode == .focus && countSession { completedFocusSessions += 1 }
        let next: PomoMode
        if mode == .focus {
            let n = max(1, settings.sessionsUntilLongBreak)
            next = (completedFocusSessions % n == 0) ? .longBreak : .shortBreak
        } else {
            next = .focus
        }
        mode = next
        remaining = duration(for: next)
        if settings.autoStartNext {
            endDate = date.addingTimeInterval(remaining)
            isRunning = true
        } else {
            endDate = nil
            isRunning = false
        }
    }
}

// MARK: - Shared store (App Group)

enum PomoStore {
    static let appGroup: String = {
        let teamPrefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String
            ?? (Bundle.main.bundleIdentifier.map { _ in "" } ?? "")
        return "\(teamPrefix)com.pomo.app"
    }()
    static let stateKey = "pomoState.v1"
    static let changeNote = "com.pomo.app.stateChanged"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func load() -> PomoState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(PomoState.self, from: data)
        else { return PomoState() }
        return state
    }

    static func save(_ state: PomoState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: stateKey)
        }
    }

    /// Notify other processes (app <-> widget) that shared state changed.
    static func postChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(changeNote as CFString),
            nil, nil, true
        )
    }
}

// MARK: - Formatting

func pomoFormat(_ t: TimeInterval) -> String {
    let total = Int(t.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}
