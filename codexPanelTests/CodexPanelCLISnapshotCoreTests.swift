import Foundation
import XCTest

final class CodexPanelCLISnapshotCoreTests: XCTestCase {
    func testRefUsesAccessibilityIdentifierWhenAvailable() {
        var siblingCounter: [String: Int] = [:]

        let ref = CLISnapshotRefBuilder.childRef(
            identifier: "settings.save-button",
            role: "AXButton",
            title: "Save",
            label: nil,
            parentRef: "@window.settings",
            siblingCounter: &siblingCounter
        )

        XCTAssertEqual(ref, "@settings.save-button")
        XCTAssertTrue(siblingCounter.isEmpty)
    }

    func testRefFallsBackToParentPathRoleTitleLabelSlug() {
        var siblingCounter: [String: Int] = [:]

        let ref = CLISnapshotRefBuilder.childRef(
            identifier: nil,
            role: "AXButton",
            title: "Save Changes",
            label: nil,
            parentRef: "@window.settings",
            siblingCounter: &siblingCounter
        )

        XCTAssertEqual(ref, "@window.settings/save-changes.1")
    }

    func testRefUsesStableIncrementForSameSiblingBase() {
        var siblingCounter: [String: Int] = [:]
        let first = CLISnapshotRefBuilder.childRef(
            identifier: nil,
            role: "AXStaticText",
            title: "Status",
            label: nil,
            parentRef: "@window.settings",
            siblingCounter: &siblingCounter
        )
        let second = CLISnapshotRefBuilder.childRef(
            identifier: nil,
            role: "AXStaticText",
            title: "Status",
            label: nil,
            parentRef: "@window.settings",
            siblingCounter: &siblingCounter
        )

        XCTAssertEqual(first, "@window.settings/status.1")
        XCTAssertEqual(second, "@window.settings/status.2")
    }

    func testSensitiveKeywordsAreRedacted() {
        let samples = [
            "my token value",
            "api key: 123",
            "apikey=abc",
            "password=123456",
            "top secret",
            "authorization: bearer x",
            "refresh_token=rt",
            "access_token=at",
            "id_token=it",
        ]

        for sample in samples {
            XCTAssertEqual(CLISnapshotRedactor.redact(sample), "<redacted>")
        }
    }

    func testKnownTokenPrefixesAndJWTLikeValuesAreRedacted() {
        XCTAssertEqual(CLISnapshotRedactor.redact("sk-abcdefghijklmnopqrstuvwxyz0123456789"), "<redacted>")
        XCTAssertEqual(CLISnapshotRedactor.redact("sess-abcdefghijklmnopqrstuvwxyz0123456789"), "<redacted>")
        XCTAssertEqual(
            CLISnapshotRedactor.redact("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50IjoidGVzdCJ9.signaturepart"),
            "<redacted>"
        )
    }

    func testTreeRendererOutputMatchesFixture() {
        let result = SnapshotResult(
            bundleIdentifier: "com.codexpanel",
            pid: 123,
            target: .settings,
            windows: [
                SnapshotWindow(
                    kind: .settings,
                    windowRef: "@codexpanel.window.openai-settings",
                    title: "Settings",
                    nodes: [
                        SnapshotNode(
                            ref: "@codexpanel.window.openai-settings/header.1",
                            role: "AXGroup",
                            title: "Header",
                            label: nil,
                            valueSummary: nil,
                            enabled: true,
                            focused: false,
                            frame: WindowFrame(x: 10, y: 10, width: 100, height: 20),
                            children: [
                                SnapshotNode(
                                    ref: "@header-title",
                                    role: "AXStaticText",
                                    title: "OpenAI Settings",
                                    label: nil,
                                    valueSummary: nil,
                                    enabled: true,
                                    focused: false,
                                    frame: nil,
                                    children: []
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        let rendered = CLISnapshotTreeRenderer.render(result)
        let expected = """
        target=settings pid=123
        window @codexpanel.window.openai-settings kind=settings title=Settings
          - @codexpanel.window.openai-settings/header.1 role=AXGroup title=Header enabled=true focused=false frame={x:10.0,y:10.0,w:100.0,h:20.0}
            - @header-title role=AXStaticText title=OpenAI Settings enabled=true focused=false
        """
        XCTAssertEqual(rendered, expected)
    }

    func testSnapshotJSONEncodingHasStableKeys() throws {
        let result = SnapshotResult(
            bundleIdentifier: "com.codexpanel",
            pid: 42,
            target: .menu,
            windows: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(json, #"{"bundleIdentifier":"com.codexpanel","pid":42,"target":"menu","windows":[]}"#)
    }
}

