import Foundation
import AVFoundation
import CryptoKit

struct PitchTestFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PitchTestFailure(message: message) }
}

@main
struct PitchSmokeTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ktvpro-pitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("stereo-tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
        input.frameLength = input.frameCapacity
        for channel in 0..<2 {
            for i in 0..<Int(input.frameLength) {
                let t = Double(i) / 48000
                input.floatChannelData![channel][i] = t >= 0.5 && t < 2.5 ? Float(0.25 * sin(2 * .pi * t * (channel == 0 ? 220 : 330))) : 0
            }
        }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: input) }
        let originalHash = SHA256.hash(data: try Data(contentsOf: source))
        for semitones in [-6, 3, 6] {
            let url = try await PitchRenderer.prepare(source: source, semitones: semitones, cacheDirectory: root)
            let file = try AVAudioFile(forReading: url)
            try require(file.length == 192000 && file.processingFormat.channelCount == 2, "Pitch must preserve frame length and stereo")
            let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: output)
            for channel in 0..<2 {
                let samples = output.floatChannelData![channel]
                var crossings = 0
                for i in 48001..<96000 {
                    try require(samples[i].isFinite && abs(samples[i]) < 1, "Output must be finite and bounded")
                    if samples[i - 1] <= 0 && samples[i] > 0 { crossings += 1 }
                }
                let expected = (channel == 0 ? 220.0 : 330.0) * pow(2, Double(semitones) / 12)
                try require(abs(Double(crossings) - expected) < 2, "Wrong frequency for \(semitones): \(crossings) vs \(expected)")
            }
            let samples = output.floatChannelData![0]
            let first = (0..<Int(output.frameLength)).first { abs(samples[$0]) > 0.02 } ?? -1
            print("Pitch \(semitones): first audible sample at \(Double(first) / 48000) s (source starts 0.5 s)")
            try require(abs(Double(first) / 48000 - 0.5) < 0.05, "Pitch must not add a large onset delay")
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let cached = try await PitchRenderer.prepare(source: source, semitones: semitones, cacheDirectory: root)
            try require(cached == url, "Cache identity")
            let after = try cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try require(modified == after, "Cache hit must not re-render")
        }
        let finalHash = SHA256.hash(data: try Data(contentsOf: source))
        try require(finalHash == originalHash, "Source file must remain unchanged")
        let zero = try await PitchRenderer.prepare(source: source, semitones: 0, cacheDirectory: root)
        try require(zero == source, "Original key must use original file")
        print("PASS: pitch frequency, fixed tempo/duration, stereo, onset alignment, cache, original preservation")
        if CommandLine.arguments.count > 1 {
            let mp3 = URL(fileURLWithPath: CommandLine.arguments[1])
            let cache = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let start = Date()
            let prepared = try await PitchRenderer.prepare(source: mp3, semitones: -2, cacheDirectory: cache)
            let original = try AVAudioFile(forReading: mp3)
            let shifted = try AVAudioFile(forReading: prepared)
            try require(original.length == shifted.length && original.processingFormat.channelCount == shifted.processingFormat.channelCount, "Real MP3 duration / channels")
            print("PASS: real MP3 −2 semitones, \(shifted.length) frames; preparation took \(Date().timeIntervalSince(start)) s")
        }
    }
}
