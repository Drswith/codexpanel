import AppKit
import Foundation
import SwiftUI
import XCTest

@MainActor
final class SettingsWindowCoordinatorTests: XCTestCase {
    func testSwitchingPagesKeepsDraftAcrossEdits() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.5", "google/gemini-2.5-pro"]
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 14, field: .proRelativeToPlusMultiplier)
        coordinator.updateModelPricing(
            for: "google/gemini-2.5-pro",
            pricing: CodexPanelModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)
        coordinator.selectedPage = .about

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .manual)
        XCTAssertEqual(coordinator.draft.manualActivationBehavior, .launchNewInstance)
        coordinator.selectedPage = .usage
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
        XCTAssertEqual(coordinator.draft.plusRelativeWeight, 12)
        XCTAssertEqual(coordinator.draft.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(
            coordinator.draft.modelPricing["google/gemini-2.5-pro"],
            CodexPanelModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        XCTAssertEqual(coordinator.draft.preferredCodexAppPath, "/Applications/Codex.app")
    }

    func testConfiguredModelPricingStillAppearsWhenHistoricalModelsAreNotReady() {
        var config = self.makeConfig()
        config.modelPricing = [
            "google/gemini-2.5-pro": CodexPanelModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            ),
        ]

        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [],
            historicalModels: []
        )

        XCTAssertEqual(coordinator.historicalModels, ["google/gemini-2.5-pro"])
        XCTAssertEqual(
            coordinator.draft.modelPricing["google/gemini-2.5-pro"],
            CodexPanelModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
    }

    func testManualAccountOrderSectionVisibilityFollowsOrderingMode() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrderingMode: .quotaSort),
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertFalse(coordinator.showsManualAccountOrderSection)

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        XCTAssertTrue(coordinator.showsManualAccountOrderSection)

        coordinator.update(\.accountOrderingMode, to: .quotaSort, field: .accountOrderingMode)
        XCTAssertFalse(coordinator.showsManualAccountOrderSection)
    }

    func testCodexAppPathSectionStaysHiddenWhenLaunchIsUnsupported() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertFalse(coordinator.showsCodexAppPathSection)

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        XCTAssertFalse(coordinator.showsCodexAppPathSection)

        coordinator.update(\.manualActivationBehavior, to: .updateConfigOnly, field: .manualActivationBehavior)
        XCTAssertFalse(coordinator.showsCodexAppPathSection)
    }

    func testSaveEmitsChangedDomainRequestsAndReopenReflectsSavedValues() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let codexAppURL = try self.makeValidCodexApp(in: temporaryDirectory)
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5", "google/gemini-2.5-pro"]
        )

        coordinator.update(\.accountOrderingMode, to: .manual, field: .accountOrderingMode)
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])
        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 14, field: .proRelativeToPlusMultiplier)
        coordinator.update(\.teamRelativeToPlusMultiplier, to: 2.2, field: .teamRelativeToPlusMultiplier)
        coordinator.updateModelPricing(
            for: "google/gemini-2.5-pro",
            pricing: CodexPanelModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: codexAppURL.path, field: .preferredCodexAppPath)

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(sink.appliedRequests.count, 1)
        XCTAssertEqual(
            requests.openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual,
                manualActivationBehavior: .updateConfigOnly
            )
        )
        XCTAssertEqual(
            requests.openAIUsage,
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                plusRelativeWeight: 12,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2.2
            )
        )
        XCTAssertEqual(
            requests.desktop,
            DesktopSettingsUpdate(preferredCodexAppPath: codexAppURL.path)
        )
        XCTAssertEqual(
            requests.modelPricing,
            ModelPricingSettingsUpdate(
                upserts: [
                    "google/gemini-2.5-pro": CodexPanelModelPricing(
                        inputUSDPerToken: 0.9e-6,
                        cachedInputUSDPerToken: 0.4e-6,
                        outputUSDPerToken: 1.8e-6
                    ),
                ],
                removals: []
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5", "google/gemini-2.5-pro"]
        )
        XCTAssertEqual(reopened.draft.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(reopened.draft.accountOrderingMode, .manual)
        XCTAssertEqual(reopened.draft.manualActivationBehavior, .updateConfigOnly)
        XCTAssertEqual(reopened.draft.usageDisplayMode, .remaining)
        XCTAssertEqual(reopened.draft.plusRelativeWeight, 12)
        XCTAssertEqual(reopened.draft.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(reopened.draft.teamRelativeToPlusMultiplier, 2.2)
        XCTAssertEqual(reopened.draft.preferredCodexAppPath, codexAppURL.path)
        XCTAssertEqual(
            reopened.draft.modelPricing["google/gemini-2.5-pro"],
            CodexPanelModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            )
        )
    }

    func testCancelRollsBackAcrossPagesAndDoesNotTriggerRequests() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let baseConfig = self.makeConfig()
        let sink = TestSettingsSaveSink(config: baseConfig)
        let coordinator = SettingsWindowCoordinator(
            config: baseConfig,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.selectedPage = .usage
        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.update(\.plusRelativeWeight, to: 14, field: .plusRelativeWeight)
        coordinator.update(\.proRelativeToPlusMultiplier, to: 15, field: .proRelativeToPlusMultiplier)
        coordinator.selectedPage = .accounts
        coordinator.update(\.preferredCodexAppPath, to: "/Applications/Codex.app", field: .preferredCodexAppPath)

        coordinator.cancel()

        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.5"]
            )
        )

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )
        XCTAssertEqual(
            reopened.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.5"]
            )
        )
    }

    func testSaveAndCloseClosesWindowAfterSuccessfulSave() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.saveAndClose(using: sink) {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(sink.appliedRequests.count, 1)
    }

    func testCancelAndCloseDoesNotSaveButClosesWindow() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.cancelAndClose {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .used)
    }

    func testSaveAndCloseKeepsWindowOpenWhenSaveFails() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )
        let sink = FailingSettingsSaveSink()
        var closeCount = 0

        coordinator.update(\.usageDisplayMode, to: .remaining, field: .usageDisplayMode)
        coordinator.saveAndClose(using: sink) {
            closeCount += 1
        }

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(coordinator.validationMessage, "save failed")
    }

    func testReconcileExternalStateRefreshesUntouchedFieldsAndPreservesEditedFields() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.5"]
        )

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)

        var externalConfig = self.makeConfig()
        externalConfig.openAI.accountOrderingMode = .manual
        externalConfig.openAI.usageDisplayMode = .remaining
        externalConfig.openAI.manualActivationBehavior = .updateConfigOnly

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts,
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertEqual(coordinator.draft.accountOrderingMode, .manual)
        XCTAssertEqual(coordinator.draft.manualActivationBehavior, .launchNewInstance)
        XCTAssertEqual(coordinator.draft.usageDisplayMode, .remaining)
    }

    func testReconcileExternalStateKeepsExplicitlyEditedFieldEvenIfValueMatchesOriginalBaseline() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.5"]
        )

        coordinator.update(\.manualActivationBehavior, to: .launchNewInstance, field: .manualActivationBehavior)
        coordinator.update(\.manualActivationBehavior, to: .updateConfigOnly, field: .manualActivationBehavior)

        var externalConfig = self.makeConfig()
        externalConfig.openAI.manualActivationBehavior = .launchNewInstance

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: initialAccounts,
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertEqual(coordinator.draft.manualActivationBehavior, .updateConfigOnly)
        XCTAssertEqual(
            coordinator.makeSaveRequests().openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha", "acct_beta"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .updateConfigOnly
            )
        )
    }

    func testReconcileExternalStateMergesNewAccountsIntoEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.5"]
        )
        coordinator.setAccountOrder(["acct_beta", "acct_alpha"])

        var externalConfig = self.makeConfig()
        externalConfig.setOpenAIAccountOrder(["acct_alpha", "acct_beta", "acct_gamma"])
        let updatedAccounts = initialAccounts + [
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts,
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_beta", "acct_alpha", "acct_gamma"])
        XCTAssertEqual(coordinator.orderedAccounts.map(\.id), ["acct_beta", "acct_alpha", "acct_gamma"])
    }

    func testReconcileExternalStateDropsRemovedAccountsFromEditedOrder() {
        let initialAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrder: ["acct_alpha", "acct_beta", "acct_gamma"]),
            accounts: initialAccounts,
            historicalModels: ["gpt-5.5"]
        )
        coordinator.setAccountOrder(["acct_gamma", "acct_beta", "acct_alpha"])

        let updatedAccounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "gamma@example.com", accountId: "acct_gamma"),
        ]
        let externalConfig = self.makeConfig(accountOrder: ["acct_alpha", "acct_gamma"])

        coordinator.reconcileExternalState(
            config: externalConfig,
            accounts: updatedAccounts,
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertEqual(coordinator.draft.accountOrder, ["acct_gamma", "acct_alpha"])
        XCTAssertEqual(coordinator.orderedAccounts.map(\.id), ["acct_gamma", "acct_alpha"])
    }

    func testRecordsPageNavigationDoesNotDirtySettings() {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let baseConfig = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(
            config: baseConfig,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )

        coordinator.selectedPage = .records

        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(coordinator.makeSaveRequests(), SettingsSaveRequests())
        XCTAssertEqual(
            coordinator.draft,
            SettingsWindowDraft(
                config: baseConfig,
                accounts: accounts,
                historicalModels: ["gpt-5.5"]
            )
        )
    }

    func testSavingFromRecordsPageDoesNotEmitAdditionalSettingsRequests() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        let sink = TestSettingsSaveSink(config: self.makeConfig())
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )

        coordinator.selectedPage = .records

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(requests, SettingsSaveRequests())
        XCTAssertTrue(sink.appliedRequests.isEmpty)
    }

    func testSidebarSelectionBindingStartsAtAccountsAndWritesBack() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.5"]
        )

        let selection = SettingsSidebarSelectionAdapter.binding(for: coordinator)

        XCTAssertEqual(selection.wrappedValue, .accounts)

        selection.wrappedValue = .usage

        XCTAssertEqual(coordinator.selectedPage, .usage)
        XCTAssertEqual(selection.wrappedValue, .usage)
    }

    func testSidebarSelectionBindingIgnoresNil() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.5"],
            selectedPage: .records
        )

        let selection = SettingsSidebarSelectionAdapter.binding(for: coordinator)
        selection.wrappedValue = nil

        XCTAssertEqual(coordinator.selectedPage, .records)
        XCTAssertEqual(selection.wrappedValue, .records)
    }

    func testRecordsToUsageNavigationKeepsSelectionBackedDetail() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.5"],
            selectedPage: .records
        )

        SettingsSidebarSelectionAdapter.apply(.usage, to: coordinator)

        XCTAssertEqual(coordinator.selectedPage, .usage)
        XCTAssertEqual(SettingsSidebarSelectionAdapter.binding(for: coordinator).wrappedValue, .usage)
    }

    func testAccountOrderTitlesIncludePlanAndPreferOrganization() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(accountOrder: ["acct_team", "acct_plus"]),
            accounts: [
                self.makeAccount(
                    email: "shared@example.com",
                    accountId: "acct_team",
                    organizationName: "Shared Team",
                    planType: "team"
                ),
                self.makeAccount(
                    email: "shared@example.com",
                    accountId: "acct_plus",
                    planType: "plus"
                ),
            ],
            historicalModels: ["gpt-5.5"]
        )

        XCTAssertEqual(
            coordinator.orderedAccounts.map(\.title),
            ["Shared Team · team", "shared@example.com · plus"]
        )
        XCTAssertEqual(coordinator.orderedAccounts.map(\.detail), ["shared@example.com", "acct_plus"])
    }

    private func makeConfig(
        accountOrder: [String] = ["acct_alpha", "acct_beta"],
        accountOrderingMode: CodexPanelOpenAIAccountOrderingMode = .quotaSort,
        modelPricing: [String: CodexPanelModelPricing] = [:]
    ) -> CodexPanelConfig {
        let alpha = CodexPanelProviderAccount(
            id: "acct_alpha",
            kind: .oauthTokens,
            label: "alpha@example.com",
            email: "alpha@example.com",
            openAIAccountId: "acct_alpha",
            accessToken: "access-alpha",
            refreshToken: "refresh-alpha",
            idToken: "id-alpha"
        )
        let beta = CodexPanelProviderAccount(
            id: "acct_beta",
            kind: .oauthTokens,
            label: "beta@example.com",
            email: "beta@example.com",
            openAIAccountId: "acct_beta",
            accessToken: "access-beta",
            refreshToken: "refresh-beta",
            idToken: "id-beta"
        )
        let gamma = CodexPanelProviderAccount(
            id: "acct_gamma",
            kind: .oauthTokens,
            label: "gamma@example.com",
            email: "gamma@example.com",
            openAIAccountId: "acct_gamma",
            accessToken: "access-gamma",
            refreshToken: "refresh-gamma",
            idToken: "id-gamma"
        )

        return CodexPanelConfig(
            active: CodexPanelActiveSelection(
                providerId: "openai-oauth",
                accountId: "acct_alpha"
            ),
            modelPricing: modelPricing,
            openAI: CodexPanelOpenAISettings(
                accountOrder: accountOrder,
                accountOrderingMode: accountOrderingMode,
                manualActivationBehavior: .updateConfigOnly
            ),
            providers: [
                CodexPanelProvider(
                    id: "openai-oauth",
                    kind: .openAIOAuth,
                    label: "OpenAI",
                    activeAccountId: "acct_alpha",
                    accounts: [alpha, beta, gamma]
                )
            ]
        )
    }

    private func makeAccount(
        email: String,
        accountId: String,
        organizationName: String? = nil,
        planType: String = "free"
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)",
            planType: planType,
            organizationName: organizationName
        )
    }

    private func makeValidCodexApp(in directory: URL) throws -> URL {
        let appURL = directory.appendingPathComponent("Codex.app", isDirectory: true)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data().write(to: resourcesURL.appendingPathComponent("codex"))
        return appURL
    }
}

@MainActor
private final class TestSettingsSaveSink: SettingsSaveRequestApplying {
    private(set) var config: CodexPanelConfig
    private(set) var appliedRequests: [SettingsSaveRequests] = []

    init(config: CodexPanelConfig) {
        self.config = config
    }

    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        self.appliedRequests.append(requests)
        try SettingsSaveRequestApplier.apply(requests, to: &self.config)
    }
}

private struct FailingSettingsSaveSink: SettingsSaveRequestApplying {
    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        throw TestSaveError.failed
    }

    private enum TestSaveError: LocalizedError {
        case failed

        var errorDescription: String? { "save failed" }
    }
}

@MainActor
final class DetachedWindowPresenterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// `DetachedWindowPresenter.show` 将建窗推迟到 main runloop；属性可能在后续若干帧才稳定。
    private func awaitDetachedWindow(
        presenter: DetachedWindowPresenter,
        id: String,
        requiredContentMinSize: CGSize? = nil,
        contentSizeAtLeast: CGSize? = nil
    ) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            let window = presenter.windowSnapshotForTesting(id: id)
                ?? NSApp.windows.first(where: { $0.identifier?.rawValue == id })
            guard let window else { continue }
            window.layoutIfNeeded()
            if let requiredContentMinSize {
                guard window.contentMinSize.width >= requiredContentMinSize.width - 0.5,
                      window.contentMinSize.height >= requiredContentMinSize.height - 0.5 else { continue }
            }
            if let contentSizeAtLeast {
                let sz = self.contentSize(of: window)
                guard sz.width >= contentSizeAtLeast.width - 0.5,
                      sz.height >= contentSizeAtLeast.height - 0.5 else { continue }
            }
            return
        }
        XCTFail("DetachedWindowPresenter 异步建窗超时: id=\(id)")
    }

    func testDefaultWindowRemainsNonResizable() throws {
        let presenter = DetachedWindowPresenter()
        let id = "detached-window-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(presenter: presenter, id: id)

        let window = try self.window(withID: id, presenter: presenter)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, .zero)
        XCTAssertEqual(window.level.rawValue, NSWindow.Level.floating.rawValue)
    }

    func testOpenAISettingsWindowIsResizableAndAppliesMinimumContentSize() throws {
        let presenter = DetachedWindowPresenter()
        let id = "openai-settings-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(
            presenter: presenter,
            id: id,
            requiredContentMinSize: CGSize(width: 760, height: 560),
            contentSizeAtLeast: CGSize(width: 820, height: 620)
        )

        let window = try self.window(withID: id, presenter: presenter)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, CGSize(width: 760, height: 560))
        XCTAssertEqual(self.contentSize(of: window), CGSize(width: 820, height: 620))
        XCTAssertEqual(window.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testExistingSettingsWindowReplaysConfigurationWithoutResettingUserSizedContent() throws {
        let presenter = DetachedWindowPresenter()
        let id = "openai-settings-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(
            presenter: presenter,
            id: id,
            requiredContentMinSize: CGSize(width: 760, height: 560),
            contentSizeAtLeast: CGSize(width: 820, height: 620)
        )

        let existingWindow = try self.window(withID: id, presenter: presenter)
        existingWindow.setContentSize(CGSize(width: 940, height: 700))

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: .openAISettings
        ) {
            Text("Updated")
        }

        XCTAssertTrue(existingWindow.styleMask.contains(.resizable))
        XCTAssertEqual(existingWindow.contentMinSize, CGSize(width: 760, height: 560))
        XCTAssertEqual(self.contentSize(of: existingWindow), CGSize(width: 940, height: 700))
        XCTAssertEqual(existingWindow.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testDefaultWindowReuseStillResetsContentSize() throws {
        let presenter = DetachedWindowPresenter()
        let id = "detached-window-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(presenter: presenter, id: id, contentSizeAtLeast: CGSize(width: 420, height: 320))

        let existingWindow = try self.window(withID: id, presenter: presenter)
        existingWindow.setContentSize(CGSize(width: 610, height: 510))

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(presenter: presenter, id: id, contentSizeAtLeast: CGSize(width: 420, height: 320))

        XCTAssertFalse(existingWindow.styleMask.contains(.resizable))
        XCTAssertEqual(existingWindow.contentMinSize, .zero)
        XCTAssertEqual(self.contentSize(of: existingWindow), CGSize(width: 420, height: 320))
    }

    func testCloseCancelsPendingDetachedWindowPresentation() {
        let presenter = DetachedWindowPresenter()
        let id = "detached-window-\(UUID().uuidString)"

        presenter.show(
            id: id,
            title: "Default",
            size: CGSize(width: 420, height: 320)
        ) {
            EmptyView()
        }
        presenter.close(id: id)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertNil(presenter.windowSnapshotForTesting(id: id))
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == id })
    }

    func testHoverPanelPresentationIsSynchronousForPopoverCloseProtection() throws {
        let presenter = DetachedWindowPresenter()
        let id = "hover-panel-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.showHoverPanel(
            id: id,
            size: CGSize(width: 272, height: 196),
            origin: CGPoint(x: 400, y: 220)
        ) {
            EmptyView()
        }

        let window = try XCTUnwrap(presenter.windowSnapshotForTesting(id: id))
        XCTAssertTrue(window is NSPanel)
        XCTAssertEqual(window.frame.origin, CGPoint(x: 400, y: 220))
    }

    private func window(withID id: String, presenter: DetachedWindowPresenter) throws -> NSWindow {
        try XCTUnwrap(presenter.windowSnapshotForTesting(id: id))
    }

    private func contentSize(of window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }
}
