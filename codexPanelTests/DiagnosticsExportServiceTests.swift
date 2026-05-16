import XCTest

final class DiagnosticsExportServiceTests: XCTestCase {
    private var rootDirectory: URL!
    private var crashReportsDirectory: URL!
    private var diagnosticsDirectory: URL!
    private var archiveSpy: ArchiveSpy!

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        self.rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("codexpanel-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        self.crashReportsDirectory = self.rootDirectory.appendingPathComponent("DiagnosticReports", isDirectory: true)
        self.diagnosticsDirectory = self.rootDirectory.appendingPathComponent(".codexpanel", isDirectory: true)
        try fileManager.createDirectory(at: self.crashReportsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.diagnosticsDirectory, withIntermediateDirectories: true)
        self.archiveSpy = ArchiveSpy(snapshotDirectory: self.rootDirectory.appendingPathComponent("archive-snapshot", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func testScanFindsMostRecentMatchingCrashReportsAndArtifacts() throws {
        let latestCrash = self.crashReportsDirectory.appendingPathComponent("Codex Panel-latest.crash")
        let contentMatchedCrash = self.crashReportsDirectory.appendingPathComponent("mystery.ips")
        let unrelatedCrash = self.crashReportsDirectory.appendingPathComponent("OtherApp.ips")
        let lifecycleLog = self.diagnosticsDirectory.appendingPathComponent("app-lifecycle.jsonl")
        let lifecycleState = self.diagnosticsDirectory.appendingPathComponent("app-lifecycle-state.json")

        try "latest".write(to: latestCrash, atomically: true, encoding: .utf8)
        try "Process: Codex Panel\nIdentifier: com.codexpanel".write(to: contentMatchedCrash, atomically: true, encoding: .utf8)
        try "Process: Other App".write(to: unrelatedCrash, atomically: true, encoding: .utf8)
        try "{}\n".write(to: lifecycleLog, atomically: true, encoding: .utf8)
        try #"{"sessionID":"abc"}"#.write(to: lifecycleState, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3)],
            ofItemAtPath: latestCrash.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: contentMatchedCrash.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4)],
            ofItemAtPath: unrelatedCrash.path
        )

        let service = self.makeService()
        let scanResult = service.scan(maxCrashReports: 2)

        XCTAssertEqual(scanResult.crashReports.map(\.fileName), [
            "Codex Panel-latest.crash",
            "mystery.ips",
        ])
        XCTAssertEqual(scanResult.lifecycleLog?.fileName, "app-lifecycle.jsonl")
        XCTAssertEqual(scanResult.lifecycleState?.fileName, "app-lifecycle-state.json")
    }

    func testExportArchiveWritesManifestAndRedactedLifecycleLog() throws {
        let crashReport = self.crashReportsDirectory.appendingPathComponent("Codex Panel-latest.ips")
        let lifecycleLog = self.diagnosticsDirectory.appendingPathComponent("app-lifecycle.jsonl")
        let lifecycleState = self.diagnosticsDirectory.appendingPathComponent("app-lifecycle-state.json")

        try "Process: Codex Panel".write(to: crashReport, atomically: true, encoding: .utf8)
        try """
{"type":"refresh","accountID":"acct-1","providerID":"prov-1","helperPath":"\(self.rootDirectory.path)/helper","downloadURL":"https://example.com/archive","access_token":"secret-token","sessionID":"session-1","recordedAt":"2026-05-16T13:00:00Z"}
""".write(to: lifecycleLog, atomically: true, encoding: .utf8)
        try #"{"sessionID":"session-1","cleanExit":false}"#.write(to: lifecycleState, atomically: true, encoding: .utf8)

        let service = self.makeService()
        let exportDestination = self.rootDirectory.appendingPathComponent("diagnostics-export")
        let result = try service.exportArchive(to: exportDestination)

        XCTAssertEqual(result.archiveURL.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archiveURL.path))
        XCTAssertEqual(result.missingArtifacts, [])

        let snapshotDirectory = self.archiveSpy.snapshotDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotDirectory.path))

        let manifestURL = snapshotDirectory.appendingPathComponent("manifest.json")
        let readmeURL = snapshotDirectory.appendingPathComponent("README.txt")
        let redactedLifecycleURL = snapshotDirectory.appendingPathComponent("app-lifecycle.redacted.jsonl")
        let copiedStateURL = snapshotDirectory.appendingPathComponent("app-lifecycle-state.json")
        let copiedCrashURL = snapshotDirectory.appendingPathComponent("Codex Panel-latest.ips")

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readmeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: redactedLifecycleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedCrashURL.path))

        let redactedLifecycleText = try String(contentsOf: redactedLifecycleURL, encoding: .utf8)
        XCTAssertFalse(redactedLifecycleText.contains("acct-1"))
        XCTAssertFalse(redactedLifecycleText.contains("prov-1"))
        XCTAssertFalse(redactedLifecycleText.contains("secret-token"))
        XCTAssertFalse(redactedLifecycleText.contains(self.rootDirectory.path))
        XCTAssertFalse(redactedLifecycleText.contains("https://example.com/archive"))
        XCTAssertTrue(redactedLifecycleText.contains("<redacted>"))
        XCTAssertTrue(redactedLifecycleText.contains("<redacted-path>"))
        XCTAssertTrue(redactedLifecycleText.contains("<redacted-url>"))
        XCTAssertTrue(redactedLifecycleText.contains("session-1"))

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        XCTAssertEqual(manifest.includedFiles.map(\.kind), [
            "crash_report",
            "lifecycle_log",
            "lifecycle_state",
        ])
        XCTAssertEqual(manifest.missingArtifacts, [])
    }

    func testExportArchiveStillProducesManifestWhenCrashReportMissing() throws {
        let service = self.makeService()
        let result = try service.exportArchive(to: self.rootDirectory.appendingPathComponent("empty-export.zip"))

        XCTAssertEqual(result.missingArtifacts, [.crashReport, .lifecycleLog, .lifecycleState])

        let manifestURL = self.archiveSpy.snapshotDirectory
            .appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(Set(manifest.missingArtifacts), Set([
            "crash_report",
            "lifecycle_log",
            "lifecycle_state",
        ]))
    }

    private func makeService() -> DiagnosticsExportService {
        DiagnosticsExportService(
            fileManager: .default,
            crashReportsDirectoryURL: self.crashReportsDirectory,
            lifecycleLogURL: self.diagnosticsDirectory.appendingPathComponent("app-lifecycle.jsonl"),
            lifecycleStateURL: self.diagnosticsDirectory.appendingPathComponent("app-lifecycle-state.json"),
            temporaryRootURL: self.rootDirectory,
            homeDirectoryURL: self.rootDirectory,
            now: { Date(timeIntervalSince1970: 1_715_856_000) },
            appVersionProvider: { "1.2.3" },
            osVersionProvider: { "macOS Test" },
            archiver: self.archiveSpy
        )
    }
}

private final class ArchiveSpy: DiagnosticsArchiveCreating {
    let snapshotDirectory: URL

    init(snapshotDirectory: URL) {
        self.snapshotDirectory = snapshotDirectory
    }

    func createArchive(from sourceDirectoryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: self.snapshotDirectory.path) {
            try fileManager.removeItem(at: self.snapshotDirectory)
        }
        try fileManager.copyItem(at: sourceDirectoryURL, to: self.snapshotDirectory)
        try Data("archive".utf8).write(to: destinationURL)
    }
}

private struct Manifest: Decodable {
    struct Entry: Decodable {
        let kind: String
        let fileName: String
        let redacted: Bool
    }

    let includedFiles: [Entry]
    let missingArtifacts: [String]
}
