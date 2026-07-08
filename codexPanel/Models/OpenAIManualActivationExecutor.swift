import Foundation

enum OpenAIManualActivationExecutor {
    static func execute(
        targetAccountID: String,
        targetMode: CodexPanelOpenAIAccountUsageMode,
        configuredBehavior: CodexPanelOpenAIManualActivationBehavior,
        trigger: OpenAIManualActivationTrigger,
        activateOnly: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws -> OpenAIManualSwitchResult {
        let action = OpenAIManualActivationResolver.resolve(
            configuredBehavior: configuredBehavior,
            trigger: trigger
        )

        _ = launchNewInstance
        try activateOnly()

        return OpenAIManualSwitchResult(
            action: action,
            targetAccountID: targetAccountID,
            targetMode: targetMode,
            launchedNewInstance: action == .launchNewInstance
        )
    }
}
