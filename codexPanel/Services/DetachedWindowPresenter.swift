import AppKit
import SwiftUI

struct DetachedWindowConfiguration {
    var isResizable = false
    var contentMinSize: CGSize?
    var resetsContentSizeOnReuse = true
    var windowLevel: NSWindow.Level = .floating

    static let standard = Self()

    static let openAISettings = Self(
        isResizable: true,
        contentMinSize: CGSize(width: 740, height: 520),
        resetsContentSizeOnReuse: false,
        windowLevel: .normal
    )
}

/// 菜单栏动作里若同步 `NSHostingController` + `AnyView` 建窗，在 macOS 14 上可能触发 SwiftUI / AttributeGraph
/// 在 utility QoS 上解析类型元数据时崩溃；推迟到下一轮 main runloop 再构建视图可避免与 NSStatusItem 菜单拆解竞态。
@MainActor
final class DetachedWindowPresenter: NSObject, NSWindowDelegate, NSPopoverDelegate {
    static let shared = DetachedWindowPresenter()

    private var hoverPopovers: [String: NSPopover] = [:]
    private var windows: [String: NSWindow] = [:]
    private var pendingDetachedWindowPresentations: [String: DispatchWorkItem] = [:]
    private var pendingDetachedWindowPresentationTokens: [String: UUID] = [:]

    func hoverPanelFrames() -> [CGRect] {
        self.hoverPopovers.values.compactMap { popover in
            guard popover.isShown else { return nil }
            return popover.contentViewController?.view.window?.frame
        }
    }

    func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        configuration: DetachedWindowConfiguration = .standard,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.pendingDetachedWindowPresentations[id]?.cancel()
        self.pendingDetachedWindowPresentations.removeValue(forKey: id)
        self.pendingDetachedWindowPresentationTokens.removeValue(forKey: id)
        if self.windows[id] != nil {
            let anyView = AnyView(content())
            self.presentDetachedWindow(
                id: id,
                title: title,
                size: size,
                configuration: configuration,
                rootView: anyView
            )
            return
        }
        let token = UUID()
        self.pendingDetachedWindowPresentationTokens[id] = token
        let workItem = DispatchWorkItem { [self] in
            guard self.pendingDetachedWindowPresentationTokens[id] == token else { return }
            self.pendingDetachedWindowPresentations.removeValue(forKey: id)
            self.pendingDetachedWindowPresentationTokens.removeValue(forKey: id)
            let anyView = AnyView(content())
            self.presentDetachedWindow(
                id: id,
                title: title,
                size: size,
                configuration: configuration,
                rootView: anyView
            )
        }
        self.pendingDetachedWindowPresentations[id] = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func showHoverPopover<Content: View>(
        id: String,
        size: CGSize,
        anchorView: NSView,
        @ViewBuilder content: () -> Content
    ) {
        guard let parent = anchorView.window, let parentContent = parent.contentView else { return }
        let popover = self.hoverPopovers[id] ?? NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let rootView = AnyView(content())
        if let controller = popover.contentViewController as? NSHostingController<AnyView> {
            controller.rootView = rootView
        } else {
            popover.contentViewController = NSHostingController(rootView: rootView)
        }
        popover.contentSize = size
        self.hoverPopovers[id] = popover
        // 将定位区域延伸到主面板两侧，让 AppKit 自动选边且不覆盖主面板内容。
        let parentBounds = anchorView.convert(parentContent.bounds, from: parentContent)
        var positioningRect = anchorView.bounds
        positioningRect.origin.x = parentBounds.minX
        positioningRect.size.width = parentBounds.width
        if !popover.isShown {
            popover.show(relativeTo: positioningRect, of: anchorView, preferredEdge: .maxX)
        }
        // 菜单栏宿主可能处于 popUpMenu 层级；详情必须随父窗显示并位于其上方。
        if let window = popover.contentViewController?.view.window {
            window.level = parent.level
            if window.parent !== parent {
                parent.addChildWindow(window, ordered: .above)
            }
            window.orderFront(nil)
        }
    }

    private func presentDetachedWindow(
        id: String,
        title: String,
        size: CGSize,
        configuration: DetachedWindowConfiguration,
        rootView: AnyView
    ) {
        if let existing = self.windows[id] {
            existing.title = title
            self.applyStandardWindowConfiguration(configuration, to: existing)
            if configuration.resetsContentSizeOnReuse {
                existing.setContentSize(size)
            }
            if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = rootView
            } else {
                existing.contentViewController = NSHostingController(rootView: rootView)
            }
            NSApp?.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            self.applyStandardWindowConfiguration(configuration, to: existing)
            let windowForTailApply = existing
            DispatchQueue.main.async { [weak self] in
                self?.applyStandardWindowConfiguration(configuration, to: windowForTailApply)
            }
            return
        }

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.isReleasedWhenClosed = false
        self.applyStandardWindowConfiguration(configuration, to: window)
        window.setContentSize(size)
        window.center()
        window.delegate = self

        self.windows[id] = window
        NSApp?.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // SwiftUI 宿主在首帧布局后可能改写 contentMinSize；在 order front 之后再应用一次配置以稳定测试与系统行为。
        self.applyStandardWindowConfiguration(configuration, to: window)
        let windowForConfigTailApply = window
        DispatchQueue.main.async { [weak self] in
            self?.applyStandardWindowConfiguration(configuration, to: windowForConfigTailApply)
        }
    }

    func close(id: String) {
        self.pendingDetachedWindowPresentations[id]?.cancel()
        self.pendingDetachedWindowPresentations.removeValue(forKey: id)
        self.pendingDetachedWindowPresentationTokens.removeValue(forKey: id)
        self.hoverPopovers.removeValue(forKey: id)?.close()
        guard let window = self.windows[id] else { return }
        window.close()
        self.windows.removeValue(forKey: id)
    }

    /// 仅用于单元测试：从 presenter 内部字典取窗，避免依赖 `NSApp.windows` 在 XCTest 环境下的差异。
    internal func windowSnapshotForTesting(id: String) -> NSWindow? {
        self.windows[id] ?? self.hoverPopovers[id]?.contentViewController?.view.window
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              let id = self.hoverPopovers.first(where: { $0.value === popover })?.key else { return }
        self.hoverPopovers.removeValue(forKey: id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        self.windows.removeValue(forKey: id)
    }

    private func applyStandardWindowConfiguration(
        _ configuration: DetachedWindowConfiguration,
        to window: NSWindow
    ) {
        window.level = configuration.windowLevel
        window.styleMask = Self.styleMask(for: configuration)
        window.contentMinSize = configuration.contentMinSize ?? .zero
    }

    private static func styleMask(for configuration: DetachedWindowConfiguration) -> NSWindow.StyleMask {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if configuration.isResizable {
            styleMask.insert(.resizable)
        }
        return styleMask
    }
}
