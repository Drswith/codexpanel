import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct DiagnosticsExportPanelService {
    typealias AppActivator = @MainActor () -> Void
    typealias ExportURLRequester = @MainActor (_ suggestedFilename: String) -> URL?

    private let activateApp: AppActivator
    private let requestExportURLAction: ExportURLRequester

    init(
        activateApp: @escaping AppActivator = { DiagnosticsExportPanelService.activateApp() },
        requestExportURLAction: @escaping ExportURLRequester = { suggestedFilename in
            DiagnosticsExportPanelService.presentExportPanel(suggestedFilename: suggestedFilename)
        }
    ) {
        self.activateApp = activateApp
        self.requestExportURLAction = requestExportURLAction
    }

    func requestExportURL() -> URL? {
        self.activateApp()
        return self.requestExportURLAction(self.defaultExportFilename())
    }

    private func defaultExportFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "codexpanel-diagnostics-\(formatter.string(from: now)).zip"
    }

    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func presentExportPanel(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L.settingsDiagnosticsExportAction
        panel.message = L.settingsDiagnosticsSavePanelMessage
        panel.prompt = L.settingsDiagnosticsSavePanelPrompt
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]
        panel.nameFieldStringValue = suggestedFilename

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return nil
        }

        if url.pathExtension.lowercased() == "zip" {
            return url.standardizedFileURL
        }
        return url.appendingPathExtension("zip").standardizedFileURL
    }
}
