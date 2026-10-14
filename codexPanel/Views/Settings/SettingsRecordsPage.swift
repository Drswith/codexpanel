import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsRecordsViewModel: ObservableObject {
    @Published private(set) var snapshot: RecordsSnapshot?
    @Published private(set) var isLoadingSnapshot = false
    @Published private(set) var isSlowLoadingSnapshot = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""
    @Published var isModelsSummaryExpanded = false
    @Published var isWarningsExpanded = false

    private let service: any RecordsSnapshotServing
    private let slowLoadingThresholdNanoseconds: UInt64
    private var requestToken: UInt64 = 0

    init(
        service: any RecordsSnapshotServing,
        slowLoadingThresholdNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.service = service
        self.slowLoadingThresholdNanoseconds = slowLoadingThresholdNanoseconds
    }

    var filteredSessions: [HistoricalSessionRecord] {
        guard let snapshot = self.snapshot else { return [] }
        let query = self.normalizedQuery
        guard query.isEmpty == false else { return snapshot.sessions }
        return snapshot.sessions.filter {
            $0.sessionID.localizedCaseInsensitiveContains(query) ||
            $0.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredModels: [HistoricalModelRecord] {
        guard let snapshot = self.snapshot else { return [] }
        let query = self.normalizedQuery
        guard query.isEmpty == false else { return snapshot.models }

        let visibleModelIDs = Set(self.filteredSessions.map(\.modelID))
        return snapshot.models.filter {
            visibleModelIDs.contains($0.modelID) ||
            $0.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    var archivedSessionCount: Int {
        self.filteredSessions.filter(\.isArchived).count
    }

    var activeSessionCount: Int {
        self.filteredSessions.count - self.archivedSessionCount
    }

    var hasSnapshot: Bool {
        self.snapshot != nil
    }

    var shouldShowSkeleton: Bool {
        self.snapshot == nil && self.isLoadingSnapshot
    }

    var statusText: String {
        if self.isRefreshingAll {
            return L.settingsRecordsRefreshingAll
        }
        if self.isLoadingSnapshot {
            if self.isSlowLoadingSnapshot {
                return self.snapshot == nil
                    ? L.settingsRecordsSlowLoading
                    : L.settingsRecordsSlowRefreshingIncremental
            }
            return self.snapshot == nil
                ? L.settingsRecordsLoading
                : L.settingsRecordsRefreshingIncremental
        }
        guard let snapshot = self.snapshot else {
            return L.settingsRecordsIdle
        }
        return L.settingsRecordsLastUpdated(
            snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    func pageDidAppear() {
        guard self.isLoadingSnapshot == false, self.isRefreshingAll == false else { return }
        self.loadCurrentWithCachedFallback()
    }

    func retryLoad() {
        self.loadCurrentWithCachedFallback()
    }

    func loadCurrent() {
        let requestToken = self.beginRequest(isRefreshAll: false)
        self.scheduleSlowLoadingCheck(for: requestToken, isRefreshAll: false)
        Task {
            do {
                let snapshot = try await self.service.loadCurrent()
                self.finishRequest(
                    token: requestToken,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshAll: false
                )
            } catch {
                self.finishRequest(
                    token: requestToken,
                    snapshot: nil,
                    errorMessage: self.displayMessage(for: error),
                    isRefreshAll: false
                )
            }
        }
    }

    func refreshAll(timeout: TimeInterval = 15) {
        guard self.isRefreshingAll == false else { return }
        let requestToken = self.beginRequest(isRefreshAll: true)
        Task {
            do {
                let snapshot = try await self.service.refreshAll(timeout: timeout)
                self.finishRequest(
                    token: requestToken,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshAll: true
                )
            } catch {
                self.finishRequest(
                    token: requestToken,
                    snapshot: nil,
                    errorMessage: self.displayMessage(for: error),
                    isRefreshAll: true
                )
            }
        }
    }

    private var normalizedQuery: String {
        self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadCurrentWithCachedFallback() {
        let requestToken = self.beginRequest(isRefreshAll: false)
        self.scheduleSlowLoadingCheck(for: requestToken, isRefreshAll: false)
        Task {
            let cachedSnapshot = await self.service.loadCached()
            self.applyCachedSnapshotIfNeeded(token: requestToken, cachedSnapshot: cachedSnapshot)
            do {
                let snapshot = try await self.service.loadCurrent()
                self.finishRequest(
                    token: requestToken,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshAll: false
                )
            } catch {
                self.finishRequest(
                    token: requestToken,
                    snapshot: nil,
                    errorMessage: self.displayMessage(for: error),
                    isRefreshAll: false
                )
            }
        }
    }

    private func beginRequest(isRefreshAll: Bool) -> UInt64 {
        self.requestToken += 1
        self.errorMessage = nil
        self.isSlowLoadingSnapshot = false
        if isRefreshAll {
            self.isRefreshingAll = true
            self.isLoadingSnapshot = false
        } else {
            self.isLoadingSnapshot = true
        }
        return self.requestToken
    }

    private func finishRequest(
        token: UInt64,
        snapshot: RecordsSnapshot?,
        errorMessage: String?,
        isRefreshAll: Bool
    ) {
        guard token == self.requestToken else { return }
        self.isLoadingSnapshot = false
        self.isSlowLoadingSnapshot = false
        if isRefreshAll {
            self.isRefreshingAll = false
        }
        if let snapshot {
            self.snapshot = snapshot
        }
        self.errorMessage = errorMessage
    }

    private func displayMessage(for error: Error) -> String {
        if let serviceError = error as? RecordsSnapshotServiceError,
           case .timedOut = serviceError {
            return L.settingsRecordsRefreshTimeout
        }
        return error.localizedDescription
    }

    private func applyCachedSnapshotIfNeeded(token: UInt64, cachedSnapshot: RecordsSnapshot?) {
        guard token == self.requestToken else { return }
        guard let cachedSnapshot, self.snapshot == nil else { return }
        self.snapshot = cachedSnapshot
    }

    private func scheduleSlowLoadingCheck(for token: UInt64, isRefreshAll: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.slowLoadingThresholdNanoseconds)
            guard token == self.requestToken else { return }
            guard isRefreshAll == false else { return }
            guard self.isLoadingSnapshot else { return }
            self.isSlowLoadingSnapshot = true
        }
    }
}

typealias SettingsRecordsModel = SettingsRecordsViewModel

struct SettingsRecordsPage: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    let onOpenUsage: () -> Void
    @State private var selectedSessionID: String?

    private var selectedSession: HistoricalSessionRecord? {
        self.recordsModel.filteredSessions.first { $0.id == self.selectedSessionID }
    }

    var body: some View {
        Form {
            Section {
                SettingsRecordsToolbar(recordsModel: self.recordsModel, onOpenUsage: self.onOpenUsage)
            } footer: {
                Text(self.recordsModel.statusText)
            }
            if let errorMessage = self.recordsModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if self.recordsModel.hasSnapshot == false {
                        Button(L.settingsRecordsRetryAction, action: self.recordsModel.retryLoad)
                    }
                }
            }
            if self.recordsModel.shouldShowSkeleton {
                Section { ProgressView(L.settingsRecordsLoading) }
            } else if self.recordsModel.hasSnapshot {
                SettingsRecordsOverview(recordsModel: self.recordsModel)
                Section {
                    SettingsRecordsSessionTable(
                        sessions: self.recordsModel.filteredSessions,
                        selection: self.$selectedSessionID
                    )
                    .frame(height: 300)
                } header: {
                    Text(L.settingsRecordsSessionsTitle)
                } footer: {
                    Text(L.settingsRecordsSessionsHint)
                }
                if let session = self.selectedSession {
                    Section(L.settingsRecordsDetailsTitle) {
                        LabeledContent(L.settingsRecordsSessionIDTitle, value: session.sessionID)
                        LabeledContent(L.settingsRecordsModelTitle, value: session.modelID)
                        LabeledContent(L.settingsRecordsStartedAtTitle,
                                       value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent(L.settingsRecordsLastActivityTitle,
                                       value: session.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent(L.settingsRecordsTotalTokensTitle, value: "\(session.totalTokens)")
                    }
                    .textSelection(.enabled)
                }
                SettingsRecordsModelsSection(recordsModel: self.recordsModel)
                if self.recordsModel.snapshot?.warnings.isEmpty == false {
                    SettingsRecordsWarningsSection(recordsModel: self.recordsModel)
                }
            } else {
                Section {
                    Text(L.settingsRecordsEmptyState).foregroundStyle(.secondary)
                    Button(L.settingsRecordsRetryAction, action: self.recordsModel.retryLoad)
                }
            }
            Section {
                DisclosureGroup(L.settingsDetails) {
                    Text(L.settingsRecordsPageHint).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { self.recordsModel.pageDidAppear() }
    }
}

private struct SettingsRecordsSessionTable: View {
    let sessions: [HistoricalSessionRecord]
    @Binding var selection: String?

    var body: some View {
        // Table 使用系统虚拟化行；Form 只布局一个有限高度的表格。
        Table(self.sessions, selection: self.$selection) {
            TableColumn(L.settingsRecordsSessionIDTitle) { session in
                Text(session.sessionID).font(.body.monospaced())
                    .lineLimit(1).truncationMode(.middle).help(session.sessionID)
            }
            .width(min: 150, ideal: 220)
            TableColumn(L.settingsRecordsModelTitle, value: \.modelID)
                .width(min: 100, ideal: 140)
            TableColumn(L.settingsRecordsStatusTitle) { session in
                Text(session.isArchived ? L.settingsRecordsArchivedBadge : L.settingsRecordsCurrentBadge)
                    .foregroundStyle(.secondary)
            }
            .width(70)
        }
        .overlay {
            if self.sessions.isEmpty {
                Text(L.settingsRecordsNoSearchResults).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsRecordsToolbar: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    let onOpenUsage: () -> Void

    var body: some View {
        TextField(L.settingsRecordsSearchPlaceholder, text: self.$recordsModel.searchText,
                  prompt: Text(L.settingsRecordsSearchPlaceholder))
            .labelsHidden()
            .accessibilityLabel(L.settingsRecordsSearchPlaceholder)
        HStack {
            Button(L.settingsRecordsRefreshAction) { self.recordsModel.refreshAll() }
                .disabled(self.recordsModel.isRefreshingAll)
            Button(L.settingsRecordsGoToUsageAction, action: self.onOpenUsage)
        }
    }
}

private struct SettingsRecordsOverview: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        Section {
            metric(L.settingsRecordsSessionsMetric, value: self.recordsModel.filteredSessions.count,
                   detail: self.recordsModel.filteredSessions.count == self.recordsModel.snapshot?.sessions.count
                   ? L.settingsRecordsAllResults
                   : L.settingsRecordsFilteredResults(self.recordsModel.filteredSessions.count,
                                                     total: self.recordsModel.snapshot?.sessions.count ?? 0))
            metric(L.settingsRecordsModelsMetric, value: self.recordsModel.filteredModels.count,
                   detail: L.settingsRecordsActiveModelsFootnote)
            metric(L.settingsRecordsArchivedMetric, value: self.recordsModel.archivedSessionCount,
                   detail: L.settingsRecordsActiveArchivedFootnote(self.recordsModel.activeSessionCount))
        }
    }

    private func metric(_ title: String, value: Int, detail: String) -> some View {
        LabeledContent {
            Text("\(value)").monospacedDigit()
        } label: {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsRecordsModelsSection: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        Section {
            DisclosureGroup(L.settingsRecordsModelsTitle, isExpanded: self.$recordsModel.isModelsSummaryExpanded) {
                if self.recordsModel.filteredModels.isEmpty {
                    Text(L.settingsRecordsModelsEmpty).foregroundStyle(.secondary)
                } else {
                    ForEach(self.recordsModel.filteredModels) { model in
                        LabeledContent {
                            Text(model.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(model.modelID).textSelection(.enabled)
                            Text(L.settingsRecordsModelSummary(model.sessionCount))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } footer: {
            Text(L.settingsRecordsModelsHint)
        }
    }
}

private struct SettingsRecordsWarningsSection: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        if let warnings = self.recordsModel.snapshot?.warnings {
            Section {
                DisclosureGroup(L.settingsRecordsWarningsTitle(warnings.count), isExpanded: self.$recordsModel.isWarningsExpanded) {
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading) {
                            Label(warning.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(warning.sessionFilePath).font(.callout.monospaced())
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } footer: {
                Text(L.settingsRecordsWarningsHint)
            }
        }
    }
}
