import Foundation

enum OpenAIAccountUsageModeTransitionExecutor {
    static func execute(
        configuredBehavior: CodexPanelOpenAIManualActivationBehavior,
        targetMode: CodexPanelOpenAIAccountUsageMode,
        currentMode: @autoclosure () -> CodexPanelOpenAIAccountUsageMode,
        applyMode: () throws -> Void,
        rollbackMode: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws -> OpenAIManualActivationAction? {
        _ = configuredBehavior
        _ = rollbackMode
        _ = launchNewInstance
        guard currentMode() != targetMode else { return nil }

        try applyMode()
        return .updateConfigOnly
    }
}
