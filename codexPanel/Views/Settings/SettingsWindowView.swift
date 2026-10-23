import AppKit
import Combine
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject private var store: TokenStore
    @ObservedObject private var updateCoordinator: UpdateCoordinator

    @StateObject private var coordinator: SettingsWindowCoordinator
    @State private var autoSaveTask: Task<Void, Never>?

    @MainActor
    init(
        store: TokenStore,
        updateCoordinator: UpdateCoordinator? = nil
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._updateCoordinator = ObservedObject(wrappedValue: updateCoordinator ?? .shared)
        self._coordinator = StateObject(
            wrappedValue: SettingsWindowCoordinator(
                config: store.config,
                accounts: store.accounts,
                historicalModels: store.historicalModels
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
        } detail: {
            self.detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: self.coordinator.draft) { _ in
            self.autoSaveTask?.cancel()
            self.autoSaveTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                guard Task.isCancelled == false else { return }
                self.coordinator.saveAutomatically(using: self.store)
            }
        }
        .onDisappear {
            self.autoSaveTask?.cancel()
            self.coordinator.saveAutomatically(using: self.store)
        }
        .onReceive(self.store.$config.dropFirst()) { config in
            self.coordinator.reconcileExternalState(
                config: config,
                accounts: self.store.accounts,
                historicalModels: self.store.localCostSummary.historicalModels ?? []
            )
        }
        .onReceive(self.store.$accounts.dropFirst()) { accounts in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$localCostSummary.dropFirst()) { summary in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: self.store.accounts,
                historicalModels: summary.historicalModels ?? []
            )
        }
    }

    private var sidebar: some View {
        List(selection: SettingsSidebarSelectionAdapter.binding(for: self.coordinator)) {
            ForEach(SettingsSidebarGroup.allCases) { group in
                Section {
                    ForEach(group.pages) { page in
                        Label {
                            Text(page.title)
                        } icon: {
                            Image(systemName: page.iconName)
                                .foregroundStyle(self.coordinator.selectedPage == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                        }
                        .tag(page)
                    }
                } header: {
                    if let title = group.title {
                        Text(title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L.settings)
        .navigationSplitViewColumnWidth(200)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let validationMessage = self.coordinator.validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Group {
                switch self.coordinator.selectedPage {
                case .accounts:
                    SettingsAccountsPage(
                        coordinator: self.coordinator
                    )
                case .usage:
                    SettingsUsagePage(store: self.store, coordinator: self.coordinator)
                case .diagnostics:
                    SettingsDiagnosticsPage()
                case .about:
                    SettingsAboutPage(updateCoordinator: self.updateCoordinator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .formStyle(.grouped)
        .navigationTitle(self.coordinator.selectedPage.title)
    }

}

@MainActor
enum SettingsSidebarSelectionAdapter {
    static func binding(for coordinator: SettingsWindowCoordinator) -> Binding<SettingsPage?> {
        Binding(
            get: { coordinator.selectedPage },
            set: { selection in
                self.apply(selection, to: coordinator)
            }
        )
    }

    static func apply(_ selection: SettingsPage?, to coordinator: SettingsWindowCoordinator) {
        guard let selection else { return }
        coordinator.selectedPage = selection
    }
}

private struct SettingsSidebarGroup: Identifiable {
    let id: String
    let title: String?
    let pages: [SettingsPage]

    static let allCases: [SettingsSidebarGroup] = [
        SettingsSidebarGroup(
            id: "primary",
            title: nil,
            pages: [SettingsPage.accounts, SettingsPage.usage, SettingsPage.diagnostics]
        ),
        SettingsSidebarGroup(
            id: "product",
            title: "Codex Panel",
            pages: [SettingsPage.about]
        ),
    ]
}

private struct SettingsAccountsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        Form {
            SettingsAccountUsageModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountUsageMode },
                    set: { self.coordinator.update(\.accountUsageMode, to: $0, field: .accountUsageMode) }
                )
            )

            SettingsAggregateGatewayProxySection(
                aggregateGatewayProxyURL: Binding(
                    get: { self.coordinator.draft.aggregateGatewayProxyURL },
                    set: { self.coordinator.update(\.aggregateGatewayProxyURL, to: $0, field: .aggregateGatewayProxyURL) }
                )
            )

            SettingsAccountOrderingModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountOrderingMode },
                    set: { self.coordinator.update(\.accountOrderingMode, to: $0, field: .accountOrderingMode) }
                )
            )

            if self.coordinator.showsManualAccountOrderSection {
                SettingsAccountOrderSection(coordinator: self.coordinator)
            }
        }
    }
}

private struct SettingsUsagePage: View {
    @ObservedObject var store: TokenStore
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        Form {
            SettingsLocalUsageEngineSection(store: self.store)

            SettingsUsageDisplayModeSection(
                usageDisplayMode: Binding(
                    get: { self.coordinator.draft.usageDisplayMode },
                    set: { self.coordinator.update(\.usageDisplayMode, to: $0, field: .usageDisplayMode) }
                )
            )

            SettingsQuotaSortSection(
                plusRelativeWeight: Binding(
                    get: { self.coordinator.draft.plusRelativeWeight },
                    set: { self.coordinator.update(\.plusRelativeWeight, to: $0, field: .plusRelativeWeight) }
                ),
                proRelativeToPlusMultiplier: Binding(
                    get: { self.coordinator.draft.proRelativeToPlusMultiplier },
                    set: { self.coordinator.update(\.proRelativeToPlusMultiplier, to: $0, field: .proRelativeToPlusMultiplier) }
                ),
                teamRelativeToPlusMultiplier: Binding(
                    get: { self.coordinator.draft.teamRelativeToPlusMultiplier },
                    set: { self.coordinator.update(\.teamRelativeToPlusMultiplier, to: $0, field: .teamRelativeToPlusMultiplier) }
                )
            )

            if self.store.localUsageEnabled {
                SettingsModelPricingSection(coordinator: self.coordinator)
            }
        }
    }
}

private struct SettingsLocalUsageEngineSection: View {
    @ObservedObject var store: TokenStore
    @State private var hasRequestedDownload = false

    private var isBusy: Bool {
        self.store.isCheckingTokscaleEngines || self.store.isInstallingTokscaleEngine
    }

    private var hasCompatibleManagedEngine: Bool {
        self.store.tokscaleEngines.contains { $0.source == .managed && $0.isCompatible }
    }

    var body: some View {
        Section {
            Toggle(
                L.localUsageEnabledTitle,
                isOn: Binding(
                    get: { self.store.localUsageEnabled },
                    set: { self.store.setLocalUsageEnabled($0) }
                )
            )

            HStack(spacing: 12) {
                if self.store.isCheckingTokscaleEngines {
                    self.progressRow(L.localUsageEngineChecking)
                } else if self.store.isInstallingTokscaleEngine {
                    self.progressRow(L.localUsageEngineDownloading)
                } else if !self.store.tokscaleEngines.isEmpty {
                    Menu {
                        ForEach(self.store.tokscaleEngines, id: \.id) { engine in
                            Button {
                                self.store.selectTokscaleEngine(id: engine.id)
                            } label: {
                                if self.store.selectedTokscaleEngineID == engine.id {
                                    Label(self.engineTitle(engine), systemImage: "checkmark")
                                } else {
                                    Text(self.engineTitle(engine))
                                }
                            }
                            .disabled(!self.store.localUsageEnabled || !engine.isCompatible)
                            .help(engine.isCompatible ? engine.executableURL.path : L.localUsageEngineIncompatible)
                        }
                    } label: {
                        Text((self.store.activeTokscaleEngine ?? self.store.tokscaleEngines.first).map(self.engineTitle) ?? L.localUsageEngineVersion)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(L.localUsageEngineVersion)
                } else if self.store.tokscaleEngineError == nil {
                    Text(self.store.hasCheckedTokscaleEngines ? L.localUsageEngineNotFound : L.localUsageEngineUnchecked)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(L.localUsageEngineCheck) {
                    self.store.checkTokscaleEngines()
                }
                .fixedSize()
                .disabled(self.isBusy)

                if !self.hasCompatibleManagedEngine {
                    Button(
                        self.hasRequestedDownload && self.store.tokscaleEngineError != nil
                            ? L.localUsageEngineRetryDownload
                            : L.localUsageEngineDownload
                    ) {
                        self.hasRequestedDownload = true
                        self.store.installManagedTokscaleEngine()
                    }
                    .fixedSize()
                    .disabled(self.isBusy)
                }
            }

            if !self.isBusy, self.store.tokscaleEngines.count == 1,
               self.store.tokscaleEngines.first?.isCompatible == false {
                Text(L.localUsageEngineIncompatible)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = self.store.tokscaleEngineError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text(L.localUsageEngineTitle)
        } footer: {
            Text(L.localUsageEngineHint)
        }
    }

    private func engineTitle(_ engine: TokscaleEngineDescriptor) -> String {
        let source = engine.source == .managed ? L.localUsageEngineManaged : L.localUsageEngineInstalled
        return "tokscale \(engine.version) · \(source)"
    }

    private func progressRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsAboutPage: View {
    @ObservedObject var updateCoordinator: UpdateCoordinator

    private let repositoryURL = URL(string: "https://github.com/Drswith/codexpanel")
    private let issuesURL = URL(string: "https://github.com/Drswith/codexpanel/issues")

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var latestVersion: String {
        if let availability = self.updateCoordinator.pendingAvailability {
            return availability.release.version
        }
        switch self.updateCoordinator.state {
        case let .upToDate(_, checkedVersion):
            return checkedVersion
        case let .executing(availability):
            return availability.release.version
        case let .updateAvailable(availability):
            return availability.release.version
        case .idle, .checking, .failed:
            return L.settingsUpdatesUnknownVersion
        }
    }

    private var shortStatusText: String {
        switch self.updateCoordinator.state {
        case .idle: return L.settingsUpdatesUnknownVersion
        case .checking: return L.settingsAboutUpdateChecking
        case .upToDate: return L.settingsAboutUpdateCurrent
        case .updateAvailable: return L.settingsAboutUpdateAvailable
        case .executing: return L.settingsAboutUpdateExecuting
        case .failed: return L.settingsAboutUpdateFailed
        }
    }

    private var statusText: String {
        switch self.updateCoordinator.state {
        case .idle:
            return L.settingsUpdatesIdle
        case .checking:
            return L.settingsUpdatesChecking
        case let .upToDate(currentVersion, _):
            return L.settingsUpdatesUpToDate(currentVersion)
        case let .updateAvailable(availability):
            return L.settingsUpdatesAvailable(
                availability.currentVersion,
                availability.release.version
            )
        case let .executing(availability):
            return L.settingsUpdatesExecuting(availability.release.version)
        case let .failed(message):
            return L.settingsUpdatesFailed(message)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text("Codex Panel").font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section(L.settingsAboutVersionPrefix) {
                    LabeledContent(L.settingsUpdatesCurrentVersionTitle) {
                        HStack {
                            Text(self.currentVersion).textSelection(.enabled)
                            if self.updateCoordinator.isChecking {
                                ProgressView().controlSize(.small)
                            }
                            Button(L.checkForUpdates) {
                                Task { await self.updateCoordinator.checkForUpdates(trigger: .manual) }
                            }
                            .disabled(self.updateCoordinator.isChecking)
                        }
                    }
                    LabeledContent(L.settingsAboutUpdateStatusTitle) {
                        Text(self.shortStatusText).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(self.statusText)
                    }
                    if self.updateCoordinator.pendingAvailability != nil {
                        LabeledContent(L.settingsUpdatesLatestVersionTitle, value: self.latestVersion)
                        Button(L.settingsUpdatesInstallAction) {
                            Task { await self.updateCoordinator.handleToolbarAction() }
                        }
                        .disabled(self.updateCoordinator.isChecking)
                    }
                }

                Section(L.settingsAboutBuildInfoTitle) {
                    LabeledContent(L.settingsAboutBuildNumberTitle,
                                   value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                    LabeledContent(L.settingsAboutSystemVersionTitle,
                                   value: ProcessInfo.processInfo.operatingSystemVersionString)
                }
                .textSelection(.enabled)

                Section(L.settingsAboutProjectTitle) {
                    if let repositoryURL = self.repositoryURL {
                        LabeledContent(L.settingsAboutGitHubAction) {
                            Link("Drswith/codexpanel", destination: repositoryURL)
                        }
                    }
                    if let issuesURL = self.issuesURL {
                        LabeledContent(L.settingsAboutIssuesAction) {
                            Link("GitHub Issues", destination: issuesURL)
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsAccountUsageModeSection: View {
    @Binding var mode: CodexPanelOpenAIAccountUsageMode

    var body: some View {
        Section {
            Picker(L.accountUsageModeTitle, selection: self.$mode) {
                ForEach(CodexPanelOpenAIAccountUsageMode.allCases) { option in
                    Text(option.title).tag(option).help(option.detail)
                }
            }
            .pickerStyle(.menu)
            Text(self.mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text(L.accountUsageModeTitle)
        } footer: {
            Text(L.accountUsageModeHint)
        }
    }
}

private struct SettingsAggregateGatewayProxySection: View {
    @Binding var aggregateGatewayProxyURL: String?

    var body: some View {
        Section {
            TextField(
                L.aggregateGatewayProxyTitle,
                text: Binding(
                    get: { self.aggregateGatewayProxyURL ?? "" },
                    set: { self.aggregateGatewayProxyURL = $0 }
                ),
                prompt: Text(L.aggregateGatewayProxyInputExample)
            )
            .labelsHidden()
            .accessibilityLabel(L.aggregateGatewayProxyTitle)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
        } header: {
            Text(L.aggregateGatewayProxyTitle)
        } footer: {
            Text(L.aggregateGatewayProxyHint)
        }
    }
}

private struct SettingsAccountOrderingModeSection: View {
    @Binding var mode: CodexPanelOpenAIAccountOrderingMode

    var body: some View {
        Section {
            Picker(L.accountOrderingModeTitle, selection: self.$mode) {
                ForEach(CodexPanelOpenAIAccountOrderingMode.allCases) { option in
                    Text(option.title).tag(option).help(option.detail)
                }
            }
            .pickerStyle(.menu)
            Text(self.mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text(L.accountOrderingModeTitle)
        } footer: {
            Text(L.accountOrderingModeHint)
        }
    }
}

private struct SettingsAccountOrderSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        Section {
            if self.coordinator.orderedAccounts.isEmpty {
                Text(L.noOpenAIAccountsForOrdering)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(self.coordinator.orderedAccounts.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 11, weight: .medium))
                                Text(item.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 6) {
                                Button(L.moveUp) {
                                    self.coordinator.moveAccount(accountID: item.id, offset: -1)
                                }
                                .disabled(index == 0)

                                Button(L.moveDown) {
                                    self.coordinator.moveAccount(accountID: item.id, offset: 1)
                                }
                                .disabled(index == self.coordinator.orderedAccounts.count - 1)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text(L.accountOrderTitle)
        } footer: {
            Text(L.accountOrderHint)
        }
    }
}

private struct SettingsUsageDisplayModeSection: View {
    @Binding var usageDisplayMode: CodexPanelUsageDisplayMode

    var body: some View {
        Section {
            Picker(L.usageDisplayModeTitle, selection: self.$usageDisplayMode) {
                ForEach(CodexPanelUsageDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }
}

private struct SettingsQuotaSortSection: View {
    @Binding var plusRelativeWeight: Double
    @Binding var proRelativeToPlusMultiplier: Double
    @Binding var teamRelativeToPlusMultiplier: Double

    private var proAbsoluteWeight: Double {
        self.plusRelativeWeight * self.proRelativeToPlusMultiplier
    }

    private var teamAbsoluteWeight: Double {
        self.plusRelativeWeight * self.teamRelativeToPlusMultiplier
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortPlusWeightTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(L.quotaSortPlusWeightValue(self.plusRelativeWeight))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: self.$plusRelativeWeight,
                    in: CodexPanelOpenAISettings.QuotaSortSettings.plusRelativeWeightRange,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortProRatioTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(
                        L.quotaSortProRatioValue(
                            self.proRelativeToPlusMultiplier,
                            absoluteProWeight: self.proAbsoluteWeight
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Slider(
                    value: self.$proRelativeToPlusMultiplier,
                    in: CodexPanelOpenAISettings.QuotaSortSettings.proRelativeToPlusRange,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.quotaSortTeamRatioTitle)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(
                        L.quotaSortTeamRatioValue(
                            self.teamRelativeToPlusMultiplier,
                            absoluteTeamWeight: self.teamAbsoluteWeight
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Slider(
                    value: self.$teamRelativeToPlusMultiplier,
                    in: CodexPanelOpenAISettings.QuotaSortSettings.teamRelativeToPlusRange,
                    step: 0.1
                )
            }
        } header: {
            Text(L.quotaSortSettingsTitle)
        } footer: {
            Text(L.quotaSortSettingsHint)
        }
    }
}

private struct SettingsModelPricingSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        Section {
            if self.coordinator.historicalModels.isEmpty {
                Text(L.modelPricingSectionEmpty)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.coordinator.historicalModels, id: \.self) { model in
                        SettingsModelPricingRow(
                            model: model,
                            pricing: Binding(
                                get: { self.coordinator.draft.modelPricing[model] },
                                set: { self.coordinator.updateModelPricing(for: model, pricing: $0) }
                            )
                        )
                    }
                }
            }
        } header: {
            Text(L.modelPricingSectionTitle)
        } footer: {
            Text(L.modelPricingSectionHint)
        }
    }
}

private struct SettingsModelPricingRow: View {
    let model: String
    @Binding var pricing: CodexPanelModelPricing?
    @State private var isEditingAutomatic = false
    @State private var pendingPricing = CodexPanelModelPricing.zero

    private let fieldWidth: CGFloat = 120
    private let tokensPerUnit: Double = 1_000_000
    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...6))

    private var editingPricing: CodexPanelModelPricing {
        get { self.pricing ?? self.pendingPricing }
        nonmutating set {
            if self.pricing != nil {
                self.pricing = newValue
            } else {
                self.pendingPricing = newValue
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(self.model)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                Spacer()
                Text(self.pricing == nil ? L.modelPricingAutomaticTitle : L.modelPricingCustomTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if self.pricing != nil {
                    Button(L.modelPricingRestoreAutomatic) {
                        self.pricing = nil
                        self.isEditingAutomatic = false
                    }
                    .buttonStyle(.borderless)
                } else if !self.isEditingAutomatic {
                    Button(L.modelPricingCustomize) {
                        self.pendingPricing = .zero
                        self.isEditingAutomatic = true
                    }
                    .buttonStyle(.borderless)
                }
            }

            if self.pricing != nil || self.isEditingAutomatic {
                HStack(alignment: .top, spacing: 10) {
                    self.priceField(
                        title: L.modelPricingInputTitle,
                        binding: Binding(
                            get: { self.editingPricing.inputUSDPerToken * self.tokensPerUnit },
                            set: {
                                self.editingPricing = CodexPanelModelPricing(
                                    inputUSDPerToken: $0 / self.tokensPerUnit,
                                    cachedInputUSDPerToken: self.editingPricing.cachedInputUSDPerToken,
                                    outputUSDPerToken: self.editingPricing.outputUSDPerToken
                                )
                            }
                        )
                    )
                    self.priceField(
                        title: L.modelPricingCachedInputTitle,
                        binding: Binding(
                            get: { self.editingPricing.cachedInputUSDPerToken * self.tokensPerUnit },
                            set: {
                                self.editingPricing = CodexPanelModelPricing(
                                    inputUSDPerToken: self.editingPricing.inputUSDPerToken,
                                    cachedInputUSDPerToken: $0 / self.tokensPerUnit,
                                    outputUSDPerToken: self.editingPricing.outputUSDPerToken
                                )
                            }
                        )
                    )
                    self.priceField(
                        title: L.modelPricingOutputTitle,
                        binding: Binding(
                            get: { self.editingPricing.outputUSDPerToken * self.tokensPerUnit },
                            set: {
                                self.editingPricing = CodexPanelModelPricing(
                                    inputUSDPerToken: self.editingPricing.inputUSDPerToken,
                                    cachedInputUSDPerToken: self.editingPricing.cachedInputUSDPerToken,
                                    outputUSDPerToken: $0 / self.tokensPerUnit
                                )
                            }
                        )
                    )
                }
                if self.isEditingAutomatic && self.pricing == nil {
                    Text(L.modelPricingCustomDraftHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L.modelPricingApplyCustom) {
                            self.pricing = self.pendingPricing
                            self.isEditingAutomatic = false
                        }
                        Button(L.modelPricingCancelCustom) {
                            self.isEditingAutomatic = false
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                Text(L.modelPricingAutomaticHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func priceField(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField(title, value: binding, format: self.numberFormat)
                .labelsHidden()
                .accessibilityLabel(title)
                .textFieldStyle(.roundedBorder)
                .frame(width: self.fieldWidth)
        }
    }
}

private extension SettingsPage {
    var title: String {
        switch self {
        case .accounts:
            return L.settingsAccountsPageTitle
        case .usage:
            return L.settingsUsagePageTitle
        case .diagnostics:
            return L.settingsDiagnosticsPageTitle
        case .about:
            return L.settingsAboutPageTitle
        }
    }

    var iconName: String {
        switch self {
        case .accounts:
            return "person.crop.circle"
        case .usage:
            return "chart.bar"
        case .diagnostics:
            return "stethoscope"
        case .about:
            return "info.circle.fill"
        }
    }


}

private extension CodexPanelOpenAIManualActivationBehavior {
    var title: String {
        switch self {
        case .updateConfigOnly:
            return L.manualActivationUpdateConfigOnly
        case .launchNewInstance:
            return L.manualActivationUpdateConfigOnly
        }
    }

    var detail: String {
        switch self {
        case .updateConfigOnly:
            return L.manualActivationUpdateConfigOnlyHint
        case .launchNewInstance:
            return L.manualActivationUpdateConfigOnlyHint
        }
    }
}

private extension CodexPanelOpenAIAccountUsageMode {
    var title: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitch
        case .aggregateGateway:
            return L.accountUsageModeAggregate
        }
    }

    var detail: String {
        switch self {
        case .switchAccount:
            return L.accountUsageModeSwitchHint
        case .aggregateGateway:
            return L.accountUsageModeAggregateHint
        }
    }
}

private extension CodexPanelOpenAIAccountOrderingMode {
    var title: String {
        switch self {
        case .quotaSort:
            return L.accountOrderingModeQuotaSort
        case .manual:
            return L.accountOrderingModeManual
        }
    }

    var detail: String {
        switch self {
        case .quotaSort:
            return L.accountOrderingModeQuotaSortHint
        case .manual:
            return L.accountOrderingModeManualHint
        }
    }
}
