@preconcurrency import AVFoundation
import Foundation

/// EQ and compression are prepared off the main thread. The player mixes the
/// colored voice and its reverb separately so reverb and bypass stay responsive.
final class TakeEffectsPreview: @unchecked Sendable {
    let asset: AVMutableComposition
    private let processedTrack: AVCompositionTrack
    private let wetTrack: AVCompositionTrack
    private let base: TakeMix
    private let directory: URL

    private init(asset: AVMutableComposition, processedTrack: AVCompositionTrack, wetTrack: AVCompositionTrack,
                 base: TakeMix, directory: URL) {
        self.asset = asset
        self.processedTrack = processedTrack
        self.wetTrack = wetTrack
        self.base = base
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func audioMix(_ levels: TakeMixLevels, enabled: Bool, reverb: Float) -> AVAudioMix {
        base.audioMix(levels, processedTrack: processedTrack, wetTrack: wetTrack, effectsEnabled: enabled, reverb: reverb)
    }

    static func prepare(from base: TakeMix, settings: VocalSettings) async throws -> TakeEffectsPreview {
        let job = Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let directory = files.temporaryDirectory.appendingPathComponent("KTake-vocal-preview-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let dry = directory.appendingPathComponent("vocal.wav")
            let processed = directory.appendingPathComponent("processed.caf")
            let wet = directory.appendingPathComponent("reverb.caf")
            var completed = false
            defer {
                if !completed { try? files.removeItem(at: directory) }
            }
            try base.writeVocalStem(to: dry)
            try renderVocal(from: dry, to: processed, tone: settings)
            try renderVocal(from: processed, to: wet, tone: nil)
            try files.removeItem(at: dry)
            try Task.checkCancellation()

            guard let composition = base.asset.mutableCopy() as? AVMutableComposition else {
                throw AppFailure(message: "无法创建人声效果回听。")
            }
            let duration = try await base.asset.load(.duration)
            let processedTrack = try await insertAudio(processed, into: composition, duration: duration)
            let wetTrack = try await insertAudio(wet, into: composition, duration: duration)
            try Task.checkCancellation()
            completed = true
            return TakeEffectsPreview(asset: composition, processedTrack: processedTrack, wetTrack: wetTrack,
                                      base: base, directory: directory)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    private static func insertAudio(_ url: URL, into composition: AVMutableComposition, duration: CMTime) async throws -> AVCompositionTrack {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppFailure(message: "无法添加人声效果音轨。")
        }
        let range = try await source.load(.timeRange)
        try track.insertTimeRange(CMTimeRange(start: range.start, duration: CMTimeMinimum(range.duration, duration)), of: source, at: .zero)
        return track
    }

    private static func renderVocal(from source: URL, to destination: URL, tone: VocalSettings?) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = input.processingFormat
        let block: AVAudioFrameCount = 4096
        let channels: AVAudioChannelCount = tone == nil ? 2 : inputFormat.channelCount
        guard let format = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw AppFailure(message: "无法准备人声效果缓冲区。")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let tone {
            let effects = VocalEffects()
            effects.update(brightness: tone.brightness, compression: tone.compression, space: 0)
            effects.connect(in: engine, from: player, to: engine.mainMixerNode, format: inputFormat, includeReverb: false)
        } else {
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.plate)
            reverb.wetDryMix = 100
            engine.attach(reverb)
            engine.connect(player, to: reverb, format: inputFormat)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        player.scheduleFile(input, at: nil)
        try engine.start()
        player.play()
        defer { engine.stop() }

        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: AVAudioFramePosition = 0
        var retries = 0
        while written < input.length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(AVAudioFramePosition(block), input.length - written))
            let status = try engine.renderOffline(count, to: buffer)
            if status == .cannotDoInCurrentContext, retries < 100 {
                retries += 1
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            guard status == .success, buffer.frameLength > 0 else {
                throw AppFailure(message: "无法准备回听人声效果。")
            }
            retries = 0
            try output.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        }
    }
}
