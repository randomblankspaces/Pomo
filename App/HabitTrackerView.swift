import SwiftUI
import UniformTypeIdentifiers

// Habit tracking integrated straight into the Pomo display — no cards, no
// chrome. A freestanding progress circle + checklist live left of the timer,
// the month heatmap lives right of it, all drawn directly on the theme.
// Exception: the Glass theme gives each widget a frosted blur backdrop.

private extension View {
    /// Clear-blur backing used ONLY by the Glass theme's calendar: the
    /// wallpaper itself, gently blurred — no white or gray material tint.
    @ViewBuilder
    func glassBacking(_ on: Bool, scale: CGFloat) -> some View {
        if on {
            self
                .padding(18 * scale)
                .background(
                    WallpaperBlurPatch()
                        // faint veil: keeps dark ink legible without hiding the view
                        .overlay(Color.white.opacity(0.17))
                        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        )
                )
        } else {
            self
        }
    }
}

// MARK: - Left panel: independent progress circle + checklist

/// Shared editing state — the header pencil toggles both panels together so
/// the right panel can show a schedule preview while you're editing.
@MainActor
final class HabitEditState: ObservableObject {
    @Published var editing = false
}

struct HabitLeftPanel: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore
    @EnvironmentObject var editState: HabitEditState
    var scale: CGFloat = 1

    private var editing: Bool { editState.editing }
    @State private var newName = ""
    @State private var newMinutes = -1   // -1 = no time by default
    @State private var newDays: Set<Int> = [0]
    @State private var showComposer = false

    var theme: Theme { engine.theme }

    var body: some View {
        // strict 50/50 vertical split: circle centered in the top half,
        // list centered in the bottom half — both as large as the half allows
        GeometryReader { geo in
            let diameter = min(geo.size.height * 0.37, geo.size.width * 0.92)
            VStack(spacing: 0) {
                progressCircle(diameter: diameter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                checklist
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // The circle stands alone — sized off its half of the screen.
    private func progressCircle(diameter: CGFloat) -> some View {
        let total = store.habits.count
        let done = store.completedCount()
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        return VStack(spacing: diameter * 0.07) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: diameter * 0.062, lineCap: .round))
                Circle()
                    .trim(from: 0, to: max(0.0001, fraction))
                    .stroke(
                        AngularGradient(colors: [theme.ringA, theme.ringB, theme.ringA], center: .center),
                        style: StrokeStyle(lineWidth: diameter * 0.062, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: theme.accent.opacity(0.5 * theme.glow), radius: 12)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
                VStack(spacing: 2) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: diameter * 0.24, weight: .bold, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                    Text("\(done)/\(total)")
                        .font(.system(size: diameter * 0.08, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .frame(width: diameter, height: diameter)

            Text(done == total && total > 0 ? "ALL CLEAR" : "TODAY")
                .font(.system(size: max(11, diameter * 0.055), weight: .bold, design: theme.fontDesign))
                .tracking(4)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            HStack {
                Text("HABITS")
                    .font(.system(size: 12 * scale, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                IconButton(systemName: editing ? "checkmark.circle.fill" : "pencil", size: 15 * scale, theme: theme) {
                    withAnimation(.snappy) { editState.editing.toggle() }
                }
                .help(editing ? "Done editing" : "Edit habits")
            }

            // 30s clock keeps day-progress bars and LATE state current
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let shown = editing ? store.habits : store.visibleHabits(on: timeline.date)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 17 * scale) {
                        ForEach(shown) { habit in
                            HabitRow(habit: habit, now: timeline.date, editing: editing, scale: scale)
                        }
                        if store.habits.isEmpty {
                            Text("No habits yet — tap the pencil")
                                .font(.system(size: 13 * scale, design: theme.fontDesign))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if editing { addRow }
        }
        .padding(.vertical, 14 * scale)
    }

    private var addRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("New habit", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                    .onSubmit(addHabit)
                OptionalTimeField(minutes: $newMinutes, accent: theme.accent)
                DayCycleChip(
                    days: $newDays,
                    cycleLength: store.cycleLength,
                    setCycleLength: { store.setCycleLength($0) },
                    theme: theme
                )
                IconButton(systemName: "plus.circle.fill", size: 17, theme: theme, action: addHabit)
            }
            // the "complex" calendar composer, right under the + row
            Button {
                showComposer = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Complex schedule…")
                        .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                }
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showComposer, arrowEdge: .bottom) {
                ScheduleComposer()
                    .environmentObject(engine)
                    .environmentObject(store)
            }
        }
    }

    private func addHabit() {
        store.add(name: newName, dueMinutes: newMinutes, days: newDays)
        newName = ""
    }
}

/// Repeat chip — click to pop up the cycle editor, where you set the routine
/// length and tap which cycle-days this habit runs on.
struct DayCycleChip: View {
    @Binding var days: Set<Int>
    let cycleLength: Int
    let setCycleLength: (Int) -> Void
    let theme: Theme
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "repeat")
                    .font(.system(size: 9, weight: .semibold))
                Text(cycleLabel(days: days, length: cycleLength))
                    .font(.system(size: 10.5, weight: .semibold, design: theme.fontDesign))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            CycleEditor(days: $days, cycleLength: cycleLength, setCycleLength: setCycleLength, accent: theme.accent)
        }
    }
}

/// Popover: set the shared routine length, then tap which days of the cycle
/// this habit runs on.
struct CycleEditor: View {
    @Binding var days: Set<Int>
    let cycleLength: Int
    let setCycleLength: (Int) -> Void
    let accent: Color
    var inline = false   // embedded in a pane: skip own padding/width

    private var length: Int { max(1, cycleLength) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ROUTINE CYCLE")
                .font(.system(size: 11, weight: .bold)).tracking(3)
                .foregroundStyle(.secondary)

            HStack {
                Text("Cycle length")
                    .font(.system(size: 13))
                Spacer()
                Stepper(value: Binding(get: { length }, set: { setCycleLength($0) }), in: 1...30) {
                    Text("\(length) day\(length == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                }
            }

            Text(length == 1 ? "Runs every day."
                 : "Tap the days of the \(length)-day cycle this habit runs on.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: min(length, 6)), spacing: 8) {
                ForEach(0..<length, id: \.self) { offset in
                    let on = days.contains(offset) || days.count >= length
                    Button { toggle(offset) } label: {
                        VStack(spacing: 1) {
                            Text("Day").font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(on ? Color.black.opacity(0.6) : Color.secondary)
                            Text("\(offset + 1)")
                                .font(.system(size: 15, weight: on ? .bold : .regular))
                                .foregroundStyle(on ? Color.black.opacity(0.85) : Color.primary)
                        }
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(on ? AnyShapeStyle(accent) : AnyShapeStyle(Color.gray.opacity(0.18)))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Button("All days") { days = Set(0..<length) }
                Button("Clear") { days = [0] }
            }
            .font(.system(size: 11.5, weight: .medium))
            .buttonStyle(.borderless)
        }
        .padding(inline ? 0 : 18)
        .frame(width: inline ? nil : 300)
    }

    private func toggle(_ offset: Int) {
        var d = days
        if d.count >= length { d = Set(0..<length) }   // was "daily" → make explicit
        if d.contains(offset) { if d.count > 1 { d.remove(offset) } }
        else { d.insert(offset) }
        days = d
    }
}

/// Optional time input: -1 means "no time". Off by default; click to enable,
/// x to clear back to no-time.
struct OptionalTimeField: View {
    @Binding var minutes: Int
    var accent: Color = .accentColor

    private var asDate: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: max(0, minutes) / 60,
                                         minute: max(0, minutes) % 60, second: 0, of: Date()) ?? Date() },
            set: { d in let c = Calendar.current
                minutes = c.component(.hour, from: d) * 60 + c.component(.minute, from: d) }
        )
    }

    var body: some View {
        if minutes < 0 {
            Button { minutes = 9 * 60 } label: {
                HStack(spacing: 3) { Image(systemName: "clock"); Text("Time") }
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(accent)
        } else {
            HStack(spacing: 2) {
                DatePicker("", selection: asDate, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).frame(width: 72)
                Button { minutes = -1 } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Complex" composer opened under the + : one column PER CYCLE-DAY, each
/// listing that day's habits in their time slots, with a per-day add.
struct ScheduleComposer: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore

    @State private var name = ""
    @State private var addMinutes = -1
    @State private var selectedDay = 0
    @State private var detailDay: Int? = nil
    private struct DropSlot: Equatable { let day: Int; let id: UUID }
    @State private var dropTarget: DropSlot? = nil   // exact row+column drag hovers over
    @State private var cycleEditID: UUID? = nil      // habit whose day-editor popover is open
    @State private var draggingID: UUID? = nil       // habit lifted off the board

    /// NSItemProvider that reports when the drag session dies (drop OR cancel),
    /// so the lifted row can reappear even on cancelled drags.
    private final class DragTracker: NSItemProvider {
        var onEnd: (() -> Void)?
        deinit { let f = onEnd; DispatchQueue.main.async { f?() } }
    }

    var theme: Theme { engine.theme }
    private var length: Int { max(1, store.cycleLength) }

    var body: some View {
        Group {
            // nested .popover dies instantly inside this (already-popover)
            // composer — the habit editor is an inline pane instead
            if let id = cycleEditID, let habit = store.habits.first(where: { $0.id == id }) {
                habitEditor(habit)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let day = detailDay {
                DayTimelineDetail(day: day) { withAnimation(.snappy) { detailDay = nil } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                overview
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(width: cycleEditID != nil ? 380
               : detailDay == nil ? max(420, min(920, CGFloat(length) * 172 + 40)) : 470,
               height: 560)
    }

    private func habitEditor(_ habit: Habit) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { cycleEditID = nil } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text("EDIT HABIT")
                    .font(.system(size: 12, weight: .bold)).tracking(3)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            TextField("Habit name", text: Binding(
                get: { store.habits.first(where: { $0.id == habit.id })?.name ?? habit.name },
                set: { store.rename(habit, to: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 14, weight: .semibold))

            CycleEditor(
                days: Binding(
                    get: { store.habits.first(where: { $0.id == habit.id })?.activeDays ?? [] },
                    set: { store.setDays(habit, $0) }
                ),
                cycleLength: store.cycleLength,
                setCycleLength: { store.setCycleLength($0) },
                accent: theme.accent,
                inline: true
            )
            Spacer(minLength: 0)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            columns
            Divider()
            addForm
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ROUTINE SCHEDULE")
                    .font(.system(size: 12, weight: .bold)).tracking(3)
                    .foregroundStyle(.secondary)
                Text("Today is Day \(store.cycleDay() + 1) of \(length)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Text("Cycle length")
                    .font(.system(size: 12))
                Stepper(value: Binding(get: { length }, set: {
                    store.setCycleLength($0)
                    selectedDay = min(selectedDay, $0 - 1)
                }), in: 1...30) {
                    Text("\(length)d")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .monospacedDigit()
                }
            }
        }
    }

    private var columns: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<length, id: \.self) { day in
                    dayColumn(day)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func dayColumn(_ day: Int) -> some View {
        let isToday = day == store.cycleDay()
        let selected = day == selectedDay
        let dayHabits = store.habits(onCycleDay: day)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button { selectedDay = day } label: {
                    HStack(spacing: 5) {
                        Text("DAY \(day + 1)")
                            .font(.system(size: 11, weight: .bold)).tracking(1)
                        if isToday {
                            Text("TODAY")
                                .font(.system(size: 7.5, weight: .heavy))
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Capsule().fill(theme.accent))
                                .foregroundStyle(.black.opacity(0.8))
                        }
                        Spacer()
                    }
                    .foregroundStyle(selected ? theme.accent : .primary)
                }
                .buttonStyle(.plain)
                Button { openDetail(day) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Day \(day + 1) timeline")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? theme.accent.opacity(0.18) : Color.gray.opacity(0.12)))

            if dayHabits.isEmpty {
                Text("No habits")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(dayHabits) { habit in
                    let done = isToday && store.isCompleted(habit)
                    let hidden = isToday && store.isHidden(habit)
                    VStack(spacing: 0) {
                        // plain gap where drop lands — no box, no outline
                        if dropTarget == DropSlot(day: day, id: habit.id) {
                            Color.clear.frame(height: 30)
                        }
                        HStack(spacing: 6) {
                            Text(timeLabel(habit.dueMinutes))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 52, alignment: .leading)
                            Text(habit.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.primary)
                                .strikethrough(done, color: .secondary)
                                .lineLimit(1)
                            if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(theme.accent) }
                            if hidden { Image(systemName: "eye.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Button {
                                store.removeFromDay(habit, day)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from Day \(day + 1)")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent.opacity(0.14)))
                        // picked up → vanishes from the board, reappears on drop
                        .opacity(draggingID == habit.id ? 0 : 1)
                        .frame(height: draggingID == habit.id ? 0 : nil)
                        .clipped()
                        .onDrag {
                            DispatchQueue.main.async {   // after the drag image snapshot
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { draggingID = habit.id }
                            }
                            let provider = DragTracker(object: "\(habit.id.uuidString)|\(day)" as NSString)
                            provider.onEnd = {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    if draggingID == habit.id { draggingID = nil }
                                    dropTarget = nil
                                }
                            }
                            return provider
                        }
                    }
                    // drop zone = gap + row together, so releasing over the
                    // opened space lands the drop instead of falling through
                    .dropDestination(for: String.self) { items, _ in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dropTarget = nil }
                        return drop(items, before: habit.id, day: day)   // land before this row
                    } isTargeted: { over in
                        // sticky: gap stays until another row targets or drop
                        // lands — clearing on un-target caused flicker loop
                        guard over else { return }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            dropTarget = DropSlot(day: day, id: habit.id)
                        }
                    }
                    // double-click a habit → inline editor pane: rename +
                    // pick exactly which cycle-days it runs on
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { cycleEditID = habit.id }
                    }
                }
            }
            Spacer(minLength: 30)   // droppable empty space under the last habit
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: dropTarget)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: draggingID)
        .frame(width: 160, alignment: .topLeading)
        .frame(minHeight: 240, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDetail(day) }
        .simultaneousGesture(TapGesture().onEnded { selectedDay = day })
        .dropDestination(for: String.self) { items, _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dropTarget = nil }
            return dropAddDay(items, day: day)   // anywhere in the column → this day, order kept
        }
    }

    private func drop(_ items: [String], before targetID: UUID?, day: Int) -> Bool {
        guard let s = items.first, case let parts = s.components(separatedBy: "|"),
              parts.count == 2, let id = UUID(uuidString: parts[0]) else { return false }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            store.place(id, before: targetID, on: day)
            draggingID = nil
        }
        return true
    }

    private func dropAddDay(_ items: [String], day: Int) -> Bool {
        guard let s = items.first, case let parts = s.components(separatedBy: "|"),
              parts.count == 2, let id = UUID(uuidString: parts[0]) else { return false }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if store.habits(onCycleDay: day).contains(where: { $0.id == id }) {
                store.place(id, before: nil, on: day)   // already on this day → move to end
            } else {
                store.addDay(id, day)                   // new day → add, keep the others
            }
            draggingID = nil
        }
        return true
    }

    private func openDetail(_ day: Int) {
        selectedDay = day
        withAnimation(.snappy) { detailDay = day }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ADD TO DAY \(selectedDay + 1)")
                .font(.system(size: 9, weight: .bold)).tracking(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("New habit", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(add)
                OptionalTimeField(minutes: $addMinutes, accent: theme.accent)
                Button(action: add) {
                    Label("Add", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func timeLabel(_ minutes: Int) -> String {
        guard minutes >= 0 else { return "—" }
        let hour = minutes / 60
        let display = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%d:%02d%@", display, minutes % 60, hour >= 12 ? "p" : "a")
    }

    private func add() {
        store.add(name: name, dueMinutes: addMinutes, days: [selectedDay])
        name = ""
    }
}

/// Precise, readable single-day timeline: every hour labeled, each habit as a
/// block at its exact time. Edit times inline, remove from the day, or add.
private struct DayTimelineDetail: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore
    let day: Int
    let onBack: () -> Void

    @State private var name = ""
    @State private var addMinutes = -1

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    private var hourHeight: CGFloat { 46 * zoom }
    private let gutter: CGFloat = 54

    var theme: Theme { engine.theme }
    private var isToday: Bool { day == store.cycleDay() }
    private var dayHabits: [Habit] { store.habits(onCycleDay: day) }
    private var timedHabits: [Habit] { dayHabits.filter { $0.hasTime } }
    private var untimedHabits: [Habit] { dayHabits.filter { !$0.hasTime } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                Text("Day \(day + 1)")
                    .font(.system(size: 17, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(.primary)
                if isToday {
                    Text("TODAY")
                        .font(.system(size: 8, weight: .heavy)).tracking(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(theme.accent))
                        .foregroundStyle(.black.opacity(0.8))
                }
                Spacer()
                Text("\(dayHabits.count) habit\(dayHabits.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button { setZoom(zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button { setZoom(zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if !untimedHabits.isEmpty { anytimeRow }

            timeline
                .gesture(MagnifyGesture()
                    .onChanged { setZoom(lastZoom * $0.magnification) }
                    .onEnded { _ in lastZoom = zoom })
            Divider()
            addForm
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            let blockWidth = geo.size.width - gutter - 10
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // hour lines + labels
                        ForEach(0...24, id: \.self) { h in
                            let y = CGFloat(h) * hourHeight
                            Path { p in
                                p.move(to: CGPoint(x: gutter, y: y))
                                p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(.white.opacity(0.09), lineWidth: 1)
                            Text(hourLabel(h))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: gutter - 8, alignment: .trailing)
                                .position(x: (gutter - 8) / 2, y: y)
                            Color.clear.frame(width: 1, height: 1).id(h)   // scroll anchor
                        }

                        // "now" marker on today's timeline
                        if isToday {
                            let cal = Calendar.current
                            let nowMin = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
                            let y = CGFloat(nowMin) / 60 * hourHeight
                            Path { p in
                                p.move(to: CGPoint(x: gutter, y: y))
                                p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(Color(hex: 0xFF5A5F), lineWidth: 1.5)
                            Circle().fill(Color(hex: 0xFF5A5F))
                                .frame(width: 6, height: 6)
                                .position(x: gutter, y: y)
                        }

                        // habit blocks — anchored to their time, but pushed
                        // down when they'd overlap so none hide each other
                        ForEach(stacked(), id: \.0.id) { habit, topY in
                            blockView(habit, width: blockWidth)
                                .position(x: gutter + 5 + blockWidth / 2, y: topY + 17)
                        }
                    }
                    .frame(height: 24 * hourHeight + 20)
                }
                .onAppear {
                    let firstHour = timedHabits.map { $0.dueMinutes / 60 }.min() ?? 7
                    proxy.scrollTo(max(0, firstHour - 1), anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func blockView(_ habit: Habit, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            DatePicker("", selection: Binding(
                get: {
                    Calendar.current.date(bySettingHour: habit.dueMinutes / 60,
                                          minute: habit.dueMinutes % 60, second: 0, of: Date()) ?? Date()
                },
                set: { d in
                    let c = Calendar.current
                    store.setDue(habit, minutes: c.component(.hour, from: d) * 60 + c.component(.minute, from: d))
                }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .scaleEffect(0.85)
            .frame(width: 66)

            TextField("", text: Binding(
                get: { habit.name },
                set: { store.rename(habit, to: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black.opacity(0.82))
            .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                store.removeFromDay(habit, day)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Remove from Day \(day + 1)")
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 34, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.9)))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ADD TO DAY \(day + 1)")
                .font(.system(size: 9, weight: .bold)).tracking(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("New habit", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(add)
                OptionalTimeField(minutes: $addMinutes, accent: theme.accent)
                Button(action: add) {
                    Label("Add", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func setZoom(_ z: CGFloat) {
        zoom = min(4, max(0.5, z)); lastZoom = zoom
    }

    /// Time-anchored y for each habit, shoved down to avoid overlap.
    private func stacked() -> [(Habit, CGFloat)] {
        var out: [(Habit, CGFloat)] = []
        var lastBottom: CGFloat = -100
        for h in timedHabits {   // sorted by dueMinutes
            let y = max(CGFloat(h.dueMinutes) / 60 * hourHeight, lastBottom + 4)
            out.append((h, y))
            lastBottom = y + 34
        }
        return out
    }

    // Untimed habits sit in an "Anytime" strip above the clock grid.
    private var anytimeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ANYTIME")
                .font(.system(size: 8, weight: .bold)).tracking(2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(untimedHabits) { habit in
                        HStack(spacing: 5) {
                            Text(habit.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.82))
                                .lineLimit(1)
                            Button { store.setDue(habit, minutes: 9 * 60) } label: {
                                Image(systemName: "clock").font(.system(size: 9))
                            }.buttonStyle(.plain).foregroundStyle(.black.opacity(0.5))
                             .help("Give it a time")
                            Button { store.removeFromDay(habit, day) } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 10))
                            }.buttonStyle(.plain).foregroundStyle(.black.opacity(0.45))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.opacity(0.9)))
                    }
                }
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        if h == 0 || h == 24 { return "12 AM" }
        if h == 12 { return "12 PM" }
        return h < 12 ? "\(h) AM" : "\(h - 12) PM"
    }

    private func add() {
        store.add(name: name, dueMinutes: addMinutes, days: [day])
        name = ""
    }
}

// MARK: - Right panel: month heatmap

struct HabitRightPanel: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore
    @EnvironmentObject var editState: HabitEditState
    var scale: CGFloat = 1

    var theme: Theme { engine.theme }

    var body: some View {
        Group {
            if editState.editing {
                SchedulePreview(scale: scale)
            } else {
                MonthHeatmap(scale: scale)
            }
        }
        .glassBacking(theme.id == "glass", scale: scale)
    }
}

/// 14-day preview showing which days each habit will fire on.
/// Replaces the month heatmap while the pencil (edit) is active.
private struct SchedulePreview: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore
    var scale: CGFloat = 1

    var theme: Theme { engine.theme }

    private var glassy: Bool { theme.id == "glass" }
    private var inkPrimary: Color { glassy ? .black.opacity(0.9) : theme.textPrimary.opacity(0.85) }
    private var inkSecondary: Color { glassy ? .black.opacity(0.66) : theme.textSecondary }
    private var mark: Color { glassy ? Color(hex: 0x2E5E9E) : theme.accent }

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [Date] = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }

        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("SCHEDULE · NEXT 14 DAYS")
                .font(.system(size: 12 * scale, weight: .bold, design: theme.fontDesign))
                .tracking(3)
                .foregroundStyle(inkSecondary)

            if store.habits.isEmpty {
                Text("No habits yet — add some with the + row on the left.")
                    .font(.system(size: 12 * scale, design: theme.fontDesign))
                    .foregroundStyle(inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12 * scale) {
                        ForEach(store.habits) { habit in
                            HabitScheduleRow(habit: habit, days: days,
                                             mark: mark, ink: inkPrimary, muted: inkSecondary,
                                             scale: scale, theme: theme)
                        }
                    }
                }
            }
        }
    }
}

private struct HabitScheduleRow: View {
    let habit: Habit
    let days: [Date]
    let mark: Color
    let ink: Color
    let muted: Color
    let scale: CGFloat
    let theme: Theme
    @EnvironmentObject var store: HabitStore

    private var dueLabel: String {
        let hour = habit.dueMinutes / 60
        let display = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%d:%02d %@", display, habit.dueMinutes % 60, habit.dueMinutes >= 720 ? "PM" : "AM")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack {
                Text(habit.name)
                    .font(.system(size: 12.5 * scale, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(habit.hasTime ? "\(store.label(for: habit)) · \(dueLabel)" : store.label(for: habit))
                    .font(.system(size: 10.5 * scale, design: theme.fontDesign))
                    .foregroundStyle(muted)
                    .monospacedDigit()
            }
            // 14-day strip: colored pip if scheduled, hairline if not
            HStack(spacing: 4 * scale) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    let scheduled = store.isScheduled(habit, on: day)
                    let cal = Calendar.current
                    let weekday = String(cal.veryShortWeekdaySymbols[cal.component(.weekday, from: day) - 1].prefix(1))
                    VStack(spacing: 2 * scale) {
                        Text(weekday)
                            .font(.system(size: 8 * scale, weight: .semibold))
                            .foregroundStyle(muted)
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 9 * scale, weight: i == 0 ? .bold : .regular, design: theme.fontDesign))
                            .foregroundStyle(muted)
                        Circle()
                            .fill(scheduled ? AnyShapeStyle(mark) : AnyShapeStyle(Color.clear))
                            .overlay(
                                Circle().strokeBorder(scheduled ? .clear : muted.opacity(0.4), lineWidth: 1)
                            )
                            .frame(width: 8 * scale, height: 8 * scale)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Habit row

private struct HabitRow: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore
    let habit: Habit
    let now: Date
    let editing: Bool
    var scale: CGFloat = 1
    @State private var hovering = false

    var theme: Theme { engine.theme }

    private var done: Bool { store.isCompleted(habit, on: now) }
    private var late: Bool { store.isLate(habit, now: now) }

    private var dayFraction: Double {
        guard habit.dueMinutes > 0 else { return 1 }
        let c = Calendar.current
        let minutes = Double(c.component(.hour, from: now) * 60 + c.component(.minute, from: now))
        return min(1, minutes / Double(habit.dueMinutes))
    }

    private var barColor: Color {
        if done { return theme.accent.opacity(0.55) }
        if late { return Color(hex: 0xFF5A5F) }
        if dayFraction > 0.8 { return Color(hex: 0xFFB03A) }
        return theme.accent
    }

    private var dueLabel: String {
        let hour = habit.dueMinutes / 60
        let display = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%d:%02d %@", display, habit.dueMinutes % 60, habit.dueMinutes >= 720 ? "PM" : "AM")
    }

    var body: some View {
        HStack(spacing: 11) {
            if editing {
                IconButton(systemName: "minus.circle.fill", size: 17 * scale, theme: theme) {
                    store.delete(habit)
                }
            } else {
                Button {
                    withAnimation(.snappy) { store.toggle(habit) }
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21 * scale))
                        .foregroundStyle(done ? theme.accent : theme.textSecondary.opacity(0.7))
                        .shadow(color: done ? theme.accent.opacity(0.6) : .clear, radius: 5)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if editing {
                        TextField("", text: Binding(
                            get: { habit.name },
                            set: { store.rename(habit, to: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15 * scale, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                    } else {
                        Text(habit.name)
                            .font(.system(size: 15 * scale, design: theme.fontDesign))
                            .foregroundStyle(done ? theme.textSecondary : theme.textPrimary)
                            .strikethrough(done, color: theme.textSecondary)
                            .lineLimit(1)
                    }
                    if hovering && late {
                        Text("LATE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: 0xFF5A5F)))
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer(minLength: 4)
                    if editing {
                        OptionalTimeField(
                            minutes: Binding(
                                get: { habit.dueMinutes },
                                set: { store.setDue(habit, minutes: $0) }
                            ),
                            accent: theme.accent
                        )
                        DayCycleChip(
                            days: Binding(
                                get: { habit.activeDays },
                                set: { store.setDays(habit, $0) }
                            ),
                            cycleLength: store.cycleLength,
                            setCycleLength: { store.setCycleLength($0) },
                            theme: theme
                        )
                    } else if habit.hasTime {
                        Text(dueLabel)
                            .font(.system(size: 11.5 * scale, design: theme.fontDesign))
                            .foregroundStyle(late ? Color(hex: 0xFF5A5F) : theme.textSecondary)
                            .monospacedDigit()
                    }
                }
                // the day creeping toward this habit's deadline (timed only) —
                // hairline track so the wallpaper shows through
                if habit.hasTime {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(5, geo.size.width * dayFraction))
                                .shadow(color: barColor.opacity(0.6), radius: 3)
                        }
                    }
                    .frame(height: 5 * scale)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            // double-click a late habit to dismiss it from today's list
            if late && !editing {
                withAnimation(.snappy) { store.hide(habit) }
            }
        }
        .animation(.snappy(duration: 0.18), value: hovering)
    }
}

// MARK: - Month heatmap (sequential single-hue ramp of the theme accent)

private struct MonthHeatmap: View {
    @EnvironmentObject var engine: PomoEngine
    @EnvironmentObject var store: HabitStore
    var scale: CGFloat = 1

    var theme: Theme { engine.theme }

    private var cellSize: CGFloat { 56 * scale }
    private var cellGap: CGFloat { 8 * scale }

    // On the Glass theme the calendar sits on a light frost card,
    // so its ink flips dark for contrast.
    private var glassy: Bool { theme.id == "glass" }
    private var inkPrimary: Color { glassy ? .black.opacity(0.9) : theme.textPrimary.opacity(0.85) }
    private var inkSecondary: Color { glassy ? .black.opacity(0.66) : theme.textSecondary }
    private var cellAccent: Color { glassy ? Color(hex: 0x2E5E9E) : theme.accent }

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        let dayCount = cal.range(of: .day, in: .month, for: today)!.count
        let leadingBlanks = cal.component(.weekday, from: firstOfMonth) - 1
        let weeks = Int(ceil(Double(leadingBlanks + dayCount) / 7))

        return VStack(alignment: .leading, spacing: 14 * scale) {
            Text(today.formatted(.dateTime.month(.wide).year()).uppercased())
                .font(.system(size: 13 * scale, weight: .bold, design: theme.fontDesign))
                .tracking(4)
                .foregroundStyle(inkSecondary)

            HStack(spacing: cellGap) {
                ForEach(Array("SMTWTFS".enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(inkSecondary)
                        .frame(width: cellSize)
                }
            }

            VStack(spacing: cellGap) {
                ForEach(0..<weeks, id: \.self) { week in
                    HStack(spacing: cellGap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let dayNumber = week * 7 + weekday - leadingBlanks + 1
                            if dayNumber >= 1 && dayNumber <= dayCount {
                                let date = cal.date(byAdding: .day, value: dayNumber - 1, to: firstOfMonth)!
                                cell(for: date, dayNumber: dayNumber, today: today)
                            } else {
                                Color.clear.frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text("Less")
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(inkSecondary)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(step == 0 ? AnyShapeStyle(Color.clear)
                                        : AnyShapeStyle(cellAccent.opacity(0.18 + 0.68 * Double(step) / 4)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(
                                    (glassy ? Color.black.opacity(0.3) : .white.opacity(0.3))
                                        .opacity(step == 0 ? 1 : 0),
                                    lineWidth: 0.8
                                )
                        )
                        .frame(width: 14, height: 14)
                }
                Text("More")
                    .font(.system(size: 11, design: theme.fontDesign))
                    .foregroundStyle(inkSecondary)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func cell(for date: Date, dayNumber: Int, today: Date) -> some View {
        let isToday = date == today
        let isFuture = date > today
        let fraction = isFuture ? 0 : store.fraction(on: date)
        let doneCount = isFuture ? 0 : store.completedCount(on: date)

        // see-through: outlines for empty days, translucent accent only when
        // there is data to show — the wallpaper stays visible everywhere
        RoundedRectangle(cornerRadius: 10)
            .fill(fraction == 0 ? AnyShapeStyle(Color.clear)
                  : AnyShapeStyle(cellAccent.opacity(0.16 + 0.62 * fraction)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isToday ? (glassy ? Color.black.opacity(0.8) : theme.ringB)
                        : isFuture ? (glassy ? .black.opacity(0.2) : .white.opacity(0.10))
                        : fraction == 0 ? (glassy ? .black.opacity(0.42) : .white.opacity(0.24))
                        : (glassy ? .black.opacity(0.12) : .white.opacity(0.06)),
                        lineWidth: isToday ? 1.8 : 1
                    )
            )
            .overlay(
                Text("\(dayNumber)")
                    .font(.system(size: 16 * scale, weight: isToday ? .bold : .regular, design: theme.fontDesign))
                    .foregroundStyle(
                        fraction > 0.55 ? (glassy ? Color.white : Color.black.opacity(0.65))
                        : isFuture ? inkSecondary.opacity(0.6) : inkPrimary
                    )
                    // light halo lifts dark digits off dark rocks behind the glass
                    .shadow(color: glassy ? .white.opacity(0.45) : .clear, radius: 2)
            )
            .frame(width: cellSize, height: cellSize)
            .shadow(color: fraction > 0.7 ? cellAccent.opacity(0.35) : .clear, radius: 5)
            .help(isFuture ? date.formatted(date: .abbreviated, time: .omitted)
                  : "\(date.formatted(date: .abbreviated, time: .omitted)) — \(doneCount)/\(store.habits.count) done")
    }
}
