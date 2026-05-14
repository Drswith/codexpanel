import AppKit
import Combine
import Foundation

private let defaultAutomaticUpdateCheckInterval: TimeInterval = 24 * 60 * 60

enum AppUpdateError: LocalizedError {
    case missingReleasesURL
    case invalidCurrentVersion(String)
    case invalidReleaseVersion(String)
    case invalidResponse
    case unexpectedStatusCode(Int)
    case noInstallableStableRelease
    case noCompatibleArtifact(UpdateArtifactArchitecture)
    case failedToOpenDownloadURL(URL)
    case automaticUpdateUnavailable

    var errorDescription: String? {
        switch self {
        case .missingReleasesURL:
            return L.updateErrorMissingReleasesURL
        case let .invalidCurrentVersion(version):
            return L.updateErrorInvalidCurrentVersion(version)
        case let .invalidReleaseVersion(version):
            return L.updateErrorInvalidReleaseVersion(version)
        case .invalidResponse:
            return L.updateErrorInvalidResponse
        case let .unexpectedStatusCode(statusCode):
            return L.updateErrorUnexpectedStatusCode(statusCode)
        case .noInstallableStableRelease:
            return L.updateErrorNoInstallableStableRelease
        case let .noCompatibleArtifact(architecture):
            return L.updateErrorNoCompatibleArtifact(architecture.displayName)
        case let .failedToOpenDownloadURL(url):
            return L.updateErrorFailedToOpenDownloadURL(url.absoluteString)
        case .automaticUpdateUnavailable:
            return L.updateErrorAutomaticUpdateUnavailable
        }
    }
}

protocol AppUpdateReleaseLoading {
    func loadLatestRelease() async throws -> AppUpdateRelease
}

protocol AppUpdateEnvironmentProviding {
    var currentVersion: String { get }
    var bundleURL: URL { get }
    var architecture: UpdateArtifactArchitecture { get }
    var updateFeedURL: URL? { get }
    var githubLatestReleaseURL: URL? { get }
    var githubReleasesURL: URL? { get }
}

protocol AppSignatureInspecting {
    func inspect(bundleURL: URL) -> AppSignatureInspection
}

protocol AppGatekeeperInspecting {
    func inspect(bundleURL: URL) -> AppGatekeeperInspection
}

protocol AppUpdateCapabilityEvaluating {
    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker]
}

protocol AppUpdateActionExecuting {
    func execute(_ availability: AppUpdateAvailability) async throws
}

protocol AppUpdateAutomaticCheckCancelling {
    func cancel()
}

protocol AppUpdateAutomaticCheckScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable @MainActor () async -> Void
    ) -> AppUpdateAutomaticCheckCancelling
}

struct AppSignatureInspection: Equatable {
    var hasUsableSignature: Bool
    var summary: String
}

struct AppGatekeeperInspection: Equatable {
    var passesAssessment: Bool
    var summary: String
}

final class TaskBasedAutomaticCheckHandle: AppUpdateAutomaticCheckCancelling {
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }

    deinit {
        self.cancel()
    }
}

struct TaskBasedAutomaticCheckScheduler: AppUpdateAutomaticCheckScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable @MainActor () async -> Void
    ) -> AppUpdateAutomaticCheckCancelling {
        let clampedInterval = max(interval, 1)
        let sleepNanoseconds = UInt64(clampedInterval * 1_000_000_000)

        let task = Task {
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }

                guard Task.isCancelled == false else { return }
                await operation()
            }
        }

        return TaskBasedAutomaticCheckHandle(task: task)
    }
}

struct LiveAppUpdateEnvironment: AppUpdateEnvironmentProviding {
    var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? version! : "0.0.0"
    }

    var bundleURL: URL {
        Bundle.main.bundleURL
    }

    var architecture: UpdateArtifactArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .universal
        #endif
    }

    var updateFeedURL: URL? {
        self.infoURL(forKey: "CodexPanelUpdateFeedURL")
    }

    var githubLatestReleaseURL: URL? {
        self.infoURL(forKey: "CodexPanelGitHubLatestReleaseURL")
            ?? Self.derivedLatestReleaseURL(from: self.githubReleasesURL)
    }

    var githubReleasesURL: URL? {
        self.infoURL(forKey: "CodexPanelGitHubReleasesURL")
    }

    private func infoURL(forKey key: String) -> URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return URL(string: rawValue)
    }

    private static func derivedLatestReleaseURL(from releasesURL: URL?) -> URL? {
        guard let releasesURL else { return nil }
        guard releasesURL.host?.lowercased() == "api.github.com" else { return nil }

        let components = releasesURL.path.split(separator: "/").map(String.init)
        guard components.count >= 4,
              components[0] == "repos",
              components[3] == "releases" else {
            return nil
        }

        let owner = components[1]
        let repository = components[2]
        return URL(string: "https://github.com/\(owner)/\(repository)/releases/latest")
    }
}

struct LiveGitHubReleasesUpdateLoader: AppUpdateReleaseLoading {
    private static let userAgent = "codexpanel"

    private struct SourceEndpoints {
        var updateFeedURL: URL?
        var latestReleaseURL: URL?
        var releasesAPIURL: URL?

        var hasAtLeastOneSource: Bool {
            self.updateFeedURL != nil || self.latestReleaseURL != nil || self.releasesAPIURL != nil
        }
    }

    var environment: AppUpdateEnvironmentProviding
    var session: URLSession = .shared

    func loadLatestRelease() async throws -> AppUpdateRelease {
        let endpoints = SourceEndpoints(
            updateFeedURL: self.environment.updateFeedURL,
            latestReleaseURL: self.environment.githubLatestReleaseURL,
            releasesAPIURL: self.environment.githubReleasesURL
        )

        guard endpoints.hasAtLeastOneSource else {
            throw AppUpdateError.missingReleasesURL
        }

        var lastError: Error?

        if let updateFeedURL = endpoints.updateFeedURL {
            do {
                return try await self.loadLatestReleaseFromUpdateFeed(updateFeedURL)
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastError = error
            }
        }

        if let latestReleaseURL = endpoints.latestReleaseURL {
            do {
                return try await self.loadLatestReleaseFromLatestReleaseURL(latestReleaseURL)
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastError = error
            }
        }

        if let releasesAPIURL = endpoints.releasesAPIURL {
            do {
                return try await self.loadLatestReleaseFromReleasesAPI(releasesAPIURL)
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw AppUpdateError.missingReleasesURL
    }

    private func loadLatestReleaseFromUpdateFeed(_ updateFeedURL: URL) async throws -> AppUpdateRelease {
        let (data, _) = try await self.fetch(url: updateFeedURL, accept: "application/json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let feed: AppUpdateFeed
        do {
            feed = try decoder.decode(AppUpdateFeed.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        guard feed.release.artifacts.isEmpty == false else {
            throw AppUpdateError.noInstallableStableRelease
        }

        return feed.release
    }

    private func loadLatestReleaseFromLatestReleaseURL(_ latestReleaseURL: URL) async throws -> AppUpdateRelease {
        let (_, response) = try await self.fetch(
            url: latestReleaseURL,
            accept: "text/html,application/xhtml+xml"
        )

        let resolvedURL = response.url ?? latestReleaseURL
        guard let metadata = Self.latestReleaseMetadata(from: resolvedURL) else {
            throw AppUpdateError.invalidResponse
        }

        let normalizedVersion = metadata.tagName.hasPrefix("v")
            ? String(metadata.tagName.dropFirst())
            : metadata.tagName

        let bundleName = "codexpanel-\(normalizedVersion)-macOS"
        let downloadRoot = metadata.repositoryURL.appendingPathComponent(
            "releases/latest/download",
            isDirectory: true
        )
        let artifacts: [AppUpdateArtifact] = [
            AppUpdateArtifact(
                architecture: .universal,
                format: .dmg,
                downloadURL: downloadRoot.appendingPathComponent("\(bundleName).dmg"),
                sha256: nil
            ),
            AppUpdateArtifact(
                architecture: .universal,
                format: .zip,
                downloadURL: downloadRoot.appendingPathComponent("\(bundleName).zip"),
                sha256: nil
            ),
        ]

        return AppUpdateRelease(
            version: normalizedVersion,
            publishedAt: nil,
            summary: nil,
            releaseNotesURL: metadata.releaseTagURL,
            downloadPageURL: metadata.releaseTagURL,
            deliveryMode: .guidedDownload,
            minimumAutomaticUpdateVersion: nil,
            artifacts: artifacts
        )
    }

    private func loadLatestReleaseFromReleasesAPI(_ releasesURL: URL) async throws -> AppUpdateRelease {
        let (data, _) = try await self.fetch(url: releasesURL, accept: "application/vnd.github+json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases: [GitHubReleaseIndexEntry]

        do {
            releases = try decoder.decode([GitHubReleaseIndexEntry].self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        guard let release = GitHubReleaseAdapter.firstInstallableStableRelease(from: releases) else {
            throw AppUpdateError.noInstallableStableRelease
        }

        return release
    }

    private func fetch(url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    private static func latestReleaseMetadata(from releaseTagURL: URL) -> (tagName: String, repositoryURL: URL, releaseTagURL: URL)? {
        let components = releaseTagURL.path.split(separator: "/").map(String.init)
        guard components.count >= 5,
              components[2] == "releases",
              components[3] == "tag" else {
            return nil
        }

        let owner = components[0]
        let repository = components[1]
        let tagName = components[4]
        guard tagName.isEmpty == false else {
            return nil
        }

        guard let repositoryURL = URL(string: "https://github.com/\(owner)/\(repository)") else {
            return nil
        }

        return (tagName: tagName, repositoryURL: repositoryURL, releaseTagURL: releaseTagURL)
    }
}

struct LocalCodesignSignatureInspector: AppSignatureInspecting {
    func inspect(bundleURL: URL) -> AppSignatureInspection {
        let output = Self.captureOutput(
            launchPath: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", bundleURL.path]
        )

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOutput.isEmpty == false else {
            return AppSignatureInspection(
                hasUsableSignature: false,
                summary: L.updateSignatureUnknown
            )
        }

        let lines = trimmedOutput.split(separator: "\n").map(String.init)
        let signatureLine = lines.first(where: { $0.hasPrefix("Signature=") }) ?? "Signature=unknown"
        let teamLine = lines.first(where: { $0.hasPrefix("TeamIdentifier=") }) ?? "TeamIdentifier=unknown"
        let summary = "\(signatureLine); \(teamLine)"
        let isAdHoc = signatureLine.localizedCaseInsensitiveContains("adhoc")
        let teamMissing = teamLine.localizedCaseInsensitiveContains("not set")

        return AppSignatureInspection(
            hasUsableSignature: isAdHoc == false && teamMissing == false,
            summary: summary
        )
    }

    fileprivate static func captureOutput(
        launchPath: String,
        arguments: [String]
    ) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return error.localizedDescription
        }
    }
}

struct LocalGatekeeperInspector: AppGatekeeperInspecting {
    func inspect(bundleURL: URL) -> AppGatekeeperInspection {
        let output = LocalCodesignSignatureInspector.captureOutput(
            launchPath: "/usr/sbin/spctl",
            arguments: ["-a", "-vv", bundleURL.path]
        )

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOutput.isEmpty == false else {
            return AppGatekeeperInspection(
                passesAssessment: false,
                summary: L.updateSignatureUnknown
            )
        }

        let passesAssessment = trimmedOutput.localizedCaseInsensitiveContains("accepted")
            && trimmedOutput.localizedCaseInsensitiveContains("no usable signature") == false
        let summary = trimmedOutput.split(separator: "\n").prefix(2).joined(separator: " | ")

        return AppGatekeeperInspection(
            passesAssessment: passesAssessment,
            summary: summary
        )
    }
}

struct DefaultAppUpdateCapabilityEvaluator: AppUpdateCapabilityEvaluating {
    var signatureInspector: AppSignatureInspecting
    var gatekeeperInspector: AppGatekeeperInspecting
    var automaticUpdaterAvailable: Bool

    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker] {
        var blockers: [AppUpdateBlocker] = []

        if release.deliveryMode == .guidedDownload {
            blockers.append(.guidedDownloadOnlyRelease)
        }

        if let minimumAutomaticUpdateVersion = release.minimumAutomaticUpdateVersion,
           let currentVersion = AppSemanticVersion(environment.currentVersion),
           let minimumVersion = AppSemanticVersion(minimumAutomaticUpdateVersion),
           currentVersion < minimumVersion {
            blockers.append(
                .bootstrapRequired(
                    currentVersion: environment.currentVersion,
                    minimumAutomaticVersion: minimumAutomaticUpdateVersion
                )
            )
        }

        if self.automaticUpdaterAvailable == false {
            blockers.append(.automaticUpdaterUnavailable)
        }

        let signatureInspection = self.signatureInspector.inspect(bundleURL: environment.bundleURL)
        if signatureInspection.hasUsableSignature == false {
            blockers.append(.missingTrustedSignature(summary: signatureInspection.summary))
        }

        let gatekeeperInspection = self.gatekeeperInspector.inspect(bundleURL: environment.bundleURL)
        if gatekeeperInspection.passesAssessment == false {
            blockers.append(.failingGatekeeperAssessment(summary: gatekeeperInspection.summary))
        }

        let installLocation = Self.installLocation(for: environment.bundleURL)
        if installLocation == .other {
            blockers.append(.unsupportedInstallLocation(installLocation))
        }

        return blockers
    }

    static func installLocation(for bundleURL: URL) -> UpdateInstallLocation {
        let standardizedPath = bundleURL.standardizedFileURL.path
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let userApplications = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .path

        if standardizedPath.hasPrefix("/Applications/") || standardizedPath == "/Applications" {
            return .applications
        }
        if standardizedPath.hasPrefix(userApplications + "/") || standardizedPath == userApplications {
            return .userApplications
        }
        return .other
    }
}

enum AppUpdateArtifactSelector {
    static func selectArtifact(
        for architecture: UpdateArtifactArchitecture,
        artifacts: [AppUpdateArtifact]
    ) throws -> AppUpdateArtifact {
        let architecturePreference: [UpdateArtifactArchitecture]
        switch architecture {
        case .arm64:
            architecturePreference = [.arm64, .universal]
        case .x86_64:
            architecturePreference = [.x86_64, .universal]
        case .universal:
            architecturePreference = [.universal, .arm64, .x86_64]
        }

        let formatPreference: [UpdateArtifactFormat] = [.dmg, .zip]

        for preferredFormat in formatPreference {
            for preferredArchitecture in architecturePreference {
                if let artifact = artifacts.first(where: {
                    $0.architecture == preferredArchitecture && $0.format == preferredFormat
                }) {
                    return artifact
                }
            }
        }

        throw AppUpdateError.noCompatibleArtifact(architecture)
    }
}

struct LiveAppUpdateActionExecutor: AppUpdateActionExecuting {
    func execute(_ availability: AppUpdateAvailability) async throws {
        guard availability.isAutomaticUpdateAllowed == false else {
            throw AppUpdateError.automaticUpdateUnavailable
        }

        guard NSWorkspace.shared.open(availability.selectedArtifact.downloadURL) else {
            throw AppUpdateError.failedToOpenDownloadURL(availability.selectedArtifact.downloadURL)
        }
    }
}

@MainActor
final class UpdateCoordinator: ObservableObject {
    static let shared = UpdateCoordinator()

    @Published private(set) var state: UpdateCoordinatorState = .idle
    @Published private(set) var pendingAvailability: AppUpdateAvailability?

    private let releaseLoader: AppUpdateReleaseLoading
    private let environment: AppUpdateEnvironmentProviding
    private let capabilityEvaluator: AppUpdateCapabilityEvaluating
    private let actionExecutor: AppUpdateActionExecuting
    private let automaticCheckScheduler: AppUpdateAutomaticCheckScheduling
    private let automaticCheckInterval: TimeInterval

    private var hasStarted = false
    private var automaticCheckHandle: AppUpdateAutomaticCheckCancelling?

    convenience init() {
        let environment = LiveAppUpdateEnvironment()
        self.init(
            releaseLoader: LiveGitHubReleasesUpdateLoader(environment: environment),
            environment: environment,
            capabilityEvaluator: DefaultAppUpdateCapabilityEvaluator(
                signatureInspector: LocalCodesignSignatureInspector(),
                gatekeeperInspector: LocalGatekeeperInspector(),
                automaticUpdaterAvailable: false
            ),
            actionExecutor: LiveAppUpdateActionExecutor(),
            automaticCheckScheduler: TaskBasedAutomaticCheckScheduler(),
            automaticCheckInterval: defaultAutomaticUpdateCheckInterval
        )
    }

    convenience init(
        releaseLoader: AppUpdateReleaseLoading,
        environment: AppUpdateEnvironmentProviding,
        capabilityEvaluator: AppUpdateCapabilityEvaluating,
        actionExecutor: AppUpdateActionExecuting
    ) {
        self.init(
            releaseLoader: releaseLoader,
            environment: environment,
            capabilityEvaluator: capabilityEvaluator,
            actionExecutor: actionExecutor,
            automaticCheckScheduler: TaskBasedAutomaticCheckScheduler(),
            automaticCheckInterval: defaultAutomaticUpdateCheckInterval
        )
    }

    init(
        releaseLoader: AppUpdateReleaseLoading,
        environment: AppUpdateEnvironmentProviding,
        capabilityEvaluator: AppUpdateCapabilityEvaluating,
        actionExecutor: AppUpdateActionExecuting,
        automaticCheckScheduler: AppUpdateAutomaticCheckScheduling,
        automaticCheckInterval: TimeInterval
    ) {
        self.releaseLoader = releaseLoader
        self.environment = environment
        self.capabilityEvaluator = capabilityEvaluator
        self.actionExecutor = actionExecutor
        self.automaticCheckScheduler = automaticCheckScheduler
        self.automaticCheckInterval = automaticCheckInterval
    }

    var isChecking: Bool {
        if case .checking = self.state {
            return true
        }
        return false
    }

    func start() {
        guard self.hasStarted == false else { return }
        self.hasStarted = true

        self.automaticCheckHandle = self.automaticCheckScheduler.scheduleRepeating(
            every: self.automaticCheckInterval
        ) { [weak self] in
            guard let self else { return }
            await self.checkForUpdates(trigger: .automaticDaily)
        }

        Task {
            await self.checkForUpdates(trigger: .automaticStartup)
        }
    }

    func stop() {
        self.automaticCheckHandle?.cancel()
        self.automaticCheckHandle = nil
        self.hasStarted = false
    }

    func handleToolbarAction() async {
        if let pendingAvailability = self.pendingAvailability {
            await self.execute(pendingAvailability)
        } else {
            await self.checkForUpdates(trigger: .manual)
        }
    }

    func checkForUpdates(trigger: UpdateCheckTrigger) async {
        guard self.isChecking == false else { return }

        self.state = .checking(trigger)

        do {
            let release = try await self.releaseLoader.loadLatestRelease()
            if let availability = try self.resolveAvailability(from: release) {
                self.pendingAvailability = availability
                self.state = .updateAvailable(availability)
            } else {
                self.pendingAvailability = nil
                self.state = .upToDate(
                    currentVersion: self.environment.currentVersion,
                    checkedVersion: release.version
                )
            }
        } catch {
            let message = error.localizedDescription
            self.state = .failed(message)
        }
    }

    private func resolveAvailability(from release: AppUpdateRelease) throws -> AppUpdateAvailability? {
        guard let currentVersion = AppSemanticVersion(self.environment.currentVersion) else {
            throw AppUpdateError.invalidCurrentVersion(self.environment.currentVersion)
        }
        guard let releaseVersion = AppSemanticVersion(release.version) else {
            throw AppUpdateError.invalidReleaseVersion(release.version)
        }
        guard currentVersion < releaseVersion else {
            return nil
        }

        let selectedArtifact = try AppUpdateArtifactSelector.selectArtifact(
            for: self.environment.architecture,
            artifacts: release.artifacts
        )

        return AppUpdateAvailability(
            currentVersion: self.environment.currentVersion,
            release: release,
            selectedArtifact: selectedArtifact,
            blockers: self.capabilityEvaluator.blockers(
                for: release,
                environment: self.environment
            )
        )
    }

    private func execute(_ availability: AppUpdateAvailability) async {
        self.state = .executing(availability)

        do {
            try await self.actionExecutor.execute(availability)
            self.pendingAvailability = availability
            self.state = .updateAvailable(availability)
        } catch {
            let message = error.localizedDescription
            self.state = .failed(message)
        }
    }
}

private extension UpdateArtifactArchitecture {
    var displayName: String {
        switch self {
        case .arm64:
            return "Apple Silicon"
        case .x86_64:
            return "Intel"
        case .universal:
            return L.updateArchitectureUniversal
        }
    }
}
