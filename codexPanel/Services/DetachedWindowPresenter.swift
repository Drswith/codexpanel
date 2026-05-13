import AppKit
import SwiftUI

private final class HoverPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct DetachedWindowConfiguration {
    var isResizable = false
    var contentMinSize: CGSize?
    var resetsContentSizeOnReuse = true

    static let standard = Self()

    static let openAISettings = Self(
        isResizable: true,
        contentMinSize: CGSize(width: 760, height: 560),
        resetsContentSizeOnReuse: false
    )
}

/// 菜单栏动作里若同步 `NSHostingController` + `AnyView` 建窗，在 macOS 14 上可能触发 SwiftUI / AttributeGraph
/// 在 utility QoS 上解析类型元数据时崩溃；推迟到下一轮 main runloop 再构建视图可避免与 NSStatusItem 菜单拆解竞态。
@MainActor
final class DetachedWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = DetachedWindowPresenter()

    private var windows: [String: NSWindow] = [:]

    func hoverPanelFrames() -> [CGRect] {
        self.windows.values.compactMap { window in
            guard window is HoverPanelWindow else { return nil }
            return window.frame
        }
    }

    func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        configuration: DetachedWindowConfiguration = .standard,
        @ViewBuilder content: @escaping () -> Content
    ) {
        DispatchQueue.main.async { [self] in
            let anyView = AnyView(content())
            self.presentDetachedWindow(
                id: id,
                title: title,
                size: size,
                configuration: configuration,
                rootView: anyView
            )
        }
    }

    func showHoverPanel<Content: View>(
        id: String,
        size: CGSize,
        origin: CGPoint,
        @ViewBuilder content: @escaping () -> Content
    ) {
        DispatchQueue.main.async { [self] in
            let anyView = AnyView(content())
            self.presentHoverPanelWindow(id: id, size: size, origin: origin, rootView: anyView)
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
            let preservedContentRect: NSRect? = configuration.resetsContentSizeOnReuse
                ? nil
                : existing.contentRect(forFrameRect: existing.frame)
            if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = rootView
            } else {
                existing.contentViewController = NSHostingController(rootView: rootView)
            }
            if let preservedContentRect {
                let frame = existing.frameRect(forContentRect: preservedContentRect)
                existing.setFrame(frame, display: true)
            }
            NSApp?.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            self.applyStandardWindowConfiguration(configuration, to: existing)
            let windowForTailApply = existing
            let contentRectSnapshot = preservedContentRect
            DispatchQueue.main.async {
                let presenter = DetachedWindowPresenter.shared
                presenter.applyStandardWindowConfiguration(configuration, to: windowForTailApply)
                if let rect = contentRectSnapshot {
                    let frame = windowForTailApply.frameRect(forContentRect: rect)
                    windowForTailApply.setFrame(frame, display: true)
                }
            }
            return
        }

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.level = .floating
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
        DispatchQueue.main.async {
            DetachedWindowPresenter.shared.applyStandardWindowConfiguration(configuration, to: windowForConfigTailApply)
        }
    }

    private func presentHoverPanelWindow(id: String, size: CGSize, origin: CGPoint, rootView: AnyView) {
        if let existing = self.windows[id] {
            if existing.frame.size != size {
                existing.setContentSize(size)
            }
            if existing.frame.origin != origin {
                existing.setFrameOrigin(origin)
            }
            if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = rootView
            } else {
                existing.contentViewController = NSHostingController(rootView: rootView)
            }
            existing.orderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: rootView)
        let window = HoverPanelWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.contentViewController = controller
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.delegate = self

        self.windows[id] = window
        window.orderFront(nil)
    }

    func close(id: String) {
        guard let window = self.windows[id] else { return }
        window.close()
        self.windows.removeValue(forKey: id)
    }

    /// 仅用于单元测试：从 presenter 内部字典取窗，避免依赖 `NSApp.windows` 在 XCTest 环境下的差异。
    internal func windowSnapshotForTesting(id: String) -> NSWindow? {
        self.windows[id]
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
