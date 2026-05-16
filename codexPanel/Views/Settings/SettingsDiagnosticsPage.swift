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
        VStack(alignment: .leading, spacing: 18) {
            Text(L.settingsDiagnosticsPageTitle)
                .font(.system(size: 16, weight: .semibold))

            Text(L.settingsDiagnosticsPageHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsDiagnosticsToolbar(model: self.model)

            if let errorMessage = self.model.errorMessage {
                SettingsDiagnosticsMessageCard(
                    title: L.settingsDiagnosticsErrorTitle,
                    message: errorMessage,
                    tone: .error
                )
            }

            if let exportMessage = self.model.exportMessage {
                SettingsDiagnosticsMessageCard(
                    title: L.settingsDiagnosticsExportedTitle,
                    message: exportMessage,
                    tone: .success
                )
            }

            if let scanResult = self.model.scanResult {
                SettingsDiagnosticsArtifactsSection(scanResult: scanResult)

                if scanResult.hasCrashReport == false {
                    SettingsDiagnosticsMessageCard(
                        title: L.settingsDiagnosticsCrashMissingTitle,
                        message: L.settingsDiagnosticsCrashMissingHint,
                        tone: .warning
                    )
                }

                SettingsDiagnosticsMessageCard(
                    title: L.settingsDiagnosticsPrivacyTitle,
                    message: L.settingsDiagnosticsPrivacyHint,
                    tone: .info
                )
            } else {
                SettingsDiagnosticsMessageCard(
                    title: L.settingsDiagnosticsStatusTitle,
                    message: self.model.statusText,
                    tone: .info
                )
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

            Text(self.model.statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            SettingsDiagnosticsInfoRow(
                title: L.settingsDiagnosticsCrashReportsTitle,
                value: self.primaryCrashText
            )

            if self.scanResult.crashReports.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.settingsDiagnosticsAdditionalCrashReportsTitle)
                        .font(.system(size: 12, weight: .medium))

                    ForEach(Array(self.scanResult.crashReports.dropFirst())) { crashReport in
                        Text(self.fileSummary(for: crashReport))
                            .font(.system(size: 11))
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
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.system(size: 12, weight: .medium))

            Text(self.value)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsDiagnosticsMessageCard: View {
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

        var backgroundColor: Color {
            switch self {
            case .info:
                return Color.secondary.opacity(0.08)
            case .success:
                return Color.green.opacity(0.10)
            case .warning:
                return Color.orange.opacity(0.12)
            case .error:
                return Color.red.opacity(0.10)
            }
        }
    }

    let title: String
    let message: String
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(self.tone.foregroundColor)

            Text(self.message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(self.tone.backgroundColor)
        )
    }
}
