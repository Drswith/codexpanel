import Foundation

enum CompatibleProviderUseExecutor {
    static func execute(
        configuredBehavior: CodexPanelOpenAIManualActivationBehavior,
        activateOnly: () throws -> Void,
        restorePreviousSelection: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws {
        _ = configuredBehavior
        _ = restorePreviousSelection
        _ = launchNewInstance
        try activateOnly()
    }
}
