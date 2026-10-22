import AppKit
import Combine
import SwiftUI

private final class ThinOverlayScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        min(6, super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle))
    }
}

private final class ActivityAwareScrollView: NSScrollView {
    var onUserScrollActivity: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        self.onUserScrollActivity?()
        super.scrollWheel(with: event)
    }
}

private enum AdaptiveScrollHeightLimit {
    case fixed(CGFloat)
    case measured(AnyView)
}

enum MenuBarErrorSource: Equatable {
    case generic
    case refresh
    case notice
}

struct MenuBarErrorBannerState: Equatable {
    let message: String
    let source: MenuBarErrorSource
}

enum MenuBarRefreshErrorResolver {
    static func nextBanner(
        current: MenuBarErrorBannerState?,
        announceResult: Bool,
        refreshMessage: String?
    ) -> MenuBarErrorBannerState? {
        if let refreshMessage {
            guard announceResult else { return current }
            return MenuBarErrorBannerState(message: refreshMessage, source: .refresh)
        }

        guard current?.source == .refresh else { return current }
        return nil
    }
}

struct MenuBarOpenRefreshGate: Equatable {
    private(set) var didTriggerOpenRefresh = false

    mutating func shouldTriggerRefresh(isRefreshing: Bool) -> Bool {
        guard self.didTriggerOpenRefresh == false else { return false }
        self.didTriggerOpenRefresh = true
        return isRefreshing == false
    }

    mutating func resetForClose() {
        self.didTriggerOpenRefresh = false
    }
}

enum MenuBarRefreshOrigin: Equatable {
    case menuOpen
    case manual

    var refreshesSessionCache: Bool {
        self == .manual
    }
}

private struct AdaptiveMenuScrollContainer<Content: View>: NSViewRepresentable {
    let heightLimit: AdaptiveScrollHeightLimit
    let initialHeight: CGFloat
    let maxHeightCap: CGFloat?
    let onMeasuredHeightChange: ((CGFloat) -> Void)?
    let content: Content

    init(
        maxHeight: CGFloat,
        maxHeightCap: CGFloat? = nil,
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .fixed(maxHeight)
        self.initialHeight = maxHeight
        self.maxHeightCap = maxHeightCap
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    init<MeasurementContent: View>(
        initialHeight: CGFloat,
        measuredHeight: @escaping () -> MeasurementContent,
        maxHeightCap: CGFloat? = nil,
        onMeasuredHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heightLimit = .measured(AnyView(measuredHeight()))
        self.initialHeight = initialHeight
        self.maxHeightCap = maxHeightCap
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.content = content()
    }

    func makeNSView(context: Context) -> AdaptiveMenuScrollHost {
        AdaptiveMenuScrollHost(
            rootView: AnyView(content),
            heightLimit: heightLimit,
            initialHeight: initialHeight,
            maxHeightCap: maxHeightCap,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    func updateNSView(_ nsView: AdaptiveMenuScrollHost, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            heightLimit: heightLimit,
            maxHeightCap: maxHeightCap,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }
}

struct NativeMenuBodyContainer<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            self.content.fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                self.content
            }
            .frame(height: self.maxHeight)
        }
        .frame(maxHeight: self.maxHeight, alignment: .top)
    }
}

private struct MenuBarMeasuredSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct ViewReferenceReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> ReporterView {
        ReporterView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfAttached()
    }

    final class ReporterView: NSView {
        var onResolve: (NSView) -> Void

        init(onResolve: @escaping (NSView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfAttached()
        }

        override func layout() {
            super.layout()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onResolve(self)
            }
        }
    }
}

private final class AdaptiveMenuScrollHost: NSView {
    private let scrollView = ActivityAwareScrollView()
    private let displayHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let measuringHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let limitHostingView = NSHostingView(rootView: AnyView(EmptyView()))

    private var heightLimit: AdaptiveScrollHeightLimit
    private var measuredHeight: CGFloat
    private var maxHeightCap: CGFloat?
    private var lastReportedHeight: CGFloat?
    private var isMeasuring = false
    private var lastMeasuredWidth: CGFloat = 0
    private var hideScrollerWorkItem: DispatchWorkItem?
    private var onMeasuredHeightChange: ((CGFloat) -> Void)?

    private let idleScrollerAlpha: CGFloat = 0
    private let visibleScrollerAlpha: CGFloat = 0.95
    private let scrollerHideDelay: TimeInterval = 0.9

    init(
        rootView: AnyView,
        heightLimit: AdaptiveScrollHeightLimit,
        initialHeight: CGFloat,
        maxHeightCap: CGFloat?,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.heightLimit = heightLimit
        self.measuredHeight = max(initialHeight, 1)
        self.maxHeightCap = maxHeightCap
        self.onMeasuredHeightChange = onMeasuredHeightChange
        super.init(frame: .zero)

        self.scrollView.drawsBackground = false
        self.scrollView.borderType = .noBorder
        self.scrollView.autohidesScrollers = true
        self.scrollView.scrollerStyle = .overlay
        self.scrollView.verticalScroller = ThinOverlayScroller()
        self.scrollView.verticalScroller?.controlSize = .mini
        self.scrollView.verticalScroller?.alphaValue = self.idleScrollerAlpha
        self.scrollView.hasVerticalScroller = false
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.documentView = self.displayHostingView
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.onUserScrollActivity = { [weak self] in
            self?.showScrollerTemporarily()
        }

        self.addSubview(self.scrollView)
        self.update(
            rootView: rootView,
            heightLimit: heightLimit,
            maxHeightCap: maxHeightCap,
            onMeasuredHeightChange: onMeasuredHeightChange
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.hideScrollerWorkItem?.cancel()
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        self.scrollView.frame = self.bounds

        let width = max(self.bounds.width, 1)
        guard abs(self.lastMeasuredWidth - width) > 1 else { return }
        self.lastMeasuredWidth = width
        self.scheduleMeasurement()
    }

    func update(
        rootView: AnyView,
        heightLimit: AdaptiveScrollHeightLimit,
        maxHeightCap: CGFloat?,
        onMeasuredHeightChange: ((CGFloat) -> Void)?
    ) {
        self.heightLimit = heightLimit
        self.maxHeightCap = maxHeightCap
        self.onMeasuredHeightChange = onMeasuredHeightChange
        self.displayHostingView.rootView = rootView
        self.measuringHostingView.rootView = rootView
        if case let .measured(limitView) = heightLimit {
            self.limitHostingView.rootView = limitView
        } else {
            self.limitHostingView.rootView = AnyView(EmptyView())
        }
        self.scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateLayout()
        }
    }

    private func recalculateLayout() {
        guard self.isMeasuring == false else { return }
        self.isMeasuring = true
        defer { self.isMeasuring = false }

        let width = max(self.bounds.width, 1)
        self.measuringHostingView.setFrameSize(NSSize(width: width, height: MenuBarPopoverSizing.minimumHeight))

        let fittingHeight = max(self.measuringHostingView.fittingSize.height, MenuBarPopoverSizing.minimumHeight)
        let limitHeight = self.resolveHeightLimit(for: width)
        let effectiveLimitHeight = min(limitHeight, max(self.maxHeightCap ?? limitHeight, 1))
        let targetHeight = min(effectiveLimitHeight, fittingHeight)
        let needsScroller = fittingHeight > effectiveLimitHeight + 1

        self.displayHostingView.setFrameSize(NSSize(width: width, height: fittingHeight))
        self.clampScrollPosition(documentHeight: fittingHeight)
        self.scrollView.hasVerticalScroller = needsScroller
        if needsScroller {
            self.hideScrollerImmediately()
        } else {
            self.hideScrollerWorkItem?.cancel()
            self.scrollView.verticalScroller?.alphaValue = self.idleScrollerAlpha
        }

        if abs((self.lastReportedHeight ?? 0) - targetHeight) > 1 {
            self.lastReportedHeight = targetHeight
            self.onMeasuredHeightChange?(targetHeight)
        }

        guard abs(self.measuredHeight - targetHeight) > 1 else { return }
        self.measuredHeight = targetHeight
        self.invalidateIntrinsicContentSize()
        self.superview?.invalidateIntrinsicContentSize()
        self.needsLayout = true
        self.superview?.needsLayout = true
    }

    private func resolveHeightLimit(for width: CGFloat) -> CGFloat {
        switch self.heightLimit {
        case let .fixed(maxHeight):
            return max(maxHeight, 1)
        case .measured:
            self.limitHostingView.setFrameSize(NSSize(width: width, height: MenuBarPopoverSizing.minimumHeight))
            return max(self.limitHostingView.fittingSize.height, MenuBarPopoverSizing.minimumHeight)
        }
    }

    private func clampScrollPosition(documentHeight: CGFloat) {
        let clipView = self.scrollView.contentView
        var origin = clipView.bounds.origin
        let maxY = max(documentHeight - clipView.bounds.height, 0)
        origin.y = min(max(origin.y, 0), maxY)
        clipView.scroll(to: origin)
        self.scrollView.reflectScrolledClipView(clipView)
    }

    private func showScrollerTemporarily() {
        guard self.scrollView.hasVerticalScroller else { return }
        self.hideScrollerWorkItem?.cancel()
        self.animateScroller(to: self.visibleScrollerAlpha)

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideScrollerImmediately()
        }
        self.hideScrollerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + self.scrollerHideDelay, execute: workItem)
    }

    private func hideScrollerImmediately() {
        guard self.scrollView.hasVerticalScroller else { return }
        self.hideScrollerWorkItem?.cancel()
        self.animateScroller(to: self.idleScrollerAlpha)
    }

    private func animateScroller(to alpha: CGFloat) {
        guard let scroller = self.scrollView.verticalScroller else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scroller.animator().alphaValue = alpha
        }
    }
}

private struct APIProviderListRow: Identifiable {
    let provider: CodexPanelProvider
    let visibleAccounts: [CodexPanelProviderAccount]

    var id: String {
        self.provider.id
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @EnvironmentObject var updateCoordinator: UpdateCoordinator

    private let costPanelID = "cost-details-hover-panel"
    private let resetCreditsPanelID = "reset-credits-hover-panel"
    private let usageRefreshInterval = OpenAIUsagePollingService.defaultRefreshInterval
    private let visibleOpenAIAccountLimit = 10
    private let openAIAccountsInitialHeight: CGFloat = 260
    private let visibleAPIEntryLimit = 10
    private let apiProvidersInitialHeight: CGFloat = 260
    private let runningThreadAttributionService = OpenAIRunningThreadAttributionService()
    private let oauthAccountService = CodexPanelOAuthAccountService()
    private let openAIAccountCSVService = OpenAIAccountCSVService()
    private let openAIAccountCSVPanelService = OpenAIAccountCSVPanelService()
    private let codexAppPathPanelService = CodexAppPathPanelService.shared

    @State private var isRefreshing = false
    @State private var errorBanner: MenuBarErrorBannerState?
    @State private var now = Date()
    @State private var runningThreadAttribution = OpenAIRunningThreadAttribution.empty
    @State private var refreshingAccounts: Set<String> = []
    @State private var copiedOpenAIAccountGroupEmail: String?
    @State private var languageToggle = false
    @State private var isCostSummaryHovered = false
    @State private var isCostPanelHovered = false
    @State private var isCostPanelPresented = false
    @State private var isResetCreditsHovered = false
    @State private var isResetCreditsPanelHovered = false
    @State private var isResetCreditsPanelPresented = false
    @State private var isResetCreditsPanelPinned = false
    @State private var openRefreshGate = MenuBarOpenRefreshGate()
    @State private var pendingCostHide: DispatchWorkItem?
    @State private var pendingResetCreditsHide: DispatchWorkItem?
    @State private var pendingCopiedOpenAIAccountGroupEmailHide: DispatchWorkItem?
    @State private var costSummaryAnchorView: NSView?
    @State private var resetCreditsAnchorView: NSView?
    @State private var isProvidersExpanded = false
    @State private var lastOpenAIManualSwitchResult: OpenAIManualSwitchResult?
    @State private var desktopInstanceBanner: OpenAIStatusBannerPresentation?
    @State private var pendingResetCredit: RateLimitResetCreditItem?
    @State private var isConsumingResetCredit = false
    @State private var launchingInstanceAccountIDs: Set<String> = []
    @State private var measuredMenuHeight: CGFloat = 0
    @State private var openAIAccountsMeasuredHeight: CGFloat = 0
    @State private var apiProvidersMeasuredHeight: CGFloat = 0
    @State private var statusItemAvailableContentHeight: CGFloat?
    @State private var countdownTimerConnection: Cancellable?
    @State private var runningThreadTimerConnection: Cancellable?
    @State private var runningThreadRefreshController = CoalescedBackgroundRefreshController<OpenAIRunningThreadAttribution>()
    @State private var usageBackfillTask: Task<Void, Never>?

    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common)
    private let runningThreadTimer = Timer.publish(
        every: OpenAIRunningThreadAttributionService.defaultRecentActivityWindow,
        on: .main,
        in: .common
    )
    private let backgroundUsageBackfillStepInterval: TimeInterval = 4
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private var groupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.groupedAccounts(
            from: store.accounts,
            summary: self.runningThreadSummary,
            quotaSortSettings: self.store.config.openAI.quotaSort,
            preferredAccountOrder: self.store.config.openAI.preferredDisplayAccountOrder,
            highlightActiveAccount: self.store.config.openAI.accountUsageMode == .switchAccount
        )
    }

    private var runningThreadSummary: OpenAIRunningThreadAttribution.Summary {
        self.runningThreadAttribution.summary
    }

    private var openAIRuntimeRouteSnapshot: OpenAIRuntimeRouteSnapshot {
        self.store.openAIRuntimeRouteSnapshot(
            runningThreadAttribution: self.runningThreadAttribution,
            now: self.now
        )
    }

    private var openAIAccountsHeightCap: CGFloat? {
        MenuBarPopoverSizing.flexibleSectionHeightCap(
            totalContentHeight: self.measuredMenuHeight,
            flexibleSectionHeight: self.openAIAccountsMeasuredHeight,
            availableHeight: self.statusItemAvailableContentHeight
        )
    }

    private var apiProvidersHeightCap: CGFloat? {
        MenuBarPopoverSizing.flexibleSectionHeightCap(
            totalContentHeight: self.measuredMenuHeight,
            flexibleSectionHeight: self.apiProvidersMeasuredHeight,
            availableHeight: self.statusItemAvailableContentHeight
        )
    }

    private var menuBodyMaximumHeight: CGFloat {
        // 标题、底栏和外边距预留固定空间；长列表交给原生 ScrollView。
        max(1, (self.statusItemAvailableContentHeight ?? MenuBarPopoverSizing.maximumHeight) - 74)
    }

    private var switchTargetAccount: TokenAccount? {
        if let selectedAccountID = self.store.config.openAI.switchModeSelection?.accountId,
           let account = self.store.oauthAccount(accountID: selectedAccountID) {
            return account
        }
        return self.store.activeAccount()
    }

    private var latestRoutedAccount: TokenAccount? {
        guard let accountID = self.openAIRuntimeRouteSnapshot.latestRoutedAccountID else {
            return nil
        }
        return self.store.oauthAccount(accountID: accountID)
    }

    private var manualSwitchBanner: OpenAIStatusBannerPresentation? {
        guard let lastOpenAIManualSwitchResult else { return nil }
        return OpenAIAccountPresentation.manualSwitchBanner(
            result: lastOpenAIManualSwitchResult,
            targetAccount: self.store.oauthAccount(accountID: lastOpenAIManualSwitchResult.targetAccountID)
        )
    }

    private var resetCreditItems: [RateLimitResetCreditItem] {
        RateLimitResetCreditPresentation.items(from: self.store.accounts, now: self.now)
    }

    private var resetCreditBanner: OpenAIStatusBannerPresentation? {
        RateLimitResetCreditPresentation.banner(from: self.store.accounts, now: self.now)
    }

    private var resetCreditTotalAvailableCount: Int {
        self.store.accounts.reduce(0) { partial, account in
            let listed = account.availableRateLimitResetCredits(now: self.now).count
            return partial + max(account.rateLimitResetAvailableCount, listed)
        }
    }

    private var runtimeRouteBanner: OpenAIStatusBannerPresentation? {
        OpenAIAccountPresentation.runtimeRouteBanner(
            snapshot: self.openAIRuntimeRouteSnapshot,
            latestRoutedAccount: self.latestRoutedAccount,
            switchTargetAccount: self.switchTargetAccount
        )
    }

    private var visibleGroupedAccounts: [OpenAIAccountGroup] {
        OpenAIAccountListLayout.visibleGroups(
            from: groupedAccounts,
            maxAccounts: visibleOpenAIAccountLimit
        )
    }

    private var openAIAccountCount: Int {
        groupedAccounts.reduce(0) { count, group in
            count + group.accounts.count
        }
    }

    private var shouldScrollOpenAIAccounts: Bool {
        self.openAIAccountCount > self.visibleOpenAIAccountLimit
    }

    private var apiEntryCount: Int {
        self.apiEntryCount(
            customProviders: self.store.customProviders,
            openRouterProvider: self.visibleOpenRouterProvider
        )
    }

    private var shouldScrollAPIProviders: Bool {
        self.apiEntryCount > self.visibleAPIEntryLimit
    }

    private var fullAPIProviderRows: [APIProviderListRow] {
        self.apiProviderRows(limit: nil)
    }

    private var visibleAPIProviderRows: [APIProviderListRow] {
        self.apiProviderRows(limit: self.visibleAPIEntryLimit)
    }

    private var availableCount: Int {
        store.accounts.filter { $0.usageStatus == .ok }.count
    }

    private var openAIAvailabilityBadgeTitle: String? {
        OpenAIAccountPresentation.headerAvailabilityBadgeTitle(
            availableCount: self.availableCount,
            totalCount: self.store.accounts.count
        )
    }

    private var visibleOpenRouterProvider: CodexPanelProvider? {
        guard let provider = store.openRouterProvider,
              provider.accounts.isEmpty == false else {
            return nil
        }
        return provider
    }

    private var isCompletelyEmpty: Bool {
        store.accounts.isEmpty &&
        store.customProviders.isEmpty &&
        self.visibleOpenRouterProvider == nil
    }

    var body: some View {
        mainMenuContent
        .frame(width: MenuBarStatusItemIdentity.popoverContentWidth)
        .onReceive(countdownTimer) { _ in
            now = Date()
            if isResetCreditsPanelPresented {
                showResetCreditsPanel()
            }
        }
        .onChange(of: self.resetCreditItems.map(\.id)) { _ in
            self.syncResetCreditsPanelAfterItemsChange()
        }
        .onReceive(runningThreadTimer) { _ in
            refreshRunningThreadAttribution()
        }
        .onReceive(store.$localCostSummary) { summary in
            self.recordMenuDiagnostic(
                type: "local_cost_summary_updated",
                fields: [
                    "updatedAt": summary.updatedAt as Any,
                    "todayCostUSD": summary.todayCostUSD,
                    "last30CostUSD": summary.last30DaysCostUSD,
                    "costPanelPresented": self.isCostPanelPresented,
                ]
            )
            guard isCostPanelPresented else { return }
            showCostPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidSucceed)) { _ in
            self.clearError()
            refreshRunningThreadAttribution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAILoginDidFail)) { notification in
            self.setGenericError(
                notification.userInfo?["message"] as? String ?? "OpenAI login failed."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexpanelStatusItemMenuWillOpen)) { _ in
            self.handleMenuPresentationOpened()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexpanelStatusItemMenuDidClose)) { _ in
            self.handleMenuPresentationClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexpanelStatusItemAvailableContentHeightDidChange)) { notification in
            self.statusItemAvailableContentHeight = notification.userInfo?["height"] as? CGFloat
        }
        .onChange(of: self.errorBanner) { _ in
            self.requestStatusItemLayoutRefresh()
        }
        .onChange(of: self.lastOpenAIManualSwitchResult) { _ in
            self.requestStatusItemLayoutRefresh()
        }
        .onChange(of: self.desktopInstanceBanner) { _ in
            self.requestStatusItemLayoutRefresh()
        }
    }

    private var mainMenuContent: some View {
        // 原生菜单宿主直接观察 SwiftUI 的自然尺寸；不要再异步测量并重设可见 HostingView。
        menuContentStack
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MenuBarMeasuredSizePreferenceKey.self, value: geometry.size)
                }
            }
            .onPreferenceChange(MenuBarMeasuredSizePreferenceKey.self) { size in
                guard MenuBarPopoverSizing.acceptsMeasuredContentWidth(size.width), size.height > 1 else { return }
                self.reportMeasuredMenuHeight(size.height, width: size.width)
            }
    }

    private var menuContentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.menuHeader

            NativeMenuBodyContainer(maxHeight: self.menuBodyMaximumHeight) {
                self.scrollableMenuBody
            }

            Divider()
                .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)

            self.menuFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 4)
        // 内容先完成布局，再由原生窗口跟随高度，避免旧窗口高度压缩标题和账号行。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var menuHeader: some View {
        HStack {
            Text("Codex Panel")
                .font(.system(size: 13, weight: .semibold))

            if let active = store.activeProvider {
                Text(active.label)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }

            Spacer()

            if let availability = self.updateCoordinator.pendingAvailability {
                Button {
                    Task { await self.updateCoordinator.handleToolbarAction() }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .foregroundColor(.accentColor)
                .help(L.menuUpdateAvailableTitle(availability.release.version))
                .accessibilityLabel(L.menuUpdateAction)
                .accessibilityIdentifier("codexpanel.update.toolbar")
                .disabled(self.updateCoordinator.isChecking)
            }

            Button {
                Task { await refresh(origin: .manual, announceResult: true) }
            } label: {
                Group {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(L.refreshUsage)
            .foregroundColor(isRefreshing ? .accentColor : .secondary)
            .disabled(isRefreshing)
        }
        .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var scrollableMenuBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)

            if isCompletelyEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(L.noAccounts)
                        .foregroundColor(.secondary)
                    Text("Add an OpenAI account, a custom provider, or OpenRouter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        CostSummaryRowView(
                            summary: store.localCostSummary,
                            currency: currency,
                            compactTokens: compactTokens
                        )
                    }
                    .background(
                        ViewReferenceReader { view in
                            resolveCostSummaryAnchor(view)
                        }
                    )
                    .onHover { hovering in
                        setCostSummaryHover(hovering)
                    }

                    openAIAccountsSection

                    providersSection
                }
                .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
                .padding(.vertical, 8)
            }

            if let banner = self.errorBanner {
                Divider()
                    .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
                HStack {
                    let isNotice = banner.source == .notice
                    Image(systemName: isNotice ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(isNotice ? .green : .yellow)
                    Text(banner.message)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        self.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
                .padding(.vertical, 8)
            }
        }
    }

    private var menuFooter: some View {
        HStack(spacing: 8) {
            if let lastUpdate = store.accounts.compactMap({ $0.lastChecked }).max() {
                Text(relativeTime(lastUpdate))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if let provider = store.activeProvider {
                Text(provider.hostLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Menu {
                Button(L.exportOpenAICSVAction) {
                    exportOpenAIAccountsCSV()
                }
                Button(L.importOpenAICSVAction) {
                    importOpenAIAccountsCSV()
                }
            } label: {
                Image(systemName: OpenAIAccountCSVToolbarUI.symbolName)
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L.openAICSVToolbar)
            .accessibilityIdentifier(OpenAIAccountCSVToolbarUI.accessibilityIdentifier)
            .help(L.openAICSVToolbar)

            Button {
                startOAuthLogin()
            } label: {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("login toolbar button")
            .accessibilityIdentifier("codexpanel.login-openai.toolbar")

            Button {
                openAddProviderWindow()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)

            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(L.settings)

            Button {
                switch L.languageOverride {
                case .none: L.languageOverride = true
                case .some(true): L.languageOverride = false
                case .some(false): L.languageOverride = nil
                }
                languageToggle.toggle()
            } label: {
                let label = languageToggle ? L.languageOverride : L.languageOverride
                Text(label == nil ? "AUTO" : (label == true ? "中" : "EN"))
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                AppLifecycleDiagnostics.shared.markTermination(reason: "quit_button")
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
        .padding(.vertical, 8)
    }

    private func openAIAvailabilityBadge(title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(availableCount > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
            .foregroundColor(availableCount > 0 ? .green : .red)
            .cornerRadius(4)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var openAIAccountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("OpenAI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let openAIAvailabilityBadgeTitle {
                    self.openAIAvailabilityBadge(title: openAIAvailabilityBadgeTitle)
                }

                Spacer(minLength: 8)

                Picker(
                    "",
                    selection: Binding(
                        get: { self.store.config.openAI.accountUsageMode },
                        set: { mode in
                            Task {
                                await self.setOpenAIAccountUsageMode(mode)
                            }
                        }
                    )
                ) {
                    ForEach(CodexPanelOpenAIAccountUsageMode.allCases) { mode in
                        Text(mode.menuToggleTitle)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("codexpanel.openai-mode-picker")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let manualSwitchBanner {
                self.openAIStatusBanner(
                    manualSwitchBanner,
                    onAction: {
                        guard let result = self.lastOpenAIManualSwitchResult else { return }
                        Task {
                            await self.applyManualSwitchRecommendation(result)
                        }
                    },
                    onDismiss: {
                        self.lastOpenAIManualSwitchResult = nil
                    }
                )
            }

            if let desktopInstanceBanner {
                self.openAIStatusBanner(
                    desktopInstanceBanner,
                    onDismiss: {
                        self.desktopInstanceBanner = nil
                    }
                )
            }

            if let resetCreditBanner {
                self.openAIStatusBanner(
                    resetCreditBanner,
                    onAction: {
                        if let soonest = RateLimitResetCreditPresentation.soonest(
                            from: self.store.accounts,
                            now: self.now
                        ) {
                            self.beginResetCreditConfirmation(soonest)
                        }
                    }
                )
            }

            if let pendingResetCredit {
                self.resetCreditConfirmation(pendingResetCredit)
            } else if self.resetCreditItems.isEmpty == false {
                self.resetCreditsSection(self.resetCreditItems)
            } else if self.resetCreditTotalAvailableCount > 0 {
                self.resetCreditsMissingDetailNotice(count: self.resetCreditTotalAvailableCount)
            }

            if let runtimeRouteBanner,
               let actionTitle = runtimeRouteBanner.actionTitle {
                HStack(spacing: 0) {
                    Spacer()

                    Button(actionTitle) {
                        self.clearStaleAggregateStickyIfNeeded()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(runtimeRouteBanner.tone == .warning ? .orange : .secondary)
                    .help(L.aggregateRuntimeClearStaleStickyHint)
                }
                .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
            }

            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No OpenAI account added.")
                        .font(.system(size: 11, weight: .medium))
                    Text("Use the toolbar plus button to add OpenAI OAuth accounts.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            } else {
                if self.shouldScrollOpenAIAccounts {
                    AdaptiveMenuScrollContainer(
                        initialHeight: openAIAccountsInitialHeight,
                        measuredHeight: {
                            openAIAccountGroupsView(visibleGroupedAccounts)
                        },
                        maxHeightCap: self.openAIAccountsHeightCap,
                        onMeasuredHeightChange: self.reportOpenAIAccountsMeasuredHeight
                    ) {
                        openAIAccountGroupsView(groupedAccounts)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    openAIAccountGroupsView(groupedAccounts)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var providersSection: some View {
        let openRouterProvider = self.visibleOpenRouterProvider
        let providerCount = store.customProviders.count + (openRouterProvider == nil ? 0 : 1)

        if providerCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isProvidersExpanded.toggle()
                    requestStatusItemLayoutRefresh()
                    DispatchQueue.main.async {
                        self.requestStatusItemLayoutRefresh()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Providers")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("\(providerCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isProvidersExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.12), value: isProvidersExpanded)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isProvidersExpanded {
                    if self.shouldScrollAPIProviders {
                        AdaptiveMenuScrollContainer(
                            initialHeight: self.apiProvidersInitialHeight,
                            measuredHeight: {
                                self.apiProviderRowsView(self.visibleAPIProviderRows)
                            },
                            maxHeightCap: self.apiProvidersHeightCap,
                            onMeasuredHeightChange: self.reportAPIProvidersMeasuredHeight
                        ) {
                            self.apiProviderRowsView(self.fullAPIProviderRows)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        self.apiProviderRowsView(self.fullAPIProviderRows)
                    }
                }
            }
        }
    }

    private func apiEntryCount(
        customProviders: [CodexPanelProvider],
        openRouterProvider: CodexPanelProvider?
    ) -> Int {
        customProviders.reduce(0) { count, provider in
            count + self.apiEntryCount(for: provider)
        } + (openRouterProvider.map { self.apiEntryCount(for: $0) } ?? 0)
    }

    private func apiEntryCount(for provider: CodexPanelProvider) -> Int {
        1 + provider.accounts.count
    }

    private func apiProviderRows(limit: Int?) -> [APIProviderListRow] {
        var remaining = limit ?? Int.max
        var rows: [APIProviderListRow] = []

        for provider in self.store.customProviders {
            guard remaining > 0 else { return rows }
            rows.append(self.apiProviderRow(for: provider, remaining: &remaining))
        }

        if let openRouterProvider = self.visibleOpenRouterProvider,
           remaining > 0 {
            rows.append(self.apiProviderRow(for: openRouterProvider, remaining: &remaining))
        }

        return rows
    }

    private func apiProviderRow(
        for provider: CodexPanelProvider,
        remaining: inout Int
    ) -> APIProviderListRow {
        remaining = max(remaining - 1, 0)
        let visibleAccounts = Array(provider.accounts.prefix(remaining))
        remaining = max(remaining - visibleAccounts.count, 0)
        return APIProviderListRow(provider: provider, visibleAccounts: visibleAccounts)
    }

    @ViewBuilder
    private func apiProviderRowsView(_ rows: [APIProviderListRow]) -> some View {
        ForEach(rows) { row in
            CompatibleProviderRowView(
                provider: row.provider,
                isActiveProvider: store.activeProvider?.id == row.provider.id,
                activeAccountId: row.provider.activeAccountId,
                visibleAccounts: row.visibleAccounts,
                onActivate: { account in
                    Task {
                        if row.provider.kind == .openRouter {
                            await activateOpenRouterProvider(accountID: account.id)
                        } else {
                            await activateCompatibleProvider(providerID: row.provider.id, accountID: account.id)
                        }
                    }
                },
                onAddAccount: { openAddProviderAccountWindow(provider: row.provider) },
                onDeleteAccount: { account in
                    if row.provider.kind == .openRouter {
                        deleteOpenRouterAccount(accountID: account.id)
                    } else {
                        deleteCompatibleAccount(providerID: row.provider.id, accountID: account.id)
                    }
                },
                onDeleteProvider: row.provider.kind == .openRouter ? nil : { deleteProvider(providerID: row.provider.id) }
            )
        }
    }

    @ViewBuilder
    private func openAIAccountGroupsView(_ groups: [OpenAIAccountGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    if let copyableEmail = OpenAIAccountPresentation.copyableAccountGroupEmail(group.email) {
                        Button {
                            self.copyOpenAIAccountGroupEmail(copyableEmail)
                        } label: {
                            self.openAIAccountGroupHeaderLabel(group)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    } else {
                        self.openAIAccountGroupHeaderLabel(group)
                    }

                    ForEach(group.accounts) { account in
                        let rowState = OpenAIAccountPresentation.rowState(
                            for: account,
                            summary: self.runningThreadSummary,
                            accountUsageMode: self.store.config.openAI.accountUsageMode
                        )
                        AccountRowView(
                            account: account,
                            rowState: rowState,
                            isRefreshing: refreshingAccounts.contains(account.id),
                            isLaunchingInstance: launchingInstanceAccountIDs.contains(account.accountId),
                            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                            defaultManualActivationBehavior: self.store.config.openAI.manualActivationBehavior
                        ) { trigger in
                            Task {
                                await activateAccount(
                                    account,
                                    trigger: trigger
                                )
                            }
                        } onLaunchInstance: {
                            Task { await launchDesktopInstance(account) }
                        } onRefresh: {
                            Task { await refreshAccount(account, announceResult: true) }
                        } onReauth: {
                            reauthAccount(account)
                        } onDelete: {
                            store.remove(account)
                        }
                    }
                }
            }
        }
    }

    private func openAIAccountGroupHeaderLabel(_ group: OpenAIAccountGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(group.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if let copiedConfirmation = OpenAIAccountPresentation.accountGroupCopyConfirmationText(
                groupEmail: group.email,
                copiedEmail: self.copiedOpenAIAccountGroupEmail
            ) {
                Text(copiedConfirmation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .lineLimit(1)
            } else if let remark = group.headerQuotaRemark(now: now) {
                Text(remark)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetCreditsSection(_ items: [RateLimitResetCreditItem]) -> some View {
        let collapsed = RateLimitResetCreditPresentation.collapsedItems(items)
        let canExpand = RateLimitResetCreditPresentation.canExpand(items)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L.resetCreditsSectionTitle)
                    .font(.system(size: 11, weight: .medium))
                Text(L.resetCreditCount(items.count))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if let soonest = items.first {
                    Button(L.resetCreditUseSoonest) {
                        self.beginResetCreditConfirmation(soonest)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(size: 10, weight: .medium))
                }
                if canExpand {
                    Button {
                        self.toggleResetCreditsPanelPinned()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.resetCreditShowAllHint)
                }
            }

            ForEach(collapsed) { item in
                ResetCreditItemRow(item: item, now: self.now) {
                    self.beginResetCreditConfirmation(item)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .background(
            ViewReferenceReader { view in
                self.resolveResetCreditsAnchor(view)
            }
        )
        .onHover { hovering in
            guard canExpand else { return }
            self.setResetCreditsHover(hovering)
        }
    }

    private func resetCreditsMissingDetailNotice(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
            Text(L.resetCreditMissingDetails(count))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func resetCreditConfirmation(_ item: RateLimitResetCreditItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.resetCreditConfirm)
                .font(.system(size: 11, weight: .medium))
            Text(
                RateLimitResetCreditPresentation.confirmMessage(
                    for: item,
                    now: self.now
                )
            )
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if item.hasMostlyUnusedWindows() {
                Text(L.resetCreditEmptyWindowWarning)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(L.resetCreditCancel) {
                    self.pendingResetCredit = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(self.isConsumingResetCredit)

                Button(L.resetCreditConfirm) {
                    Task { await self.consumeResetCredit(item) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(self.isConsumingResetCredit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func openAIStatusBanner(
        _ banner: OpenAIStatusBannerPresentation,
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        let accentColor: Color = banner.tone == .warning ? .orange : .accentColor
        let iconName = banner.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Text(banner.message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = banner.actionTitle,
                   let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                }
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accentColor.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func copyOpenAIAccountGroupEmail(_ email: String) {
        guard let copiedEmail = OpenAIAccountGroupEmailCopyAction.perform(email: email) else {
            return
        }

        self.copiedOpenAIAccountGroupEmail = copiedEmail
        self.pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        let hideWorkItem = DispatchWorkItem {
            self.copiedOpenAIAccountGroupEmail = nil
            self.pendingCopiedOpenAIAccountGroupEmailHide = nil
        }
        self.pendingCopiedOpenAIAccountGroupEmailHide = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWorkItem)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        return L.hoursAgo(seconds / 3600)
    }

    private func currency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func compactTokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.2fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }

    private func shortDay(_ date: Date) -> String {
        Self.shortDayFormatter.string(from: date)
    }

    private func reportMeasuredMenuHeight(_ height: CGFloat, width: CGFloat) {
        self.measuredMenuHeight = height
        NotificationCenter.default.post(
            name: .codexpanelStatusItemMeasuredHeightDidChange,
            object: nil,
            userInfo: [
                "height": height,
                "width": width,
            ]
        )
    }

    private func reportOpenAIAccountsMeasuredHeight(_ height: CGFloat) {
        self.openAIAccountsMeasuredHeight = height
    }

    private func reportAPIProvidersMeasuredHeight(_ height: CGFloat) {
        self.apiProvidersMeasuredHeight = height
    }

    private func requestStatusItemLayoutRefresh() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .codexpanelRequestStatusItemLayoutRefresh,
                object: nil
            )
        }
    }

    private func recordMenuDiagnostic(type: String, fields: [String: Any] = [:]) {
        AppLifecycleDiagnostics.shared.recordEvent(type: type, fields: fields)
    }

    private func resolveCostSummaryAnchor(_ view: NSView) {
        if self.costSummaryAnchorView !== view {
            self.costSummaryAnchorView = view
        }
        guard isCostPanelPresented else { return }
        showCostPanel()
    }

    private func setCostSummaryHover(_ hovering: Bool) {
        isCostSummaryHovered = hovering
        self.recordMenuDiagnostic(
            type: "cost_summary_hover_changed",
            fields: [
                "hovering": hovering,
                "costPanelPresented": self.isCostPanelPresented,
                "costPanelHovered": self.isCostPanelHovered,
            ]
        )
        if hovering {
            presentCostPanel()
        } else {
            scheduleCostPanelHideIfNeeded()
        }
    }

    private func setCostPanelHover(_ hovering: Bool) {
        isCostPanelHovered = hovering
        self.recordMenuDiagnostic(
            type: "cost_panel_hover_changed",
            fields: [
                "hovering": hovering,
                "costPanelPresented": self.isCostPanelPresented,
                "costSummaryHovered": self.isCostSummaryHovered,
            ]
        )
        if hovering {
            presentCostPanel()
        } else {
            scheduleCostPanelHideIfNeeded()
        }
    }

    private func presentCostPanel() {
        pendingCostHide?.cancel()
        pendingCostHide = nil
        isCostPanelPresented = true
        self.recordMenuDiagnostic(
            type: "cost_panel_present_requested",
            fields: [
                "costSummaryHovered": self.isCostSummaryHovered,
                "costPanelHovered": self.isCostPanelHovered,
            ]
        )
        showCostPanel()
    }

    private func scheduleCostPanelHideIfNeeded() {
        pendingCostHide?.cancel()
        self.recordMenuDiagnostic(
            type: "cost_panel_hide_scheduled",
            fields: [
                "costSummaryHovered": self.isCostSummaryHovered,
                "costPanelHovered": self.isCostPanelHovered,
            ]
        )
        let work = DispatchWorkItem {
            if !isCostSummaryHovered && !isCostPanelHovered {
                isCostPanelPresented = false
                self.recordMenuDiagnostic(type: "cost_panel_closed_after_delay")
                DetachedWindowPresenter.shared.close(id: costPanelID)
            }
        }
        pendingCostHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func showCostPanel() {
        guard let anchorView = costSummaryAnchorView,
              anchorView.window != nil else { return }

        let panelSize = CGSize(
            width: CostDetailsPanelView.panelWidth,
            height: CostDetailsPanelView.panelHeight(hasHistory: !store.localCostSummary.dailyEntries.isEmpty)
        )
        DetachedWindowPresenter.shared.showHoverPopover(
            id: costPanelID,
            size: panelSize,
            anchorView: anchorView
        ) {
            CostDetailsPanelView(
                summary: store.localCostSummary,
                currency: currency,
                compactTokens: compactTokens,
                shortDay: shortDay
            )
            .onHover { hovering in
                setCostPanelHover(hovering)
            }
        }
    }

    private func beginResetCreditConfirmation(_ item: RateLimitResetCreditItem) {
        self.closeResetCreditsPanel()
        self.pendingResetCredit = item
    }

    private func resolveResetCreditsAnchor(_ view: NSView) {
        if self.resetCreditsAnchorView !== view {
            self.resetCreditsAnchorView = view
        }
        guard self.isResetCreditsPanelPresented else { return }
        self.showResetCreditsPanel()
    }

    private func setResetCreditsHover(_ hovering: Bool) {
        self.isResetCreditsHovered = hovering
        if hovering {
            self.presentResetCreditsPanel()
        } else {
            self.scheduleResetCreditsPanelHideIfNeeded()
        }
    }

    private func setResetCreditsPanelHover(_ hovering: Bool) {
        self.isResetCreditsPanelHovered = hovering
        if hovering {
            self.presentResetCreditsPanel()
        } else {
            self.scheduleResetCreditsPanelHideIfNeeded()
        }
    }

    private func toggleResetCreditsPanelPinned() {
        if self.isResetCreditsPanelPinned {
            self.isResetCreditsPanelPinned = false
            if self.isResetCreditsHovered == false && self.isResetCreditsPanelHovered == false {
                self.closeResetCreditsPanel()
            }
            return
        }
        self.isResetCreditsPanelPinned = true
        self.presentResetCreditsPanel()
    }

    private func presentResetCreditsPanel() {
        guard RateLimitResetCreditPresentation.canExpand(self.resetCreditItems) else {
            self.closeResetCreditsPanel()
            return
        }
        self.pendingResetCreditsHide?.cancel()
        self.pendingResetCreditsHide = nil
        self.isResetCreditsPanelPresented = true
        self.showResetCreditsPanel()
    }

    private func scheduleResetCreditsPanelHideIfNeeded() {
        guard self.isResetCreditsPanelPinned == false else { return }
        self.pendingResetCreditsHide?.cancel()
        let work = DispatchWorkItem {
            if self.isResetCreditsPanelPinned == false,
               self.isResetCreditsHovered == false,
               self.isResetCreditsPanelHovered == false {
                self.closeResetCreditsPanel()
            }
        }
        self.pendingResetCreditsHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func closeResetCreditsPanel() {
        self.pendingResetCreditsHide?.cancel()
        self.pendingResetCreditsHide = nil
        self.isResetCreditsPanelPresented = false
        self.isResetCreditsHovered = false
        self.isResetCreditsPanelHovered = false
        self.isResetCreditsPanelPinned = false
        DetachedWindowPresenter.shared.close(id: self.resetCreditsPanelID)
    }

    private func syncResetCreditsPanelAfterItemsChange() {
        guard self.isResetCreditsPanelPresented else { return }
        if RateLimitResetCreditPresentation.canExpand(self.resetCreditItems) {
            self.showResetCreditsPanel()
        } else {
            self.closeResetCreditsPanel()
        }
    }

    private func showResetCreditsPanel() {
        guard self.isResetCreditsPanelPresented,
              RateLimitResetCreditPresentation.canExpand(self.resetCreditItems),
              let anchorView = self.resetCreditsAnchorView,
              anchorView.window != nil else { return }

        let items = self.resetCreditItems
        let panelSize = CGSize(
            width: ResetCreditsPanelView.panelWidth,
            height: ResetCreditsPanelView.panelHeight(itemCount: items.count)
        )
        DetachedWindowPresenter.shared.showHoverPopover(
            id: self.resetCreditsPanelID,
            size: panelSize,
            anchorView: anchorView
        ) {
            ResetCreditsPanelView(
                items: items,
                now: self.now,
                onUse: { item in
                    self.beginResetCreditConfirmation(item)
                }
            )
            .onHover { hovering in
                self.setResetCreditsPanelHover(hovering)
            }
        }
    }

    private func activateAccount(
        _ account: TokenAccount,
        trigger: OpenAIManualActivationTrigger = .primaryTap
    ) async {
        do {
            let result = try await OpenAIManualActivationExecutor.execute(
                targetAccountID: account.accountId,
                targetMode: .switchAccount,
                configuredBehavior: self.store.config.openAI.manualActivationBehavior,
                trigger: trigger
            ) {
                try self.store.activate(
                    account,
                    reason: .manual,
                    automatic: false,
                    forced: false,
                    protectedByManualGrace: false
                )
            } launchNewInstance: {
                try self.store.activate(
                    account,
                    reason: .manual,
                    automatic: false,
                    forced: false,
                    protectedByManualGrace: false
                )
            }

            self.lastOpenAIManualSwitchResult = result
            self.refreshRunningThreadAttribution()
            self.clearError()
            Task { @MainActor in
                OpenAIUsagePollingService.shared.refreshNow()
            }
        } catch {
            self.lastOpenAIManualSwitchResult = nil
            self.setGenericError(error.localizedDescription)
        }
    }

    private func launchDesktopInstance(_ account: TokenAccount) async {
        guard self.launchingInstanceAccountIDs.contains(account.accountId) == false else { return }
        self.launchingInstanceAccountIDs.insert(account.accountId)
        defer { self.launchingInstanceAccountIDs.remove(account.accountId) }

        do {
            // 目标账号就是当前激活账号 → 共享 ~/.codex（实时同步 + 原生线程写锁互斥）；
            // 换账号 → 克隆快照并替换凭据。
            let mode: CodexDesktopInstanceMode = account.isActive ? .sharedHome : .clonedHome
            let record = try await CodexDesktopInstanceService.shared.launchInstance(
                for: account,
                mode: mode
            )
            let detail = record.mode == .sharedHome
                ? L.desktopInstanceLaunchedSharedDetail(record.accountLabel, Int(record.pid))
                : L.desktopInstanceLaunchedDetail(record.accountLabel, Int(record.pid))
            self.desktopInstanceBanner = OpenAIStatusBannerPresentation(
                title: L.desktopInstanceLaunchedTitle,
                message: detail,
                actionTitle: nil,
                tone: .info
            )
            self.clearError()
        } catch {
            self.desktopInstanceBanner = OpenAIStatusBannerPresentation(
                title: L.desktopInstanceLaunchFailedTitle,
                message: error.localizedDescription,
                actionTitle: nil,
                tone: .warning
            )
        }
    }

    private func activateCompatibleProvider(providerID: String, accountID: String) async {
        let previousActiveProviderID = self.store.config.active.providerId
        let previousActiveAccountID = self.store.config.active.accountId

        do {
            try await CompatibleProviderUseExecutor.execute(
                configuredBehavior: self.store.config.openAI.manualActivationBehavior
            ) {
                try self.store.activateCustomProvider(
                    providerID: providerID,
                    accountID: accountID
                )
            } restorePreviousSelection: {
                try self.store.restoreActiveSelection(
                    activeProviderID: previousActiveProviderID,
                    activeAccountID: previousActiveAccountID
                )
            } launchNewInstance: {
                try self.store.activateCustomProvider(
                    providerID: providerID,
                    accountID: accountID
                )
            }

            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func activateOpenRouterProvider(accountID: String) async {
        let previousActiveProviderID = self.store.config.active.providerId
        let previousActiveAccountID = self.store.config.active.accountId

        do {
            try await CompatibleProviderUseExecutor.execute(
                configuredBehavior: self.store.config.openAI.manualActivationBehavior
            ) {
                try self.store.activateOpenRouterProvider(accountID: accountID)
            } restorePreviousSelection: {
                try self.store.restoreActiveSelection(
                    activeProviderID: previousActiveProviderID,
                    activeAccountID: previousActiveAccountID
                )
            } launchNewInstance: {
                try self.store.activateOpenRouterProvider(accountID: accountID)
            }

            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func setOpenAIAccountUsageMode(_ mode: CodexPanelOpenAIAccountUsageMode) async {
        let previousMode = self.store.config.openAI.accountUsageMode
        let previousActiveProviderID = self.store.config.active.providerId
        let previousActiveAccountID = self.store.config.active.accountId

        do {
            _ = try await OpenAIAccountUsageModeTransitionExecutor.execute(
                configuredBehavior: self.store.config.openAI.manualActivationBehavior,
                targetMode: mode,
                currentMode: previousMode,
                applyMode: {
                    try self.store.updateOpenAIAccountUsageMode(mode)
                },
                rollbackMode: {
                    try self.store.restoreOpenAIAccountUsageMode(
                        previousMode,
                        activeProviderID: previousActiveProviderID,
                        activeAccountID: previousActiveAccountID
                    )
                },
                launchNewInstance: {
                    try self.store.updateOpenAIAccountUsageMode(mode)
                }
            )
            self.lastOpenAIManualSwitchResult = nil
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func applyManualSwitchRecommendation(
        _ result: OpenAIManualSwitchResult
    ) async {
        _ = result
    }

    private func clearStaleAggregateStickyIfNeeded() {
        let snapshot = self.openAIRuntimeRouteSnapshot
        guard self.store.clearStaleAggregateSticky(using: snapshot) else { return }
        self.clearError()
        self.refreshRunningThreadAttribution()
    }

    private func deleteCompatibleAccount(providerID: String, accountID: String) {
        do {
            try store.removeCustomProviderAccount(providerID: providerID, accountID: accountID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func deleteProvider(providerID: String) {
        do {
            try store.removeCustomProvider(providerID: providerID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func deleteOpenRouterAccount(accountID: String) {
        do {
            try store.removeOpenRouterProviderAccount(accountID: accountID)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func startOAuthLogin() {
        CodexPanelUICommandRouter.shared.openLogin()
    }

    private func exportOpenAIAccountsCSV() {
        do {
            let snapshot = try self.oauthAccountService.exportAccountsForInterchange()
            guard snapshot.accounts.isEmpty == false else {
                self.setGenericError(L.noOpenAIAccountsToExport)
                return
            }

            guard let exportURL = self.openAIAccountCSVPanelService.requestExportURL() else {
                return
            }

            let exportText = try self.openAIAccountCSVService.makeCSV(
                from: snapshot.accounts,
                metadataByAccountID: snapshot.metadataByAccountID,
                proxiesJSON: snapshot.proxiesJSON
            )
            try exportText.write(to: exportURL, atomically: true, encoding: .utf8)
            self.clearError()
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func importOpenAIAccountsCSV() {
        do {
            guard let importURL = self.openAIAccountCSVPanelService.requestImportURL() else {
                return
            }

            let importText = try String(contentsOf: importURL, encoding: .utf8)
            let parsed = try self.openAIAccountCSVService.parseCSV(importText)
            let result = try self.oauthAccountService.importAccounts(
                parsed.accounts,
                activeAccountID: parsed.activeAccountID,
                interopContext: parsed.interopContext
            )

            self.store.load()
            self.refreshRunningThreadAttribution()
            self.clearError()
            self.refreshImportedAccounts(accountIDs: result.importedAccountIDs)
        } catch {
            self.setGenericError(error.localizedDescription)
        }
    }

    private func openSettingsWindow() {
        CodexPanelUICommandRouter.shared.openSettings()
    }

    private func openAddProviderWindow(defaultPreset: AddProviderPreset = .preset) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider",
            title: "Add Provider",
            size: CGSize(width: 520, height: 420)
        ) {
            AddProviderSheet(defaultPreset: defaultPreset) { result in
                do {
                    if result.isOpenRouter {
                        try store.addOpenRouterProvider(accountLabel: result.accountLabel, apiKey: result.apiKey)
                    } else {
                        try store.addCompatibleProvider(
                            label: result.label, baseURL: result.baseURL,
                            accountLabel: result.accountLabel, apiKey: result.apiKey,
                            wireAPI: result.wireAPI, presetID: result.presetID
                        )
                    }
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider")
            }
        }
    }

    private func openAddProviderAccountWindow(provider: CodexPanelProvider) {
        self.requestCloseStatusItemMenu()
        DetachedWindowPresenter.shared.show(
            id: "add-provider-account-\(provider.id)",
            title: "Add Account",
            size: CGSize(width: 400, height: 220)
        ) {
            AddProviderAccountSheet(provider: provider) { label, apiKey in
                do {
                    if provider.kind == .openRouter {
                        try store.addOpenRouterProviderAccount(label: label, apiKey: apiKey)
                    } else {
                        try store.addCustomProviderAccount(providerID: provider.id, label: label, apiKey: apiKey)
                    }
                    self.clearError()
                    DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
                } catch {
                    self.setGenericError(error.localizedDescription)
                }
            } onCancel: {
                DetachedWindowPresenter.shared.close(id: "add-provider-account-\(provider.id)")
            }
        }
    }

    private func handleMenuPresentationOpened() {
        countdownTimerConnection?.cancel()
        countdownTimerConnection = countdownTimer.connect()
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = runningThreadTimer.connect()
        store.load()
        store.markActiveAccount()
        isProvidersExpanded = false
        refreshRunningThreadAttribution()
        self.recordMenuDiagnostic(
            type: "status_item_menu_opened_view_ready",
            fields: ["activeProviderKind": store.activeProvider?.kind.rawValue as Any]
        )
        triggerRefreshOnOpenIfNeeded()
    }

    private func handleMenuPresentationClosed() {
        self.recordMenuDiagnostic(
            type: "status_item_menu_view_closed",
            fields: [
                "costPanelPresented": self.isCostPanelPresented,
                "costSummaryHovered": self.isCostSummaryHovered,
                "costPanelHovered": self.isCostPanelHovered,
            ]
        )
        runningThreadRefreshController.reset()
        countdownTimerConnection?.cancel()
        countdownTimerConnection = nil
        runningThreadTimerConnection?.cancel()
        runningThreadTimerConnection = nil
        openRefreshGate.resetForClose()
        pendingCostHide?.cancel()
        pendingCostHide = nil
        pendingResetCreditsHide?.cancel()
        pendingResetCreditsHide = nil
        pendingCopiedOpenAIAccountGroupEmailHide?.cancel()
        pendingCopiedOpenAIAccountGroupEmailHide = nil
        copiedOpenAIAccountGroupEmail = nil
        isCostPanelPresented = false
        isCostSummaryHovered = false
        isCostPanelHovered = false
        isResetCreditsPanelPresented = false
        isResetCreditsHovered = false
        isResetCreditsPanelHovered = false
        isResetCreditsPanelPinned = false
        pendingResetCredit = nil
        isConsumingResetCredit = false
        DetachedWindowPresenter.shared.close(id: costPanelID)
        DetachedWindowPresenter.shared.close(id: resetCreditsPanelID)
    }

    private func triggerRefreshOnOpenIfNeeded() {
        let shouldTrigger = openRefreshGate.shouldTriggerRefresh(isRefreshing: isRefreshing)
        self.recordMenuDiagnostic(
            type: "refresh_on_open_gate_evaluated",
            fields: [
                "shouldTrigger": shouldTrigger,
                "isRefreshing": isRefreshing,
            ]
        )
        guard shouldTrigger else { return }
        Task { await refreshOnOpen() }
    }

    private func refreshOnOpen() async {
        self.recordMenuDiagnostic(
            type: "refresh_on_open_started",
            fields: ["activeProviderKind": store.activeProvider?.kind.rawValue as Any]
        )
        now = Date()
        store.refreshLocalCostSummary(
            force: true,
            minimumInterval: 0,
            refreshSessionCache: false
        )
        refreshRunningThreadAttribution()

        guard store.activeProvider?.kind == .openAIOAuth else { return }

        let activeAccount = store.activeAccount()
        if let activeAccount,
           activeAccount.isSuspended == false,
           activeAccount.tokenExpired == false {
            isRefreshing = true
            refreshingAccounts.insert(activeAccount.id)
            defer {
                refreshingAccounts.remove(activeAccount.id)
                isRefreshing = false
            }

            let outcome = await WhamService.shared.refreshOne(account: activeAccount, store: store)
            store.load()
            now = Date()
            refreshRunningThreadAttribution()
            self.applyRefreshFeedback(
                announceResult: false,
                message: self.refreshFailureMessage(for: activeAccount, outcome: outcome)
            )
            self.recordMenuDiagnostic(
                type: "refresh_on_open_active_account_finished",
                fields: [
                    "accountID": activeAccount.id,
                    "outcome": String(describing: outcome),
                ]
            )
        }

        self.scheduleBackgroundUsageBackfill(excluding: activeAccount?.id)
        self.recordMenuDiagnostic(type: "refresh_on_open_finished")
    }

    private func refresh(
        origin: MenuBarRefreshOrigin,
        force: Bool = true,
        announceResult: Bool = false
    ) async {
        let shouldRefreshOAuth = force || store.hasStaleOAuthUsageSnapshot(maxAge: usageRefreshInterval)
        let shouldRefreshLocalCost = force || store.localCostSummary.updatedAt == nil

        guard shouldRefreshOAuth || shouldRefreshLocalCost else {
            return
        }

        var didRequestLocalCostRefresh = false
        if shouldRefreshLocalCost {
            now = Date()
            didRequestLocalCostRefresh = true
            store.refreshLocalCostSummary(
                force: true,
                minimumInterval: 0,
                refreshSessionCache: origin.refreshesSessionCache
            )
            refreshRunningThreadAttribution()
        }

        if shouldRefreshOAuth == false {
            return
        }

        guard store.beginAllUsageRefresh() else { return }
        isRefreshing = true
        defer {
            store.endAllUsageRefresh()
            isRefreshing = false
        }
        let outcomes = await WhamService.shared.refreshAll(store: store)
        store.load()
        now = Date()
        if didRequestLocalCostRefresh == false {
            store.refreshLocalCostSummary(
                force: true,
                minimumInterval: usageRefreshInterval,
                refreshSessionCache: origin.refreshesSessionCache
            )
        }
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(from: outcomes)
        )
    }

    private func refreshAccount(_ account: TokenAccount, announceResult: Bool) async {
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }
        let outcome = await self.refreshOneRetryingIfSkipped(account)
        store.load()
        now = Date()
        refreshRunningThreadAttribution()
        self.applyRefreshFeedback(
            announceResult: announceResult,
            message: self.refreshFailureMessage(for: account, outcome: outcome)
        )
    }

    private func consumeResetCredit(_ item: RateLimitResetCreditItem) async {
        guard let account = self.store.oauthAccount(accountID: item.accountId) else {
            self.pendingResetCredit = nil
            return
        }

        self.isConsumingResetCredit = true
        defer { self.isConsumingResetCredit = false }

        do {
            let result = try await WhamService.shared.consumeResetCredit(
                account: account,
                creditId: item.creditId
            )
            switch result.code {
            case .reset:
                self.pendingResetCredit = nil
                self.setNotice(L.resetCreditUsed(result.windowsReset))
                await self.refreshAccount(account, announceResult: true)
            case .alreadyRedeemed:
                self.pendingResetCredit = nil
                self.setNotice(L.resetCreditAlreadyRedeemed)
                await self.refreshAccount(account, announceResult: true)
            case .nothingToReset:
                self.setGenericError(L.resetCreditNothingToReset)
            case .noCredit:
                self.pendingResetCredit = nil
                await self.refreshAccount(account, announceResult: false)
                self.setGenericError(L.resetCreditNoCredit)
            case .unknown:
                self.setGenericError(L.resetCreditConsumeFailed)
            }
        } catch {
            self.setGenericError(L.resetCreditConsumeFailed)
        }
    }

    private func refreshOneRetryingIfSkipped(
        _ account: TokenAccount,
        maxAttempts: Int = 5,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) async -> WhamRefreshOutcome {
        var attempt = 0
        while true {
            let currentAccount = self.store.oauthAccount(accountID: account.accountId) ?? account
            let outcome = await WhamService.shared.refreshOne(account: currentAccount, store: self.store)
            guard outcome == .skipped else { return outcome }
            attempt += 1
            guard attempt < maxAttempts else { return outcome }
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }

    private func scheduleBackgroundUsageBackfill(excluding accountID: String?) {
        let maxAge = self.usageRefreshInterval
        let now = Date()
        let candidates = self.store.accounts
            .filter { account in
                account.id != accountID &&
                account.isSuspended == false &&
                account.tokenExpired == false &&
                account.isUsageSnapshotStale(maxAge: maxAge, now: now)
            }
            .sorted { lhs, rhs in
                (lhs.usageSnapshotAge(now: now) ?? .infinity) > (rhs.usageSnapshotAge(now: now) ?? .infinity)
            }

        guard candidates.isEmpty == false else { return }

        self.usageBackfillTask?.cancel()
        let stepSleep = UInt64(max(self.backgroundUsageBackfillStepInterval, 0) * 1_000_000_000)
        self.usageBackfillTask = Task {
            for (index, account) in candidates.enumerated() {
                if Task.isCancelled { return }
                if index > 0 && stepSleep > 0 {
                    do {
                        try await Task.sleep(nanoseconds: stepSleep)
                    } catch {
                        return
                    }
                }

                _ = await WhamService.shared.refreshOne(account: account, store: self.store)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.store.load()
                    self.now = Date()
                    self.refreshRunningThreadAttribution()
                }
            }
        }
    }

    private func reauthAccount(_: TokenAccount) {
        self.startOAuthLogin()
    }

    private func requestCloseStatusItemMenu() {
        NotificationCenter.default.post(name: .codexpanelRequestCloseStatusItemMenu, object: nil)
    }

    private func refreshFailureMessage(from outcomes: [WhamRefreshOutcome]) -> String? {
        let failures = outcomes.compactMap(\.errorMessage)
        guard failures.isEmpty == false else { return nil }
        if outcomes.contains(.updated) || outcomes.contains(.skipped) {
            return failures.first
        }
        return failures.first ?? "Refresh failed."
    }

    private func refreshFailureMessage(for account: TokenAccount, outcome: WhamRefreshOutcome) -> String? {
        guard let message = outcome.errorMessage else { return nil }
        let label = account.displayIdentifier
        return "\(label): \(message)"
    }

    private func clearError() {
        self.errorBanner = nil
    }

    private func setGenericError(_ message: String?) {
        guard let message else {
            self.clearError()
            return
        }
        self.errorBanner = MenuBarErrorBannerState(message: message, source: .generic)
    }

    private func setNotice(_ message: String?) {
        guard let message else {
            self.clearError()
            return
        }
        self.errorBanner = MenuBarErrorBannerState(message: message, source: .notice)
    }

    private func applyRefreshFeedback(announceResult: Bool, message: String?) {
        self.errorBanner = MenuBarRefreshErrorResolver.nextBanner(
            current: self.errorBanner,
            announceResult: announceResult,
            refreshMessage: message
        )
    }

    private func refreshImportedAccounts(accountIDs: [String]) {
        let importedAccountIDs = Set(accountIDs)
        guard importedAccountIDs.isEmpty == false else { return }

        let importedAccounts = self.store.accounts.filter { importedAccountIDs.contains($0.accountId) }
        guard importedAccounts.isEmpty == false else { return }

        Task {
            await withTaskGroup(of: Void.self) { group in
                for account in importedAccounts {
                    group.addTask {
                        _ = await WhamService.shared.refreshOne(account: account, store: self.store)
                    }
                }
            }
        }
    }

    private func switchAccountAndLaunchNewInstance(
        _ account: TokenAccount,
        reason: AutoRoutingSwitchReason,
        automatic: Bool,
        forced: Bool
    ) async throws {
        let previousActiveAccount = self.store.activeAccount()

        do {
            try self.store.activate(
                account,
                reason: reason,
                automatic: automatic,
                forced: forced,
                protectedByManualGrace: false
            )

            _ = try await CodexDesktopInstanceService.shared.launchInstance(
                for: account,
                mode: .sharedHome
            )
        } catch {
            if let previousActiveAccount,
               previousActiveAccount.accountId != account.accountId {
                try? self.store.activate(previousActiveAccount)
            }
            throw error
        }
    }

    private func refreshRunningThreadAttribution() {
        let now = Date()
        let service = self.runningThreadAttributionService

        self.runningThreadRefreshController.requestRefresh(now: now) { refreshDate in
            service.load(now: refreshDate)
        } apply: { attribution in
            self.runningThreadAttribution = attribution
        }
    }
}

private enum AddProviderPreset: String, CaseIterable, Identifiable {
    case preset
    case custom

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .preset:
            return L.addProviderPresetTab
        case .custom:
            return "Custom"
        }
    }
}

private struct AddProviderResult {
    let label: String
    let baseURL: String
    let accountLabel: String
    let apiKey: String
    let wireAPI: CodexPanelWireAPI
    let presetID: String?
    let isOpenRouter: Bool
}

private struct AddProviderSheet: View {
    @State private var preset: AddProviderPreset
    @State private var label = ""
    @State private var baseURL = ""
    @State private var accountLabel = ""
    @State private var apiKey = ""
    @State private var customWireAPI: CodexPanelWireAPI = .chat
    @State private var selectedPresetID: String

    let onSave: (AddProviderResult) -> Void
    let onCancel: () -> Void

    init(
        defaultPreset: AddProviderPreset = .preset,
        onSave: @escaping (AddProviderResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._preset = State(initialValue: defaultPreset)
        self.onSave = onSave
        self.onCancel = onCancel
        let firstPreset = CodexPanelProviderPresetCatalog.all.first
        self._selectedPresetID = State(initialValue: firstPreset?.id ?? "")
    }

    private var selectedPreset: CodexPanelProviderPreset? {
        CodexPanelProviderPresetCatalog.preset(id: self.selectedPresetID)
    }

    private var canSave: Bool {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return false }

        switch self.preset {
        case .preset:
            return self.selectedPreset != nil
        case .custom:
            return self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Provider")
                .font(.headline)

            Picker("Preset", selection: $preset) {
                ForEach(AddProviderPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            switch preset {
            case .preset:
                presetSection
            case .custom:
                customSection
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(self.makeResult())
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: self.preset == .custom ? 380 : 460)
    }

    @ViewBuilder private var presetSection: some View {
        Picker(L.addProviderPresetVendor, selection: $selectedPresetID) {
            ForEach(CodexPanelProviderPresetGroup.allCases) { group in
                Section(group.title) {
                    ForEach(CodexPanelProviderPresetCatalog.all.filter { $0.group == group }) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
            }
        }

        TextField("Account label", text: $accountLabel)
        SecureField("API key", text: $apiKey)

        if let note = selectedPreset?.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var customSection: some View {
        TextField("Provider name", text: $label)
        TextField("Base URL", text: $baseURL)
        Picker(L.addProviderWireAPI, selection: $customWireAPI) {
            ForEach(CodexPanelWireAPI.allCases) { wire in
                Text(wire.title).tag(wire)
            }
        }
        .pickerStyle(.segmented)
        if customWireAPI == .chat {
            Text(L.addProviderWireAPIChatHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        TextField("Account label", text: $accountLabel)
        SecureField("API key", text: $apiKey)
    }

    private func makeResult() -> AddProviderResult {
        switch preset {
        case .preset:
            let selected = self.selectedPreset
            if selected?.kind == .openRouter {
                return AddProviderResult(
                    label: "OpenRouter",
                    baseURL: "",
                    accountLabel: accountLabel,
                    apiKey: apiKey,
                    wireAPI: .responses,
                    presetID: selected?.id,
                    isOpenRouter: true
                )
            }
            return AddProviderResult(
                label: selected?.displayName ?? self.selectedPresetID,
                baseURL: selected?.baseURL ?? "",
                accountLabel: accountLabel,
                apiKey: apiKey,
                wireAPI: selected?.wireAPI ?? .chat,
                presetID: selected?.id,
                isOpenRouter: false
            )
        case .custom:
            return AddProviderResult(
                label: label,
                baseURL: baseURL,
                accountLabel: accountLabel,
                apiKey: apiKey,
                wireAPI: customWireAPI,
                presetID: nil,
                isOpenRouter: false
            )
        }
    }
}

private struct AddProviderAccountSheet: View {
    let provider: CodexPanelProvider
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var label = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account · \(provider.label)")
                .font(.headline)

            TextField("Account label", text: $label)
            SecureField("API key", text: $apiKey)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(label, apiKey)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
