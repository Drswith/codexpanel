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

struct MenuBarGlobalShortcut: Equatable {
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
    /// 自动化专用：不与正式版或另一开发实例的常用入口竞争。
    static let debugMenuOpen = Self(
        keyCode: UInt32(kVK_ANSI_9),
        modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
        identifier: 3
    )
    #endif

    static var all: [Self] {
        var shortcuts = [Self.primary]
        #if DEBUG
        shortcuts.append(contentsOf: [.debugAlternate, .debugMenuOpen])
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
        // Preserve the existing content insets when changing the system presentation host.
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

enum MenuBarPopoverAnchorPolicy {
    static func isUsable(_ frame: CGRect, on screenFrame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 &&
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    static func isStable(_ frame: CGRect, previous: CGRect?) -> Bool {
        guard let previous else { return false }
        return abs(frame.minX - previous.minX) < 0.5 &&
            abs(frame.minY - previous.minY) < 0.5 &&
            abs(frame.width - previous.width) < 0.5 &&
            abs(frame.height - previous.height) < 0.5
    }
}

private final class StatusItemHotKeyController {
    private let action: (UInt32) -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init(action: @escaping (UInt32) -> Void) {
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
                controller.action(hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &self.eventHandler
        )
        guard installStatus == noErr else {
            AppLifecycleDiagnostics.shared.recordEvent(type: "status_item_shortcut_handler_failed", fields: ["status": installStatus])
            return
        }

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
                AppLifecycleDiagnostics.shared.recordEvent(
                    type: "status_item_shortcut_registration_failed",
                    fields: ["identifier": shortcut.identifier, "status": registerStatus]
                )
                // 某个组合已被其他实例占用时，继续注册剩余入口。
                continue
            }
            self.hotKeyRefs.append(hotKeyRef)
            AppLifecycleDiagnostics.shared.recordEvent(
                type: "status_item_shortcut_registered",
                fields: ["identifier": shortcut.identifier]
            )
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

/// SwiftUI owns the status item and its native, arrowless MenuBarExtra window.
/// This bridge retains the existing refresh, shortcut and presentation notifications.
@MainActor
final class MenuBarStatusItemController: NSObject, ObservableObject {
    static let shared = MenuBarStatusItemController()

    @Published var isInserted = true
    @Published private(set) var isRuntimeReady = false
    var runtimeInitializer: (() -> Void)?
    @Published private(set) var presentation = MenuBarStatusItemPresentation(
        iconName: "terminal", title: "", emphasis: .primary
    )
    private weak var nativeStatusItem: NSStatusItem?
    private weak var menuWindow: NSWindow?
    private var isPresented = false
    private var cancellables: Set<AnyCancellable> = []
    private var deferredRuntimeWork: DispatchWorkItem?
    private var hasReportedFirstFrame = false
    private var isStarted = false
    private var isPreparingRuntime = false
    private lazy var hotKeyController = StatusItemHotKeyController { [weak self] identifier in
        #if DEBUG
        if identifier == MenuBarGlobalShortcut.debugMenuOpen.identifier {
            guard self?.isPresented == false else { return }
            self?.toggleFromKeyboardShortcut()
            return
        }
        #endif
        self?.toggleFromKeyboardShortcut()
    }

    func start() {
        guard self.cancellables.isEmpty else { return }
        self.isStarted = true
        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: .standard)
        self.isInserted = Self.resolvedVisibilityPreference()
        self.hotKeyController.start()
        self.observeFirstFrame()

        NotificationCenter.default.publisher(for: .codexpanelRequestCloseStatusItemMenu)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.closeMenu() }
            .store(in: &self.cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                let visible = Self.resolvedVisibilityPreference()
                if self?.isInserted != visible { self?.isInserted = visible }
            }.store(in: &self.cancellables)
        AppLifecycleDiagnostics.shared.recordEvent(type: "status_item_host_started", fields: ["pid": getpid()])
    }

    private func observeFirstFrame(attempts: Int = 100) {
        guard self.isStarted else { return }
        if let button = self.resolveStatusItem()?.button, let window = button.window,
           window.isVisible, button.bounds.width > 0, button.image != nil {
            button.displayIfNeeded()
            if !self.hasReportedFirstFrame {
                self.hasReportedFirstFrame = true
                AppLifecycleDiagnostics.shared.recordEvent(type: "status_item_first_frame_ready", fields: ["pid": getpid()])
            }
            self.scheduleRuntimeInitialization()
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.observeFirstFrame(attempts: attempts - 1)
            }
        } else {
            self.scheduleRuntimeInitialization()
        }
    }

    private func scheduleRuntimeInitialization() {
        guard !self.isRuntimeReady, self.deferredRuntimeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.prepareMenuContent() }
        self.deferredRuntimeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750), execute: work)
    }

    func prepareMenuContent() {
        guard !self.isRuntimeReady, !self.isPreparingRuntime else { return }
        self.isPreparingRuntime = true
        defer { self.isPreparingRuntime = false }
        self.deferredRuntimeWork?.cancel()
        self.deferredRuntimeWork = nil
        self.runtimeInitializer?()
        self.updateAppearance()

        for publisher in [TokenStore.shared.objectWillChange.eraseToAnyPublisher(),
                          UpdateCoordinator.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateAppearance() }
            }.store(in: &self.cancellables)
        }
        self.isRuntimeReady = true
    }

    func stop() {
        self.isStarted = false
        self.deferredRuntimeWork?.cancel()
        self.deferredRuntimeWork = nil
        self.closeMenu()
        self.hotKeyController.stop()
        self.cancellables.removeAll()
        self.isInserted = false
        self.isRuntimeReady = false
        self.hasReportedFirstFrame = false
    }

    nonisolated static func resolvedVisibilityPreference(userDefaults: UserDefaults = .standard) -> Bool {
        MenuBarStatusItemIdentity.resolvedVisibility(domain: userDefaults.dictionaryRepresentation())
    }

    func attachMenuWindow(_ window: NSWindow) {
        self.menuWindow = window
        self.synchronizePresentation()
        #if DEBUG
        AppLifecycleDiagnostics.shared.recordEvent(type: "native_menu_geometry", fields: [
            "windowWidth": window.frame.width,
            "contentWidth": window.contentView?.bounds.width as Any,
            "contentHeight": window.contentView?.bounds.height as Any,
            "outerInset": MenuBarPopoverSizing.horizontalContentInset,
        ])
        #endif
    }

    func synchronizePresentation() {
        guard let window = self.menuWindow else { return }
        // Occlusion notifications also fire when the native menu is ordered out.
        let visible = window.isVisible
        if visible && !self.isRuntimeReady {
            self.prepareMenuContent()
            DispatchQueue.main.async { [weak self] in self?.synchronizePresentation() }
            return
        }
        guard visible != self.isPresented else { return }
        if visible { self.menuWillOpen() } else { self.menuDidClose() }
    }

    func menuWillOpen() {
        guard !self.isPresented else { return }
        self.isPresented = true
        self.publishAvailableContentHeight(self.menuWindow?.screen.map {
            max(1, $0.visibleFrame.height - MenuBarPopoverSizing.verticalMargin)
        })
        NotificationCenter.default.post(name: .codexpanelStatusItemMenuWillOpen, object: self)
        AppLifecycleDiagnostics.shared.recordEvent(type: "status_item_menu_opened", fields: ["pid": getpid()])
    }

    func menuDidClose() {
        guard self.isPresented else { return }
        self.isPresented = false
        self.publishAvailableContentHeight(nil)
        NotificationCenter.default.post(name: .codexpanelStatusItemMenuDidClose, object: self)
        AppLifecycleDiagnostics.shared.recordEvent(type: "status_item_menu_closed", fields: ["pid": getpid()])
    }

    private func closeMenu() {
        guard self.isPresented else { return }
        if let item = self.resolveStatusItem(), let session = self.expandedSession(for: item) {
            session.perform(NSSelectorFromString("cancel"))
        } else if let button = self.resolveStatusItem()?.button {
            button.performClick(nil)
        } else {
            self.menuWindow?.orderOut(nil)
        }
        self.synchronizePresentation()
    }

    private func toggleFromKeyboardShortcut() {
        if self.isInserted == false { self.isInserted = true }
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.resolveStatusItem() else { return }
            NSApp.activate(ignoringOtherApps: true)
            let delegateSelector = NSSelectorFromString("expandedInterfaceDelegate")
            if #available(macOS 27.0, *), item.responds(to: delegateSelector),
               item.perform(delegateSelector)?.takeUnretainedValue() != nil {
                if let session = self.expandedSession(for: item) {
                    session.perform(NSSelectorFromString("cancel"))
                } else {
                    // macOS 27 no longer assigns a button action to window-style extras.
                    // AppKit exposes session cancellation, but not a public begin method.
                    // Keep this compatibility bridge guarded; SwiftUI still owns the window.
                    let selector = NSSelectorFromString("_beginExpandedInterfaceSession:")
                    guard item.responds(to: selector), let implementation = item.method(for: selector) else { return }
                    typealias BeginSession = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
                    unsafeBitCast(implementation, to: BeginSession.self)(item, selector, .greatestFiniteMagnitude)
                }
            } else {
                item.button?.performClick(nil)
            }
        }
    }

    // Resolve new AppKit session APIs dynamically so older Xcode SDKs still compile.
    private func expandedSession(for item: NSStatusItem) -> NSObject? {
        guard #available(macOS 27.0, *) else { return nil }
        let selector = NSSelectorFromString("expandedInterfaceSession")
        guard item.responds(to: selector),
              let session = item.perform(selector)?.takeUnretainedValue() as? NSObject,
              session.responds(to: NSSelectorFromString("cancel")) else { return nil }
        return session
    }

    private func resolveStatusItem() -> NSStatusItem? {
        if let nativeStatusItem { return nativeStatusItem }
        // MenuBarExtra has no public status-item accessor. Restrict introspection to
        // its status-bar windows and exclude inactive-display replicas.
        let selector = NSSelectorFromString("statusItem")
        self.nativeStatusItem = NSApp.windows.lazy.compactMap { window -> NSStatusItem? in
            guard String(describing: type(of: window)).contains("NSStatusBarWindow"),
                  window.responds(to: selector),
                  let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem,
                  !String(describing: type(of: item)).contains("Replicant") else { return nil }
            return item
        }.first
        if let item = self.nativeStatusItem {
            item.autosaveName = MenuBarStatusItemIdentity.statusItemAutosaveName
            item.behavior = MenuBarStatusItemIdentity.statusItemBehavior
            item.button?.setAccessibilityLabel(MenuBarStatusItemIdentity.accessibilityLabel)
            item.button?.setAccessibilityIdentifier(MenuBarStatusItemIdentity.accessibilityIdentifier)
        }
        return self.nativeStatusItem
    }

    private func updateAppearance() {
        let presentation = MenuBarStatusItemPresentation.make(
            accounts: TokenStore.shared.accounts,
            activeProvider: TokenStore.shared.activeProvider,
            aggregateRoutedAccount: TokenStore.shared.aggregateRoutedAccount,
            usageDisplayMode: TokenStore.shared.config.openAI.usageDisplayMode,
            accountUsageMode: TokenStore.shared.config.openAI.accountUsageMode,
            updateAvailable: UpdateCoordinator.shared.pendingAvailability != nil
        )
        if self.presentation != presentation { self.presentation = presentation }
        RateLimitResetNotificationService.shared.evaluate(accounts: TokenStore.shared.accounts)
    }

    private func publishAvailableContentHeight(_ height: CGFloat?) {
        NotificationCenter.default.post(
            name: .codexpanelStatusItemAvailableContentHeightDidChange,
            object: self,
            userInfo: height.map { ["height": $0] }
        )
    }
}

struct NativeMenuBarContent: View {
    @ObservedObject private var controller = MenuBarStatusItemController.shared
    var body: AnyView {
        // Keep MenuBarView's existing outer insets and all internal content unchanged.
        // The system supplies the window material, outline and rounded corners.
        // 运行态准备完毕后再构造完整菜单，轻量分支保持稳定的 AnyView 类型。
        if !self.controller.isRuntimeReady {
            return AnyView(ProgressView()
                .frame(width: MenuBarStatusItemIdentity.popoverContentWidth, height: 80)
                .background(NativeMenuBarWindowReader()))
        }
        return AnyView(MenuBarView()
            .environmentObject(TokenStore.shared)
            .environmentObject(OAuthManager.shared)
            .environmentObject(UpdateCoordinator.shared)
            .background(NativeMenuBarWindowReader()))
    }
}

private struct NativeMenuBarWindowReader: NSViewRepresentable {

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(frame: .zero)
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.attach()
    }

    final class ReaderView: NSView {
        private var observations: [NSObjectProtocol] = []

        override init(frame: NSRect) { super.init(frame: frame) }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.observations.forEach { NotificationCenter.default.removeObserver($0) }
            self.observations.removeAll()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                self.observations.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        MenuBarStatusItemController.shared.synchronizePresentation()
                    }
                })
            }
            self.attach()
        }

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let window = self.window {
                    MenuBarStatusItemController.shared.attachMenuWindow(window)
                }
            }
        }

        deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
