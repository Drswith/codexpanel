import Foundation

enum RecordsRefreshMode: String, Codable, Equatable, Sendable {
    case incremental
    case rebuildAll
}

enum RecordsSnapshotWarningKind: String, Codable, Equatable, Sendable {
    case unreadableSessionFile
    case incompleteSessionRecord
}

struct RecordsSnapshotWarning: Codable, Equatable, Identifiable, Sendable {
    let sessionFilePath: String
    let kind: RecordsSnapshotWarningKind
    let message: String

    var id: String {
        "\(self.kind.rawValue)|\(self.sessionFilePath)|\(self.message)"
    }
}

struct HistoricalModelRecord: Codable, Equatable, Identifiable, Sendable {
    let modelID: String
    let sessionCount: Int
    let lastSeenAt: Date

    var id: String { self.modelID }
}

struct HistoricalSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let modelID: String
    let startedAt: Date
    let lastActivityAt: Date
    let isArchived: Bool
    let totalTokens: Int

    var id: String { self.sessionID }
}

struct RecordsSourceSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

struct RecordsSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let models: [HistoricalModelRecord]
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

protocol RecordsSourceSnapshotLoading: Sendable {
    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot
}

protocol RecordsSnapshotServing: Sendable {
    func loadCached() async -> RecordsSnapshot?
    func loadCurrent() async throws -> RecordsSnapshot
    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot
}

enum RecordsSnapshotServiceError: LocalizedError, Equatable {
    case requestSuperseded
    case timedOut(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestSuperseded:
            return "Records request was superseded by a newer request."
        case .timedOut(let timeout):
            let seconds = String(format: "%.1f", timeout)
            return "Records refresh timed out after \(seconds) seconds."
        }
    }
}

struct RecordsSnapshotService: RecordsSnapshotServing {
    private struct PersistedSnapshotPayload: Codable {
        let version: Int
        let generatedAt: Date
        let refreshMode: RecordsRefreshMode
        let sessions: [HistoricalSessionRecord]
        let warnings: [RecordsSnapshotWarning]
    }

    private let persistedSnapshotVersion = 1
    private let sourceLoader: any RecordsSourceSnapshotLoading
    private let requestCoordinator: RecordsSnapshotRequestCoordinator
    private let snapshotCacheURL: URL

    init(
        sourceLoader: any RecordsSourceSnapshotLoading = SessionLogStore.shared,
        requestCoordinator: RecordsSnapshotRequestCoordinator = RecordsSnapshotRequestCoordinator(),
        snapshotCacheURL: URL = CodexPaths.recordsSnapshotCacheURL
    ) {
        self.sourceLoader = sourceLoader
        self.requestCoordinator = requestCoordinator
        self.snapshotCacheURL = snapshotCacheURL
    }

    func loadCached() async -> RecordsSnapshot? {
        guard let data = try? Data(contentsOf: self.snapshotCacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PersistedSnapshotPayload.self, from: data),
              payload.version == self.persistedSnapshotVersion else {
            return nil
        }
        return RecordsSnapshot(
            generatedAt: payload.generatedAt,
            refreshMode: payload.refreshMode,
            models: Self.models(from: payload.sessions),
            sessions: payload.sessions.sorted(by: Self.shouldSortSessionsBefore),
            warnings: payload.warnings.sorted(by: Self.shouldSortWarningsBefore)
        )
    }

    func loadCurrent() async throws -> RecordsSnapshot {
        let snapshot = try await self.requestCoordinator.runRequest(
            refreshMode: .incremental,
            timeout: nil,
            sourceLoader: self.sourceLoader,
            makeSnapshot: Self.makeSnapshot(from:)
        )
        self.persistCached(snapshot)
        return snapshot
    }

    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot {
        let snapshot = try await self.requestCoordinator.runRequest(
            refreshMode: .rebuildAll,
            timeout: max(0, timeout),
            sourceLoader: self.sourceLoader,
            makeSnapshot: Self.makeSnapshot(from:)
        )
        self.persistCached(snapshot)
        return snapshot
    }

    private func persistCached(_ snapshot: RecordsSnapshot) {
        let payload = PersistedSnapshotPayload(
            version: self.persistedSnapshotVersion,
            generatedAt: snapshot.generatedAt,
            refreshMode: snapshot.refreshMode,
            sessions: snapshot.sessions,
            warnings: snapshot.warnings
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: self.snapshotCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? CodexPaths.writeSecureFile(data, to: self.snapshotCacheURL)
    }

    private nonisolated static func makeSnapshot(from sourceSnapshot: RecordsSourceSnapshot) -> RecordsSnapshot {
        RecordsSnapshot(
            generatedAt: sourceSnapshot.generatedAt,
            refreshMode: sourceSnapshot.refreshMode,
            models: Self.models(from: sourceSnapshot.sessions),
            sessions: sourceSnapshot.sessions.sorted(by: Self.shouldSortSessionsBefore),
            warnings: sourceSnapshot.warnings.sorted(by: Self.shouldSortWarningsBefore)
        )
    }

    private nonisolated static func models(from sessions: [HistoricalSessionRecord]) -> [HistoricalModelRecord] {
        let groupedSessions = Dictionary(grouping: sessions, by: \.modelID)
        return groupedSessions.map { modelID, groupedRecords in
            HistoricalModelRecord(
                modelID: modelID,
                sessionCount: groupedRecords.count,
                lastSeenAt: groupedRecords.map(\.lastActivityAt).max() ?? .distantPast
            )
        }
        .sorted(by: Self.shouldSortModelsBefore)
    }

    private nonisolated static func shouldSortSessionsBefore(
        _ lhs: HistoricalSessionRecord,
        _ rhs: HistoricalSessionRecord
    ) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.sessionID < rhs.sessionID
    }

    private nonisolated static func shouldSortModelsBefore(
        _ lhs: HistoricalModelRecord,
        _ rhs: HistoricalModelRecord
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        if lhs.sessionCount != rhs.sessionCount {
            return lhs.sessionCount > rhs.sessionCount
        }
        return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
    }

    private nonisolated static func shouldSortWarningsBefore(
        _ lhs: RecordsSnapshotWarning,
        _ rhs: RecordsSnapshotWarning
    ) -> Bool {
        if lhs.sessionFilePath != rhs.sessionFilePath {
            return lhs.sessionFilePath < rhs.sessionFilePath
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.message < rhs.message
    }
}

actor RecordsSnapshotRequestCoordinator: Sendable {
    private var latestRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
    private var activeTask: Task<RecordsSnapshot, Error>?

    func runRequest(
        refreshMode: RecordsRefreshMode,
        timeout: TimeInterval?,
        sourceLoader: any RecordsSourceSnapshotLoading,
        makeSnapshot: @escaping @Sendable (RecordsSourceSnapshot) -> RecordsSnapshot
    ) async throws -> RecordsSnapshot {
        self.latestRequestID &+= 1
        let requestID = self.latestRequestID

        self.activeTask?.cancel()

        let task = Task<RecordsSnapshot, Error> {
            let sourceSnapshot = try await sourceLoader.loadRecordsSourceSnapshot(refreshMode: refreshMode)
            return makeSnapshot(sourceSnapshot)
        }

        self.activeRequestID = requestID
        self.activeTask = task

        do {
            let snapshot = try await self.resolve(task, timeout: timeout)
            guard self.activeRequestID == requestID else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }
            self.clearActiveRequest(ifMatching: requestID)
            return snapshot
        } catch {
            if error is CancellationError {
                if self.activeRequestID == requestID {
                    self.clearActiveRequest(ifMatching: requestID)
                }
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            if self.activeRequestID == requestID {
                self.clearActiveRequest(ifMatching: requestID)
            }
            throw error
        }
    }

    private func clearActiveRequest(ifMatching requestID: UInt64) {
        guard self.activeRequestID == requestID else { return }
        self.activeRequestID = nil
        self.activeTask = nil
    }

    private func resolve(
        _ task: Task<RecordsSnapshot, Error>,
        timeout: TimeInterval?
    ) async throws -> RecordsSnapshot {
        guard let timeout else {
            return try await task.value
        }

        let clampedTimeout = max(0, timeout)
        return try await withThrowingTaskGroup(of: Result<RecordsSnapshot, Error>.self) { group in
            group.addTask {
                do {
                    return .success(try await task.value)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                if clampedTimeout > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                }
                return .failure(RecordsSnapshotServiceError.timedOut(timeout: clampedTimeout))
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            switch first {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                if case RecordsSnapshotServiceError.timedOut = error {
                    task.cancel()
                }
                throw error
            }
        }
    }
}
