import AppKit
import CoreGraphics
import Foundation

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            let type = element(at: index, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}

@discardableResult
private func drawGradient(
    in context: CGContext,
    colors: [NSColor],
    start: CGPoint,
    end: CGPoint
) -> Bool {
    let cgColors = colors.map { $0.cgColor } as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil) else {
        return false
    }
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    return true
}

private func roundedPath(in rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

private func drawWaveform(in context: CGContext, rect: CGRect) {
    let yMid = rect.midY + 8
    let xStart = rect.minX + 90
    let xEnd = rect.maxX - 90

    let path = CGMutablePath()
    path.move(to: CGPoint(x: xStart, y: yMid))
    path.addCurve(
        to: CGPoint(x: xStart + 120, y: yMid + 6),
        control1: CGPoint(x: xStart + 35, y: yMid - 10),
        control2: CGPoint(x: xStart + 80, y: yMid + 14)
    )
    path.addCurve(
        to: CGPoint(x: xStart + 205, y: yMid + 140),
        control1: CGPoint(x: xStart + 145, y: yMid + 24),
        control2: CGPoint(x: xStart + 180, y: yMid + 115)
    )
    path.addCurve(
        to: CGPoint(x: xStart + 295, y: yMid - 132),
        control1: CGPoint(x: xStart + 225, y: yMid + 115),
        control2: CGPoint(x: xStart + 268, y: yMid - 110)
    )
    path.addCurve(
        to: CGPoint(x: xStart + 390, y: yMid + 175),
        control1: CGPoint(x: xStart + 320, y: yMid - 150),
        control2: CGPoint(x: xStart + 360, y: yMid + 140)
    )
    path.addCurve(
        to: CGPoint(x: xStart + 505, y: yMid - 102),
        control1: CGPoint(x: xStart + 420, y: yMid + 160),
        control2: CGPoint(x: xStart + 468, y: yMid - 80)
    )
    path.addCurve(
        to: CGPoint(x: xStart + 620, y: yMid + 8),
        control1: CGPoint(x: xStart + 542, y: yMid - 120),
        control2: CGPoint(x: xStart + 585, y: yMid + 28)
    )
    path.addCurve(
        to: CGPoint(x: xEnd, y: yMid),
        control1: CGPoint(x: xStart + 650, y: yMid + 12),
        control2: CGPoint(x: xEnd - 45, y: yMid - 10)
    )

    context.saveGState()
    context.addPath(path)
    context.setLineWidth(86)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(NSColor(hex: 0x7C5BFF, alpha: 0.17).cgColor)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.setLineWidth(62)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    _ = drawGradient(
        in: context,
        colors: [
            NSColor(hex: 0x54E6F6, alpha: 0.96),
            NSColor(hex: 0x7D67FF, alpha: 0.97),
            NSColor(hex: 0x3C6DFF, alpha: 0.96)
        ],
        start: CGPoint(x: rect.minX + 140, y: rect.maxY - 180),
        end: CGPoint(x: rect.maxX - 140, y: rect.minY + 170)
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.setLineWidth(14)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.43).cgColor)
    context.strokePath()
    context.restoreGState()
}

private func drawIcon(size: Int = 1024) -> NSImage {
    let width = size
    let height = size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let context = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(size: NSSize(width: width, height: height))
    }

    let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    context.setFillColor(NSColor.clear.cgColor)
    context.fill(canvas)

    let iconRect = canvas.insetBy(dx: 74, dy: 74)
    let iconPath = roundedPath(in: iconRect, radius: 190)

    context.saveGState()
    context.addPath(iconPath)
    context.clip()
    _ = drawGradient(
        in: context,
        colors: [
            NSColor(hex: 0xD6E9FF, alpha: 0.98),
            NSColor(hex: 0x96B4E3, alpha: 0.98),
            NSColor(hex: 0x8D86D6, alpha: 0.98)
        ],
        start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.maxX, y: iconRect.minY)
    )
    context.restoreGState()

    let topHighlightRect = CGRect(
        x: iconRect.minX + 34,
        y: iconRect.midY + 60,
        width: iconRect.width - 68,
        height: iconRect.height * 0.37
    )
    context.saveGState()
    context.addPath(roundedPath(in: topHighlightRect, radius: 130))
    context.clip()
    _ = drawGradient(
        in: context,
        colors: [
            NSColor.white.withAlphaComponent(0.58),
            NSColor.white.withAlphaComponent(0.09),
            NSColor.white.withAlphaComponent(0.00)
        ],
        start: CGPoint(x: topHighlightRect.midX, y: topHighlightRect.maxY),
        end: CGPoint(x: topHighlightRect.midX, y: topHighlightRect.minY)
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(iconPath)
    context.setLineWidth(11)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    context.strokePath()
    context.restoreGState()

    let innerStrokeRect = iconRect.insetBy(dx: 12, dy: 12)
    context.saveGState()
    context.addPath(roundedPath(in: innerStrokeRect, radius: 176))
    context.setLineWidth(3)
    context.setStrokeColor(NSColor(hex: 0x66E9F8, alpha: 0.36).cgColor)
    context.strokePath()
    context.restoreGState()

    drawWaveform(in: context, rect: iconRect)

    let glowRect = iconRect.insetBy(dx: 120, dy: 118)
    context.saveGState()
    context.addPath(roundedPath(in: glowRect, radius: 130))
    context.clip()
    _ = drawGradient(
        in: context,
        colors: [
            NSColor.white.withAlphaComponent(0.22),
            NSColor.white.withAlphaComponent(0.00)
        ],
        start: CGPoint(x: glowRect.midX, y: glowRect.maxY),
        end: CGPoint(x: glowRect.midX, y: glowRect.minY)
    )
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(rep)
    return image
}

func writePNG(image: NSImage, to url: URL) throws {
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "VoiceScribe.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try pngData.write(to: url, options: .atomic)
}

let targetPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let outputURL = URL(fileURLWithPath: targetPath)
let icon = drawIcon()
try writePNG(image: icon, to: outputURL)
print("Wrote icon: \(outputURL.path)")
