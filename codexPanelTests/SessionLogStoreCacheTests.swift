import Foundation
import XCTest

final class SessionLogStoreCacheTests: CodexPanelTestCase {
    func testPersistedCacheReusesUnchangedFileAndUpgradesLegacyMilliseconds() throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions")
        try self.writeFastSession(directory: directory, fileName: "stable.jsonl", id: "stable",
            timestamp: "2026-04-21T08:00:00Z", model: "gpt-5.5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
        let file = directory.appendingPathComponent("stable.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_777_000_000.123456)], ofItemAtPath: file.path)
        _ = self.makeStore(home: home).sessionRecords()

        let cacheURL = home.appendingPathComponent(".codexpanel/test-session-cache.json")
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        let cacheKey = try XCTUnwrap(files.keys.first)
        var record = try XCTUnwrap(files[cacheKey])
        var fingerprint = try XCTUnwrap(record["fingerprint"] as? [String: Any])
        fingerprint.removeValue(forKey: "modificationDateReferenceTime")
        record["fingerprint"] = fingerprint; files[cacheKey] = record; cache["files"] = files
        try JSONSerialization.data(withJSONObject: cache).write(to: cacheURL)

        for _ in 0..<2 {
            let sink = DiagnosticsSink()
            let store = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
            let snapshot = store.sessionRecords()
            XCTAssertEqual(snapshot.first?.usage.totalTokens, 120)
            let event = try XCTUnwrap(sink.events().last { $0.type == "session_cache_refreshed" })
            XCTAssertEqual(event.fields["cacheHitCount"] as? Int, 1)
            XCTAssertEqual(event.fields["fullParsedFileCount"] as? Int, 0)
        }
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        let upgradedFiles = try XCTUnwrap(upgraded["files"] as? [String: [String: Any]])
        let upgradedFingerprint = try XCTUnwrap(upgradedFiles[cacheKey]?["fingerprint"] as? [String: Any])
        XCTAssertNotNil(upgradedFingerprint["modificationDateReferenceTime"] as? Double)
    }

    func testPersistedPreciseFingerprintDetectsSameSizeRewriteWithinMillisecond() throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions")
        try self.writeFastSession(directory: directory, fileName: "changed.jsonl", id: "changed",
            timestamp: "2026-04-21T08:00:00Z", model: "gpt-5.5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 20)
        let file = directory.appendingPathComponent("changed.jsonl")
        let firstDate = Date(timeIntervalSince1970: 1_777_000_000.1231)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: file.path)
        _ = self.makeStore(home: home).sessionRecords()
        let data = try String(contentsOf: file).replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":200")
        // 原地、等长重写，保留文件身份；修改时间只增加 0.2 ms。
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(data.utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: firstDate.addingTimeInterval(0.0002)], ofItemAtPath: file.path)
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
        let snapshot = store.sessionRecords()
        XCTAssertEqual(snapshot.first?.usage.totalTokens, 220)
        let event = try XCTUnwrap(sink.events().last { $0.type == "session_cache_refreshed" })
        XCTAssertEqual(event.fields["fullParsedFileCount"] as? Int, 1)
        XCTAssertEqual(event.fields["incrementallyParsedFileCount"] as? Int, 0)
    }

    func testConstructingStoreDefersCacheRestorationUntilFirstQuery() throws {
        let home = try self.makeCodexHome()
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { type, fields in
            sink.record(type: type, fields: fields)
        }
        XCTAssertFalse(sink.events().contains { $0.type == "session_cache_restored" })
        _ = store.historicalModels()
        _ = store.historicalModels()
        XCTAssertEqual(sink.events().filter { $0.type == "session_cache_restored" }.count, 1)
    }

    func testPersistedDatesPreserveLegacySecondsFractionsAndOffsets() throws {
        for value in ["2026-10-13T05:56:53Z", "2026-10-13T05:56:53.123Z", "2026-10-13T13:56:53.123+08:00"] {
            let expected = try XCTUnwrap(ISO8601Parsing.parse(value))
            let actual = try XCTUnwrap(SessionLogStore.parsePersistedDate(value))
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000_001)
        }
        XCTAssertNil(SessionLogStore.parsePersistedDate("invalid"))
    }

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
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: true), ["gpt-5.5"])

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

        XCTAssertEqual(store.historicalModels(refreshSessionCache: false), ["gpt-5.5"])
        XCTAssertEqual(
            store.historicalModels(refreshSessionCache: true),
            ["google/gemini-2.5-pro", "gpt-5.5"]
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
            model: "gpt-5.5",
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




    func testIncrementalRefreshParsesOnlyAppendedSessionLines() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sink = DiagnosticsSink()
        let store = self.makeStore(
            home: home,
            diagnosticsRecorder: { type, fields in
                sink.record(type: type, fields: fields)
            }
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let firstSnapshot = store.sessionRecords()
        XCTAssertEqual(firstSnapshot.first?.usage.totalTokens, 120)

        let sessionURL = codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("alpha.jsonl")
        let appendedLine = #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":150,"cached_input_tokens":20,"output_tokens":50}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()

        // 重启服务后仍只读取追加内容。
        let reloaded = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
        let appendedSnapshot = reloaded.sessionRecords()
        XCTAssertEqual(appendedSnapshot.first?.usage.totalTokens, 200)

        let finished = try XCTUnwrap(
            sink.events().last { $0.type == "session_cache_refreshed" }
        )
        XCTAssertEqual(finished.fields["fileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["fullParsedFileCount"] as? Int, 0)
        XCTAssertEqual(finished.fields["incrementallyParsedFileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["parsedBytes"] as? Int64, Int64(appendedLine.utf8.count))
    }

    func testChangedSessionFileFallsBackToFullParse() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sink = DiagnosticsSink()
        let store = self.makeStore(
            home: home,
            diagnosticsRecorder: { type, fields in
                sink.record(type: type, fields: fields)
            }
        )

        let sessionsDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try self.writeFastSession(
            directory: sessionsDirectory,
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )
        _ = store.sessionRecords()

        try self.writeFastSession(
            directory: sessionsDirectory,
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 7,
            cachedInputTokens: 1,
            outputTokens: 3
        )

        let rebuiltSnapshot = store.sessionRecords()
        XCTAssertEqual(rebuiltSnapshot.first?.usage.totalTokens, 10)

        let finished = try XCTUnwrap(
            sink.events().last { $0.type == "session_cache_refreshed" }
        )
        XCTAssertEqual(finished.fields["fileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["fullParsedFileCount"] as? Int, 1)
        XCTAssertEqual(finished.fields["incrementallyParsedFileCount"] as? Int, 0)
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
        diagnosticsRecorder: @escaping (String, [String: Any]) -> Void = { _, _ in },
        billableCostCalculator: @escaping (String, SessionLogStore.Usage, SessionLogStore.Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) -> SessionLogStore {
        SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: home.appendingPathComponent(".codexpanel/test-session-cache.json"),
            persistedUsageLedgerURL: home.appendingPathComponent(".codexpanel/test-ledger.json"),
            diagnosticsRecorder: diagnosticsRecorder,
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
