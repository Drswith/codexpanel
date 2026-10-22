import AppKit
import Foundation
import SwiftUI
import XCTest

@MainActor
final class SettingsWindowCoordinatorTests: XCTestCase {
    func testSettingsRouterDefersToRegisteredNativeScene() async {
        var prepared = 0
        let router = CodexPanelUICommandRouter(prepareRuntime: { prepared += 1 })
        let opened = expectation(description: "native scene opened")
        router.openSettings()
        XCTAssertEqual(prepared, 1)
        router.registerSettingsSceneAction { opened.fulfill() }
        await fulfillment(of: [opened], timeout: 1)
        XCTAssertEqual(prepared, 1)
    }

    func testSettingsRouterUsesNativeSceneForSubsequentRequests() async {
        var prepared = 0
        let router = CodexPanelUICommandRouter(prepareRuntime: { prepared += 1 })
        let opened = expectation(description: "native scene opened twice")
        opened.expectedFulfillmentCount = 2
        router.registerSettingsSceneAction { opened.fulfill() }
        router.openSettings()
        router.openSettings()
        await fulfillment(of: [opened], timeout: 1)
        XCTAssertEqual(prepared, 2)
    }

    func testAutomaticSavePersistsEditsAndDoesNotRepeatUnchangedWrites() {
        let config = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: [])
        let sink = TestSettingsSaveSink(config: config)
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)

        coordinator.saveAutomatically(using: sink)

        XCTAssertEqual(sink.config.openAI.quotaSort.plusRelativeWeight, 12)
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertNil(coordinator.validationMessage)
        coordinator.saveAutomatically(using: sink)
        XCTAssertEqual(sink.appliedRequests.count, 1)
    }

    func testAutomaticSaveRetainsUnsavedEditAfterFailureAndCanRetry() {
        let config = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: [])
        coordinator.update(\.plusRelativeWeight, to: 12, field: .plusRelativeWeight)

        coordinator.saveAutomatically(using: FailingSettingsSaveSink())

        XCTAssertTrue(coordinator.hasChanges)
        XCTAssertEqual(coordinator.draft.plusRelativeWeight, 12)
        XCTAssertEqual(coordinator.validationMessage, "save failed")
        let sink = TestSettingsSaveSink(config: config)
        coordinator.saveAutomatically(using: sink)
        XCTAssertEqual(sink.config.openAI.quotaSort.plusRelativeWeight, 12)
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertNil(coordinator.validationMessage)
    }

    func testAutomaticSavePreservesLastValidProxyUntilInputIsCorrected() {
        var config = self.makeConfig()
        config.openAI.aggregateGatewayProxyURL = "http://127.0.0.1:7890"
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: [])
        let sink = TestSettingsSaveSink(config: config)
        coordinator.update(\.aggregateGatewayProxyURL, to: "http://", field: .aggregateGatewayProxyURL)

        coordinator.saveAutomatically(using: sink)

        XCTAssertEqual(sink.config.openAI.aggregateGatewayProxyURL, "http://127.0.0.1:7890")
        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertNotNil(coordinator.validationMessage)
        coordinator.update(\.aggregateGatewayProxyURL, to: "http://127.0.0.1:7891", field: .aggregateGatewayProxyURL)
        coordinator.saveAutomatically(using: sink)
        XCTAssertEqual(sink.config.openAI.aggregateGatewayProxyURL, "http://127.0.0.1:7891")
        XCTAssertNil(coordinator.validationMessage)
        XCTAssertFalse(coordinator.hasChanges)
    }

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

    func testAutomaticModelPricingDoesNotMaterializeLegacyOrUnknownPrices() {
        let config = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(
            config: config,
            accounts: [],
            historicalModels: ["gpt-5.5", "unknown-model"]
        )
        let sink = TestSettingsSaveSink(config: config)

        XCTAssertEqual(Set(coordinator.historicalModels), ["gpt-5.5", "unknown-model"])
        XCTAssertTrue(coordinator.draft.modelPricing.isEmpty)
        XCTAssertNil(coordinator.makeSaveRequests().modelPricing)
        coordinator.saveAutomatically(using: sink)
        XCTAssertTrue(sink.appliedRequests.isEmpty)
        XCTAssertTrue(sink.config.modelPricing.isEmpty)
    }

    func testExplicitCustomPriceMatchingLegacyDefaultRemainsAnOverride() throws {
        let config = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: ["gpt-5.5"])
        let sink = TestSettingsSaveSink(config: config)
        // 曾经的 Swift 默认价仍可能是用户选择的固定覆盖，不能据此恢复自动。
        let pricing = CodexPanelModelPricing(
            inputUSDPerToken: 5e-6,
            cachedInputUSDPerToken: 5e-7,
            outputUSDPerToken: 3e-5
        )
        coordinator.updateModelPricing(for: "gpt-5.5", pricing: pricing)

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(requests.modelPricing, ModelPricingSettingsUpdate(upserts: ["gpt-5.5": pricing], removals: []))
        XCTAssertEqual(sink.config.modelPricing["gpt-5.5"], pricing)
        let reopened = SettingsWindowCoordinator(config: sink.config, accounts: [], historicalModels: ["gpt-5.5"])
        XCTAssertEqual(reopened.draft.modelPricing["gpt-5.5"], pricing)
    }

    func testExplicitZeroPriceIsDistinctFromAutomaticPricing() throws {
        let config = self.makeConfig()
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: ["unknown-model"])
        let sink = TestSettingsSaveSink(config: config)
        coordinator.updateModelPricing(for: "unknown-model", pricing: .zero)

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(requests.modelPricing, ModelPricingSettingsUpdate(upserts: ["unknown-model": .zero], removals: []))
        XCTAssertEqual(sink.config.modelPricing["unknown-model"], .zero)
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testRestoreAutomaticRemovesOnlySelectedOverrideAndPersistsAfterReopen() throws {
        let config = self.makeConfig(modelPricing: ["gpt-5.5": .zero, "other-model": .zero])
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: ["gpt-5.5"])
        let sink = TestSettingsSaveSink(config: config)
        coordinator.updateModelPricing(for: "gpt-5.5", pricing: nil)

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(requests.modelPricing, ModelPricingSettingsUpdate(upserts: [:], removals: ["gpt-5.5"]))
        XCTAssertNil(sink.config.modelPricing["gpt-5.5"])
        XCTAssertEqual(sink.config.modelPricing["other-model"], .zero)
        let reopened = SettingsWindowCoordinator(config: sink.config, accounts: [], historicalModels: ["gpt-5.5"])
        XCTAssertNil(reopened.draft.modelPricing["gpt-5.5"])
        XCTAssertFalse(reopened.hasChanges)
    }

    func testFailedRestoreAutomaticRetainsRemovalThroughExternalRefreshAndRetry() {
        let config = self.makeConfig(modelPricing: ["gpt-5.5": .zero])
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: ["gpt-5.5"])
        coordinator.updateModelPricing(for: "gpt-5.5", pricing: nil)
        coordinator.saveAutomatically(using: FailingSettingsSaveSink())

        var externalConfig = config
        externalConfig.modelPricing["gpt-5.5"] = CodexPanelModelPricing(
            inputUSDPerToken: 1e-6, cachedInputUSDPerToken: 0.1e-6, outputUSDPerToken: 2e-6
        )
        coordinator.reconcileExternalState(config: externalConfig, accounts: [], historicalModels: ["gpt-5.5"])

        XCTAssertNil(coordinator.draft.modelPricing["gpt-5.5"])
        XCTAssertEqual(coordinator.validationMessage, "save failed")
        XCTAssertEqual(coordinator.makeSaveRequests().modelPricing, ModelPricingSettingsUpdate(upserts: [:], removals: ["gpt-5.5"]))
        let sink = TestSettingsSaveSink(config: externalConfig)
        coordinator.saveAutomatically(using: sink)
        XCTAssertNil(sink.config.modelPricing["gpt-5.5"])
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertNil(coordinator.validationMessage)
    }

    func testExternalModelPricingMergesUneditedModelsWithoutOverwritingLocalDraft() throws {
        let config = self.makeConfig(modelPricing: ["local-model": .zero, "external-model": .zero])
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: [])
        let localPricing = CodexPanelModelPricing(
            inputUSDPerToken: 1e-6, cachedInputUSDPerToken: 0.1e-6, outputUSDPerToken: 2e-6
        )
        let externalPricing = CodexPanelModelPricing(
            inputUSDPerToken: 3e-6, cachedInputUSDPerToken: 0.3e-6, outputUSDPerToken: 4e-6
        )
        coordinator.updateModelPricing(for: "local-model", pricing: localPricing)
        var externalConfig = config
        externalConfig.modelPricing = [
            "local-model": externalPricing,
            "external-model": externalPricing,
            "new-model": .zero,
        ]

        coordinator.reconcileExternalState(config: externalConfig, accounts: [], historicalModels: ["automatic-model"])

        XCTAssertEqual(coordinator.draft.modelPricing["local-model"], localPricing)
        XCTAssertEqual(coordinator.draft.modelPricing["external-model"], externalPricing)
        XCTAssertEqual(coordinator.draft.modelPricing["new-model"], .zero)
        XCTAssertNil(coordinator.draft.modelPricing["automatic-model"])
        XCTAssertTrue(coordinator.historicalModels.contains("automatic-model"))
        XCTAssertTrue(coordinator.historicalModels.contains("new-model"))
        let sink = TestSettingsSaveSink(config: externalConfig)
        let requests = try coordinator.save(using: sink)
        XCTAssertEqual(requests.modelPricing, ModelPricingSettingsUpdate(upserts: ["local-model": localPricing], removals: []))
        XCTAssertEqual(sink.config.modelPricing["external-model"], externalPricing)
    }

    func testExternalRestoreAutomaticIsAcceptedForUneditedModelDuringAnotherPriceEdit() {
        let config = self.makeConfig(modelPricing: ["external-model": .zero])
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [], historicalModels: ["local-model"])
        coordinator.updateModelPricing(for: "local-model", pricing: .zero)
        var externalConfig = config
        externalConfig.modelPricing.removeValue(forKey: "external-model")

        coordinator.reconcileExternalState(config: externalConfig, accounts: [], historicalModels: ["local-model", "external-model"])

        XCTAssertNil(coordinator.draft.modelPricing["external-model"])
        XCTAssertEqual(coordinator.makeSaveRequests().modelPricing, ModelPricingSettingsUpdate(upserts: ["local-model": .zero], removals: []))
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
                manualActivationBehavior: .launchNewInstance
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
        XCTAssertEqual(reopened.draft.manualActivationBehavior, .launchNewInstance)
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

    func testAggregateGatewayProxyURLSavesThroughAccountRequestAndNormalizesValue() throws {
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

        coordinator.update(
            \.aggregateGatewayProxyURL,
            to: " socks5://127.0.0.1:7890 ",
            field: .aggregateGatewayProxyURL
        )

        let requests = try coordinator.save(using: sink)

        XCTAssertEqual(
            requests.openAIAccount,
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha", "acct_beta"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .updateConfigOnly,
                aggregateGatewayProxyURL: " socks5://127.0.0.1:7890 "
            )
        )
        XCTAssertEqual(sink.config.openAI.aggregateGatewayProxyURL, "socks5://127.0.0.1:7890")

        let reopened = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )
        XCTAssertEqual(reopened.draft.aggregateGatewayProxyURL, "socks5://127.0.0.1:7890")
    }

    func testChangingOrClearingAggregateGatewayProxyPreservesLaunchNewInstanceBehavior() throws {
        let accounts = [
            self.makeAccount(email: "alpha@example.com", accountId: "acct_alpha"),
            self.makeAccount(email: "beta@example.com", accountId: "acct_beta"),
        ]
        var config = self.makeConfig()
        config.openAI.manualActivationBehavior = .launchNewInstance
        config.openAI.aggregateGatewayProxyURL = "socks5://127.0.0.1:7890"
        let sink = TestSettingsSaveSink(config: config)
        let coordinator = SettingsWindowCoordinator(
            config: sink.config,
            accounts: accounts,
            historicalModels: ["gpt-5.5"]
        )

        coordinator.update(
            \.aggregateGatewayProxyURL,
            to: "http://127.0.0.1:7891",
            field: .aggregateGatewayProxyURL
        )

        let changedRequests = try coordinator.save(using: sink)
        XCTAssertEqual(
            try XCTUnwrap(changedRequests.openAIAccount).manualActivationBehavior,
            .launchNewInstance
        )
        XCTAssertEqual(sink.config.openAI.manualActivationBehavior, .launchNewInstance)
        XCTAssertEqual(sink.config.openAI.aggregateGatewayProxyURL, "http://127.0.0.1:7891")

        coordinator.update(
            \.aggregateGatewayProxyURL,
            to: nil,
            field: .aggregateGatewayProxyURL
        )

        let clearedRequests = try coordinator.save(using: sink)
        XCTAssertEqual(
            try XCTUnwrap(clearedRequests.openAIAccount).manualActivationBehavior,
            .launchNewInstance
        )
        XCTAssertEqual(sink.config.openAI.manualActivationBehavior, .launchNewInstance)
        XCTAssertNil(sink.config.openAI.aggregateGatewayProxyURL)
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

    func testDiagnosticsPageNavigationDoesNotDirtySettings() {
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

        coordinator.selectedPage = .diagnostics

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

    func testSavingFromDiagnosticsPageDoesNotEmitAdditionalSettingsRequests() throws {
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

        coordinator.selectedPage = .diagnostics

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
            selectedPage: .diagnostics
        )

        let selection = SettingsSidebarSelectionAdapter.binding(for: coordinator)
        selection.wrappedValue = nil

        XCTAssertEqual(coordinator.selectedPage, .diagnostics)
        XCTAssertEqual(selection.wrappedValue, .diagnostics)
    }

    func testDiagnosticsToUsageNavigationKeepsSelectionBackedDetail() {
        let coordinator = SettingsWindowCoordinator(
            config: self.makeConfig(),
            accounts: [],
            historicalModels: ["gpt-5.5"],
            selectedPage: .diagnostics
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

    func testResizableDetachedWindowAppliesMinimumContentSize() throws {
        let presenter = DetachedWindowPresenter()
        let id = "openai-settings-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: DetachedWindowConfiguration(
                isResizable: true, contentMinSize: CGSize(width: 740, height: 520),
                resetsContentSizeOnReuse: false, windowLevel: .normal
            )
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(
            presenter: presenter,
            id: id,
            requiredContentMinSize: CGSize(width: 740, height: 520),
            contentSizeAtLeast: CGSize(width: 820, height: 620)
        )

        let window = try self.window(withID: id, presenter: presenter)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, CGSize(width: 740, height: 520))
        XCTAssertEqual(self.contentSize(of: window), CGSize(width: 820, height: 620))
        XCTAssertEqual(window.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testExistingResizableDetachedWindowPreservesUserSizedContent() throws {
        let presenter = DetachedWindowPresenter()
        let id = "openai-settings-\(UUID().uuidString)"
        defer { presenter.close(id: id) }

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: DetachedWindowConfiguration(
                isResizable: true, contentMinSize: CGSize(width: 740, height: 520),
                resetsContentSizeOnReuse: false, windowLevel: .normal
            )
        ) {
            EmptyView()
        }
        self.awaitDetachedWindow(
            presenter: presenter,
            id: id,
            requiredContentMinSize: CGSize(width: 740, height: 520),
            contentSizeAtLeast: CGSize(width: 820, height: 620)
        )

        let existingWindow = try self.window(withID: id, presenter: presenter)
        existingWindow.setContentSize(CGSize(width: 940, height: 700))

        presenter.show(
            id: id,
            title: "Settings",
            size: CGSize(width: 820, height: 620),
            configuration: DetachedWindowConfiguration(
                isResizable: true, contentMinSize: CGSize(width: 740, height: 520),
                resetsContentSizeOnReuse: false, windowLevel: .normal
            )
        ) {
            Text("Updated")
        }

        XCTAssertTrue(existingWindow.styleMask.contains(.resizable))
        XCTAssertEqual(existingWindow.contentMinSize, CGSize(width: 740, height: 520))
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

    func testHoverPopoverIsAnchoredAboveMenuWindowAndClosesSynchronously() throws {
        let presenter = DetachedWindowPresenter()
        let id = "hover-popover-\(UUID().uuidString)"
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let parent = NSWindow(contentRect: anchor.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        parent.contentView = anchor
        parent.level = .popUpMenu
        parent.orderFront(nil)
        defer {
            presenter.close(id: id)
            parent.orderOut(nil)
        }

        presenter.showHoverPopover(id: id, size: CGSize(width: 272, height: 196), anchorView: anchor) {
            Color.clear.frame(width: 272, height: 196)
        }

        let window = try XCTUnwrap(presenter.windowSnapshotForTesting(id: id))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.parent === parent)
        XCTAssertEqual(window.level, parent.level)
        XCTAssertTrue(presenter.hoverPanelFrames().contains(window.frame))
        presenter.close(id: id)
        XCTAssertNil(presenter.windowSnapshotForTesting(id: id))
        XCTAssertTrue(presenter.hoverPanelFrames().isEmpty)
    }

    private func window(withID id: String, presenter: DetachedWindowPresenter) throws -> NSWindow {
        try XCTUnwrap(presenter.windowSnapshotForTesting(id: id))
    }

    private func contentSize(of window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }
}
