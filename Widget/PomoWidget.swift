import WidgetKit
import SwiftUI

@main
struct PomoWidgetBundle: WidgetBundle {
    var body: some Widget {
        PomoWidget()
    }
}

// MARK: - Timeline

struct PomoEntry: TimelineEntry {
    let date: Date
    let state: PomoState
}

struct PomoProvider: TimelineProvider {
    func placeholder(in context: Context) -> PomoEntry {
        PomoEntry(date: Date(), state: PomoState())
    }

    func getSnapshot(in context: Context, completion: @escaping (PomoEntry) -> Void) {
        var state = PomoStore.load()
        state.normalize()
        completion(PomoEntry(date: Date(), state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PomoEntry>) -> Void) {
        var state = PomoStore.load()
        let now = Date()
        state.normalize(now: now)

        var entries: [PomoEntry] = [PomoEntry(date: now, state: state)]

        if state.isRunning, let end = state.endDate {
            // Per-minute entries keep the progress ring moving; the digits
            // count down live via Text(timerInterval:).
            var t = now.addingTimeInterval(60 - now.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 60))
            while t < end && entries.count < 60 {
                entries.append(PomoEntry(date: t, state: state))
                t = t.addingTimeInterval(60)
            }
            // Entry for the moment the phase flips.
            var flipped = state
            flipped.normalize(now: end.addingTimeInterval(0.5))
            entries.append(PomoEntry(date: end, state: flipped))
            completion(Timeline(entries: entries, policy: .atEnd))
        } else {
            completion(Timeline(entries: entries, policy: .never))
        }
    }
}

// MARK: - Widget

struct PomoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PomoWidget", provider: PomoProvider()) { entry in
            PomoWidgetView(entry: entry)
        }
        .configurationDisplayName("Pomo Timer")
        .description("Your pomodoro timer, right on the desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

struct PomoWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: PomoEntry

    var theme: Theme { Themes.theme(entry.state.settings.themeID) }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                LinearGradient(colors: theme.bg, startPoint: .top, endPoint: .bottom)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            ring(size: 78, lineWidth: 7, fontSize: 17)
            HStack(spacing: 10) {
                Text(entry.state.mode.shortTitle.uppercased())
                    .font(.system(size: 8, weight: .bold, design: theme.fontDesign))
                    .tracking(1.5)
                    .foregroundStyle(theme.textSecondary)
                toggleButton(size: 22)
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            ring(size: 96, lineWidth: 8, fontSize: 20)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(theme.emoji) \(entry.state.mode.title)")
                    .font(.system(size: 11, weight: .bold, design: theme.fontDesign))
                    .tracking(2)
                    .foregroundStyle(theme.textSecondary)

                sessionDots

                HStack(spacing: 10) {
                    toggleButton(size: 30)
                    Button(intent: PomoSkipIntent()) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Button(intent: PomoResetIntent()) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ring(size: CGFloat, lineWidth: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.0001, entry.state.progress(at: entry.date)))
                .stroke(
                    AngularGradient(colors: [theme.ringA, theme.ringB, theme.ringA], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            countdownText(fontSize: fontSize)
                .foregroundStyle(theme.textPrimary)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func countdownText(fontSize: CGFloat) -> some View {
        if entry.state.isRunning, let end = entry.state.endDate, end > entry.date {
            Text(timerInterval: entry.date...end, countsDown: true)
                .font(.system(size: fontSize, weight: .bold, design: theme.fontDesign))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: 70)
        } else {
            Text(pomoFormat(entry.state.currentRemaining(at: entry.date)))
                .font(.system(size: fontSize, weight: .bold, design: theme.fontDesign))
                .monospacedDigit()
        }
    }

    private func toggleButton(size: CGFloat) -> some View {
        Button(intent: PomoToggleIntent()) {
            Image(systemName: entry.state.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.75))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [theme.ringA, theme.ringB],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private var sessionDots: some View {
        let total = max(1, entry.state.settings.sessionsUntilLongBreak)
        let done = entry.state.completedFocusSessions % total
        return HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < done ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.white.opacity(0.18)))
                    .frame(width: 5, height: 5)
            }
            Text("\(entry.state.completedFocusSessions)")
                .font(.system(size: 9, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
        }
    }
}
