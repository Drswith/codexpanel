import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsDiagnosticsViewModel: ObservableObject {
    @Published private(set) var scanResult: DiagnosticsScanResult?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportMessage: String?

    private let service: DiagnosticsExportService
    private let panelService: DiagnosticsExportPanelService
    private var hasLoaded = false

    init(
        service: DiagnosticsExportService? = nil,
        panelService: DiagnosticsExportPanelService? = nil
    ) {
        self.service = service ?? .live()
        self.panelService = panelService ?? DiagnosticsExportPanelService()
    }

    var statusText: String {
        if self.isExporting {
            return L.settingsDiagnosticsExporting
        }
        if self.isRefreshing {
            return L.settingsDiagnosticsRefreshing
        }
        guard let scanResult else {
            return L.settingsDiagnosticsIdle
        }
        return L.settingsDiagnosticsLastScanned(
            scanResult.scannedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    func pageDidAppear() {
        guard self.hasLoaded == false else { return }
        self.hasLoaded = true
        self.refresh()
    }

    func refresh() {
        guard self.isRefreshing == false, self.isExporting == false else { return }
        self.isRefreshing = true
        self.errorMessage = nil
        self.scanResult = self.service.scan()
        self.isRefreshing = false
    }

    func exportDiagnostics() {
        guard self.isExporting == false else { return }
        guard let exportURL = self.panelService.requestExportURL() else { return }

        self.isExporting = true
        self.errorMessage = nil

        do {
            let result = try self.service.exportArchive(to: exportURL)
            self.scanResult = result.scanResult
            self.exportMessage = L.settingsDiagnosticsExportSucceeded(
                result.archiveURL.lastPathComponent,
                result.includedFiles.map(\.fileName)
            )
        } catch {
            self.errorMessage = error.localizedDescription
        }

        self.isExporting = false
    }
}

struct SettingsDiagnosticsPage: View {
    @StateObject private var model = SettingsDiagnosticsViewModel()

    var body: some View {
        Form {
            Section {
                SettingsDiagnosticsToolbar(model: self.model)
            } footer: {
                Text(self.model.statusText)
            }

            if let errorMessage = self.model.errorMessage {
                SettingsDiagnosticsMessageSection(
                    title: L.settingsDiagnosticsErrorTitle,
                    message: errorMessage,
                    tone: .error
                )
            }

            if let exportMessage = self.model.exportMessage {
                SettingsDiagnosticsMessageSection(
                    title: L.settingsDiagnosticsExportedTitle,
                    message: exportMessage,
                    tone: .success
                )
            }

            if let scanResult = self.model.scanResult {
                SettingsDiagnosticsArtifactsSection(scanResult: scanResult)

                if scanResult.hasCrashReport == false {
                    SettingsDiagnosticsMessageSection(
                        title: L.settingsDiagnosticsCrashMissingTitle,
                        message: L.settingsDiagnosticsCrashMissingHint,
                        tone: .warning
                    )
                }

                SettingsDiagnosticsMessageSection(
                    title: L.settingsDiagnosticsPrivacyTitle,
                    message: L.settingsDiagnosticsPrivacyHint,
                    tone: .info
                )
            } else {
                SettingsDiagnosticsMessageSection(
                    title: L.settingsDiagnosticsStatusTitle,
                    message: self.model.statusText,
                    tone: .info
                )
            }
            Section {
                DisclosureGroup(L.settingsDetails) {
                    Text(L.settingsDiagnosticsPageHint).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            self.model.pageDidAppear()
        }
    }
}

private struct SettingsDiagnosticsToolbar: View {
    @ObservedObject var model: SettingsDiagnosticsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(L.settingsDiagnosticsRefreshAction) {
                    self.model.refresh()
                }
                .disabled(self.model.isRefreshing || self.model.isExporting)

                Button(L.settingsDiagnosticsExportAction) {
                    self.model.exportDiagnostics()
                }
                .disabled(self.model.isRefreshing || self.model.isExporting)
            }

        }
    }
}

private struct SettingsDiagnosticsArtifactsSection: View {
    let scanResult: DiagnosticsScanResult

    private var primaryCrashText: String {
        guard let crashReport = self.scanResult.crashReports.first else {
            return L.settingsDiagnosticsCrashNotFound
        }
        return self.fileSummary(for: crashReport)
    }

    private var lifecycleLogText: String {
        guard let lifecycleLog = self.scanResult.lifecycleLog else {
            return L.settingsDiagnosticsLifecycleLogMissing
        }
        return self.fileSummary(for: lifecycleLog)
    }

    private var lifecycleStateText: String {
        guard let lifecycleState = self.scanResult.lifecycleState else {
            return L.settingsDiagnosticsLifecycleStateMissing
        }
        return self.fileSummary(for: lifecycleState)
    }

    var body: some View {
        Section {
            SettingsDiagnosticsInfoRow(
                title: L.settingsDiagnosticsCrashReportsTitle,
                value: self.primaryCrashText
            )

            if self.scanResult.crashReports.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.settingsDiagnosticsAdditionalCrashReportsTitle)
                        .font(.headline)

                    ForEach(Array(self.scanResult.crashReports.dropFirst())) { crashReport in
                        Text(self.fileSummary(for: crashReport))
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsDiagnosticsInfoRow(
                title: L.settingsDiagnosticsLifecycleLogTitle,
                value: self.lifecycleLogText
            )

            SettingsDiagnosticsInfoRow(
                title: L.settingsDiagnosticsLifecycleStateTitle,
                value: self.lifecycleStateText
            )
        }
    }

    private func fileSummary(for descriptor: DiagnosticsArtifactDescriptor) -> String {
        let timestamp = descriptor.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? L.settingsDiagnosticsUnknownTime
        if let sizeBytes = descriptor.sizeBytes {
            return L.settingsDiagnosticsFileSummary(
                descriptor.fileName,
                timestamp,
                ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            )
        }
        return L.settingsDiagnosticsFileSummaryWithoutSize(descriptor.fileName, timestamp)
    }
}

private struct SettingsDiagnosticsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(self.title) {
            Text(self.value).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct SettingsDiagnosticsMessageSection: View {
    enum Tone {
        case info
        case success
        case warning
        case error

        var foregroundColor: Color {
            switch self {
            case .info:
                return .secondary
            case .success:
                return .green
            case .warning:
                return .orange
            case .error:
                return .red
            }
        }

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "exclamationmark.circle"
            }
        }
    }

    let title: String
    let message: String
    let tone: Tone

    var body: some View {
        Section {
            DisclosureGroup {
                Text(self.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } label: {
                Label(self.title, systemImage: self.tone.symbol)
                    .foregroundStyle(self.tone.foregroundColor)
            }
        }
    }
}
