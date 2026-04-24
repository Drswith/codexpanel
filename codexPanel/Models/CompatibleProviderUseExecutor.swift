import Foundation

enum CompatibleProviderUseExecutor {
    static func execute(
        configuredBehavior: CodexPanelOpenAIManualActivationBehavior,
        activateOnly: () throws -> Void,
        restorePreviousSelection: () throws -> Void,
        launchNewInstance: () async throws -> Void
    ) async throws {
        try activateOnly()

        guard configuredBehavior == .launchNewInstance else { return }

        do {
            try await launchNewInstance()
        } catch {
            try? restorePreviousSelection()
            throw error
        }
    }
}
