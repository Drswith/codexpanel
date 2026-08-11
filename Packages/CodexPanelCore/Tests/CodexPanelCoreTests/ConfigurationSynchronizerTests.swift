import Foundation
import XCTest
@testable import CodexPanelCore

final class ConfigurationSynchronizerTests: XCTestCase {
    func testRejectsInvalidContractBeforeMutatingFileSystem() {
        let root = URL(fileURLWithPath: "/virtual/codex-core-invalid", isDirectory: true)
        let paths = CodexConfigurationPaths(
            authURL: root.appendingPathComponent("auth.json"),
            configTOMLURL: root.appendingPathComponent("config.toml"),
            authBackupURL: root.appendingPathComponent("auth.json.backup"),
            configBackupURL: root.appendingPathComponent("config.toml.backup")
        )
        var mutationCount = 0
        let fileSystem = CodexConfigurationFileSystem(
            prepare: { mutationCount += 1 },
            readData: { _ in nil },
            readString: { _ in nil },
            backupFileIfPresent: { _, _ in mutationCount += 1 },
            writeSecureFile: { _, _ in mutationCount += 1 },
            fileExists: { _ in false },
            removeFileIfPresent: { _ in mutationCount += 1 }
        )
        var request = self.makeOAuthRequest()
        request.schemaVersion = 99

        XCTAssertThrowsError(
            try CodexConfigurationSynchronizer(
                paths: paths,
                fileSystem: fileSystem
            ).synchronize(request)
        ) { error in
            XCTAssertEqual(
                error as? CodexConfigurationSyncError,
                .unsupportedSchemaVersion
            )
        }
        XCTAssertEqual(mutationCount, 0)
    }

    func testRestoresBothFilesWhenSecondWriteFails() throws {
        let root = URL(fileURLWithPath: "/virtual/codex-core-test", isDirectory: true)
        let paths = CodexConfigurationPaths(
            authURL: root.appendingPathComponent("auth.json"),
            configTOMLURL: root.appendingPathComponent("config.toml"),
            authBackupURL: root.appendingPathComponent("auth.json.backup"),
            configBackupURL: root.appendingPathComponent("config.toml.backup")
        )
        let originalAuth = Data("old-auth".utf8)
        let originalTOML = Data("model = \"old\"\n".utf8)
        var storage = [
            paths.authURL: originalAuth,
            paths.configTOMLURL: originalTOML,
        ]
        var shouldFailConfigWrite = true

        let fileSystem = CodexConfigurationFileSystem(
            prepare: {},
            readData: { storage[$0] },
            readString: { storage[$0].map { String(decoding: $0, as: UTF8.self) } },
            backupFileIfPresent: { source, destination in
                storage[destination] = storage[source]
            },
            writeSecureFile: { data, url in
                if url == paths.configTOMLURL, shouldFailConfigWrite {
                    shouldFailConfigWrite = false
                    throw TestFailure.configWriteFailed
                }
                storage[url] = data
            },
            fileExists: { storage[$0] != nil },
            removeFileIfPresent: { storage.removeValue(forKey: $0) }
        )
        let synchronizer = CodexConfigurationSynchronizer(
            paths: paths,
            fileSystem: fileSystem,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )

        XCTAssertThrowsError(try synchronizer.synchronize(self.makeOAuthRequest())) { error in
            XCTAssertEqual(error as? TestFailure, .configWriteFailed)
        }
        XCTAssertEqual(storage[paths.authURL], originalAuth)
        XCTAssertEqual(storage[paths.configTOMLURL], originalTOML)
        XCTAssertEqual(storage[paths.authBackupURL], originalAuth)
        XCTAssertEqual(storage[paths.configBackupURL], originalTOML)
    }

    private func makeOAuthRequest() -> CodexConfigurationSyncRequest {
        CodexConfigurationSyncRequest(
            global: CodexGlobalConfiguration(
                defaultModel: "gpt-5.5",
                reviewModel: "gpt-5.5",
                reasoningEffort: "medium",
                serviceTier: "standard"
            ),
            provider: CodexProviderConfiguration(kind: .openAIOAuth),
            credentials: CodexAccountCredentials(
                accessToken: "access",
                refreshToken: "refresh",
                idToken: "id",
                accountID: "account"
            ),
            accountUsageMode: .direct,
            network: CodexNetworkConfiguration(
                openAIAccountGatewayBaseURL: "http://localhost:1456/v1",
                openRouterGatewayBaseURL: "http://localhost:1457/v1",
                chatCompletionsGatewayBaseURL: "http://localhost:1458/v1",
                openRouterGatewayAPIKey: "codexpanel-openrouter-gateway"
            )
        )
    }
}

private enum TestFailure: Error, Equatable {
    case configWriteFailed
}
