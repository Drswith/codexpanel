import Combine
import Foundation

protocol SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws
}

extension TokenStore: SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        try self.saveSettings(requests)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case accounts
    case usage
    case about
    case diagnostics

    var id: String { self.rawValue }
}

struct SettingsWindowDraft: Equatable {
    var accountOrder: [String]
    var accountUsageMode: CodexPanelOpenAIAccountUsageMode
    var accountOrderingMode: CodexPanelOpenAIAccountOrderingMode
    var manualActivationBehavior: CodexPanelOpenAIManualActivationBehavior
    var usageDisplayMode: CodexPanelUsageDisplayMode
    var plusRelativeWeight: Double
    var proRelativeToPlusMultiplier: Double
    var teamRelativeToPlusMultiplier: Double
    var modelPricing: [String: CodexPanelModelPricing]
    var preferredCodexAppPath: String?
    var aggregateGatewayProxyURL: String?

    init(config: CodexPanelConfig, accounts: [TokenAccount], historicalModels: [String]) {
        self.accountOrder = Self.normalizedAccountOrder(
            config.openAI.accountOrder,
            availableAccountIDs: accounts.map(\.accountId)
        )
        self.accountUsageMode = config.openAI.accountUsageMode
        self.accountOrderingMode = config.openAI.accountOrderingMode
        self.manualActivationBehavior = config.openAI.manualActivationBehavior
        self.usageDisplayMode = config.openAI.usageDisplayMode
        self.plusRelativeWeight = config.openAI.quotaSort.plusRelativeWeight
        self.proRelativeToPlusMultiplier = config.openAI.quotaSort.proRelativeToPlusMultiplier
        self.teamRelativeToPlusMultiplier = config.openAI.quotaSort.teamRelativeToPlusMultiplier
        // 只保存用户显式设置的价格；缺少条目表示由统计引擎自动定价。
        self.modelPricing = config.modelPricing
        self.preferredCodexAppPath = config.desktop.preferredCodexAppPath
        self.aggregateGatewayProxyURL = config.openAI.aggregateGatewayProxyURL
    }

    static func mergedAccountOrder(
        preferredAccountOrder: [String],
        fallbackAccountOrder: [String],
        availableAccountIDs: [String]
    ) -> [String] {
        self.normalizedAccountOrder(
            preferredAccountOrder + fallbackAccountOrder,
            availableAccountIDs: availableAccountIDs
        )
    }

    private static func normalizedAccountOrder(_ accountOrder: [String], availableAccountIDs: [String]) -> [String] {
        let availableSet = Set(availableAccountIDs)
        var normalized: [String] = []
        var seen: Set<String> = []

        for accountID in accountOrder where availableSet.contains(accountID) {
            guard seen.insert(accountID).inserted else { continue }
            normalized.append(accountID)
        }

        for accountID in availableAccountIDs where seen.insert(accountID).inserted {
            normalized.append(accountID)
        }

        return normalized
    }

    static func normalizedHistoricalModels(_ historicalModels: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for model in historicalModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }

        return normalized.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func mergedHistoricalModels(
        preferredHistoricalModels: [String],
        fallbackHistoricalModels: [String]
    ) -> [String] {
        self.normalizedHistoricalModels(
            preferredHistoricalModels + fallbackHistoricalModels
        )
    }

    static func settingsHistoricalModels(
        config: CodexPanelConfig,
        historicalModels: [String]
    ) -> [String] {
        self.mergedHistoricalModels(
            preferredHistoricalModels: historicalModels,
            fallbackHistoricalModels: Array(config.modelPricing.keys)
        )
    }
}

struct SettingsOpenAIAccountOrderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

private enum SettingsOpenAIAccountTitlePreference {
    case organization
    case email
}

private enum SettingsOpenAIAccountTitlePresentation {
    static func title(
        for account: TokenAccount,
        preference: SettingsOpenAIAccountTitlePreference
    ) -> String {
        "\(self.baseTitle(for: account, preference: preference)) · \(self.planDisplayName(for: account))"
    }

    private static func baseTitle(
        for account: TokenAccount,
        preference: SettingsOpenAIAccountTitlePreference
    ) -> String {
        switch preference {
        case .organization:
            return self.baseTitlePreferOrganization(for: account)
        case .email:
            return self.baseTitlePreferEmail(for: account)
        }
    }

    private static func baseTitlePreferOrganization(for account: TokenAccount) -> String {
        if let username = account.normalizedUsername {
            return username
        }
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        if let displayName = account.normalizedDisplayName {
            return displayName
        }
        if account.email.isEmpty == false {
            return account.email
        }
        return account.accountId
    }

    private static func baseTitlePreferEmail(for account: TokenAccount) -> String {
        if let username = account.normalizedUsername {
            return username
        }
        if let displayName = account.normalizedDisplayName {
            return displayName
        }
        if account.email.isEmpty == false {
            return account.email
        }
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false {
            return organizationName
        }
        return account.accountId
    }

    private static func planDisplayName(for account: TokenAccount) -> String {
        let normalized = account.planType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "free" : normalized
    }
}

enum SettingsDirtyField: Hashable {
    case accountOrder
    case accountUsageMode
    case accountOrderingMode
    case manualActivationBehavior
    case usageDisplayMode
    case plusRelativeWeight
    case proRelativeToPlusMultiplier
    case teamRelativeToPlusMultiplier
    case modelPricing
    case preferredCodexAppPath
    case aggregateGatewayProxyURL
}

@MainActor
final class SettingsWindowCoordinator: ObservableObject {
    @Published var selectedPage: SettingsPage
    @Published var draft: SettingsWindowDraft
    @Published var validationMessage: String?
    @Published private(set) var historicalModels: [String]

    private var accounts: [TokenAccount]
    private var baseline: SettingsWindowDraft
    private var dirtyFields: Set<SettingsDirtyField> = []
    private var editedModelPricing: Set<String> = []

    init(
        config: CodexPanelConfig,
        accounts: [TokenAccount],
        historicalModels: [String],
        selectedPage: SettingsPage = .accounts
    ) {
        let normalizedHistoricalModels = SettingsWindowDraft.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        let draft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            historicalModels: normalizedHistoricalModels
        )
        self.selectedPage = selectedPage
        self.draft = draft
        self.historicalModels = normalizedHistoricalModels
        self.accounts = accounts
        self.baseline = draft
        self.validationMessage = nil
    }

    var hasChanges: Bool {
        self.makeSaveRequests().isEmpty == false
    }

    var orderedAccounts: [SettingsOpenAIAccountOrderItem] {
        let accountByID = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.accountId, $0) })
        return self.draft.accountOrder.compactMap { accountID in
            guard let account = accountByID[accountID] else { return nil }
            return SettingsOpenAIAccountOrderItem(
                id: accountID,
                title: Self.accountTitle(for: account),
                detail: Self.accountDetail(for: account)
            )
        }
    }

    var showsManualAccountOrderSection: Bool {
        self.draft.accountOrderingMode == .manual
    }

    func moveAccount(accountID: String, offset: Int) {
        guard let currentIndex = self.draft.accountOrder.firstIndex(of: accountID) else { return }
        let targetIndex = currentIndex + offset
        guard self.draft.accountOrder.indices.contains(targetIndex) else { return }
        self.draft.accountOrder.swapAt(currentIndex, targetIndex)
        self.dirtyFields.insert(.accountOrder)
    }

    func setAccountOrder(_ accountOrder: [String]) {
        self.draft.accountOrder = accountOrder
        self.dirtyFields.insert(.accountOrder)
    }

    func update<Value>(
        _ keyPath: WritableKeyPath<SettingsWindowDraft, Value>,
        to value: Value,
        field: SettingsDirtyField
    ) {
        self.draft[keyPath: keyPath] = value
        self.dirtyFields.insert(field)
    }

    func updateModelPricing(for model: String, pricing: CodexPanelModelPricing?) {
        self.draft.modelPricing[model] = pricing
        self.editedModelPricing.insert(model)
        self.historicalModels = SettingsWindowDraft.mergedHistoricalModels(
            preferredHistoricalModels: self.historicalModels,
            fallbackHistoricalModels: [model]
        )
        self.dirtyFields.insert(.modelPricing)
    }

    func saveAutomatically(using sink: SettingsSaveRequestApplying) {
        let proxyURL = self.draft.aggregateGatewayProxyURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proxyURL.isEmpty || CodexPanelOpenAISettings.normalizedAggregateGatewayProxyURL(proxyURL) != nil else {
            self.validationMessage = L.aggregateGatewayProxyInvalidMessage
            return
        }
        do {
            _ = try self.save(using: sink)
            self.validationMessage = nil
        } catch {
            self.validationMessage = error.localizedDescription
        }
    }

    func save(using sink: SettingsSaveRequestApplying) throws -> SettingsSaveRequests {
        let requests = self.makeSaveRequests()
        guard requests.isEmpty == false else { return requests }
        try sink.applySettingsSaveRequests(requests)
        self.baseline = self.draft
        self.dirtyFields.removeAll()
        self.editedModelPricing.removeAll()
        self.validationMessage = nil
        return requests
    }

    func reconcileExternalState(
        config: CodexPanelConfig,
        accounts: [TokenAccount],
        historicalModels: [String]
    ) {
        let normalizedHistoricalModels = SettingsWindowDraft.settingsHistoricalModels(
            config: config,
            historicalModels: historicalModels
        )
        let externalDraft = SettingsWindowDraft(
            config: config,
            accounts: accounts,
            historicalModels: normalizedHistoricalModels
        )
        self.accounts = accounts

        if self.dirtyFields.contains(.accountOrder) == false {
            self.draft.accountOrder = externalDraft.accountOrder
        } else {
            self.draft.accountOrder = SettingsWindowDraft.mergedAccountOrder(
                preferredAccountOrder: self.draft.accountOrder,
                fallbackAccountOrder: externalDraft.accountOrder,
                availableAccountIDs: accounts.map(\.accountId)
            )
        }
        self.baseline.accountOrder = externalDraft.accountOrder

        self.reconcile(\.accountUsageMode, externalValue: externalDraft.accountUsageMode, field: .accountUsageMode)
        self.reconcile(\.accountOrderingMode, externalValue: externalDraft.accountOrderingMode, field: .accountOrderingMode)
        self.reconcile(\.manualActivationBehavior, externalValue: externalDraft.manualActivationBehavior, field: .manualActivationBehavior)
        self.reconcile(\.usageDisplayMode, externalValue: externalDraft.usageDisplayMode, field: .usageDisplayMode)
        self.reconcile(\.plusRelativeWeight, externalValue: externalDraft.plusRelativeWeight, field: .plusRelativeWeight)
        self.reconcile(\.proRelativeToPlusMultiplier, externalValue: externalDraft.proRelativeToPlusMultiplier, field: .proRelativeToPlusMultiplier)
        self.reconcile(\.teamRelativeToPlusMultiplier, externalValue: externalDraft.teamRelativeToPlusMultiplier, field: .teamRelativeToPlusMultiplier)
        self.reconcileModelPricing(
            externalValue: externalDraft.modelPricing,
            externalHistoricalModels: normalizedHistoricalModels
        )
        self.reconcile(\.preferredCodexAppPath, externalValue: externalDraft.preferredCodexAppPath, field: .preferredCodexAppPath)
        self.reconcile(\.aggregateGatewayProxyURL, externalValue: externalDraft.aggregateGatewayProxyURL, field: .aggregateGatewayProxyURL)
    }

    func makeSaveRequests() -> SettingsSaveRequests {
        var requests = SettingsSaveRequests()

        if self.draft.accountOrder != self.baseline.accountOrder ||
            self.draft.accountUsageMode != self.baseline.accountUsageMode ||
            self.draft.accountOrderingMode != self.baseline.accountOrderingMode ||
            self.draft.manualActivationBehavior != self.baseline.manualActivationBehavior ||
            self.draft.aggregateGatewayProxyURL != self.baseline.aggregateGatewayProxyURL {
            if self.draft.aggregateGatewayProxyURL != self.baseline.aggregateGatewayProxyURL {
                requests.openAIAccount = OpenAIAccountSettingsUpdate(
                    accountOrder: self.draft.accountOrder,
                    accountUsageMode: self.draft.accountUsageMode,
                    accountOrderingMode: self.draft.accountOrderingMode,
                    manualActivationBehavior: self.draft.manualActivationBehavior,
                    aggregateGatewayProxyURL: self.draft.aggregateGatewayProxyURL
                )
            } else {
                requests.openAIAccount = OpenAIAccountSettingsUpdate(
                    accountOrder: self.draft.accountOrder,
                    accountUsageMode: self.draft.accountUsageMode,
                    accountOrderingMode: self.draft.accountOrderingMode,
                    manualActivationBehavior: self.draft.manualActivationBehavior
                )
            }
        }

        if self.draft.usageDisplayMode != self.baseline.usageDisplayMode ||
            self.draft.plusRelativeWeight != self.baseline.plusRelativeWeight ||
            self.draft.proRelativeToPlusMultiplier != self.baseline.proRelativeToPlusMultiplier ||
            self.draft.teamRelativeToPlusMultiplier != self.baseline.teamRelativeToPlusMultiplier {
            requests.openAIUsage = OpenAIUsageSettingsUpdate(
                usageDisplayMode: self.draft.usageDisplayMode,
                plusRelativeWeight: self.draft.plusRelativeWeight,
                proRelativeToPlusMultiplier: self.draft.proRelativeToPlusMultiplier,
                teamRelativeToPlusMultiplier: self.draft.teamRelativeToPlusMultiplier
            )
        }

        let modelPricingUpdate = self.makeModelPricingUpdate()
        if modelPricingUpdate.upserts.isEmpty == false || modelPricingUpdate.removals.isEmpty == false {
            requests.modelPricing = modelPricingUpdate
        }

        if self.draft.preferredCodexAppPath != self.baseline.preferredCodexAppPath {
            requests.desktop = DesktopSettingsUpdate(
                preferredCodexAppPath: self.draft.preferredCodexAppPath
            )
        }

        return requests
    }

    private static func accountTitle(for account: TokenAccount) -> String {
        SettingsOpenAIAccountTitlePresentation.title(for: account, preference: .organization)
    }

    private static func accountDetail(for account: TokenAccount) -> String {
        if let organizationName = account.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           organizationName.isEmpty == false,
           account.email.isEmpty == false {
            return account.email
        }
        if account.displayIdentifier != account.email,
           account.email.isEmpty == false {
            return account.email
        }
        return account.accountId
    }

    private func reconcile<Value: Equatable>(
        _ keyPath: WritableKeyPath<SettingsWindowDraft, Value>,
        externalValue: Value,
        field: SettingsDirtyField
    ) {
        if self.dirtyFields.contains(field) == false {
            self.draft[keyPath: keyPath] = externalValue
        }
        self.baseline[keyPath: keyPath] = externalValue
    }

    private func reconcileModelPricing(
        externalValue: [String: CodexPanelModelPricing],
        externalHistoricalModels: [String]
    ) {
        if self.dirtyFields.contains(.modelPricing) == false {
            self.historicalModels = externalHistoricalModels
            self.draft.modelPricing = externalValue
        } else {
            let mergedHistoricalModels = SettingsWindowDraft.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: externalHistoricalModels
            )
            var mergedPricing = externalValue
            for model in self.editedModelPricing {
                // nil 是用户明确恢复自动，不能被外部同步的旧自定义价格覆盖。
                mergedPricing[model] = self.draft.modelPricing[model]
            }

            self.historicalModels = mergedHistoricalModels
            self.draft.modelPricing = mergedPricing
        }

        self.baseline.modelPricing = externalValue
    }

    private func makeModelPricingUpdate() -> ModelPricingSettingsUpdate {
        var upserts: [String: CodexPanelModelPricing] = [:]
        var removals: [String] = []

        let models = Set(self.draft.modelPricing.keys).union(self.baseline.modelPricing.keys)
        for model in models.sorted() {
            let draftPricing = self.draft.modelPricing[model]
            let baselinePricing = self.baseline.modelPricing[model]
            guard draftPricing != baselinePricing else { continue }

            if let draftPricing {
                upserts[model] = draftPricing
            } else {
                removals.append(model)
            }
        }

        return ModelPricingSettingsUpdate(
            upserts: upserts,
            removals: removals
        )
    }
}
