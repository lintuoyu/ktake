import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ rgb: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

private func render(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    let tile = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                      cornerWidth: 216, cornerHeight: 216, transform: nil)
    let stops = [color(0xffcb53), color(0xee3c60), color(0x652bd9)]
    let gradient = CGGradient(colorsSpace: sRGB, colors: stops as CFArray, locations: [0, 0.42, 1])!
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 123), end: CGPoint(x: 866, y: 887),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    // Slant the stroke centers while keeping the terminals round.
    func italicPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x + (512 - y) * 0.24, y: y)
    }
    context.setStrokeColor(color(0xffffff))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(138)
    context.move(to: italicPoint(374, 316))
    context.addLine(to: italicPoint(374, 708))
    context.strokePath()

    context.setLineWidth(pixels <= 32 ? 134 : 128)
    context.move(to: italicPoint(374, 555))
    context.addLine(to: italicPoint(633, 316))
    context.move(to: italicPoint(467, 481))
    context.addLine(to: italicPoint(651, 708))
    context.strokePath()
    return context.makeImage()!
}

@main
struct RenderAppIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for density in [1, 2] {
                let name = "icon_\(size)x\(size)\(density == 2 ? "@2x" : "").png"
                let url = folder.appendingPathComponent(name)
                guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(output, render(pixels: size * density), nil)
                guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}
