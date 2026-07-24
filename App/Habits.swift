import Foundation

struct Habit: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var dueMinutes: Int          // minutes from midnight; -1 == no time set
    var activeDays: Set<Int>     // which day-offsets of the global cycle it runs on

    var hasTime: Bool { dueMinutes >= 0 }
}

/// Compact label for a habit's days within a cycle of `length`.
func cycleLabel(days: Set<Int>, length: Int) -> String {
    let n = max(1, length)
    if n == 1 || days.count >= n { return "Daily" }
    let sorted = days.sorted().map { "D\($0 + 1)" }
    if sorted.count <= 3 { return sorted.joined(separator: "·") }
    return "\(sorted.count) days"
}

/// Habits, a global rotating cycle, and daily completions — persisted as one
/// CSV at ~/Library/Application Support/Pomo/habits.csv
///   cycle,<length>,<anchorEpoch>,
///   habit,<uuid>,<name>,<dueMinutes>,<activeDays |-sep>
///   done,<yyyy-MM-dd>,<uuid>,<HH:mm>
///   hidden,<yyyy-MM-dd>,<uuid>,
@MainActor
final class HabitStore: ObservableObject {
    @Published private(set) var habits: [Habit] = []
    @Published private(set) var completions: [String: [UUID: String]] = [:]
    @Published private(set) var hidden: [String: Set<UUID>] = [:]

    /// Length of the rotating routine (1 = plain daily). Day 1 = offset 0.
    @Published private(set) var cycleLength: Int = 1
    /// The calendar day that counts as "Day 1" of the cycle.
    private var cycleAnchor: Date = Calendar.current.startOfDay(for: Date())
    /// Per-cycle-day manual ordering of habit ids — each day independent.
    @Published private var dayOrder: [Int: [UUID]] = [:]

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("habits.csv")
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    init() {
        // midnight: re-publish so checklist/circle/heatmap roll to the new day
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        load()
        if habits.isEmpty && completions.isEmpty {
            habits = [
                Habit(name: "Morning stretch", dueMinutes: 9 * 60, activeDays: [0]),
                Habit(name: "Study block", dueMinutes: 15 * 60, activeDays: [0]),
                Habit(name: "Read 20 minutes", dueMinutes: 21 * 60, activeDays: [0]),
            ]
            save()
        }
    }

    static func dateKey(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    // MARK: cycle math

    private func daysSinceAnchor(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: cycleAnchor),
                                  to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Which day of the cycle a date falls on (0-based). 0 == "Day 1".
    func cycleDay(on date: Date = Date()) -> Int {
        let n = max(1, cycleLength)
        let d = daysSinceAnchor(date)
        return ((d % n) + n) % n
    }

    func isScheduled(_ habit: Habit, on date: Date) -> Bool {
        guard daysSinceAnchor(date) >= 0 else { return false }
        if habit.activeDays.isEmpty { return true }
        return habit.activeDays.contains(cycleDay(on: date))
    }

    /// Habits assigned to a cycle-day offset, in that day's own manual order
    /// (ids not yet ordered fall back to list order).
    func habits(onCycleDay offset: Int) -> [Habit] {
        let members = habits.filter { $0.activeDays.count >= max(1, cycleLength) || $0.activeDays.contains(offset) }
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var result: [Habit] = []
        var seen = Set<UUID>()
        for id in dayOrder[offset] ?? [] {
            if let h = byID[id] { result.append(h); seen.insert(id) }
        }
        for h in members where !seen.contains(h.id) { result.append(h) }
        return result
    }

    func label(for habit: Habit) -> String { cycleLabel(days: habit.activeDays, length: cycleLength) }

    // MARK: queries

    func isCompleted(_ habit: Habit, on date: Date = Date()) -> Bool {
        completions[Self.dateKey(date)]?[habit.id] != nil
    }

    func isLate(_ habit: Habit, now: Date = Date()) -> Bool {
        guard habit.hasTime, !isCompleted(habit, on: now) else { return false }
        let c = Calendar.current
        let minutes = c.component(.hour, from: now) * 60 + c.component(.minute, from: now)
        return minutes > habit.dueMinutes
    }

    func isHidden(_ habit: Habit, on date: Date = Date()) -> Bool {
        hidden[Self.dateKey(date)]?.contains(habit.id) ?? false
    }

    /// Habits shown in today's checklist — scheduled today, not dismissed,
    /// in today's manual (composer drag) order.
    func visibleHabits(on date: Date = Date()) -> [Habit] {
        let dropped = hidden[Self.dateKey(date)] ?? []
        return habits(onCycleDay: cycleDay(on: date))
            .filter { isScheduled($0, on: date) && !dropped.contains($0.id) }
    }

    func fraction(on date: Date) -> Double {
        let visible = visibleHabits(on: date)
        guard !visible.isEmpty else { return 0 }
        let ids = Set(visible.map(\.id))
        let done = (completions[Self.dateKey(date)] ?? [:]).keys.filter { ids.contains($0) }.count
        return Double(done) / Double(visible.count)
    }

    func completedCount(on date: Date = Date()) -> Int {
        let ids = Set(visibleHabits(on: date).map(\.id))
        return (completions[Self.dateKey(date)] ?? [:]).keys.filter { ids.contains($0) }.count
    }

    func visibleCount(on date: Date = Date()) -> Int { visibleHabits(on: date).count }

    // MARK: mutations

    func toggle(_ habit: Habit, on date: Date = Date()) {
        let key = Self.dateKey(date)
        var day = completions[key] ?? [:]
        if day[habit.id] != nil { day[habit.id] = nil }
        else { day[habit.id] = Self.timeFormatter.string(from: Date()) }
        completions[key] = day
        save()
    }

    func hide(_ habit: Habit, on date: Date = Date()) {
        let key = Self.dateKey(date)
        var day = hidden[key] ?? []
        day.insert(habit.id)
        hidden[key] = day
        save()
    }

    @discardableResult
    func add(name: String, dueMinutes: Int, days: Set<Int>? = nil) -> Habit? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved = sanitize(days ?? Set(0..<max(1, cycleLength)))
        let habit = Habit(name: trimmed, dueMinutes: dueMinutes, activeDays: resolved)
        habits.append(habit)
        save()
        return habit
    }

    func delete(_ habit: Habit) { habits.removeAll { $0.id == habit.id }; save() }

    func rename(_ habit: Habit, to name: String) {
        guard let i = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[i].name = name; save()
    }

    func setDue(_ habit: Habit, minutes: Int) {
        guard let i = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[i].dueMinutes = minutes; save()
    }

    /// Assign which cycle-days this habit runs on.
    func setDays(_ habit: Habit, _ days: Set<Int>) {
        guard let i = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[i].activeDays = sanitize(days); save()
    }

    /// Toggle a single cycle-day for a habit.
    func toggleDay(_ habit: Habit, _ offset: Int) {
        guard let i = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        var days = habits[i].activeDays
        if days.count >= max(1, cycleLength) { days = Set(0..<max(1, cycleLength)) }  // was daily → make explicit
        if days.contains(offset) { if days.count > 1 { days.remove(offset) } }
        else { days.insert(offset) }
        habits[i].activeDays = sanitize(days); save()
    }

    /// Give a habit a cycle-day (no save) — used before saving in add/place.
    private func ensureDay(_ id: UUID, _ day: Int) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        var days = habits[i].activeDays
        if days.count >= max(1, cycleLength) { days = Set(0..<max(1, cycleLength)) }  // daily → explicit
        days.insert(day)
        habits[i].activeDays = sanitize(days)
    }

    /// Assign a habit to a cycle-day, appended to that day's order.
    func addDay(_ id: UUID, _ day: Int) {
        ensureDay(id, day)
        var order = dayOrder[day] ?? []
        if !order.contains(id) { order.append(id) }
        dayOrder[day] = order
        save()
    }

    /// Reorder within a day only (independent of every other day): assign the
    /// habit to `day` and move it just before `targetID` in that day's order.
    func place(_ id: UUID, before targetID: UUID?, on day: Int) {
        guard id != targetID, habits.contains(where: { $0.id == id }) else { return }
        ensureDay(id, day)
        var order = habits(onCycleDay: day).map(\.id)   // current members, this day's order
        order.removeAll { $0 == id }
        if let t = targetID, let ti = order.firstIndex(of: t) {
            order.insert(id, at: ti)
        } else {
            order.append(id)
        }
        dayOrder[day] = order
        save()
    }

    /// Stop a habit running on a given cycle-day. If that empties its schedule
    /// (e.g. a daily habit in a 1-day cycle), delete the habit outright.
    func removeFromDay(_ habit: Habit, _ offset: Int) {
        guard let i = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        var days = habits[i].activeDays
        if days.count >= max(1, cycleLength) { days = Set(0..<max(1, cycleLength)) }  // daily → explicit
        days.remove(offset)
        if days.isEmpty { habits.remove(at: i) } else { habits[i].activeDays = days }
        save()
    }

    /// Change the global routine length. Daily habits stay daily; day-specific
    /// habits keep the offsets that still fit. Anchors "Day 1" to today.
    func setCycleLength(_ n: Int) {
        let new = max(1, min(30, n))
        let old = max(1, cycleLength)
        for i in habits.indices {
            if habits[i].activeDays.count >= old {          // was daily
                habits[i].activeDays = Set(0..<new)
            } else {
                var kept = habits[i].activeDays.filter { $0 < new }
                if kept.isEmpty { kept = [0] }
                habits[i].activeDays = kept
            }
        }
        cycleLength = new
        cycleAnchor = Calendar.current.startOfDay(for: Date())
        save()
    }

    private func sanitize(_ days: Set<Int>) -> Set<Int> {
        let n = max(1, cycleLength)
        var d = days.filter { $0 >= 0 && $0 < n }
        if d.isEmpty { d = [0] }
        return d
    }

    // MARK: CSV persistence

    private func save() {
        var lines = ["type,a,b,c"]
        lines.append("cycle,\(cycleLength),\(Int(cycleAnchor.timeIntervalSince1970)),")
        for habit in habits {
            let days = habit.activeDays.sorted().map(String.init).joined(separator: "|")
            lines.append("habit,\(habit.id.uuidString),\(Self.escape(habit.name)),\(habit.dueMinutes),\(days)")
        }
        for (day, entries) in completions.sorted(by: { $0.key < $1.key }) {
            for (id, time) in entries { lines.append("done,\(day),\(id.uuidString),\(time)") }
        }
        for (day, ids) in hidden.sorted(by: { $0.key < $1.key }) {
            for id in ids { lines.append("hidden,\(day),\(id.uuidString),") }
        }
        for (day, ids) in dayOrder.sorted(by: { $0.key < $1.key }) where !ids.isEmpty {
            lines.append("order,\(day),\(ids.map(\.uuidString).joined(separator: "|")),")
        }
        try? lines.joined(separator: "\n").write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    private func load() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        var loadedHabits: [Habit] = []
        var loadedCompletions: [String: [UUID: String]] = [:]
        var loadedHidden: [String: Set<UUID>] = [:]
        var loadedOrder: [Int: [UUID]] = [:]
        var loadedLength = 1
        var sawCycle = false
        var maxLegacyLen = 1

        func pipe(_ s: String) -> Set<Int> { Set(s.split(separator: "|").compactMap { Int($0) }) }

        for line in text.split(separator: "\n").dropFirst() {
            let f = Self.parse(String(line))
            guard f.count >= 4 else { continue }
            switch f[0] {
            case "cycle":
                sawCycle = true
                loadedLength = max(1, Int(f[1]) ?? 1)
                if let epoch = Double(f[2]) { cycleAnchor = Date(timeIntervalSince1970: epoch) }
            case "habit":
                guard let id = UUID(uuidString: f[1]), let due = Int(f[3]) else { break }
                var days: Set<Int>
                // new format: field4 = activeDays (pipe or single int), exactly 5 fields
                if f.count == 5 {
                    days = f[4].isEmpty ? [0] : pipe(f[4])
                } else {
                    // legacy: field4=perHabitLength, field6=activeDays
                    let len = Int(f[4]) ?? 1
                    maxLegacyLen = max(maxLegacyLen, len)
                    days = (f.count >= 7 && !f[6].isEmpty) ? pipe(f[6]) : [0]
                }
                if days.isEmpty { days = [0] }
                loadedHabits.append(Habit(id: id, name: f[2], dueMinutes: due, activeDays: days))
            case "done":
                if let id = UUID(uuidString: f[2]) { loadedCompletions[f[1], default: [:]][id] = f[3] }
            case "hidden":
                if let id = UUID(uuidString: f[2]) { loadedHidden[f[1], default: []].insert(id) }
            case "order":
                if let day = Int(f[1]) {
                    loadedOrder[day] = f[2].split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                }
            default: break
            }
        }
        habits = loadedHabits
        completions = loadedCompletions
        hidden = loadedHidden
        dayOrder = loadedOrder
        cycleLength = sawCycle ? loadedLength : maxLegacyLen
    }

    private static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func parse(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") }
                        else if next == "," { inQuotes = false; fields.append(current); current = "" }
                        else { current.append(next) }
                    } else { inQuotes = false }
                } else { current.append(ch) }
            } else if ch == "\"" && current.isEmpty {
                inQuotes = true
            } else if ch == "," {
                fields.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}
