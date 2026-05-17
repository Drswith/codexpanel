import AppKit
import Combine
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject private var store: TokenStore
    @ObservedObject private var updateCoordinator: UpdateCoordinator
    private let codexAppPathPanelService: CodexAppPathPanelService
    private let onClose: () -> Void

    @StateObject private var coordinator: SettingsWindowCoordinator
    @StateObject private var recordsModel: SettingsRecordsModel

    @MainActor
    init(
        store: TokenStore,
        updateCoordinator: UpdateCoordinator? = nil,
        codexAppPathPanelService: CodexAppPathPanelService,
        initialPage: SettingsPage = .accounts,
        onClose: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._updateCoordinator = ObservedObject(wrappedValue: updateCoordinator ?? .shared)
        self.codexAppPathPanelService = codexAppPathPanelService
        self.onClose = onClose
        self._coordinator = StateObject(
            wrappedValue: SettingsWindowCoordinator(
                config: store.config,
                accounts: store.accounts,
                historicalModels: store.historicalModels,
                selectedPage: initialPage
            )
        )
        self._recordsModel = StateObject(
            wrappedValue: SettingsRecordsModel(
                service: RecordsSnapshotService()
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
        .accessibilityIdentifier("codexpanel.settings.window")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    self.coordinator.cancelAndClose(onClose: self.onClose)
                } label: {
                    SettingsToolbarActionButtonLabel(title: L.cancel)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    self.coordinator.saveAndClose(
                        using: self.store,
                        onClose: self.onClose
                    )
                } label: {
                    SettingsToolbarActionButtonLabel(
                        title: L.save,
                        isEnabled: self.coordinator.hasChanges
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(self.coordinator.hasChanges == false)
            }
        }
        .onReceive(self.store.$config.dropFirst()) { config in
            self.coordinator.reconcileExternalState(
                config: config,
                accounts: self.store.accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$accounts.dropFirst()) { accounts in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: accounts,
                historicalModels: self.store.historicalModels
            )
        }
        .onReceive(self.store.$historicalModels.dropFirst()) { historicalModels in
            self.coordinator.reconcileExternalState(
                config: self.store.config,
                accounts: self.store.accounts,
                historicalModels: historicalModels
            )
        }
    }

    private var sidebar: some View {
        ZStack {
            SettingsSidebarBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(SettingsSidebarGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            if let title = group.title {
                                Text(title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(group.pages) { page in
                                    Button {
                                        SettingsSidebarSelectionAdapter.apply(page, to: self.coordinator)
                                    } label: {
                                        SettingsSidebarRow(
                                            page: page,
                                            isSelected: self.coordinator.selectedPage == page
                                        )
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 230)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: self.coordinator.selectedPage == .about ? 0 : 6) {
                    Text("Codex Panel \(L.settings)")
                        .font(.system(size: 20, weight: .semibold))
                    if self.coordinator.selectedPage != .about {
                        Text(L.settingsWindowHint)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let validationMessage = self.coordinator.validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                switch self.coordinator.selectedPage {
                case .accounts:
                    SettingsAccountsPage(
                        coordinator: self.coordinator,
                        codexAppPathPanelService: self.codexAppPathPanelService
                    )
                case .records:
                    SettingsRecordsPage(recordsModel: self.recordsModel) {
                        SettingsSidebarSelectionAdapter.apply(SettingsPage.usage, to: self.coordinator)
                    }
                case .usage:
                    SettingsUsagePage(coordinator: self.coordinator)
                case .diagnostics:
                    SettingsDiagnosticsPage()
                case .about:
                    SettingsAboutPage(updateCoordinator: self.updateCoordinator)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            pages: [SettingsPage.accounts, SettingsPage.records, SettingsPage.usage, SettingsPage.diagnostics]
        ),
        SettingsSidebarGroup(
            id: "product",
            title: "Codex Panel",
            pages: [SettingsPage.about]
        ),
    ]
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(self.page.iconTint.gradient)
                    .frame(width: 20, height: 20)
                Image(systemName: self.page.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }

            Text(self.page.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(self.isSelected ? .white : .primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 34)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.isSelected ? Color.accentColor.opacity(0.92) : .clear)
        )
    }
}

private struct SettingsSidebarBackground: View {
    var body: some View {
        SettingsSidebarMaterialView()
            .overlay(Color.white.opacity(0.015))
    }
}

private struct SettingsSidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

private struct SettingsAccountsPage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator
    let codexAppPathPanelService: CodexAppPathPanelService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.accounts.title)
                .font(.system(size: 16, weight: .semibold))

            SettingsAccountUsageModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountUsageMode },
                    set: { self.coordinator.update(\.accountUsageMode, to: $0, field: .accountUsageMode) }
                )
            )

            SettingsAccountOrderingModeSection(
                mode: Binding(
                    get: { self.coordinator.draft.accountOrderingMode },
                    set: { self.coordinator.update(\.accountOrderingMode, to: $0, field: .accountOrderingMode) }
                )
            )

            if self.coordinator.showsManualActivationBehaviorSection {
                SettingsManualActivationBehaviorSection(
                    behavior: Binding(
                        get: { self.coordinator.draft.manualActivationBehavior },
                        set: { self.coordinator.update(\.manualActivationBehavior, to: $0, field: .manualActivationBehavior) }
                    ),
                    preferredCodexAppPath: Binding(
                        get: { self.coordinator.draft.preferredCodexAppPath },
                        set: { self.coordinator.update(\.preferredCodexAppPath, to: $0, field: .preferredCodexAppPath) }
                    ),
                    validationMessage: self.$coordinator.validationMessage,
                    codexAppPathPanelService: self.codexAppPathPanelService,
                    showsCodexAppPathSection: self.coordinator.showsCodexAppPathSection
                )
            }

            if self.coordinator.showsManualAccountOrderSection {
                SettingsAccountOrderSection(coordinator: self.coordinator)
            }
        }
    }
}

private struct SettingsUsagePage: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPage.usage.title)
                .font(.system(size: 16, weight: .semibold))

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

            SettingsModelPricingSection(coordinator: self.coordinator)
        }
    }
}

private struct SettingsAboutPage: View {
    @ObservedObject var updateCoordinator: UpdateCoordinator
    @State private var cliInstallMessage: String?

    private let cliInstallService = CodexPanelCLIInstallService()
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

    private var cliStatus: CodexPanelCLIInstallStatus {
        self.cliInstallService.status()
    }

    private var cliStatusText: String {
        switch self.cliStatus {
        case .helperMissing(let helperPath, _):
            return L.codexPanelCLIInstallHelperMissing(helperPath)
        case .notInstalled(_, let installPath):
            return L.codexPanelCLIInstallNotInstalled(installPath)
        case .installed(let helperPath, let installPath, let linkedTarget):
            return L.codexPanelCLIInstallInstalled(
                installPath: installPath,
                linkedTarget: linkedTarget,
                helperPath: helperPath
            )
        }
    }

    var body: some View {
        VStack {
            Spacer(minLength: 12)

            VStack(spacing: 22) {
                SettingsAboutAppIcon()

                VStack(spacing: 6) {
                    Text("Codex Panel")
                        .font(.system(size: 28, weight: .bold))
                    Text("\(L.settingsAboutVersionPrefix) \(self.currentVersion)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 4) {
                    Text(L.settingsAboutDescriptionLine1)
                    Text(L.settingsAboutDescriptionLine2)
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    SettingsAboutActionButton(
                        title: L.settingsAboutGitHubAction,
                        icon: "chevron.left.forwardslash.chevron.right"
                    ) {
                        self.open(self.repositoryURL)
                    }
                    SettingsAboutActionButton(
                        title: L.settingsAboutIssuesAction,
                        icon: "ladybug"
                    ) {
                        self.open(self.issuesURL)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SettingsAboutInfoRow(
                        title: L.settingsUpdatesCurrentVersionTitle,
                        value: self.currentVersion
                    )
                    SettingsAboutInfoRow(
                        title: L.settingsUpdatesLatestVersionTitle,
                        value: self.latestVersion
                    )
                    SettingsAboutInfoRow(
                        title: L.settingsAboutUpdateStatusTitle,
                        value: self.statusText
                    )

                    HStack(spacing: 10) {
                        SettingsAboutActionButton(
                            title: L.settingsUpdatesCheckAction,
                            icon: "arrow.triangle.2.circlepath"
                        ) {
                            Task { await self.updateCoordinator.checkForUpdates(trigger: .manual) }
                        }
                        .disabled(self.updateCoordinator.isChecking)

                        if self.updateCoordinator.pendingAvailability != nil {
                            SettingsAboutActionButton(
                                title: L.settingsUpdatesInstallAction,
                                icon: "arrow.down.to.line"
                            ) {
                                Task { await self.updateCoordinator.handleToolbarAction() }
                            }
                            .disabled(self.updateCoordinator.isChecking)
                        }
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )

                VStack(alignment: .leading, spacing: 12) {
                    SettingsAboutInfoRow(
                        title: L.codexPanelCLIInstallStatusTitle(commandName: self.cliInstallService.commandName),
                        value: self.cliStatusText
                    )

                    Text(L.codexPanelCLIInstallHint(commandName: self.cliInstallService.commandName))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        SettingsAboutActionButton(
                            title: L.codexPanelCLIInstallAction(commandName: self.cliInstallService.commandName),
                            icon: "terminal"
                        ) {
                            do {
                                let result = try self.cliInstallService.installSymlink()
                                self.cliInstallMessage = L.codexPanelCLIInstallSucceeded(
                                    installPath: result.installPath,
                                    helperPath: result.helperPath
                                )
                            } catch {
                                self.cliInstallMessage = error.localizedDescription
                            }
                        }
                        .disabled({
                            if case .helperMissing = self.cliStatus {
                                return true
                            }
                            return false
                        }())

                        if let cliInstallMessage = self.cliInstallMessage {
                            Text(cliInstallMessage)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsAboutAppIcon: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 12)
    }
}

private struct SettingsAboutInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 92, alignment: .leading)

            Text(self.value)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

private struct SettingsAboutActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            SettingsCapsuleButtonLabel(title: self.title, icon: self.icon)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsToolbarActionButtonLabel: View {
    let title: String
    var isEnabled: Bool = true

    var body: some View {
        SettingsCapsuleButtonLabel(
            title: self.title,
            isEnabled: self.isEnabled
        )
    }
}

private struct SettingsCapsuleButtonLabel: View {
    let title: String
    var icon: String? = nil
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: self.icon == nil ? 0 : 6) {
            if let icon = self.icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }

            Text(self.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(self.isEnabled ? .primary : Color.secondary.opacity(0.9))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(self.isEnabled ? 0.06 : 0.03))
        )
        .opacity(self.isEnabled ? 1.0 : 0.78)
    }
}

private struct SettingsAccountUsageModeSection: View {
    @Binding var mode: CodexPanelOpenAIAccountUsageMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountUsageModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountUsageModeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexPanelOpenAIAccountUsageMode.allCases) { option in
                    Button {
                        self.mode = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.mode == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.mode == option ? .accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.mode == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SettingsManualActivationBehaviorSection: View {
    @Binding var behavior: CodexPanelOpenAIManualActivationBehavior
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService
    let showsCodexAppPathSection: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.manualActivationBehaviorTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.manualActivationBehaviorHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexPanelOpenAIManualActivationBehavior.allCases) { option in
                    Button {
                        self.behavior = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.behavior == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.behavior == option ? .accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.behavior == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if self.showsCodexAppPathSection {
                SettingsCodexAppPathSection(
                    preferredCodexAppPath: self.$preferredCodexAppPath,
                    validationMessage: self.$validationMessage,
                    codexAppPathPanelService: self.codexAppPathPanelService
                )
            }
        }
    }
}

private struct SettingsAccountOrderingModeSection: View {
    @Binding var mode: CodexPanelOpenAIAccountOrderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountOrderingModeTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountOrderingModeHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CodexPanelOpenAIAccountOrderingMode.allCases) { option in
                    Button {
                        self.mode = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: self.mode == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(self.mode == option ? .accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.mode == option ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SettingsAccountOrderSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.accountOrderTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.accountOrderHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.06))
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsCodexAppPathSection: View {
    @Binding var preferredCodexAppPath: String?
    @Binding var validationMessage: String?

    let codexAppPathPanelService: CodexAppPathPanelService

    private var status: CodexDesktopPreferredAppPathStatus {
        CodexDesktopLaunchProbeService.preferredAppPathStatus(for: self.preferredCodexAppPath)
    }

    private var displayedValue: String {
        switch self.status {
        case .automatic:
            return L.codexAppPathAutomaticStatus
        case .manualValid(let path), .manualInvalid(let path):
            return path
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L.codexAppPathTitle)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 72, alignment: .leading)

            Group {
                switch self.status {
                case .automatic:
                    Text(self.displayedValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                case .manualValid, .manualInvalid:
                    Text(self.displayedValue)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(self.statusColor)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 0)

            Button(L.codexAppPathChooseAction) {
                self.chooseCodexApp()
            }

            if (self.preferredCodexAppPath ?? "").isEmpty == false {
                Button(L.codexAppPathResetAction) {
                    self.preferredCodexAppPath = nil
                    self.validationMessage = nil
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var statusColor: Color {
        switch self.status {
        case .automatic:
            return .secondary
        case .manualValid:
            return .primary
        case .manualInvalid:
            return .orange
        }
    }

    private func chooseCodexApp() {
        guard let selectedURL = self.codexAppPathPanelService.requestCodexAppURL(
            currentPath: self.preferredCodexAppPath
        ) else {
            return
        }

        guard let validatedURL = CodexDesktopLaunchProbeService.validatedPreferredCodexAppURL(
            from: selectedURL.path
        ) else {
            self.validationMessage = L.codexAppPathInvalidSelection
            return
        }

        self.preferredCodexAppPath = validatedURL.path
        self.validationMessage = nil
    }
}

private struct SettingsUsageDisplayModeSection: View {
    @Binding var usageDisplayMode: CodexPanelUsageDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.usageDisplayModeTitle)
                .font(.system(size: 12, weight: .medium))

            Picker(L.usageDisplayModeTitle, selection: self.$usageDisplayMode) {
                ForEach(CodexPanelUsageDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(L.quotaSortSettingsTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.quotaSortSettingsHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        }
    }
}

private struct SettingsModelPricingSection: View {
    @ObservedObject var coordinator: SettingsWindowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.modelPricingSectionTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.modelPricingSectionHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                                get: { self.coordinator.draft.modelPricing[model] ?? .zero },
                                set: { self.coordinator.updateModelPricing(for: model, pricing: $0) }
                            )
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsModelPricingRow: View {
    let model: String
    @Binding var pricing: CodexPanelModelPricing

    private let fieldWidth: CGFloat = 120
    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...10))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.model)
                .font(.system(size: 11, weight: .medium))
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 10) {
                self.priceField(
                    title: L.modelPricingInputTitle,
                    binding: Binding(
                        get: { self.pricing.inputUSDPerToken },
                        set: {
                            self.pricing = CodexPanelModelPricing(
                                inputUSDPerToken: $0,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingCachedInputTitle,
                    binding: Binding(
                        get: { self.pricing.cachedInputUSDPerToken },
                        set: {
                            self.pricing = CodexPanelModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: $0,
                                outputUSDPerToken: self.pricing.outputUSDPerToken
                            )
                        }
                    )
                )
                self.priceField(
                    title: L.modelPricingOutputTitle,
                    binding: Binding(
                        get: { self.pricing.outputUSDPerToken },
                        set: {
                            self.pricing = CodexPanelModelPricing(
                                inputUSDPerToken: self.pricing.inputUSDPerToken,
                                cachedInputUSDPerToken: self.pricing.cachedInputUSDPerToken,
                                outputUSDPerToken: $0
                            )
                        }
                    )
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func priceField(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            TextField(title, value: binding, format: self.numberFormat)
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
        case .records:
            return L.settingsRecordsPageTitle
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
        case .records:
            return "clock.arrow.circlepath"
        case .usage:
            return "chart.bar"
        case .diagnostics:
            return "stethoscope"
        case .about:
            return "info.circle.fill"
        }
    }

    var iconTint: Color {
        switch self {
        case .accounts:
            return Color(red: 0.40, green: 0.63, blue: 1.00)
        case .records:
            return Color(red: 0.99, green: 0.65, blue: 0.16)
        case .usage:
            return Color(red: 0.20, green: 0.76, blue: 0.86)
        case .diagnostics:
            return Color(red: 0.90, green: 0.36, blue: 0.32)
        case .about:
            return Color(red: 0.45, green: 0.76, blue: 0.97)
        }
    }
}

private extension CodexPanelOpenAIManualActivationBehavior {
    var title: String {
        switch self {
        case .updateConfigOnly:
            return L.manualActivationUpdateConfigOnly
        case .launchNewInstance:
            return L.manualActivationLaunchNewInstance
        }
    }

    var detail: String {
        switch self {
        case .updateConfigOnly:
            return L.manualActivationUpdateConfigOnlyHint
        case .launchNewInstance:
            return L.manualActivationLaunchNewInstanceHint
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
