import Foundation
import AVFoundation

private struct MixTestFailure: Error, CustomStringConvertible { let description: String }

@main
struct TakeMixSmokeTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ktv-mix-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let dry = root.appendingPathComponent("dry.wav")
        let backing = root.appendingPathComponent("backing.wav")
        try makeTone(at: dry, rate: 48_000, channels: 1, seconds: 1, hz: 440, active: 0.12..<0.35)
        try makeTone(at: backing, rate: 44_100, channels: 2, seconds: 3, hz: 880, active: 1.15..<1.32)
        let original = try Data(contentsOf: dry)
        let take = Take(id: UUID(), createdAt: .now, filename: dry.lastPathComponent, songName: "合成录音",
                        mediaPath: nil, videoStartSeconds: 1, duration: 1, sampleRate: 48_000, interrupted: false,
                        accompanimentPath: backing.path, captureSongSeconds: 0.9, backingVolume: 0.65, hasBacking: true)
        let request = TakeReviewRequest(take: take, vocalURL: dry, outputUID: nil)
        let mix = try await TakeMix.build(for: request, backingURL: backing, vocalDelayMS: 0)
        let output = root.appendingPathComponent("mix.wav")
        try await mix.exportWAV(to: output, levels: TakeMixLevels(vocal: 0.6, backing: 0.4))
        let file = try AVAudioFile(forReading: output)
        try expect(file.fileFormat.channelCount == 2 && file.fileFormat.sampleRate == 48_000 && file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24, "stereo 24-bit 48 kHz WAV")
        try expect(abs(file.length - 48_000) <= 2, "mix ends with the take, not at end of backing")
        let samples = try read(output)
        try expect(tone(samples, at: 0.05, hz: 880) < 0.002, "no backing before the actual recording location")
        let vocal = tone(samples, at: 0.15, hz: 440)
        let music = tone(samples, at: 0.27, hz: 880)
        try expect(vocal > 0.08 && music > 0.06, "both tracks rendered at the correct take positions")

        let shifted = try await TakeMix.build(for: request, backingURL: backing, vocalDelayMS: 120)
        try await shifted.exportWAV(to: output, levels: TakeMixLevels(vocal: 0.3, backing: 0.4))
        let after = try read(output)
        let early = tone(after, at: 0.15, hz: 440)
        let shiftedVocal = tone(after, at: 0.27, hz: 440)
        try expect(early < 0.002 && abs(shiftedVocal / vocal - 0.5) < 0.03,
                   "positive correction shifts vocal later and export uses preview gains: early=\(early) shifted=\(shiftedVocal) original=\(vocal)")
        try expect(abs(tone(after, at: 0.27, hz: 880) - music) < 0.002, "vocal correction does not move the backing")
        try expect(abs(after.count - 53_760) <= 2, "delayed vocal tail is preserved")
        let preserved = try Data(contentsOf: dry)
        try expect(preserved == original, "export never modifies the source WAV")
        print("PASS: start clock placement, mid-song crop, two independent gains, offset, stereo WAV, atomic replacement and unchanged dry audio")

        let patchURL = root.appendingPathComponent("patch.wav")
        try makeTone(at: patchURL, rate: 48_000, channels: 1, seconds: 0.08, hz: 1320, active: 0..<0.08)
        let range = PracticeRange(start: 0.1, end: 0.36)
        let patchTake = Take(id: UUID(), createdAt: .now, filename: patchURL.lastPathComponent, songName: take.songName,
                             mediaPath: nil, videoStartSeconds: 1, duration: 0.08, sampleRate: 48_000, interrupted: true,
                             captureSongSeconds: 1.1, parentTakeID: take.id, punchRange: range)
        let replacement = try await TakeMix.build(for: request, backingURL: backing, vocalDelayMS: 0,
                                                   patch: TakePatch(take: patchTake, url: patchURL, range: range))
        try await replacement.exportWAV(to: output, levels: TakeMixLevels(vocal: 0.6, backing: 0.4))
        let replaced = try read(output)
        try expect(replaced.count == samples.count, "A/B versions have the same timeline and length")
        try expect(abs(tone(replaced, at: 0.15, hz: 440, seconds: 0.025) - vocal) < 0.003, "late-start coverage keeps the earlier original")
        let inserted = tone(replaced, at: 0.218, hz: 1320, seconds: 0.025)
        let originalLeak = tone(replaced, at: 0.218, hz: 440, seconds: 0.025)
        try expect(abs(inserted - vocal) < 0.003 && originalLeak < 0.002,
                   "the selected span uses only the punch-in: replacement=\(inserted), original outside=\(vocal), original inside=\(originalLeak)")
        try expect(abs(tone(replaced, at: 0.30, hz: 440, seconds: 0.025) - vocal) < 0.003, "early-stop coverage keeps the original tail")
        try expect(abs(tone(replaced, at: 0.29, hz: 880, seconds: 0.025) - tone(samples, at: 0.29, hz: 880, seconds: 0.025)) < 0.002,
                   "replacement leaves accompaniment unchanged")
        print("PASS: punch-in uses actual capture coverage, leaves the rest untouched, and preserves the timeline")

        let preview = try await TakeEffectsPreview.prepare(from: mix, settings: VocalSettings())
        let reviewLevels = TakeMixLevels(vocal: 0.6, backing: 0.4)
        let wet = try await readPreview(preview, levels: reviewLevels, reverb: 30, to: output)
        let bypassed = try await readPreview(preview, levels: reviewLevels, reverb: 30, enabled: false, to: output)
        try expect(wet.count == samples.count && zip(bypassed, samples).allSatisfy { abs($0 - $1) < 0.00001 },
                   "reverb bypass preserves the dry mix and its timeline")
        try expect(rms(wet, during: 0.43..<0.65) > 0.0001 && rms(bypassed, during: 0.43..<0.65) < 0.00001,
                   "the effect produces a reverb tail after the vocal")
        let backingOnly = try await readPreview(preview, levels: TakeMixLevels(vocal: 0, backing: 0.4), reverb: 0, to: output)
        let backingWithEffect = try await readPreview(preview, levels: TakeMixLevels(vocal: 0, backing: 0.4), reverb: 45, to: output)
        try expect(backingOnly == backingWithEffect, "the accompaniment does not pass through the reverb")
        let standalone = try await TakeMix.build(for: request, backingURL: nil, vocalDelayMS: 0)
        let standalonePreview = try await TakeEffectsPreview.prepare(from: standalone, settings: VocalSettings())
        let solo = try await readPreview(standalonePreview, levels: TakeMixLevels(includesBacking: false), reverb: 30, to: output)
        try expect(rms(solo, during: 0.43..<0.65) > 0.0001, "reverb also works for a recording without accompaniment")
        let testVoice = root.appendingPathComponent("effect-test.wav")
        try makeTone(at: testVoice, rate: 48_000, channels: 1, seconds: 1, hz: 3200, active: 0.05..<0.9)
        let toneBase = try await TakeMix.build(for: TakeReviewRequest(take: take, vocalURL: testVoice, outputUID: nil),
                                               backingURL: nil, vocalDelayMS: 0)
        let mutedHighs = try await TakeEffectsPreview.prepare(from: toneBase, settings: VocalSettings(brightness: -4, compression: 0))
        let brightHighs = try await TakeEffectsPreview.prepare(from: toneBase, settings: VocalSettings(brightness: 6, compression: 0))
        let compressed = try await TakeEffectsPreview.prepare(from: toneBase, settings: VocalSettings(brightness: 6, compression: 1))
        let soloLevels = TakeMixLevels(includesBacking: false)
        let darkSamples = try await readPreview(mutedHighs, levels: soloLevels, reverb: 0, to: output)
        let brightSamples = try await readPreview(brightHighs, levels: soloLevels, reverb: 0, to: output)
        let compressedSamples = try await readPreview(compressed, levels: soloLevels, reverb: 0, to: output)
        try expect(rms(brightSamples, during: 0.3..<0.7) > rms(darkSamples, during: 0.3..<0.7) * 2,
                   "brightness changes the level near the vocal presence band")
        try expect(rms(compressedSamples, during: 0.3..<0.7) < rms(brightSamples, during: 0.3..<0.7) * 0.95,
                   "compression controls the peaks of an otherwise identical vocal")
        try await mix.exportWAV(to: output, levels: reviewLevels)
        let exported = try read(output)
        let originalAfterPreview = try Data(contentsOf: dry)
        try expect(exported == samples && originalAfterPreview == original, "preview leaves the dry source and export unchanged")
        print("PASS: audible brightness, compression and reverb, dry bypass, unchanged backing, standalone takes and unaffected WAV export")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw MixTestFailure(description: message) }
    }
    private static func makeTone(at url: URL, rate: Double, channels: AVAudioChannelCount,
                                 seconds: Double, hz: Double, active: Range<Double>) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / rate
            let value = active.contains(time) ? Float(0.3 * sin(2 * .pi * hz * time)) : 0
            for channel in 0..<Int(channels) { buffer.floatChannelData![channel][frame] = value }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    private static func readPreview(_ preview: TakeEffectsPreview, levels: TakeMixLevels, reverb: Float,
                                    enabled: Bool = true, to output: URL) async throws -> [Float] {
        let tracks = try await preview.asset.loadTracks(withMediaType: .audio)
        let duration = try await preview.asset.load(.duration)
        try WAVRenderer.write(asset: preview.asset, tracks: tracks, mix: preview.audioMix(levels, enabled: enabled, reverb: reverb),
                              to: output, sampleRate: 48_000, channels: 2, duration: duration.seconds)
        return try read(output)
    }
    private static func rms(_ samples: [Float], during range: Range<Double>) -> Double {
        let segment = samples[Int(range.lowerBound * 48_000)..<Int(range.upperBound * 48_000)]
        return sqrt(segment.reduce(0) { $0 + Double($1 * $1) } / Double(segment.count))
    }
    private static func tone(_ samples: [Float], at start: Double, hz: Double, seconds: Double = 0.05) -> Double {
        let first = Int((start * 48_000).rounded())
        let count = Int((seconds * 48_000).rounded())
        var sum = 0.0
        var quadrature = 0.0
        let step = 2.0 * Double.pi * hz / 48_000.0
        for frame in first..<(first + count) {
            sum += Double(samples[frame]) * sin(step * Double(frame))
            quadrature += Double(samples[frame]) * cos(step * Double(frame))
        }
        return hypot(sum, quadrature) * 2 / Double(count)
    }
}
