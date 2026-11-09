@preconcurrency import AVFoundation
import CryptoKit

/// Prepares a tempo-preserving accompaniment, separate from the live vocal engine.
enum PitchRenderer {
    static let range = -6...6

    static func prepare(source: URL, semitones: Int, cacheDirectory: URL? = nil,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard range.contains(semitones) else { throw AppFailure(message: "升降调范围为 −6 到 +6 个半音。") }
        guard semitones != 0 else { return source }
        let task = Task.detached(priority: .userInitiated) {
            try render(source: source, semitones: semitones, cacheDirectory: cacheDirectory, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func render(source: URL, semitones: Int, cacheDirectory: URL?,
                               progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KTV Pro/Pitch/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent("\(hash)-\(semitones).caf")
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, (1...2).contains(format.channelCount) else {
            throw AppFailure(message: "升降调目前支持单声道或双声道伴奏。")
        }
        if let cached = try? AVAudioFile(forReading: destination), cached.length == file.length,
           cached.processingFormat.sampleRate == format.sampleRate, cached.processingFormat.channelCount == format.channelCount {
            progress(1)
            return destination
        }

        let temporary = directory.appendingPathComponent("preparing-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = Float(semitones * 100)
        pitch.rate = 1
        pitch.overlap = 16
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        player.scheduleFile(file, at: nil)
        try engine.start()
        player.play()
        defer { engine.stop() }
        let latencyFrames = AVAudioFramePosition((pitch.latency * format.sampleRate).rounded())
        var toSkip = latencyFrames
        var written: AVAudioFramePosition = 0
        var retries = 0
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var output: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw AppFailure(message: "无法准备升降调缓冲区。") }
        var lastReported = 0.0
        while written < file.length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, file.length - written + toSkip))
            let result = try engine.renderOffline(count, to: buffer)
            if result == .cannotDoInCurrentContext {
                retries += 1
                guard retries < 500 else { throw AppFailure(message: "升降调处理暂时无法继续，请重新尝试。") }
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            guard result == .success, buffer.frameLength > 0 else { throw AppFailure(message: "升降调处理失败（\(result.rawValue)）。") }
            retries = 0
            let skip = Int(min(toSkip, AVAudioFramePosition(buffer.frameLength)))
            toSkip -= AVAudioFramePosition(skip)
            let available = Int(buffer.frameLength) - skip
            let length = min(available, Int(file.length - written))
            if length > 0 {
                if skip > 0 {
                    for channel in 0..<Int(format.channelCount) {
                        let samples = buffer.floatChannelData![channel]
                        memmove(samples, samples.advanced(by: skip), length * MemoryLayout<Float>.size)
                    }
                }
                buffer.frameLength = AVAudioFrameCount(length)
                try output!.write(from: buffer)
                written += AVAudioFramePosition(length)
            }
            let fraction = Double(written) / Double(file.length)
            if fraction - lastReported >= 0.02 { progress(fraction); lastReported = fraction }
        }
        output = nil // Close the header before publishing a cache entry.
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }
}
