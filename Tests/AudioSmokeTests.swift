import Foundation
import AVFoundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(description: message) }
}

@main
struct AudioSmokeTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ktvpro-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        for i in 0..<512 { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.1) }
        let url = root.appendingPathComponent("take.wav")
        let writer = try RecordingWriter(url: url, format: format)
        for i in 0..<10 {
            writer.append(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition(i * 512), atRate: 48000))
        }
        let result = await finish(writer)
        try check(result.frames == 5120 && result.issue == nil, "WAV frame count / successful close")
        let file = try AVAudioFile(forReading: url)
        try check(file.length == 5120, "WAV must contain every submitted frame")
        try check(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24, "WAV must be 24-bit PCM")
        try check(file.fileFormat.channelCount == 1 && file.fileFormat.sampleRate == 48000, "WAV sample rate and channels")
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
        try file.read(into: read, frameCount: 512)
        try check(abs(read.floatChannelData![0][40] - buffer.floatChannelData![0][40]) < 0.00001, "Dry recording samples must be preserved")
        print("PASS: 24-bit mono WAV, frame integrity, dry sample preservation")

        let stoppedFrames = result.frames
        writer.append(buffer, at: AVAudioTime(sampleTime: 10000, atRate: 48000))
        let afterStop = await finish(writer)
        try check(afterStop.frames == stoppedFrames, "Frames after finish must be rejected")

        let full = try RecordingWriter(url: root.appendingPathComponent("full.wav"), format: format, poolSize: 0)
        full.append(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48000))
        let overflow = await finish(full)
        try check(overflow.issue != nil && overflow.frames == 0, "Backpressure must be visible, never silent")
        print("PASS: late-buffer rejection and disk backpressure reporting")

        let bridge = CaptureBridge()
        bridge.receive(buffer, time: AVAudioTime(sampleTime: 0, atRate: 48000))
        try check(bridge.meter.peakDB > -11 && bridge.meter.peakDB < -10, "Input level must match source")
        buffer.floatChannelData![0][0] = 1
        bridge.receive(buffer, time: AVAudioTime(sampleTime: 512, atRate: 48000))
        try check(bridge.meter.clipUntil > ProcessInfo.processInfo.systemUptime, "Clip indicator must latch")
        let testWriter = try RecordingWriter(url: root.appendingPathComponent("test.wav"), format: format)
        bridge.beginMicTest(testWriter)
        buffer.floatChannelData![0][0] = 0.3
        bridge.receive(buffer, time: AVAudioTime(hostTime: 100))
        buffer.floatChannelData![0][0] = 1
        bridge.receive(buffer, time: AVAudioTime(hostTime: 200))
        let testLevel = bridge.endMicTest()
        let testResult = await finish(testWriter)
        try check(testResult.frames == 1024 && testResult.firstHostTime == 100 && testLevel.nearClipping && testLevel.peakDB == 0,
                  "mic test collects its own peak and clip, and records the first written host time")
        print("PASS: input metering and clip detection")

        let dryTail = try renderEffects(space: 0)
        let wetTail = try renderEffects(space: 30)
        try check(wetTail > dryTail * 2 + 0.000001, "Reverb must produce an audible tail")
        let mutedTail = try renderEffects(space: 30, monitoring: false)
        try check(mutedTail == 0, "Monitoring off must also silence the reverb tail")
        print("PASS: actual Apple EQ / dynamics / reverb chain renders offline, with reverb tail")
        print("PASS: post-effect monitor mute silences the entire effect chain")
        let quickDry = try renderEffects(space: 0, quickPlayback: true)
        let quickWet = try renderEffects(space: 26, quickPlayback: true)
        try check(quickWet > quickDry * 2 + 0.000001, "List playback must apply the recorded reverb")
        print("PASS: list playback's reverb graph renders a tail at the recorded setting")
        try check(timeLabel(.nan) == "00:00" && timeLabel(125) == "02:05", "Duration formatting")
        print("All audio smoke tests passed. No microphone or speaker was opened.")
    }

    static func finish(_ writer: RecordingWriter) async -> RecordingWriter.Result {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }

    @MainActor static func renderEffects(space: Float, monitoring: Bool = true, quickPlayback: Bool = false) throws -> Double {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        if quickPlayback {
            try TakePlayer.connectReverb(in: engine, source: player, format: format, amount: space)
        } else {
            let monitor = AVAudioMixerNode()
            let effects = VocalEffects()
            effects.update(brightness: 2, compression: 0.35, space: space)
            engine.attach(player)
            engine.attach(monitor)
            for node in effects.nodes { engine.attach(node) }
            engine.connect(player, to: effects.eq, format: format)
            engine.connect(effects.eq, to: effects.dynamics, format: format)
            engine.connect(effects.dynamics, to: effects.reverb, format: format)
            engine.connect(effects.reverb, to: monitor, format: stereo)
            engine.connect(monitor, to: engine.mainMixerNode, format: stereo)
            monitor.outputVolume = monitoring ? 1 : 0
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        source.frameLength = 48000
        for i in 0..<48000 {
            source.floatChannelData![0][i] = i < 4800 ? 0.2 * sin(Float(i) * 2 * .pi * 440 / 48000) : 0
        }
        player.scheduleBuffer(source)
        try engine.start()
        player.play()
        defer { engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var frames = 0
        var tailEnergy = 0.0
        var retries = 0
        while frames < 48000 {
            let count = AVAudioFrameCount(min(512, 48000 - frames))
            let status = try engine.renderOffline(count, to: output)
            if status == .cannotDoInCurrentContext {
                retries += 1
                try check(retries < 100, "Offline engine stalled")
                continue
            }
            try check(status == .success, "Offline render failed: \(status.rawValue)")
            for i in 0..<Int(output.frameLength) {
                let value = output.floatChannelData![0][i]
                try check(value.isFinite && abs(value) < 4, "Effect output must be finite and bounded")
                if frames + i > 12000 { tailEnergy += Double(value * value) }
            }
            frames += Int(output.frameLength)
        }
        return tailEnergy
    }
}
