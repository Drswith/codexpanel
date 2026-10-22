import CryptoKit
import Foundation
import XCTest

@MainActor
final class TokscaleEngineManagerTests: CodexPanelTestCase {
    private var root: URL { CodexPaths.codexBarRoot.appendingPathComponent("engine-tests") }
    private var managed: URL { self.root.appendingPathComponent("engines/tokscale") }
    private var binary: Data { Data("#!/bin/sh\nprintf 'tokscale 4.20.0\\n'\n".utf8) }

    private func executable(at url: URL, data: Data? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? self.binary).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func archive(symlink: Bool = false) throws -> Data {
        let source = self.root.appendingPathComponent(UUID().uuidString)
        let entry = source.appendingPathComponent("package/bin/tokscale")
        if symlink {
            try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "/usr/bin/true")
        } else {
            try self.executable(at: entry)
        }
        return try TokscaleProcessRunner().run(TokscaleProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", "-", "-C", source.path, "package/bin/tokscale"], environment: ["PATH": "/usr/bin:/bin"], workingDirectoryURL: source, timeout: 5, maximumOutputBytes: 1_024 * 1_024))
    }

    private func manifest(archive: Data, binary: Data? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": "4.20.0",
            "platforms": [TokscaleEngineManager.currentArchitecture: [
                "url": "https://registry.npmjs.org/@tokscale/cli-darwin-arm64/-/cli-darwin-arm64-4.20.0.tgz",
                "integrity": "sha512-" + Data(SHA512.hash(data: archive)).base64EncodedString(),
                "binarySHA256": SHA256.hash(data: binary ?? self.binary).map { String(format: "%02x", $0) }.joined(),
            ]],
        ])
    }

    func testCompatibleVersionsExcludeOlderMajorAndPrereleases() {
        for version in ["4.20.0", "4.20.9", "4.21.0", "4.999.1"] { XCTAssertTrue(TokscaleVersion.isCompatible(version), version) }
        for version in ["4.19.9", "5.0.0", "3.99.0", "4.20.0-rc.1", "4.20", "4.20.0\n"] { XCTAssertFalse(TokscaleVersion.isCompatible(version), version) }
        XCTAssertEqual(TokscaleVersion.parseOutput(Data("tokscale 4.21.0\n".utf8)), "4.21.0")
        XCTAssertNil(TokscaleVersion.parseOutput(Data("4.21.0".utf8)))
    }

    func testDiscoveryDeduplicatesLinksAndNeverClassifiesManagedAsInstalled() throws {
        let first = self.root.appendingPathComponent("bin-one/tokscale")
        let duplicate = self.root.appendingPathComponent("bin-two/tokscale")
        let managed = self.managed.appendingPathComponent("4.20.0/\(TokscaleEngineManager.currentArchitecture)/tokscale")
        let alias = self.root.appendingPathComponent("bin-managed-alias/tokscale")
        try self.executable(at: first)
        try self.executable(at: managed)
        for (link, target) in [(duplicate, first), (alias, managed)] {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }
        let path = [first, duplicate, alias].map { $0.deletingLastPathComponent().path }.joined(separator: ":")
        let manifest = try self.manifest(archive: Data())
        let manager = TokscaleEngineManager(managedRootURL: self.managed, searchPathProvider: { path }, manifestDataProvider: { manifest })
        let engines = try manager.discover()
        XCTAssertEqual(engines.map(\.source), [.installed, .managed])
        XCTAssertEqual(engines[0].executableURL, first)
        XCTAssertEqual(engines[1].executableURL, managed)
    }

    func testDiscoveryPreservesWrapperRuntimePathAndIsolatesCredentialsAndHistory() throws {
        let directory = self.root.appendingPathComponent("bin")
        let runtime = directory.appendingPathComponent("example-runtime")
        try self.executable(at: runtime, data: Data("#!/bin/sh\n[ \"$OPENAI_API_KEY\" = '' ] || exit 2\n[ \"$CODEX_HOME\" != '/real-codex' ] || exit 3\n[ \"$HOME\" != '/real-home' ] || exit 4\nprintf 'tokscale 5.0.0\\n'\n".utf8))
        try self.executable(at: directory.appendingPathComponent("tokscale"), data: Data("#!/usr/bin/env example-runtime\n".utf8))
        let manager = TokscaleEngineManager(managedRootURL: self.managed, inheritedEnvironment: { ["HOME": "/real-home", "CODEX_HOME": "/real-codex", "OPENAI_API_KEY": "secret"] }, searchPathProvider: { directory.path }, manifestDataProvider: { throw TokscaleEngineError.manifestMissing })
        let engines = try manager.discover()
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engines.first?.version, "5.0.0")
        XCTAssertEqual(engines.first?.isCompatible, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.managed.path))
    }

    func testManagedInstallVerifiesAndPublishesOnlyInsideManagedRoot() throws {
        let archive = try self.archive()
        let manifest = try self.manifest(archive: archive)
        let downloader = FixtureTokscaleDownloader(data: archive)
        let manager = TokscaleEngineManager(managedRootURL: self.managed, searchPathProvider: { "" }, manifestDataProvider: { manifest }, downloader: downloader)
        let descriptor = try manager.installManaged()
        XCTAssertEqual(descriptor.source, .managed)
        XCTAssertEqual(descriptor.version, "4.20.0")
        XCTAssertEqual(descriptor.executableURL, self.managed.appendingPathComponent("4.20.0/\(TokscaleEngineManager.currentArchitecture)/tokscale"))
        XCTAssertEqual(try Data(contentsOf: descriptor.executableURL), self.binary)
        XCTAssertEqual(try manager.discover(), [descriptor])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: descriptor.executableURL.deletingLastPathComponent().path), ["tokscale"])
    }

    func testDownloadChecksumFailurePreservesExistingManagedCopy() throws {
        let archive = try self.archive()
        let manifest = try self.manifest(archive: archive)
        let destination = self.managed.appendingPathComponent("4.20.0/\(TokscaleEngineManager.currentArchitecture)/tokscale")
        try self.executable(at: destination)
        let manager = TokscaleEngineManager(managedRootURL: self.managed, manifestDataProvider: { manifest }, downloader: FixtureTokscaleDownloader(data: Data("corrupt".utf8)))
        XCTAssertThrowsError(try manager.installManaged()) { error in XCTAssertEqual(error as? TokscaleEngineError, .checksumMismatch) }
        XCTAssertEqual(try Data(contentsOf: destination), self.binary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["tokscale"])
    }

    func testSymlinkArchiveMemberIsRejectedBeforePublishing() throws {
        let archive = try self.archive(symlink: true)
        let manifest = try self.manifest(archive: archive)
        let manager = TokscaleEngineManager(managedRootURL: self.managed, manifestDataProvider: { manifest }, downloader: FixtureTokscaleDownloader(data: archive))
        XCTAssertThrowsError(try manager.installManaged()) { error in XCTAssertEqual(error as? TokscaleEngineError, .invalidArchive) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.managed.appendingPathComponent("4.20.0/\(TokscaleEngineManager.currentArchitecture)/tokscale").path))
    }

    func testManagedDirectoryCannotRedirectInstallationThroughSymlink() throws {
        let archive = try self.archive()
        let manifest = try self.manifest(archive: archive)
        let external = self.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: self.managed, withDestinationURL: external)
        let manager = TokscaleEngineManager(managedRootURL: self.managed, manifestDataProvider: { manifest }, downloader: FixtureTokscaleDownloader(data: archive))
        XCTAssertThrowsError(try manager.installManaged()) { error in XCTAssertEqual(error as? TokscaleEngineError, .installationFailed) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testProfileStateDirectoryCannotRedirectManagedInstallThroughSymlink() throws {
        let external = CodexPaths.realHome.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: CodexPaths.codexBarRoot, withDestinationURL: external)
        let manifest = try self.manifest(archive: Data())
        let manager = TokscaleEngineManager(manifestDataProvider: { manifest }, downloader: FixtureTokscaleDownloader(data: Data()))
        XCTAssertThrowsError(try manager.installManaged()) { error in XCTAssertEqual(error as? TokscaleEngineError, .installationFailed) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testDefaultManagedRootFollowsProfileChangesWithoutReinitialization() throws {
        let manifest = try self.manifest(archive: Data())
        let manager = TokscaleEngineManager(searchPathProvider: { "" }, manifestDataProvider: { manifest })
        let originalHome = CodexPaths.realHome
        try self.executable(at: CodexPaths.codexBarRoot.appendingPathComponent("engines/tokscale/4.20.0/\(TokscaleEngineManager.currentArchitecture)/tokscale"))
        XCTAssertEqual(try manager.discover().count, 1)
        let prior = ProcessInfo.processInfo.environment["CODEXPANEL_HOME"]!
        defer { setenv("CODEXPANEL_HOME", prior, 1) }
        setenv("CODEXPANEL_HOME", originalHome.appendingPathComponent("second-profile").path, 1)
        XCTAssertEqual(try manager.discover(), [])
    }
}

private struct FixtureTokscaleDownloader: TokscalePackageDownloading {
    let data: Data
    func download(from url: URL, to destination: URL) throws { try self.data.write(to: destination) }
}
