import AppKit
import Carbon
import Combine
import SwiftUI

extension Notification.Name {
    static let codexpanelRequestCloseStatusItemMenu = Notification.Name("com.codexpanel.status-item-menu.close")
    static let codexpanelStatusItemMeasuredHeightDidChange = Notification.Name("com.codexpanel.status-item-menu.height-changed")
    static let codexpanelStatusItemAvailableContentHeightDidChange = Notification.Name("com.codexpanel.status-item-menu.available-content-height-changed")
    static let codexpanelRequestStatusItemLayoutRefresh = Notification.Name("com.codexpanel.status-item-menu.layout-refresh")
    static let codexpanelStatusItemMenuWillOpen = Notification.Name("com.codexpanel.status-item-menu.will-open")
    static let codexpanelStatusItemMenuDidClose = Notification.Name("com.codexpanel.status-item-menu.did-close")
}

private struct MenuBarGlobalShortcut {
    let keyCode: UInt32
    let modifiers: UInt32
    let identifier: UInt32

    static let signature: OSType = 0x43444252

    static let primary = Self(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        identifier: 1
    )

    #if DEBUG
    static let debugAlternate = Self(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        identifier: 2
    )
    #endif

    static var all: [Self] {
        var shortcuts = [Self.primary]
        #if DEBUG
        shortcuts.append(.debugAlternate)
        #endif
        return shortcuts
    }
}

enum MenuBarPopoverClosePolicy {
    private static let protectedFrameHitInset: CGFloat = 2

    static func shouldClosePopover(
        mouseLocation: CGPoint,
        protectedWindowFrames: [CGRect]
    ) -> Bool {
        protectedWindowFrames
            .map { $0.insetBy(dx: -self.protectedFrameHitInset, dy: -self.protectedFrameHitInset) }
            .allSatisfy { $0.contains(mouseLocation) == false }
    }
}

enum MenuBarPopoverSizing {
    private static let legacyDefaultHeight: CGFloat = 520
    static let minimumHeight: CGFloat = 1
    private static let legacyMaximumHeight: CGFloat = 640
    private static let measuredContentWidthTolerance: CGFloat = 1
    static let sectionHorizontalInset: CGFloat = 8
    static let sectionVerticalInset: CGFloat = 12
    static let verticalMargin: CGFloat = 12
    private static let legacyTopContentInset: CGFloat = 6
    private static let legacyBottomContentInset: CGFloat = 6
    private static let macOS15TopContentInset: CGFloat = 8
    private static let macOS15BottomContentInset: CGFloat = 8

    static var defaultHeight: CGFloat {
        self.defaultHeight(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static var maximumHeight: CGFloat {
        self.maximumHeight(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static var topContentInset: CGFloat {
        self.contentInsets(for: ProcessInfo.processInfo.operatingSystemVersion).top
    }

    static var bottomContentInset: CGFloat {
        self.contentInsets(for: ProcessInfo.processInfo.operatingSystemVersion).bottom
    }

    static var horizontalContentInset: CGFloat {
        self.topContentInset
    }

    static func clampedHeight(desiredHeight: CGFloat, availableHeight: CGFloat?) -> CGFloat {
        self.clampedHeight(
            desiredHeight: desiredHeight,
            availableHeight: availableHeight,
            version: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    static func clampedHeight(
        desiredHeight: CGFloat,
        availableHeight: CGFloat?,
        version: OperatingSystemVersion
    ) -> CGFloat {
        let maxHeight = max(self.minimumHeight, availableHeight ?? self.maximumHeight(for: version))
        return min(max(desiredHeight, self.minimumHeight), maxHeight)
    }

    static func initialSize(availableHeight: CGFloat?) -> NSSize {
        self.initialSize(
            availableHeight: availableHeight,
            version: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    static func initialSize(
        availableHeight: CGFloat?,
        version: OperatingSystemVersion
    ) -> NSSize {
        NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: self.clampedHeight(
                desiredHeight: self.defaultHeight(for: version),
                availableHeight: availableHeight,
                version: version
            )
        )
    }

    static func acceptsMeasuredContentWidth(_ width: CGFloat) -> Bool {
        abs(width - MenuBarStatusItemIdentity.popoverContentWidth) <= self.measuredContentWidthTolerance
    }

    static func flexibleSectionHeightCap(
        totalContentHeight: CGFloat,
        flexibleSectionHeight: CGFloat,
        availableHeight: CGFloat?
    ) -> CGFloat? {
        guard let availableHeight,
              totalContentHeight > 0,
              flexibleSectionHeight > 0 else {
            return nil
        }
        guard totalContentHeight > availableHeight else {
            return nil
        }

        let fixedHeight = max(totalContentHeight - flexibleSectionHeight, 0)
        return max(availableHeight - fixedHeight, self.minimumHeight)
    }

    static func contentInsets(for version: OperatingSystemVersion) -> (top: CGFloat, bottom: CGFloat) {
        guard version.majorVersion >= 15 else {
            return (self.legacyTopContentInset, self.legacyBottomContentInset)
        }
        // macOS 15 popover chrome leaves less visible breathing room near the top and bottom.
        return (self.macOS15TopContentInset, self.macOS15BottomContentInset)
    }

    static func defaultHeight(for version: OperatingSystemVersion) -> CGFloat {
        self.legacyDefaultHeight + self.additionalVerticalInset(for: version)
    }

    static func maximumHeight(for version: OperatingSystemVersion) -> CGFloat {
        self.legacyMaximumHeight + self.additionalVerticalInset(for: version)
    }

    private static func additionalVerticalInset(for version: OperatingSystemVersion) -> CGFloat {
        let insets = self.contentInsets(for: version)
        return (insets.top - self.legacyTopContentInset) + (insets.bottom - self.legacyBottomContentInset)
    }
}

private final class StatusItemHotKeyController {
    private let action: () -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        self.stop()
    }

    func start() {
        guard self.hotKeyRefs.isEmpty else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == MenuBarGlobalShortcut.signature,
                      MenuBarGlobalShortcut.all.contains(where: { $0.identifier == hotKeyID.id }) else {
                    return noErr
                }

                let controller = Unmanaged<StatusItemHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.action()
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &self.eventHandler
        )
        guard installStatus == noErr else { return }

        for shortcut in MenuBarGlobalShortcut.all {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(
                signature: MenuBarGlobalShortcut.signature,
                id: shortcut.identifier
            )
            let registerStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            guard registerStatus == noErr, let hotKeyRef else {
                self.stop()
                return
            }
            self.hotKeyRefs.append(hotKeyRef)
        }

        if self.hotKeyRefs.isEmpty {
            if let eventHandler = self.eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
        }
    }

    func stop() {
        for hotKeyRef in self.hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        self.hotKeyRefs.removeAll()
        if let eventHandler = self.eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarStatusItemController()

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var initialMeasurementWindow: NSWindow?
    private var pendingInitialPopoverTrigger: String?
    private var pendingInitialPopoverAvailableHeight: CGFloat?
    private var initialMeasurementFallbackWorkItem: DispatchWorkItem?
    private var latestMeasuredContentHeight: CGFloat?
    private var didPostMenuWillOpenForCurrentPresentation = false
    private var isPreparingInitialMeasurementOpenState = false
    private var allowsProgrammaticPopoverClose = false
    private var cancellables: Set<AnyCancellable> = []
    private lazy var hotKeyController = StatusItemHotKeyController { [weak self] in
        self?.togglePopoverFromKeyboardShortcut()
    }

    private override init() {
        super.init()
        self.popover.behavior = .transient
        self.popover.delegate = self
    }

    func start() {
        guard self.statusItem == nil else {
            self.applyVisibilityPreference()
            self.updateAppearance()
            return
        }

        let userDefaults = UserDefaults.standard
        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: userDefaults)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = MenuBarStatusItemIdentity.statusItemAutosaveName
        item.behavior = MenuBarStatusItemIdentity.statusItemBehavior

        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        button.target = self
        button.action = #selector(self.togglePopover(_:))
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(MenuBarStatusItemIdentity.accessibilityLabel)
        button.setAccessibilityIdentifier(MenuBarStatusItemIdentity.accessibilityIdentifier)

        self.statusItem = item
        self.applyVisibilityPreference(userDefaults: userDefaults)
        self.popover.contentViewController = NSHostingController(
            rootView: self.makeMenuBarRootView()
        )

        self.bindState()
        self.updateAppearance()
        self.hotKeyController.start()
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_host_started",
            fields: ["pid": getpid()]
        )
    }

    func stop() {
        self.cancelInitialMeasurement()
        self.hotKeyController.stop()
        self.popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        self.cancellables.removeAll()
    }

    private func bindState() {
        guard self.cancellables.isEmpty else { return }

        TokenStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAppearanceRefresh()
            }
            .store(in: &self.cancellables)

        UpdateCoordinator.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAppearanceRefresh()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexpanelRequestCloseStatusItemMenu)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.closePopover()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexpanelStatusItemMeasuredHeightDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if self.pendingInitialPopoverTrigger != nil,
                   self.isPreparingInitialMeasurementOpenState {
                    self.recordPopoverSizingDiagnostic(
                        "status_item_menu_height_measurement_rejected_before_open_state",
                        fields: [
                            "height": notification.userInfo?["height"] as Any,
                            "width": notification.userInfo?["width"] as Any,
                            "popoverShown": self.popover.isShown,
                        ]
                    )
                    return
                }
                guard let height = notification.userInfo?["height"] as? CGFloat,
                      let width = notification.userInfo?["width"] as? CGFloat,
                      MenuBarPopoverSizing.acceptsMeasuredContentWidth(width) else {
                    self.recordPopoverSizingDiagnostic(
                        "status_item_menu_height_measurement_rejected",
                        fields: [
                            "height": notification.userInfo?["height"] as Any,
                            "width": notification.userInfo?["width"] as Any,
                            "pendingInitialOpen": self.pendingInitialPopoverTrigger != nil,
                            "popoverShown": self.popover.isShown,
                        ]
                    )
                    return
                }

                self.recordPopoverSizingDiagnostic(
                    "status_item_menu_height_measurement_accepted",
                    fields: [
                        "height": height,
                        "width": width,
                        "pendingInitialOpen": self.pendingInitialPopoverTrigger != nil,
                        "popoverShown": self.popover.isShown,
                    ]
                )
                self.latestMeasuredContentHeight = height
                if self.pendingInitialPopoverTrigger != nil {
                    self.completeInitialMeasurementAndShowPopover()
                    return
                }
                guard self.popover.isShown else { return }
                self.refreshPopoverSize(
                    desiredContentHeight: self.latestMeasuredContentHeight,
                    availableHeight: self.availablePopoverHeightBelowStatusItem()
                )
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexpanelRequestStatusItemLayoutRefresh)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.schedulePopoverSizeRefresh(
                    desiredContentHeight: nil,
                    availableHeight: self.availablePopoverHeightBelowStatusItem(),
                    remainingAttempts: 6
                )
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyVisibilityPreference()
            }
            .store(in: &self.cancellables)
    }

    private func scheduleAppearanceRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.updateAppearance()
        }
    }

    private func makeMenuBarRootView() -> AnyView {
        AnyView(
            MenuBarView()
                .environmentObject(TokenStore.shared)
                .environmentObject(OAuthManager.shared)
                .environmentObject(UpdateCoordinator.shared)
        )
    }

    private func updateAppearance() {
        guard let button = self.statusItem?.button else { return }

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: TokenStore.shared.accounts,
            activeProvider: TokenStore.shared.activeProvider,
            aggregateRoutedAccount: TokenStore.shared.aggregateRoutedAccount,
            usageDisplayMode: TokenStore.shared.config.openAI.usageDisplayMode,
            accountUsageMode: TokenStore.shared.config.openAI.accountUsageMode,
            updateAvailable: UpdateCoordinator.shared.pendingAvailability != nil
        )

        button.image = presentation.makeTemplateImage(
            accessibilityDescription: MenuBarStatusItemIdentity.accessibilityLabel
        )
        button.contentTintColor = nil
        button.attributedTitle = presentation.attributedTitle
    }

    private func applyVisibilityPreference(userDefaults: UserDefaults = .standard) {
        guard let statusItem = self.statusItem else { return }

        let visible = Self.resolvedVisibilityPreference(userDefaults: userDefaults)
        if visible == false {
            self.closePopover()
        }
        statusItem.isVisible = visible
    }

    nonisolated static func resolvedVisibilityPreference(userDefaults: UserDefaults = .standard) -> Bool {
        MenuBarStatusItemIdentity.resolvedVisibility(domain: userDefaults.dictionaryRepresentation())
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        if self.popover.isShown {
            self.closePopover(sender)
            return
        }
        self.showPopover(trigger: "button")
    }

    private func togglePopoverFromKeyboardShortcut() {
        if self.statusItem == nil {
            self.start()
        }
        if self.popover.isShown {
            self.closePopover()
            return
        }
        self.showPopover(trigger: "keyboard_shortcut")
    }

    private func showPopover(trigger: String) {
        self.updateAppearance()
        let availableHeight = self.availablePopoverHeightBelowStatusItem()
        guard self.latestMeasuredContentHeight != nil else {
            self.beginInitialMeasurement(trigger: trigger, availableHeight: availableHeight)
            return
        }
        self.presentPopover(trigger: trigger, availableHeight: availableHeight)
    }

    private func presentPopover(trigger: String, availableHeight: CGFloat?) {
        guard let button = self.statusItem?.button else { return }

        self.prepareMenuPresentationForCurrentOpen()
        let contentHeight = self.latestMeasuredContentHeight ?? MenuBarPopoverSizing.defaultHeight
        let popoverHeight = MenuBarPopoverSizing.clampedHeight(
            desiredHeight: contentHeight,
            availableHeight: availableHeight
        )
        self.popover.contentSize = NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: popoverHeight
        )
        self.publishAvailableContentHeight(availableHeight)
        self.recordPopoverSizingDiagnostic(
            "status_item_menu_present_popover",
            fields: [
                "trigger": trigger,
                "contentHeight": contentHeight,
                "popoverHeight": popoverHeight,
                "availableHeight": availableHeight as Any,
                "hasMeasuredHeight": self.latestMeasuredContentHeight != nil,
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        self.popover.contentViewController?.view.window?.makeKey()
        self.schedulePopoverSizeRefresh(availableHeight: availableHeight)
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_menu_opened",
            fields: [
                "pid": getpid(),
                "trigger": trigger,
            ]
        )
    }

    private func closePopover(_ sender: AnyObject? = nil) {
        guard self.popover.isShown else { return }
        self.allowsProgrammaticPopoverClose = true
        defer { self.allowsProgrammaticPopoverClose = false }
        self.popover.performClose(sender)
    }

    private func schedulePopoverSizeRefresh(
        desiredContentHeight: CGFloat? = nil,
        availableHeight: CGFloat?,
        remainingAttempts: Int = 3
    ) {
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.refreshPopoverSize(
                desiredContentHeight: desiredContentHeight,
                availableHeight: availableHeight ?? self.availablePopoverHeightBelowStatusItem()
            )
            self.schedulePopoverSizeRefresh(
                desiredContentHeight: desiredContentHeight,
                availableHeight: availableHeight,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func beginInitialMeasurement(trigger: String, availableHeight: CGFloat?) {
        guard self.pendingInitialPopoverTrigger == nil else { return }
        guard let contentViewController = self.popover.contentViewController else {
            self.presentPopover(trigger: trigger, availableHeight: availableHeight)
            return
        }

        self.pendingInitialPopoverTrigger = trigger
        self.pendingInitialPopoverAvailableHeight = availableHeight

        let measurementHeight = MenuBarPopoverSizing.minimumHeight
        let window = NSWindow(
            contentRect: NSRect(
                x: -10_000,
                y: -10_000,
                width: MenuBarStatusItemIdentity.popoverContentWidth,
                height: measurementHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.popover.contentViewController = nil
        window.contentViewController = contentViewController
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.orderFront(nil)
        self.initialMeasurementWindow = window
        self.isPreparingInitialMeasurementOpenState = true
        self.recordPopoverSizingDiagnostic(
            "status_item_menu_initial_measurement_started",
            fields: [
                "trigger": trigger,
                "availableHeight": availableHeight as Any,
                "measurementWindowWidth": window.frame.width,
                "measurementWindowHeight": window.frame.height,
            ]
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingInitialPopoverTrigger != nil else { return }
            self.prepareMenuPresentationForCurrentOpen()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingInitialPopoverTrigger != nil else { return }
                self.isPreparingInitialMeasurementOpenState = false
                self.initialMeasurementWindow?.contentViewController?.view.needsLayout = true
                self.initialMeasurementWindow?.contentViewController?.view.layoutSubtreeIfNeeded()
                self.recordPopoverSizingDiagnostic(
                    "status_item_menu_initial_measurement_open_state_ready",
                    fields: [
                        "latestMeasuredContentHeight": self.latestMeasuredContentHeight as Any,
                    ]
                )
            }
        }

        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingInitialPopoverTrigger != nil else { return }
            if self.latestMeasuredContentHeight == nil,
               let fallbackHeight = self.measureCurrentInitialMeasurementViewHeight() {
                self.latestMeasuredContentHeight = fallbackHeight
            }
            self.recordPopoverSizingDiagnostic(
                "status_item_menu_initial_measurement_fallback",
                fields: [
                    "latestMeasuredContentHeight": self.latestMeasuredContentHeight as Any,
                    "pendingInitialOpen": self.pendingInitialPopoverTrigger != nil,
                ]
            )
            self.completeInitialMeasurementAndShowPopover()
        }
        self.initialMeasurementFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fallbackWorkItem)
    }

    private func completeInitialMeasurementAndShowPopover() {
        guard let trigger = self.pendingInitialPopoverTrigger else { return }
        let availableHeight = self.pendingInitialPopoverAvailableHeight
        self.recordPopoverSizingDiagnostic(
            "status_item_menu_initial_measurement_completed",
            fields: [
                "trigger": trigger,
                "latestMeasuredContentHeight": self.latestMeasuredContentHeight as Any,
                "availableHeight": availableHeight as Any,
            ]
        )
        self.cancelInitialMeasurement()
        self.presentPopover(trigger: trigger, availableHeight: availableHeight)
    }

    private func cancelInitialMeasurement() {
        self.initialMeasurementFallbackWorkItem?.cancel()
        self.initialMeasurementFallbackWorkItem = nil
        self.pendingInitialPopoverTrigger = nil
        self.pendingInitialPopoverAvailableHeight = nil
        self.isPreparingInitialMeasurementOpenState = false
        if let contentViewController = self.initialMeasurementWindow?.contentViewController {
            self.initialMeasurementWindow?.contentViewController = nil
            self.popover.contentViewController = contentViewController
        }
        self.initialMeasurementWindow?.orderOut(nil)
        self.initialMeasurementWindow = nil
    }

    private func measureCurrentInitialMeasurementViewHeight() -> CGFloat? {
        guard let view = self.initialMeasurementWindow?.contentViewController?.view else { return nil }
        view.layoutSubtreeIfNeeded()
        let fittingHeight = max(view.fittingSize.height, MenuBarPopoverSizing.minimumHeight)
        guard fittingHeight > MenuBarPopoverSizing.minimumHeight + 1 else { return nil }
        return fittingHeight
    }

    private func prepareMenuPresentationForCurrentOpen() {
        guard self.didPostMenuWillOpenForCurrentPresentation == false else { return }
        self.didPostMenuWillOpenForCurrentPresentation = true
        NotificationCenter.default.post(name: .codexpanelStatusItemMenuWillOpen, object: self)
    }

    private func refreshPopoverSize(
        desiredContentHeight: CGFloat?,
        availableHeight: CGFloat?
    ) {
        guard let view = self.popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let contentHeight = desiredContentHeight ?? view.fittingSize.height
        let popoverHeight = MenuBarPopoverSizing.clampedHeight(
            desiredHeight: contentHeight,
            availableHeight: availableHeight
        )
        self.popover.contentSize = NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: popoverHeight
        )
        self.publishAvailableContentHeight(availableHeight)
        self.recordPopoverSizingDiagnostic(
            "status_item_menu_refresh_popover_size",
            fields: [
                "contentHeight": contentHeight,
                "popoverHeight": popoverHeight,
                "availableHeight": availableHeight as Any,
                "usedCachedMeasurement": desiredContentHeight != nil,
            ]
        )
    }

    private func publishAvailableContentHeight(_ height: CGFloat?) {
        var userInfo: [AnyHashable: Any]?
        if let height {
            userInfo = ["height": height]
        }
        NotificationCenter.default.post(
            name: .codexpanelStatusItemAvailableContentHeightDidChange,
            object: self,
            userInfo: userInfo
        )
    }

    private func recordPopoverSizingDiagnostic(_ type: String, fields: [String: Any]) {
        #if DEBUG
        AppLifecycleDiagnostics.shared.recordEvent(type: type, fields: fields)
        #endif
    }

    private func availablePopoverHeightBelowStatusItem() -> CGFloat? {
        guard let button = self.statusItem?.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        let visibleFrame = screen.visibleFrame
        return max(
            MenuBarPopoverSizing.minimumHeight,
            buttonFrameOnScreen.minY - visibleFrame.minY - MenuBarPopoverSizing.verticalMargin
        )
    }

    func popoverWillShow(_ notification: Notification) {
        self.prepareMenuPresentationForCurrentOpen()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if self.allowsProgrammaticPopoverClose {
            AppLifecycleDiagnostics.shared.recordEvent(
                type: "status_item_menu_should_close",
                fields: [
                    "decision": "allow_programmatic",
                    "hoverPanelCount": DetachedWindowPresenter.shared.hoverPanelFrames().count,
                ]
            )
            return true
        }

        // Treat hover panels as part of the same transient surface as the menu popover.
        let hoverPanelFrames = DetachedWindowPresenter.shared.hoverPanelFrames()
        let shouldClose = MenuBarPopoverClosePolicy.shouldClosePopover(
            mouseLocation: NSEvent.mouseLocation,
            protectedWindowFrames: hoverPanelFrames
        )
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_menu_should_close",
            fields: [
                "decision": shouldClose ? "allow" : "deny",
                "mouseX": NSEvent.mouseLocation.x,
                "mouseY": NSEvent.mouseLocation.y,
                "hoverPanelCount": hoverPanelFrames.count,
            ]
        )
        return shouldClose
    }

    func popoverDidClose(_ notification: Notification) {
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_menu_closed",
            fields: ["pid": getpid()]
        )
        self.statusItem?.button?.highlight(false)
        self.didPostMenuWillOpenForCurrentPresentation = false
        self.publishAvailableContentHeight(nil)
        NotificationCenter.default.post(name: .codexpanelStatusItemMenuDidClose, object: self)
    }
}
