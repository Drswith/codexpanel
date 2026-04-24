import AppKit
import Carbon
import Combine
import SwiftUI

extension Notification.Name {
    static let codexpanelRequestCloseStatusItemMenu = Notification.Name("com.codexpanel.status-item-menu.close")
    static let codexpanelStatusItemMeasuredHeightDidChange = Notification.Name("com.codexpanel.status-item-menu.height-changed")
    static let codexpanelRequestStatusItemLayoutRefresh = Notification.Name("com.codexpanel.status-item-menu.layout-refresh")
    static let codexpanelStatusItemMenuWillOpen = Notification.Name("com.codexpanel.status-item-menu.will-open")
    static let codexpanelStatusItemMenuDidClose = Notification.Name("com.codexpanel.status-item-menu.did-close")
}

private enum MenuBarGlobalShortcut {
    static let keyCode = UInt32(kVK_ANSI_B)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let signature: OSType = 0x43444252
    static let identifier: UInt32 = 1
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
    static let verticalMargin: CGFloat = 12
    private static let legacyTopContentInset: CGFloat = 10
    private static let legacyBottomContentInset: CGFloat = 12
    private static let macOS15TopContentInset: CGFloat = 16
    private static let macOS15BottomContentInset: CGFloat = 18

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
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        self.stop()
    }

    func start() {
        guard self.hotKeyRef == nil else { return }

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
                      hotKeyID.id == MenuBarGlobalShortcut.identifier else {
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

        let hotKeyID = EventHotKeyID(
            signature: MenuBarGlobalShortcut.signature,
            id: MenuBarGlobalShortcut.identifier
        )
        let registerStatus = RegisterEventHotKey(
            MenuBarGlobalShortcut.keyCode,
            MenuBarGlobalShortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &self.hotKeyRef
        )
        if registerStatus != noErr {
            if let eventHandler = self.eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.hotKeyRef = nil
        }
    }

    func stop() {
        if let hotKeyRef = self.hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
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
    private var latestMeasuredContentHeight: CGFloat?
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
            rootView: MenuBarView()
                .environmentObject(TokenStore.shared)
                .environmentObject(OAuthManager.shared)
                .environmentObject(UpdateCoordinator.shared)
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
                if let height = notification.userInfo?["height"] as? CGFloat {
                    self.latestMeasuredContentHeight = height
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
                    availableHeight: self.availablePopoverHeightBelowStatusItem(),
                    remainingAttempts: 2
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
        guard let button = self.statusItem?.button else { return }

        self.updateAppearance()
        let availableHeight = self.availablePopoverHeightBelowStatusItem()
        self.popover.contentSize = MenuBarPopoverSizing.initialSize(availableHeight: availableHeight)
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
        availableHeight: CGFloat?,
        remainingAttempts: Int = 3
    ) {
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.refreshPopoverSize(
                desiredContentHeight: self.latestMeasuredContentHeight,
                availableHeight: availableHeight ?? self.availablePopoverHeightBelowStatusItem()
            )
            self.schedulePopoverSizeRefresh(
                availableHeight: availableHeight,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func refreshPopoverSize(
        desiredContentHeight: CGFloat?,
        availableHeight: CGFloat?
    ) {
        guard let view = self.popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let contentHeight = desiredContentHeight ?? view.fittingSize.height
        self.popover.contentSize = NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: MenuBarPopoverSizing.clampedHeight(
                desiredHeight: contentHeight,
                availableHeight: availableHeight
            )
        )
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
        NotificationCenter.default.post(name: .codexpanelStatusItemMenuWillOpen, object: self)
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
        NotificationCenter.default.post(name: .codexpanelStatusItemMenuDidClose, object: self)
    }
}
