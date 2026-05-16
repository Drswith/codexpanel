import Foundation
import XCTest

final class SessionLogStoreRecordsSnapshotTests: CodexPanelTestCase {
    private final class DiagnosticsSink {
        private let lock = NSLock()
        private var values: [(type: String, fields: [String: Any])] = []

        func record(type: String, fields: [String: Any]) {
            self.lock.lock()
            self.values.append((type: type, fields: fields))
            self.lock.unlock()
        }

        func events() -> [(type: String, fields: [String: Any])] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }
    }

    func testHistoricalModelsRefreshSessionCacheIncludesNewSessionModel() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { type, fields in
            sink.record(type: type, fields: fields)
        }

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: true), ["gpt-5.4"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 50,
            cachedInputTokens: 0,
            outputTokens: 10
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: false), ["gpt-5.4"])
        XCTAssertEqual(
            store.historicalModels(refreshSessionCache: true),
            ["google/gemini-2.5-pro", "gpt-5.4"]
        )
    }

    func testReduceBillableEventsRefreshSessionCacheRebuildsLedgerForNewSessionFiles() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(
            home: home,
            billableCostCalculator: { _, usage, _ in
                Double(usage.totalTokens)
            }
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha"]
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: false),
            ["alpha"]
        )
        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha", "beta"]
        )
    }

    func testLoadRecordsSourceSnapshotCapturesWarnings() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sink = DiagnosticsSink()
        let store = self.makeStore(
            home: home,
            recordsDiagnosticsRecorder: { type, fields in
                sink.record(type: type, fields: fields)
            }
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "valid.jsonl",
            id: "valid",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let incompleteURL = codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("incomplete.jsonl")
        let incompleteContent = [
            #"{"payload":{"type":"session_meta","id":"broken","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":90,"cached_input_tokens":10,"output_tokens":10}}}"#,
        ].joined(separator: "\n") + "\n"
        try incompleteContent.write(to: incompleteURL, atomically: true, encoding: .utf8)

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)

        XCTAssertEqual(snapshot.refreshMode, .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["valid"])
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].sessionFilePath.hasSuffix("/incomplete.jsonl"))
        XCTAssertEqual(snapshot.warnings[0].kind, .incompleteSessionRecord)
    }

    func testRebuildAllReturnsFreshRecordsSourceSnapshot() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let firstSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(firstSnapshot.sessions.map(\.sessionID), ["alpha"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        let rebuiltSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)

        XCTAssertEqual(rebuiltSnapshot.refreshMode, .rebuildAll)
        XCTAssertEqual(rebuiltSnapshot.sessions.map(\.sessionID), ["beta", "alpha"])
        XCTAssertEqual(
            rebuiltSnapshot.sessions.map(\.modelID),
            ["google/gemini-2.5-pro", "gpt-5.4"]
        )
    }

    func testLoadRecordsSourceSnapshotRecordsDiagnosticsWithStats() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sink = DiagnosticsSink()
        let store = self.makeStore(
            home: home,
            recordsDiagnosticsRecorder: { type, fields in
                sink.record(type: type, fields: fields)
            }
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        _ = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)

        let events = sink.events()
        let started = try XCTUnwrap(events.first { $0.type == "records_snapshot_load_started" })
        let finished = try XCTUnwrap(events.first { $0.type == "records_snapshot_load_finished" })

        XCTAssertEqual(started.fields["refreshMode"] as? String, "incremental")
        XCTAssertEqual(finished.fields["refreshMode"] as? String, "incremental")
        XCTAssertEqual(finished.fields["fileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["cacheHitCount"] as? Int, 0)
        XCTAssertEqual(finished.fields["parsedFileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["changedFileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["warningCount"] as? Int, 0)
        XCTAssertGreaterThan((finished.fields["totalBytes"] as? Int) ?? 0, 0)
    }

    private func billableSessionIDs(from store: SessionLogStore, refreshSessionCache: Bool) -> [String] {
        store.reduceBillableEvents(into: Set<String>(), refreshSessionCache: refreshSessionCache) { partialResult, event in
            partialResult.insert(event.sessionID)
        }
        .sorted()
    }

    private func makeCodexHome() throws -> URL {
        let home = try XCTUnwrap(self.temporaryHomeURL())
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func temporaryHomeURL() -> URL? {
        let home = ProcessInfo.processInfo.environment["CODEXPANEL_HOME"]
        guard let home, home.isEmpty == false else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func makeStore(
        home: URL,
        recordsDiagnosticsRecorder: @escaping (String, [String: Any]) -> Void = { _, _ in },
        billableCostCalculator: @escaping (String, SessionLogStore.Usage, SessionLogStore.Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) -> SessionLogStore {
        SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: home.appendingPathComponent(".codexpanel/test-records-session-cache.json"),
            persistedUsageLedgerURL: home.appendingPathComponent(".codexpanel/test-records-ledger.json"),
            recordsDiagnosticsRecorder: recordsDiagnosticsRecorder,
            billableCostCalculator: billableCostCalculator
        )
    }

    private func writeFastSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(cachedInputTokens),"output_tokens":\#(outputTokens)}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

}
