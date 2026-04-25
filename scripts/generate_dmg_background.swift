import AppKit
import Foundation

struct DMGBackgroundRenderer {
    let size = NSSize(width: 720, height: 460)

    func render(to url: URL, appName: String) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(self.size.width),
            pixelsHigh: Int(self.size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RendererError.bitmapCreationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RendererError.bitmapCreationFailed
        }
        NSGraphicsContext.current = context

        let rect = NSRect(origin: .zero, size: self.size)
        self.drawBackground(in: rect)
        self.drawAccent(in: rect)
        self.drawText(in: rect, appName: appName)
        self.drawArrow(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
            throw RendererError.pngEncodingFailed
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try pngData.write(to: url)
    }

    private func drawBackground(in rect: NSRect) {
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.17, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.29, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1),
        ])
        gradient?.draw(in: rect, angle: -22)
    }

    private func drawAccent(in rect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSBezierPath(roundedRect: NSRect(x: 58, y: 54, width: 604, height: 352), xRadius: 28, yRadius: 28)
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.05).setFill()
        glow.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawText(in rect: NSRect, appName: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.98),
            .paragraphStyle: paragraph,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.82),
            .paragraphStyle: paragraph,
        ]
        NSString(string: "安装 \(appName)").draw(
            in: NSRect(x: 68, y: 332, width: 420, height: 48),
            withAttributes: titleAttributes
        )
        NSString(string: "将应用拖到 Applications 文件夹即可完成安装").draw(
            in: NSRect(x: 68, y: 292, width: 460, height: 30),
            withAttributes: subtitleAttributes
        )
    }

    private func drawArrow(in rect: NSRect) {
        let line = NSBezierPath()
        line.lineWidth = 12
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: 282, y: 212))
        line.line(to: NSPoint(x: 440, y: 212))
        NSColor(calibratedRed: 0.85, green: 0.92, blue: 1, alpha: 0.88).setStroke()
        line.stroke()

        let arrowHead = NSBezierPath()
        arrowHead.move(to: NSPoint(x: 424, y: 244))
        arrowHead.line(to: NSPoint(x: 464, y: 212))
        arrowHead.line(to: NSPoint(x: 424, y: 180))
        arrowHead.close()
        NSColor(calibratedRed: 0.85, green: 0.92, blue: 1, alpha: 0.88).setFill()
        arrowHead.fill()
    }

    enum RendererError: Error {
        case bitmapCreationFailed
        case pngEncodingFailed
    }
}

let outputPath = CommandLine.arguments.dropFirst().first
let appName = CommandLine.arguments.dropFirst(2).first ?? "Codex Panel.app"
let displayName = appName.hasSuffix(".app") ? String(appName.dropLast(4)) : appName

guard let outputPath else {
    fputs("Usage: swift generate_dmg_background.swift <output> [appName]\n", stderr)
    exit(1)
}

do {
    try DMGBackgroundRenderer().render(
        to: URL(fileURLWithPath: outputPath),
        appName: displayName
    )
} catch {
    fputs("Failed to render DMG background: \(error)\n", stderr)
    exit(1)
}
