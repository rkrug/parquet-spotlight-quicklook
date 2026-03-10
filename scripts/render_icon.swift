import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render_icon.swift <size> <output-png>\n", stderr)
    exit(2)
}

guard let size = Int(CommandLine.arguments[1]), size > 0 else {
    fputs("Invalid size.\n", stderr)
    exit(2)
}

let outputPath = CommandLine.arguments[2]
let canvasSize = CGFloat(size)
let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize))

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Unable to acquire graphics context.\n", stderr)
    exit(1)
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let outerRect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
let inset = canvasSize * 0.06
let cardRect = outerRect.insetBy(dx: inset, dy: inset)
let radius = canvasSize * 0.17

let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)
cardPath.addClip()

let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.08, green: 0.47, blue: 0.85, alpha: 1.0),
        NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.91, alpha: 1.0)
    ]
)
gradient?.draw(in: cardPath, angle: 60)

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: canvasSize * 0.30, weight: .bold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.96)
]
let title = "PQ" as NSString
let titleSize = title.size(withAttributes: titleAttributes)
let titlePoint = CGPoint(
    x: (canvasSize - titleSize.width) / 2.0,
    y: canvasSize * 0.56
)
title.draw(at: titlePoint, withAttributes: titleAttributes)

let lineColor = NSColor.white.withAlphaComponent(0.93).cgColor
context.setStrokeColor(lineColor)
context.setLineWidth(canvasSize * 0.030)
context.setLineCap(.round)

let root = CGPoint(x: canvasSize * 0.50, y: canvasSize * 0.46)
let mid = CGPoint(x: canvasSize * 0.50, y: canvasSize * 0.34)
let left = CGPoint(x: canvasSize * 0.33, y: canvasSize * 0.20)
let center = CGPoint(x: canvasSize * 0.50, y: canvasSize * 0.20)
let right = CGPoint(x: canvasSize * 0.67, y: canvasSize * 0.20)

context.move(to: root)
context.addLine(to: mid)
context.strokePath()

for point in [left, center, right] {
    context.move(to: mid)
    context.addLine(to: point)
    context.strokePath()
}

context.setFillColor(NSColor.white.cgColor)
let nodeRadius = canvasSize * 0.050
for point in [root, mid, left, center, right] {
    let rect = CGRect(
        x: point.x - nodeRadius,
        y: point.y - nodeRadius,
        width: nodeRadius * 2.0,
        height: nodeRadius * 2.0
    )
    context.fillEllipse(in: rect)
}

let outline = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)
NSColor.white.withAlphaComponent(0.18).setStroke()
outline.lineWidth = max(2.0, canvasSize * 0.008)
outline.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let pngData = rep.representation(using: .png, properties: [.compressionFactor: 1.0])
else {
    fputs("Failed to create PNG data.\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL, options: .atomic)
