@preconcurrency import AVFoundation
import Foundation

struct TakePatch: Identifiable {
    let take: Take
    let url: URL
    let range: PracticeRange
    var id: UUID { take.id }
}

struct TakeReviewRequest: Identifiable {
    let take: Take
    let vocalURL: URL
    let outputUID: String?
    var versions: [TakePatch] = []
    var microphoneReady = false
    var reviewEffects = VocalSettings(enabled: false)
    var id: UUID { take.id }
    var backingURL: URL? {
        guard take.hasBacking != false, let path = take.accompanimentPath ?? take.mediaPath else { return nil }
        return Take.recordedMediaURL(path)
    }
}

struct TakeMixLevels {
    var vocal: Float = 1
    var backing: Float = 0.65
    var includesBacking = true
}

/// The composition is built once and is never mutated after publication.
struct TakeMix: @unchecked Sendable {
    let asset: AVMutableComposition
    let duration: Double
    let vocalStart: Double
    private let vocalTrack: AVCompositionTrack
    private let backingTrack: AVCompositionTrack?
    private let replacement: Replacement?

    private struct Replacement {
        let track: AVCompositionTrack
        let start: Double
        let end: Double
    }

    static func build(for request: TakeReviewRequest, backingURL: URL?, vocalDelayMS: Int, patch: TakePatch? = nil) async throws -> TakeMix {
        let dry = AVURLAsset(url: request.vocalURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let dryTrack = try await dry.loadTracks(withMediaType: .audio).first else {
            throw AppFailure(message: "找不到可用的录音音轨。")
        }
        let dryRange = try await dryTrack.load(.timeRange)
        let songStart = request.take.videoStartSeconds.isFinite ? max(0, request.take.videoStartSeconds) : 0
        let captureStart = request.take.captureSongSeconds.flatMap { $0.isFinite ? $0 : nil } ?? songStart
        let voiceRelativeStart = backingURL == nil ? 0 : Double(vocalDelayMS) / 1000
        let backingRelativeStart = songStart - captureStart
        // Never play accompaniment from before the actual recording's song start.
        let earliest = min(0, voiceRelativeStart)
        let backingTrim = max(0, earliest - backingRelativeStart)
        let voiceAt = voiceRelativeStart - earliest
        let backingAt = max(earliest, backingRelativeStart) - earliest
        let backingSourceStart = songStart + backingTrim
        let drySeconds = dryRange.duration.seconds
        guard drySeconds.isFinite, drySeconds > 0 else {
            throw AppFailure(message: "录音时长无效。")
        }
        let composition = AVMutableComposition()
        guard let vocalDestination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppFailure(message: "无法创建回听音轨。")
        }
        try vocalDestination.insertTimeRange(dryRange, of: dryTrack, at: time(voiceAt))
        let backingDestination: AVMutableCompositionTrack?
        if let backingURL {
            let backing = AVURLAsset(url: backingURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceTrack = try await backing.loadTracks(withMediaType: .audio).first else {
                throw AppFailure(message: "这条录音没有可用的伴奏音轨。")
            }
            let sourceRange = try await sourceTrack.load(.timeRange)
            let backingSeconds = min(sourceRange.duration.seconds - backingSourceStart, voiceAt + drySeconds - backingAt)
            guard backingSeconds.isFinite, backingSeconds > 0,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AppFailure(message: "录音与当时的伴奏没有重叠片段。")
            }
            let offset = time(backingSourceStart)
            let duration = CMTimeMinimum(time(backingSeconds), CMTimeSubtract(sourceRange.duration, offset))
            try track.insertTimeRange(CMTimeRange(start: CMTimeAdd(sourceRange.start, offset), duration: duration),
                                      of: sourceTrack, at: time(backingAt))
            backingDestination = track
        } else { backingDestination = nil }
        var replacement: Replacement?
        if let patch {
            let file = AVURLAsset(url: patch.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard patch.take.parentTakeID == request.take.id, patch.range.isValid,
                  let patchTrack = try await file.loadTracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AppFailure(message: "找不到可用的补录音轨。")
            }
            let range = try await patchTrack.load(.timeRange)
            let patchStart = patch.take.captureSongSeconds.flatMap { $0.isFinite ? $0 : nil } ?? patch.take.videoStartSeconds
            let relative = patchStart - captureStart
            let start = max(patch.range.start, relative)
            let end = min(patch.range.end, drySeconds, relative + range.duration.seconds)
            guard relative.isFinite, end.isFinite, end - start >= 0.05 else {
                throw AppFailure(message: "这条补录没有覆盖所选片段。")
            }
            let skip = time(start - relative)
            let length = CMTimeMinimum(time(end - start), CMTimeSubtract(range.duration, skip))
            try destination.insertTimeRange(CMTimeRange(start: CMTimeAdd(range.start, skip), duration: length),
                                            of: patchTrack, at: time(voiceAt + start))
            replacement = Replacement(track: destination, start: voiceAt + start, end: voiceAt + start + length.seconds)
        }
        return TakeMix(asset: composition, duration: voiceAt + drySeconds, vocalStart: voiceAt,
                       vocalTrack: vocalDestination, backingTrack: backingDestination, replacement: replacement)
    }

    func audioMix(_ levels: TakeMixLevels, processedTrack: AVCompositionTrack? = nil, wetTrack: AVCompositionTrack? = nil,
                  effectsEnabled: Bool = false, reverb: Float = 0,
                  voiceOnly: Bool = false) -> AVAudioMix {
        let vocal = min(1, max(0, levels.vocal))
        let backing = backingTrack != nil && levels.includesBacking && !voiceOnly ? min(1, max(0, levels.backing)) : 0
        let headroom = max(1, vocal + backing)
        let processed = effectsEnabled && processedTrack != nil
        let wet = effectsEnabled && wetTrack != nil ? min(1, max(0, reverb / 100)) : 0
        let voiceParameters = AVMutableAudioMixInputParameters(track: vocalTrack)
        let vocalGain = processed ? 0 : vocal / headroom * (1 - wet)
        voiceParameters.setVolume(vocalGain, at: .zero)
        var parameters: [AVAudioMixInputParameters] = [voiceParameters]
        if let backingTrack, !voiceOnly {
            let input = AVMutableAudioMixInputParameters(track: backingTrack)
            input.setVolume(backing / headroom, at: .zero)
            parameters.append(input)
        }
        if let wetTrack {
            let input = AVMutableAudioMixInputParameters(track: wetTrack)
            input.setVolume(vocal / headroom * wet, at: .zero)
            parameters.append(input)
        }
        if let processedTrack {
            let input = AVMutableAudioMixInputParameters(track: processedTrack)
            input.setVolume(processed ? vocal / headroom * (1 - wet) : 0, at: .zero)
            parameters.append(input)
        }
        if let replacement {
            // Crossfade at the cut while keeping the original audible outside the captured coverage.
            let fade = min(0.012, (replacement.end - replacement.start) / 4)
            let entering = CMTimeRange(start: Self.time(replacement.start), duration: Self.time(fade))
            let leaving = CMTimeRange(start: Self.time(replacement.end - fade), duration: Self.time(fade))
            let patchParameters = AVMutableAudioMixInputParameters(track: replacement.track)
            patchParameters.setVolume(0, at: .zero)
            voiceParameters.setVolumeRamp(fromStartVolume: vocalGain, toEndVolume: 0, timeRange: entering)
            voiceParameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: vocalGain, timeRange: leaving)
            patchParameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: vocalGain, timeRange: entering)
            patchParameters.setVolumeRamp(fromStartVolume: vocalGain, toEndVolume: 0, timeRange: leaving)
            parameters.append(patchParameters)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    func exportWAV(to destination: URL, levels: TakeMixLevels) async throws {
        let job = Task.detached(priority: .userInitiated) { try writeWAV(to: destination, levels: levels) }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    private func writeWAV(to destination: URL, levels: TakeMixLevels) throws {
        let tracks = vocalTracks + (backingTrack.map { [$0] } ?? [])
        try WAVRenderer.write(asset: asset, tracks: tracks, mix: audioMix(levels),
                              to: destination, sampleRate: 48_000, channels: 2, duration: duration)
    }

    private var vocalTracks: [AVCompositionTrack] { [vocalTrack] + (replacement.map { [$0.track] } ?? []) }

    func writeVocalStem(to destination: URL) throws {
        try WAVRenderer.write(asset: asset, tracks: vocalTracks, mix: audioMix(TakeMixLevels(), voiceOnly: true),
                              to: destination, sampleRate: 48_000, channels: 1, duration: duration)
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
}
