import AppKit
import ApplicationServices
import Foundation

private enum CLIIO {
    static func printStdout(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    static func printStderr(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(code: .unknown, message: "Failed to encode JSON output.")
        }
        self.printStdout(text)
    }
}

private struct AXWindowInfo {
    var windowElement: AXUIElement
    var identifier: String?
    var title: String?
    var kind: SnapshotTarget
}

private final class CodexPanelAXInspector {
    private let identity: CLIRuntimeIdentity

    init(identity: CLIRuntimeIdentity = .current) {
        self.identity = identity
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func snapshot(
        app: NSRunningApplication,
        target: SnapshotTarget
    ) throws -> SnapshotResult {
        guard self.isTrusted() else {
            throw CLIError(
                code: .accessibilityDenied,
                message: "Accessibility permission is required for snapshot.",
                hint: "Enable accessibility access for codexpanel in System Settings > Privacy & Security > Accessibility.",
                jsonOutput: true
            )
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = self.collectWindows(for: appElement)
        let windowMetadata = windows.map { info in
            CLISnapshotWindowMetadata(identifier: info.identifier, title: info.title, kind: info.kind)
        }
        let selectedIndices = CLISnapshotWindowSelectionCore.selectWindowIndices(windowMetadata, target: target)
        let selected = selectedIndices.map { windows[$0] }

        let snapshotWindows = selected.map { info in
            SnapshotWindow(
                kind: info.kind,
                windowRef: self.windowRef(for: info),
                title: info.title,
                nodes: self.collectNodes(from: info.windowElement, rootRef: self.windowRef(for: info))
            )
        }

        return SnapshotResult(
            bundleIdentifier: self.identity.bundleIdentifier,
            pid: app.processIdentifier,
            target: target == .auto ? CLISnapshotWindowSelectionCore.autoResolvedTarget(for: windowMetadata) : target,
            windows: snapshotWindows
        )
    }

    func currentState(for app: NSRunningApplication?) -> StateResult {
        let trusted = self.isTrusted()
        guard let app else {
            return CLIStateResultBuilder.build(
                from: CLIStateComputationInput(
                    appRunning: false,
                    pid: nil,
                    accessibilityTrusted: trusted,
                    menuVisible: false,
                    visibleWindows: []
                )
            )
        }

        guard trusted else {
            return CLIStateResultBuilder.build(
                from: CLIStateComputationInput(
                    appRunning: true,
                    pid: app.processIdentifier,
                    accessibilityTrusted: false,
                    menuVisible: false,
                    visibleWindows: []
                )
            )
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = self.collectWindows(for: appElement)
        let visible = windows.map { self.windowRef(for: $0) }
        let menuVisible = windows.contains(where: { $0.kind == .menu })

        return CLIStateResultBuilder.build(
            from: CLIStateComputationInput(
                appRunning: true,
                pid: app.processIdentifier,
                accessibilityTrusted: true,
                menuVisible: menuVisible,
                visibleWindows: visible
            )
        )
    }

    private func collectWindows(for appElement: AXUIElement) -> [AXWindowInfo] {
        guard let rawWindows = self.attribute(appElement, kAXWindowsAttribute as CFString) as? [Any] else {
            return []
        }
        return rawWindows.compactMap { raw in
            guard let element = self.asAXUIElement(raw) else { return nil }
            let identifier = (self.attribute(element, kAXIdentifierAttribute as CFString) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (self.attribute(element, kAXTitleAttribute as CFString) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = CLISnapshotWindowSelectionCore.classifyWindow(identifier: identifier, title: title)
            return AXWindowInfo(
                windowElement: element,
                identifier: identifier?.isEmpty == false ? identifier : nil,
                title: title?.isEmpty == false ? title : nil,
                kind: kind
            )
        }
    }

    private func windowRef(for info: AXWindowInfo) -> String {
        CLISnapshotRefBuilder.windowRef(
            identifier: info.identifier,
            title: info.title,
            kind: info.kind
        )
    }

    private func collectNodes(from root: AXUIElement, rootRef: String) -> [SnapshotNode] {
        let directChildren = self.children(of: root)
        var siblingCounter: [String: Int] = [:]
        return directChildren.map { child in
            self.makeNode(
                child,
                parentRef: rootRef,
                siblingCounter: &siblingCounter
            )
        }
    }

    private func makeNode(
        _ element: AXUIElement,
        parentRef: String,
        siblingCounter: inout [String: Int]
    ) -> SnapshotNode {
        let role = (self.attribute(element, kAXRoleAttribute as CFString) as? String) ?? "AXUnknown"
        let title = CLISnapshotRedactor.redact(self.attribute(element, kAXTitleAttribute as CFString) as? String)
        let label = CLISnapshotRedactor.redact(self.attribute(element, kAXDescriptionAttribute as CFString) as? String)
        let valueSummary = self.valueSummary(for: element)
        let enabled = self.bool(self.attribute(element, kAXEnabledAttribute as CFString))
        let focused = self.bool(self.attribute(element, kAXFocusedAttribute as CFString))
        let frame = self.frame(for: element)

        let identifier = CLISnapshotRedactor.redact(self.attribute(element, kAXIdentifierAttribute as CFString) as? String)
        let ref = CLISnapshotRefBuilder.childRef(
            identifier: identifier,
            role: role,
            title: title,
            label: label,
            parentRef: parentRef,
            siblingCounter: &siblingCounter
        )

        let children = self.children(of: element)
        var childSiblingCounter: [String: Int] = [:]
        let childNodes = children.map { child in
            self.makeNode(
                child,
                parentRef: ref,
                siblingCounter: &childSiblingCounter
            )
        }

        return SnapshotNode(
            ref: ref,
            role: role,
            title: title,
            label: label,
            valueSummary: valueSummary,
            enabled: enabled,
            focused: focused,
            frame: frame,
            children: childNodes
        )
    }

    private func attribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return nil }
        return value
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let array = self.attribute(element, kAXChildrenAttribute as CFString) as? [Any] else {
            return []
        }
        return array.compactMap { self.asAXUIElement($0) }
    }

    private func bool(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let number as NSNumber:
            return number.boolValue
        case let text as NSString:
            return text.boolValue
        default:
            return nil
        }
    }

    private func frame(for element: AXUIElement) -> WindowFrame? {
        guard let position = self.axValue(
            self.attribute(element, kAXPositionAttribute as CFString),
            expectedType: .cgPoint
        ),
        let size = self.axValue(
            self.attribute(element, kAXSizeAttribute as CFString),
            expectedType: .cgSize
        ) else {
            return nil
        }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else {
            return nil
        }
        return WindowFrame(
            x: origin.x,
            y: origin.y,
            width: dimensions.width,
            height: dimensions.height
        )
    }

    private func valueSummary(for element: AXUIElement) -> String? {
        guard let raw = self.attribute(element, kAXValueAttribute as CFString) else { return nil }
        if let text = raw as? String {
            return CLISnapshotRedactor.redact(text)
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        if let attributed = raw as? NSAttributedString {
            return CLISnapshotRedactor.redact(attributed.string)
        }
        if let array = raw as? [Any] {
            return "array(\(array.count))"
        }
        return String(describing: type(of: raw))
    }

    private func asAXUIElement(_ raw: Any) -> AXUIElement? {
        let cf = raw as CFTypeRef
        guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(cf, to: AXUIElement.self)
    }

    private func axValue(_ raw: Any?, expectedType: AXValueType) -> AXValue? {
        guard let raw else { return nil }
        let cf = raw as CFTypeRef
        guard CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(cf, to: AXValue.self)
        guard AXValueGetType(value) == expectedType else { return nil }
        return value
    }
}

private final class CodexPanelCLI {
    private let arguments: [String]
    private let identity: CLIRuntimeIdentity
    private let appLocator: CodexPanelAppLocator
    private let axInspector: CodexPanelAXInspector
    private let waitPoller = CLIViewWaitPoller()

    private struct AXStateProvider: CLIViewStateProviding {
        let appLocator: CodexPanelAppLocator
        let axInspector: CodexPanelAXInspector

        func currentState() -> StateResult {
            let app = self.appLocator.runningApp()
            return self.axInspector.currentState(for: app)
        }
    }

    init(arguments: [String], identity: CLIRuntimeIdentity = .current) {
        self.arguments = arguments
        self.identity = identity
        self.appLocator = CodexPanelAppLocator(identity: identity)
        self.axInspector = CodexPanelAXInspector(identity: identity)
    }

    func run() throws {
        let command = try CLIArgumentParser.parse(arguments: self.arguments)
        switch command {
        case .view(let viewCommand):
            try self.runView(viewCommand)
        case .state:
            try self.runState()
        case .snapshot(let snapshotCommand):
            try self.runSnapshot(snapshotCommand)
        case .doctor:
            try self.runDoctor()
        }
    }

    private func runView(_ command: ViewCommand) throws {
        guard let url = self.makeViewURL(command) else {
            throw CLIError(
                code: .routeUnsupported,
                message: "Unsupported view route.",
                jsonOutput: command.jsonOutput
            )
        }
        let routingAppURL = self.appLocator.preferredRoutingAppURL()
        guard CLIViewURLOpener.open(url, appURL: routingAppURL) else {
            throw CLIError(
                code: .appUnavailable,
                message: "Codex Panel app is not reachable.",
                hint: "Install/launch Codex Panel and retry.",
                jsonOutput: command.jsonOutput
            )
        }

        if let wait = command.waitSeconds {
            try self.waitForView(command, timeout: wait)
        }

        if command.jsonOutput {
            try CLIIO.printJSON(
                ViewResult(
                    ok: true,
                    action: command.action.rawValue,
                    target: command.target.rawValue,
                    page: command.page?.rawValue,
                    waitSeconds: command.waitSeconds
                )
            )
        } else {
            CLIIO.printStdout("ok")
        }
    }

    private func runState() throws {
        let app = self.appLocator.runningApp()
        var state = self.axInspector.currentState(for: app)
        state.appVersion = self.appLocator.appVersion(bundleURL: app?.bundleURL ?? self.appLocator.installedAppURL())
        try CLIIO.printJSON(state)
    }

    private func runSnapshot(_ command: SnapshotCommand) throws {
        guard let app = self.appLocator.runningApp() else {
            throw CLIError(
                code: .appUnavailable,
                message: "Codex Panel app is not running.",
                hint: "Launch Codex Panel first.",
                jsonOutput: command.format == .json
            )
        }
        let snapshot = try self.axInspector.snapshot(app: app, target: command.target)
        switch command.format {
        case .json:
            try CLIIO.printJSON(snapshot)
        case .tree:
            CLIIO.printStdout(CLISnapshotTreeRenderer.render(snapshot))
        }
    }

    private func runDoctor() throws {
        let runningApp = self.appLocator.runningApp()
        let installedURL = self.appLocator.installedAppURL()
        let helperAppURL = self.appLocator.helperOwningAppURL()
        let bundleURL = helperAppURL ?? runningApp?.bundleURL ?? installedURL
        let helperPath = bundleURL?
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(self.identity.commandName, isDirectory: false)
            .path
        let helperBundled: Bool
        if let helperPath {
            helperBundled = FileManager.default.fileExists(atPath: helperPath)
        } else {
            helperBundled = false
        }

        let cliSymlinkPath = NSHomeDirectory() + "/.local/bin/\(self.identity.commandName)"
        let cliExists = FileManager.default.fileExists(atPath: cliSymlinkPath)
        let cliTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: cliSymlinkPath)

        let doctor = DoctorResult(
            cliCommandName: self.identity.commandName,
            bundleIdentifier: self.identity.bundleIdentifier,
            urlScheme: self.identity.urlScheme,
            appInstalled: installedURL != nil || helperAppURL != nil,
            appBundlePath: bundleURL?.path,
            appRunning: runningApp != nil,
            pid: runningApp?.processIdentifier,
            appVersion: self.appLocator.appVersion(bundleURL: bundleURL),
            helperBundled: helperBundled,
            helperPath: helperPath,
            cliSymlinkPath: cliSymlinkPath,
            cliSymlinkExists: cliExists,
            cliSymlinkTarget: cliTarget,
            accessibilityTrusted: self.axInspector.isTrusted()
        )
        try CLIIO.printJSON(doctor)
    }

    private func makeViewURL(_ command: ViewCommand) -> URL? {
        CLIViewURLBuilder.makeViewURL(command: command, identity: self.identity)
    }

    private func waitForView(_ command: ViewCommand, timeout: TimeInterval) throws {
        guard self.axInspector.isTrusted() else {
            throw CLIError(
                code: .accessibilityDenied,
                message: "Accessibility permission is required for --wait.",
                hint: "Enable accessibility access for codexpanel in System Settings > Privacy & Security > Accessibility.",
                jsonOutput: command.jsonOutput
            )
        }

        let provider = AXStateProvider(appLocator: self.appLocator, axInspector: self.axInspector)
        let waitCommand = CLIViewWaitCommand(action: command.action, target: command.target)
        if self.waitPoller.waitUntilSatisfied(command: waitCommand, timeout: timeout, provider: provider) {
            return
        }
        throw CLIError(
            code: .waitTimeout,
            message: "Timed out waiting for view state transition.",
            jsonOutput: command.jsonOutput
        )
    }
}

private func emitJSONError(_ error: CLIError) {
    do {
        try CLIIO.printJSON(
            CLIErrorPayload(
                error: .init(
                    code: Int(error.code.rawValue),
                    message: error.message,
                    hint: error.hint
                )
            )
        )
    } catch {
        CLIIO.printStderr(error.localizedDescription)
    }
}

do {
    let cli = CodexPanelCLI(arguments: Array(CommandLine.arguments.dropFirst()))
    try cli.run()
    exit(CLIExitCode.success.rawValue)
} catch let cliError as CLIError {
    if cliError.jsonOutput {
        emitJSONError(cliError)
    } else {
        CLIIO.printStderr(cliError.message)
        if let hint = cliError.hint {
            CLIIO.printStderr("hint: \(hint)")
        }
    }
    exit(cliError.code.rawValue)
} catch {
    CLIIO.printStderr(error.localizedDescription)
    exit(CLIExitCode.unknown.rawValue)
}
