import Foundation

protocol DiagnosticsArchiveCreating {
    func createArchive(from sourceDirectoryURL: URL, to destinationURL: URL) throws
}

struct DiagnosticsArtifactDescriptor: Equatable, Identifiable {
    enum Kind: String, Codable {
        case crashReport = "crash_report"
        case lifecycleLog = "lifecycle_log"
        case lifecycleState = "lifecycle_state"
    }

    let kind: Kind
    let url: URL
    let modifiedAt: Date?
    let sizeBytes: Int64?

    var id: String { self.url.path }
    var fileName: String { self.url.lastPathComponent }
}

struct DiagnosticsScanResult: Equatable {
    let scannedAt: Date
    let crashReports: [DiagnosticsArtifactDescriptor]
    let lifecycleLog: DiagnosticsArtifactDescriptor?
    let lifecycleState: DiagnosticsArtifactDescriptor?

    var hasCrashReport: Bool { self.crashReports.isEmpty == false }
}

struct DiagnosticsExportIncludedFile: Equatable {
    let kind: DiagnosticsArtifactDescriptor.Kind
    let fileName: String
    let redacted: Bool
}

struct DiagnosticsExportResult: Equatable {
    let archiveURL: URL
    let scanResult: DiagnosticsScanResult
    let includedFiles: [DiagnosticsExportIncludedFile]
    let missingArtifacts: [DiagnosticsArtifactDescriptor.Kind]
}

enum DiagnosticsExportError: LocalizedError, Equatable {
    case prepareWorkspaceFailed(String)
    case readArtifactFailed(String)
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .prepareWorkspaceFailed(let message):
            return L.settingsDiagnosticsPrepareWorkspaceFailed(message)
        case .readArtifactFailed(let message):
            return L.settingsDiagnosticsReadArtifactFailed(message)
        case .archiveFailed(let message):
            return L.settingsDiagnosticsArchiveFailed(message)
        }
    }
}

private struct DiagnosticsExportManifest: Codable, Equatable {
    let generatedAt: String
    let appVersion: String?
    let osVersion: String
    let includedFiles: [DiagnosticsExportManifestEntry]
    let missingArtifacts: [String]
    let notes: [String]
}

private struct DiagnosticsExportManifestEntry: Codable, Equatable {
    let kind: String
    let fileName: String
    let redacted: Bool
}

struct DiagnosticsExportService {
    private let fileManager: FileManager
    private let crashReportsDirectoryURL: URL
    private let lifecycleLogURL: URL
    private let lifecycleStateURL: URL
    private let temporaryRootURL: URL
    private let homeDirectoryURL: URL
    private let now: () -> Date
    private let appVersionProvider: () -> String?
    private let osVersionProvider: () -> String
    private let archiver: any DiagnosticsArchiveCreating

    init(
        fileManager: FileManager = .default,
        crashReportsDirectoryURL: URL,
        lifecycleLogURL: URL,
        lifecycleStateURL: URL,
        temporaryRootURL: URL,
        homeDirectoryURL: URL,
        now: @escaping () -> Date = { Date() },
        appVersionProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        },
        osVersionProvider: @escaping () -> String = {
            ProcessInfo.processInfo.operatingSystemVersionString
        },
        archiver: any DiagnosticsArchiveCreating = DittoDiagnosticsArchiver()
    ) {
        self.fileManager = fileManager
        self.crashReportsDirectoryURL = crashReportsDirectoryURL
        self.lifecycleLogURL = lifecycleLogURL
        self.lifecycleStateURL = lifecycleStateURL
        self.temporaryRootURL = temporaryRootURL
        self.homeDirectoryURL = homeDirectoryURL
        self.now = now
        self.appVersionProvider = appVersionProvider
        self.osVersionProvider = osVersionProvider
        self.archiver = archiver
    }

    static func live() -> DiagnosticsExportService {
        let fileManager = FileManager.default
        let crashReportsDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return DiagnosticsExportService(
            fileManager: fileManager,
            crashReportsDirectoryURL: crashReportsDirectoryURL,
            lifecycleLogURL: CodexPaths.codexBarRoot.appendingPathComponent("app-lifecycle.jsonl"),
            lifecycleStateURL: CodexPaths.codexBarRoot.appendingPathComponent("app-lifecycle-state.json"),
            temporaryRootURL: fileManager.temporaryDirectory,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser
        )
    }

    func scan(maxCrashReports: Int = 3) -> DiagnosticsScanResult {
        DiagnosticsScanResult(
            scannedAt: self.now(),
            crashReports: self.findCrashReports(limit: maxCrashReports),
            lifecycleLog: self.describeFile(at: self.lifecycleLogURL, kind: .lifecycleLog),
            lifecycleState: self.describeFile(at: self.lifecycleStateURL, kind: .lifecycleState)
        )
    }

    func exportArchive(to destinationURL: URL, maxCrashReports: Int = 3) throws -> DiagnosticsExportResult {
        let scanResult = self.scan(maxCrashReports: maxCrashReports)
        let workspaceRootURL = self.temporaryRootURL
            .appendingPathComponent("codexpanel-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectoryURL = workspaceRootURL
            .appendingPathComponent("codexpanel-diagnostics", isDirectory: true)
        let archiveURL = self.normalizedArchiveURL(from: destinationURL)

        do {
            try self.fileManager.createDirectory(at: payloadDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw DiagnosticsExportError.prepareWorkspaceFailed(error.localizedDescription)
        }

        defer {
            try? self.fileManager.removeItem(at: workspaceRootURL)
        }

        var includedFiles: [DiagnosticsExportIncludedFile] = []

        for crashReport in scanResult.crashReports {
            let destination = payloadDirectoryURL.appendingPathComponent(crashReport.fileName)
            do {
                try self.copyItem(at: crashReport.url, to: destination)
            } catch {
                throw DiagnosticsExportError.readArtifactFailed(error.localizedDescription)
            }
            includedFiles.append(
                DiagnosticsExportIncludedFile(
                    kind: .crashReport,
                    fileName: crashReport.fileName,
                    redacted: false
                )
            )
        }

        if let lifecycleLog = scanResult.lifecycleLog {
            let redactedLogURL = payloadDirectoryURL.appendingPathComponent("app-lifecycle.redacted.jsonl")
            do {
                let sanitizedData = try self.makeSanitizedLifecycleLogData(from: lifecycleLog.url)
                try sanitizedData.write(to: redactedLogURL)
            } catch let exportError as DiagnosticsExportError {
                throw exportError
            } catch {
                throw DiagnosticsExportError.readArtifactFailed(error.localizedDescription)
            }
            includedFiles.append(
                DiagnosticsExportIncludedFile(
                    kind: .lifecycleLog,
                    fileName: redactedLogURL.lastPathComponent,
                    redacted: true
                )
            )
        }

        if let lifecycleState = scanResult.lifecycleState {
            let stateCopyURL = payloadDirectoryURL.appendingPathComponent(lifecycleState.fileName)
            do {
                try self.copyItem(at: lifecycleState.url, to: stateCopyURL)
            } catch {
                throw DiagnosticsExportError.readArtifactFailed(error.localizedDescription)
            }
            includedFiles.append(
                DiagnosticsExportIncludedFile(
                    kind: .lifecycleState,
                    fileName: stateCopyURL.lastPathComponent,
                    redacted: false
                )
            )
        }

        let missingArtifacts = self.missingArtifacts(for: scanResult)
        let manifest = self.makeManifest(
            scanResult: scanResult,
            includedFiles: includedFiles,
            missingArtifacts: missingArtifacts
        )

        do {
            let manifestData = try JSONEncoder.diagnosticsManifestEncoder.encode(manifest)
            try manifestData.write(to: payloadDirectoryURL.appendingPathComponent("manifest.json"))
            guard let readmeData = self.makeReadme(
                scanResult: scanResult,
                includedFiles: includedFiles,
                missingArtifacts: missingArtifacts
            )
            .data(using: .utf8) else {
                throw DiagnosticsExportError.prepareWorkspaceFailed("failed to encode README")
            }
            try readmeData.write(to: payloadDirectoryURL.appendingPathComponent("README.txt"))
        } catch {
            throw DiagnosticsExportError.prepareWorkspaceFailed(error.localizedDescription)
        }

        do {
            if self.fileManager.fileExists(atPath: archiveURL.path) {
                try self.fileManager.removeItem(at: archiveURL)
            }
            try self.archiver.createArchive(from: payloadDirectoryURL, to: archiveURL)
        } catch let exportError as DiagnosticsExportError {
            throw exportError
        } catch {
            throw DiagnosticsExportError.archiveFailed(error.localizedDescription)
        }

        return DiagnosticsExportResult(
            archiveURL: archiveURL,
            scanResult: scanResult,
            includedFiles: includedFiles,
            missingArtifacts: missingArtifacts
        )
    }

    private func describeFile(at url: URL, kind: DiagnosticsArtifactDescriptor.Kind) -> DiagnosticsArtifactDescriptor? {
        guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              resourceValues.isRegularFile == true else {
            return nil
        }
        let sizeBytes = resourceValues.fileSize.map(Int64.init)
        return DiagnosticsArtifactDescriptor(
            kind: kind,
            url: url,
            modifiedAt: resourceValues.contentModificationDate,
            sizeBytes: sizeBytes
        )
    }

    private func findCrashReports(limit: Int) -> [DiagnosticsArtifactDescriptor] {
        guard let urls = try? self.fileManager.contentsOfDirectory(
            at: self.crashReportsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let rankedReports: [(descriptor: DiagnosticsArtifactDescriptor, relevance: Int)] = urls.compactMap { url in
            guard self.isSupportedCrashReport(url) else { return nil }
            let relevance = self.crashReportRelevanceScore(for: url)
            guard relevance > 0 else { return nil }
            guard let descriptor = self.describeFile(at: url, kind: .crashReport) else { return nil }
            return (descriptor: descriptor, relevance: relevance)
        }
        return rankedReports
        .sorted { lhs, rhs in
            let lhsDate = lhs.descriptor.modifiedAt ?? Date.distantPast
            let rhsDate = rhs.descriptor.modifiedAt ?? Date.distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if lhs.relevance != rhs.relevance {
                return lhs.relevance > rhs.relevance
            }
            return lhs.descriptor.fileName.localizedStandardCompare(rhs.descriptor.fileName) == .orderedAscending
        }
        .prefix(limit)
        .map { $0.descriptor }
    }

    private func isSupportedCrashReport(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ips" || ext == "crash"
    }

    private func crashReportRelevanceScore(for url: URL) -> Int {
        let fileName = url.lastPathComponent.lowercased()
        var score = 0

        if fileName.contains("codexpanel") || fileName.contains("codex panel") {
            score += 4
        }
        if fileName.contains("com.codexpanel") {
            score += 2
        }

        if let content = self.readTextPrefix(from: url, maxBytes: 65_536)?.lowercased() {
            if content.contains("com.codexpanel") {
                score += 3
            }
            if content.contains("codex panel") || content.contains("codexpanel") {
                score += 1
            }
        }

        return score
    }

    private func readTextPrefix(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            guard let readData = try handle.read(upToCount: maxBytes) else { return nil }
            data = readData
        } catch {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeSanitizedLifecycleLogData(from url: URL) throws -> Data {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DiagnosticsExportError.readArtifactFailed(L.settingsDiagnosticsLifecycleDecodeFailed)
        }

        let sanitizedLines = text
            .split(whereSeparator: \.isNewline)
            .map { self.sanitizedLifecycleLine(String($0)) }

        return Data((sanitizedLines.joined(separator: "\n") + "\n").utf8)
    }

    private func sanitizedLifecycleLine(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let sanitizedData = try? JSONSerialization.data(
                withJSONObject: self.sanitizedJSONValue(dictionary, key: nil),
                options: [.sortedKeys]
              ),
              let sanitizedLine = String(data: sanitizedData, encoding: .utf8) else {
            return self.redactedString(line)
        }
        return sanitizedLine
    }

    private func sanitizedJSONValue(_ value: Any, key: String?) -> Any {
        let normalizedKey = self.normalizedKey(key)

        if self.shouldFullyRedact(key: normalizedKey) {
            return "<redacted>"
        }
        if self.shouldRedactAsPath(key: normalizedKey) {
            return "<redacted-path>"
        }
        if self.shouldRedactAsURL(key: normalizedKey) {
            return "<redacted-url>"
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                result[item.key] = self.sanitizedJSONValue(item.value, key: item.key)
            }
        }
        if let array = value as? [Any] {
            return array.map { self.sanitizedJSONValue($0, key: key) }
        }
        if let string = value as? String {
            return self.redactedString(string)
        }
        return value
    }

    private func normalizedKey(_ key: String?) -> String {
        key?
            .replacingOccurrences(of: "_", with: "")
            .lowercased() ?? ""
    }

    private func shouldFullyRedact(key: String) -> Bool {
        guard key.isEmpty == false else { return false }
        let exactMatches: Set<String> = [
            "accountid",
            "providerid",
            "activeaccountid",
            "activeproviderid",
            "targetaccountid",
            "email",
        ]
        if exactMatches.contains(key) {
            return true
        }
        return key.contains("token") || key.contains("apikey") || key.contains("secret")
    }

    private func shouldRedactAsPath(key: String) -> Bool {
        guard key.isEmpty == false else { return false }
        return key.contains("path") || key.contains("filepath")
    }

    private func shouldRedactAsURL(key: String) -> Bool {
        guard key.isEmpty == false else { return false }
        return key.contains("url") || key.contains("uri")
    }

    private func redactedString(_ string: String) -> String {
        let homePath = self.homeDirectoryURL.path
        guard homePath.isEmpty == false else { return string }
        return string.replacingOccurrences(of: homePath, with: "~")
    }

    private func missingArtifacts(for scanResult: DiagnosticsScanResult) -> [DiagnosticsArtifactDescriptor.Kind] {
        var missing: [DiagnosticsArtifactDescriptor.Kind] = []
        if scanResult.crashReports.isEmpty {
            missing.append(.crashReport)
        }
        if scanResult.lifecycleLog == nil {
            missing.append(.lifecycleLog)
        }
        if scanResult.lifecycleState == nil {
            missing.append(.lifecycleState)
        }
        return missing
    }

    private func makeManifest(
        scanResult: DiagnosticsScanResult,
        includedFiles: [DiagnosticsExportIncludedFile],
        missingArtifacts: [DiagnosticsArtifactDescriptor.Kind]
    ) -> DiagnosticsExportManifest {
        DiagnosticsExportManifest(
            generatedAt: ISO8601DateFormatter().string(from: scanResult.scannedAt),
            appVersion: self.appVersionProvider(),
            osVersion: self.osVersionProvider(),
            includedFiles: includedFiles.map {
                DiagnosticsExportManifestEntry(
                    kind: $0.kind.rawValue,
                    fileName: $0.fileName,
                    redacted: $0.redacted
                )
            },
            missingArtifacts: missingArtifacts.map(\.rawValue),
            notes: self.redactionNotes()
        )
    }

    private func makeReadme(
        scanResult: DiagnosticsScanResult,
        includedFiles: [DiagnosticsExportIncludedFile],
        missingArtifacts: [DiagnosticsArtifactDescriptor.Kind]
    ) -> String {
        let generatedAt = scanResult.scannedAt.formatted(date: .abbreviated, time: .shortened)
        let appVersion = self.appVersionProvider() ?? L.settingsDiagnosticsUnknownVersion
        let includedSection = includedFiles.isEmpty
            ? "- \(L.settingsDiagnosticsNoIncludedArtifacts)"
            : includedFiles.map {
                let suffix = $0.redacted ? L.settingsDiagnosticsReadmeRedactedSuffix : ""
                return "- \($0.fileName) (\($0.kind.readmeLabel))\(suffix)"
            }
            .joined(separator: "\n")
        let missingSection = missingArtifacts.isEmpty
            ? "- \(L.settingsDiagnosticsReadmeNothingMissing)"
            : missingArtifacts.map { "- \($0.readmeLabel)" }.joined(separator: "\n")
        let notesSection = self.redactionNotes()
            .map { "- \($0)" }
            .joined(separator: "\n")

        if L.zh {
            let missingCrashGuidance = missingArtifacts.contains(.crashReport)
                ? """

如果这里没有找到崩溃日志：
1. 先复现一次 Codex Panel 闪退。
2. 等待几秒，让 macOS 把 `.ips` / `.crash` 写入系统诊断目录。
3. 重新打开 Codex Panel，进入“设置 -> 诊断”，再次刷新或导出。
"""
                : ""
            return """
Codex Panel 诊断导出

生成时间：\(generatedAt)
App 版本：\(appVersion)
系统版本：\(self.osVersionProvider())

本次包含：
\(includedSection)

当前缺失：
\(missingSection)

脱敏说明：
\(notesSection)\(missingCrashGuidance)
"""
        }

        let missingCrashGuidance = missingArtifacts.contains(.crashReport)
            ? """

If the crash report is missing:
1. Reproduce the Codex Panel crash once.
2. Wait a few seconds so macOS can write the `.ips` / `.crash` report.
3. Reopen Codex Panel, go to Settings -> Diagnostics, then refresh or export again.
"""
            : ""
        return """
Codex Panel Diagnostics Export

Generated At: \(generatedAt)
App Version: \(appVersion)
OS Version: \(self.osVersionProvider())

Included:
\(includedSection)

Missing:
\(missingSection)

Redaction Notes:
\(notesSection)\(missingCrashGuidance)
"""
    }

    private func redactionNotes() -> [String] {
        if L.zh {
            return [
                "运行期事件日志会脱敏账号 ID、provider ID、token、API key、邮箱、本地路径和 URL。",
                "崩溃日志与 session 状态文件保持原始内容，便于维护者直接排查。",
            ]
        }
        return [
            "Runtime lifecycle logs redact account IDs, provider IDs, tokens, API keys, emails, local paths, and URLs.",
            "Crash reports and session state files stay unmodified so maintainers can inspect them directly.",
        ]
    }

    private func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        if self.fileManager.fileExists(atPath: destinationURL.path) {
            try self.fileManager.removeItem(at: destinationURL)
        }
        try self.fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func normalizedArchiveURL(from url: URL) -> URL {
        guard url.pathExtension.lowercased() != "zip" else {
            return url.standardizedFileURL
        }
        return url.appendingPathExtension("zip").standardizedFileURL
    }
}

struct DittoDiagnosticsArchiver: DiagnosticsArchiveCreating {
    func createArchive(from sourceDirectoryURL: URL, to destinationURL: URL) throws {
        let process = Process()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            sourceDirectoryURL.path,
            destinationURL.path,
        ]
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw DiagnosticsExportError.archiveFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiagnosticsExportError.archiveFailed(
                message?.isEmpty == false
                    ? message!
                    : "ditto exited with status \(process.terminationStatus)"
            )
        }
    }
}

private extension DiagnosticsArtifactDescriptor.Kind {
    var readmeLabel: String {
        switch self {
        case .crashReport:
            return L.settingsDiagnosticsCrashReportsTitle
        case .lifecycleLog:
            return L.settingsDiagnosticsLifecycleLogTitle
        case .lifecycleState:
            return L.settingsDiagnosticsLifecycleStateTitle
        }
    }
}

private extension JSONEncoder {
    static var diagnosticsManifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
