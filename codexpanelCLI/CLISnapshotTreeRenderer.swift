import Foundation

enum CLISnapshotTreeRenderer {
    static func render(_ result: SnapshotResult) -> String {
        var lines: [String] = []
        lines.append("target=\(result.target.rawValue) pid=\(result.pid)")
        for window in result.windows {
            lines.append("window \(window.windowRef) kind=\(window.kind.rawValue)\(window.title.map { " title=\($0)" } ?? "")")
            for node in window.nodes {
                self.append(node: node, depth: 1, into: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func append(node: SnapshotNode, depth: Int, into lines: inout [String]) {
        let prefix = String(repeating: "  ", count: depth)
        var parts: [String] = []
        parts.append(node.ref)
        parts.append("role=\(node.role)")
        if let title = node.title { parts.append("title=\(title)") }
        if let label = node.label { parts.append("label=\(label)") }
        if let valueSummary = node.valueSummary { parts.append("value=\(valueSummary)") }
        if let enabled = node.enabled { parts.append("enabled=\(enabled)") }
        if let focused = node.focused { parts.append("focused=\(focused)") }
        if let frame = node.frame {
            parts.append(
                String(
                    format: "frame={x:%.1f,y:%.1f,w:%.1f,h:%.1f}",
                    frame.x,
                    frame.y,
                    frame.width,
                    frame.height
                )
            )
        }
        lines.append("\(prefix)- \(parts.joined(separator: " "))")
        for child in node.children {
            self.append(node: child, depth: depth + 1, into: &lines)
        }
    }
}

