import Foundation
import XCTest
@testable import CodexPanelCore

final class DesktopSidebarStateTests: XCTestCase {
    func testMergesLocalProjectStateIntoTargetWithoutCopyingAccountState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let index = DesktopSidebarState.ProjectIndex(
            roots: ["server-project": ["/project"], "server-second": ["/project"]],
            threads: [
                "explicit": .init(cwd: "/other", projectID: nil),
                "by-root": .init(cwd: "/project/subdir", projectID: "server-project"),
                "conflict": .init(cwd: "/project", projectID: "other-project"),
            ]
        )

        let host = "local:\(home.resolvingSymlinksInPath().path)"
        let scope = DesktopSidebarState.scopeKey
        let state: [String: Any] = [
            scope: ["owner": "source", "inactive": ["target": ["globals": ["unrelated": true], "atoms": ["private": "target"]]]],
            "local-projects": [
                "project": ["id": "project", "rootPaths": ["/project"]],
                "second": ["id": "second", "rootPaths": ["/project"]],
                "cloud": ["id": "cloud", "rootPaths": ["/cloud"], "chatGptBacking": [:]],
            ],
            "app-server-project-id-by-legacy-project-id-by-host": [host: ["project": "server-project", "second": "server-second"]],
            "thread-project-assignments": ["explicit": ["projectKind": "local", "projectId": "project"]],
            "pinned-project-ids": ["project", "cloud"],
            "sidebar-project-thread-orders": ["project": ["threadIds": ["by-root", "explicit", "conflict"]]],
            "thread-writable-roots": ["explicit": ["/private"]],
            "electron-persisted-atom-state": ["sidebar-project-expanded-v1-codex:project": false, "private": "source"],
        ]

        let data = try XCTUnwrap(DesktopSidebarState.merge(state, source: "source", target: "target", codexHome: home) { index })
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(result[scope] as? [String: Any])
        XCTAssertEqual(accounts["owner"] as? String, "source")
        let inactive = try XCTUnwrap(accounts["inactive"] as? [String: [String: Any]])
        let globals = try XCTUnwrap(inactive["target"]?["globals"] as? [String: Any])
        let atoms = try XCTUnwrap(inactive["target"]?["atoms"] as? [String: Any])
        XCTAssertEqual(Set((globals["local-projects"] as? [String: Any] ?? [:]).keys), ["project", "second"])
        XCTAssertEqual(globals["pinned-project-ids"] as? [String], ["project"])
        XCTAssertEqual((globals["sidebar-project-thread-orders"] as? [String: [String: [String]]])?["project"]?["threadIds"], ["by-root", "explicit"])
        XCTAssertEqual(globals["unrelated"] as? Bool, true)
        XCTAssertNil(globals["thread-writable-roots"])
        XCTAssertEqual(atoms["private"] as? String, "target")
        XCTAssertEqual(atoms["sidebar-project-expanded-v1-codex:project"] as? Bool, false)
        XCTAssertNil(try DesktopSidebarState.merge(result, source: "source", target: "target", codexHome: home) { index })
    }
}
