@preconcurrency import AVFoundation
import Foundation

/// Renders timeline gaps as PCM silence so every exported file has a defined zero point.
enum WAVRenderer {
    static func write(asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix? = nil,
                      to destination: URL, sampleRate: Int32, channels: UInt32,
                      duration: Double, leadingFrames: Int64 = 0) throws {
        let frameCount = (duration * Double(sampleRate)).rounded()
        let maximumFrames = Int64(UInt32.max - 4096) / (Int64(channels) * 3)
        guard leadingFrames >= 0, frameCount.isFinite, frameCount >= 1,
              frameCount <= Double(maximumFrames - leadingFrames) else {
            throw AppFailure(message: "音轨时长无效或超出单个 WAV 的大小上限。")
        }
        let outputLength = Int64(frameCount) + leadingFrames
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".KTV-\(UUID().uuidString).wav")
        let files = FileManager.default
        defer { try? files.removeItem(at: temporary) }
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                  AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                                  AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                  AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
        output.audioMix = mix
        guard reader.canAdd(output) else { throw AppFailure(message: "无法读取导出音轨。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppFailure(message: "无法开始音频导出。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var settings = pcm
        settings[AVLinearPCMBitDepthKey] = 24
        settings[AVLinearPCMIsFloatKey] = false
        var file: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: settings,
                                                 commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let format = file?.processingFormat,
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw AppFailure(message: "无法准备导出的音频缓冲。")
        }
        silence.frameLength = silence.frameCapacity
        for audioBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let bytes = audioBuffer.mData { memset(bytes, 0, Int(audioBuffer.mDataByteSize)) }
        }
        var buffer: AVAudioPCMBuffer?
        var framesWritten: Int64 = 0
        var wroteSamples = false
        func fillSilence(to target: Int64) throws {
            while framesWritten < target {
                try Task.checkCancellation()
                let count = min(Int64(silence.frameCapacity), target - framesWritten)
                silence.frameLength = AVAudioFrameCount(count)
                try file?.write(from: silence)
                framesWritten += count
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let firstFrame = timestamp.isNumeric ? CMTimeConvertScale(timestamp, timescale: sampleRate, method: .roundHalfAwayFromZero).value + leadingFrames : framesWritten
            try fillSilence(to: min(outputLength, firstFrame))
            let skip = max(0, framesWritten - firstFrame)
            let count = min(Int64(CMSampleBufferGetNumSamples(sample)) - skip, outputLength - framesWritten)
            guard count > 0 else { continue }
            if (buffer?.frameCapacity ?? 0) < AVAudioFrameCount(count) {
                buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            }
            guard let buffer else { throw AppFailure(message: "无法准备导出的音频缓冲。") }
            buffer.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(skip), frameCount: Int32(count),
                                                              into: buffer.mutableAudioBufferList) == noErr else {
                throw AppFailure(message: "无法读取导出样本。")
            }
            try file?.write(from: buffer)
            framesWritten += count
            wroteSamples = true
        }
        guard reader.status == .completed, wroteSamples else {
            throw reader.error ?? AppFailure(message: "没有读到可导出的音频。")
        }
        try fillSilence(to: outputLength)
        file = nil
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary)
        } else { try files.moveItem(at: temporary, to: destination) }
    }
}
