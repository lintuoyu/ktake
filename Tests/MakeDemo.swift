import AppKit
import AVFoundation

/// A silent, generated local fixture for checking playback without user media.
@main
struct MakeDemo {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 960, AVVideoHeightKey: 540
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 960, kCVPixelBufferHeightKey as String: 540])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<360 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &pixelBuffer)
            let buffer = pixelBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 960, height: 540,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.04, green: 0.12, blue: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
            context.setFillColor(CGColor(red: 0.15, green: 0.42, blue: 0.35, alpha: 1))
            let offset = sin(Double(frame) / 40) * 75
            context.fillEllipse(in: CGRect(x: 580 + offset, y: 80, width: 350, height: 350))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text = "KTV Pro\nMV playback check"
            (text as NSString).draw(at: NSPoint(x: 70, y: 250), withAttributes: [
                .font: NSFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: NSColor.white
            ])
            (String(format: "%02d / 12 seconds", frame / 30) as NSString).draw(at: NSPoint(x: 74, y: 180),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                                 .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
            NSGraphicsContext.restoreGraphicsState()
            context.setFillColor(CGColor(red: 0.43, green: 0.86, blue: 0.73, alpha: 1))
            context.fill(CGRect(x: 70, y: 100, width: 820 * Double(frame) / 359, height: 4))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        print(url.path)
    }
}
