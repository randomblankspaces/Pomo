import AppIntents
import WidgetKit

private func mutateShared(_ mutate: (inout PomoState) -> Void) {
    var state = PomoStore.load()
    state.normalize()
    mutate(&state)
    PomoStore.save(state)
    PomoStore.postChanged()
    WidgetCenter.shared.reloadAllTimelines()
}

struct PomoToggleIntent: AppIntent {
    static var title: LocalizedStringResource { "Start / Pause Pomodoro" }
    static var description: IntentDescription { "Starts or pauses the Pomo timer." }

    func perform() async throws -> some IntentResult {
        mutateShared { $0.toggle() }
        return .result()
    }
}

struct PomoSkipIntent: AppIntent {
    static var title: LocalizedStringResource { "Skip Phase" }
    static var description: IntentDescription { "Skips to the next focus/break phase." }

    func perform() async throws -> some IntentResult {
        mutateShared { $0.skip() }
        return .result()
    }
}

struct PomoResetIntent: AppIntent {
    static var title: LocalizedStringResource { "Reset Timer" }
    static var description: IntentDescription { "Resets the current phase." }

    func perform() async throws -> some IntentResult {
        mutateShared { $0.reset() }
        return .result()
    }
}
