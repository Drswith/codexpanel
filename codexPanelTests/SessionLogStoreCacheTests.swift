import Foundation
import XCTest

final class SessionLogStoreCacheTests: CodexPanelTestCase {
    func testLifecycleRefreshReadsOnlyAppendAndKeepsInactiveSessionCursor() throws {
        let home = try self.makeCodexHome()
        let file = home.appendingPathComponent(".codex/sessions/alpha.jsonl")
        let initial = self.lifecycleSession(id: "alpha") + String(repeating: "{}\n", count: 350_000)
        try Data(initial.utf8).write(to: file)
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
        XCTAssertEqual(store.currentSessionLifecycleRecords(matchingSessionIDs: ["alpha"]).first?.taskLifecycleState, .running)
        XCTAssertEqual(store.currentSessionLifecycleRecords(matchingSessionIDs: ["alpha"]).count, 1)
        XCTAssertEqual(sink.events().filter { $0.type == "session_lifecycle_scanned" }.count, 1)
        XCTAssertTrue(store.currentSessionLifecycleRecords(matchingSessionIDs: ["other"]).isEmpty)

        let appended = #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"
        try self.append(Data(appended.utf8), to: file)
        XCTAssertEqual(store.currentSessionLifecycleRecords(matchingSessionIDs: ["alpha"]).first?.taskLifecycleState, .completed)
        let event = try XCTUnwrap(sink.events().last)
        XCTAssertEqual(event.fields["incremental"] as? Bool, true)
        XCTAssertEqual(event.fields["parsedBytes"] as? Int64, Int64(appended.utf8.count))
    }

    func testLifecycleRefreshRetainsPartialUTF8LineUntilCompleted() throws {
        let home = try self.makeCodexHome()
        let file = home.appendingPathComponent(".codex/sessions/alpha.jsonl")
        try Data(self.lifecycleSession(id: "alpha").utf8).write(to: file)
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.taskLifecycleState, .running)
        let line = Data((#"{"type":"event_msg","payload":{"type":"task_complete","message":"完成"}}"# + "\n").utf8)
        let split = try XCTUnwrap(line.firstIndex(of: 0xE5)) + 1
        try self.append(line.prefix(split), to: file)
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.taskLifecycleState, .running)
        XCTAssertEqual(sink.events().last?.fields["parsedBytes"] as? Int64, 0)
        try self.append(line.suffix(from: split), to: file)
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.taskLifecycleState, .completed)
        XCTAssertEqual(sink.events().last?.fields["incremental"] as? Bool, true)
        XCTAssertEqual(sink.events().last?.fields["parsedBytes"] as? Int64, Int64(line.count))
    }

    func testLifecycleRefreshRebuildsAfterTruncationReplacementAndRewrite() throws {
        let home = try self.makeCodexHome()
        let file = home.appendingPathComponent(".codex/sessions/alpha.jsonl")
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
        try Data((self.lifecycleSession(id: "alpha") + String(repeating: "{}\n", count: 100)).utf8).write(to: file)
        _ = store.currentSessionLifecycleRecords()
        // 同 inode 截断。
        let truncated = Data(self.lifecycleSession(id: "short", state: "task_complete").utf8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: truncated)
        try handle.close()
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.id, "short")
        XCTAssertEqual(sink.events().last?.fields["incremental"] as? Bool, false)

        // 原子替换为更大的文件。
        let replacement = self.lifecycleSession(id: "replacement") + String(repeating: "{}\n", count: 200)
        try Data(replacement.utf8).write(to: file, options: .atomic)
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.id, "replacement")
        XCTAssertEqual(sink.events().last?.fields["incremental"] as? Bool, false)

        // 同 inode 改写头部后追加，头尾校验必须拒绝旧游标。
        let rewritten = replacement.replacingOccurrences(of: "replacement", with: "rewrittenxx") + "{}\n"
        let rewriteHandle = try FileHandle(forWritingTo: file)
        try rewriteHandle.write(contentsOf: Data(rewritten.utf8))
        try rewriteHandle.close()
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.id, "rewrittenxx")
        XCTAssertEqual(sink.events().last?.fields["incremental"] as? Bool, false)
    }

    func testLifecycleRefreshReusesCompleteUsageCacheCursor() throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions")
        try self.writeFastSession(directory: directory, fileName: "alpha.jsonl", id: "alpha",
            timestamp: "2026-04-21T08:00:00Z", model: "gpt-5.5", inputTokens: 1, cachedInputTokens: 0, outputTokens: 1)
        let sink = DiagnosticsSink()
        let store = self.makeStore(home: home) { sink.record(type: $0, fields: $1) }
        _ = store.sessionRecords()
        XCTAssertEqual(store.currentSessionLifecycleRecords().count, 1)
        XCTAssertFalse(sink.events().contains { $0.type == "session_lifecycle_scanned" })
        try self.append(Data((#"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n").utf8), to: directory.appendingPathComponent("alpha.jsonl"))
        XCTAssertEqual(store.currentSessionLifecycleRecords().first?.taskLifecycleState, .completed)
        XCTAssertEqual(sink.events().last?.fields["incremental"] as? Bool, true)
    }

    private func lifecycleSession(id: String, state: String = "task_started") -> String {
        [
            #"{"type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-10-29T07:00:00Z"}}"#,
            #"{"type":"event_msg","payload":{"type":"\#(state)"}}"#,
        ].joined(separator: "\n") + "\n"
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

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
