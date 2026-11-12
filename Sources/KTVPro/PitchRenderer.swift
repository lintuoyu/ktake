@preconcurrency import AVFoundation
import CryptoKit
import Darwin

/// Prepares seekable FLAC playback or a tempo-preserving pitch shift.
enum PitchRenderer {
    static let range = -6...6

    static func prepare(source: URL, semitones: Int, cacheDirectory: URL? = nil,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard range.contains(semitones) else { throw AppFailure(message: "升降调范围为 −6 到 +6 个半音。") }
        // AVPlayer can report a successful FLAC seek while decoding from an earlier position.
        guard semitones != 0 || source.pathExtension.lowercased() == "flac" else { return source }
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
        guard file.length > 0, format.sampleRate > 0, format.channelCount > 0 else {
            throw AppFailure(message: "音频文件没有可播放的样本。")
        }
        guard semitones == 0 || (1...2).contains(format.channelCount) else {
            throw AppFailure(message: "升降调目前支持单声道或双声道伴奏。")
        }
        if let cached = try? AVAudioFile(forReading: destination), cached.length == file.length,
           cached.processingFormat.sampleRate == format.sampleRate, cached.processingFormat.channelCount == format.channelCount {
            progress(1)
            return destination
        }

        let temporary = directory.appendingPathComponent("preparing-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if semitones == 0 {
            try decodePCM(file, to: temporary)
        } else {
            try renderShifted(file, semitones: semitones, to: temporary, progress: progress)
        }
        try Task.checkCancellation()
        // Concurrent preparations may share a cache key. Publish only a complete file.
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        progress(1)
        return destination
    }

    private static func decodePCM(_ file: AVAudioFile, to destination: URL) throws {
        let format = file.processingFormat
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw AppFailure(message: "无法准备 FLAC 播放缓冲区。")
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else {
                throw AppFailure(message: "FLAC 音频未能完整读取。")
            }
            try output.write(from: buffer)
        }
    }

    private static func renderShifted(_ file: AVAudioFile, semitones: Int, to destination: URL,
                                      progress: @escaping @Sendable (Double) -> Void) throws {
        let format = file.processingFormat
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
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
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
                try output.write(from: buffer)
                written += AVAudioFramePosition(length)
            }
            let fraction = Double(written) / Double(file.length)
            if fraction - lastReported >= 0.02 { progress(fraction); lastReported = fraction }
        }
    }
}
