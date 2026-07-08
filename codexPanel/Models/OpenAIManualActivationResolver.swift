import Foundation

enum OpenAIManualSwitchCopyKey: Equatable {
    case defaultTargetUpdated
    case launchedNewInstance
}

enum OpenAIImmediateEffectRecommendation: Equatable {
    case noneNeeded
    case launchNewInstance
}

enum OpenAIManualActivationTrigger: Equatable {
    case primaryTap
    case contextOverride(CodexPanelOpenAIManualActivationBehavior)
}

enum OpenAIManualActivationAction: Equatable {
    case updateConfigOnly
    case launchNewInstance
}

struct OpenAIManualSwitchResult: Equatable {
    let action: OpenAIManualActivationAction
    let targetAccountID: String
    let targetMode: CodexPanelOpenAIAccountUsageMode
    let launchedNewInstance: Bool
    let affectsRunningThreads: Bool
    let copyKey: OpenAIManualSwitchCopyKey
    let immediateEffectRecommendation: OpenAIImmediateEffectRecommendation

    init(
        action: OpenAIManualActivationAction,
        targetAccountID: String,
        targetMode: CodexPanelOpenAIAccountUsageMode,
        launchedNewInstance: Bool
    ) {
        self.action = action
        self.targetAccountID = targetAccountID
        self.targetMode = targetMode
        self.launchedNewInstance = launchedNewInstance
        self.affectsRunningThreads = false
        self.copyKey = launchedNewInstance ? .launchedNewInstance : .defaultTargetUpdated
        self.immediateEffectRecommendation = .noneNeeded
    }
}

struct OpenAIAggregateStickyBindingSnapshot: Equatable {
    let threadID: String
    let accountID: String
    let updatedAt: Date
}

struct OpenAIRuntimeRouteSnapshot: Equatable {
    let configuredMode: CodexPanelOpenAIAccountUsageMode
    let effectiveMode: CodexPanelOpenAIAccountUsageMode
    let aggregateRuntimeActive: Bool
    let latestRoutedAccountID: String?
    let latestRoutedAccountIsSummary: Bool
    let stickyAffectsFutureRouting: Bool
    let leaseActive: Bool
    let staleStickyEligible: Bool
    let staleStickyThreadID: String?
    let latestRouteAt: Date?
}

enum OpenAIManualActivationResolver {
    static func resolve(
        configuredBehavior: CodexPanelOpenAIManualActivationBehavior,
        trigger: OpenAIManualActivationTrigger
    ) -> OpenAIManualActivationAction {
        _ = configuredBehavior
        _ = trigger
        return .updateConfigOnly
    }
}
