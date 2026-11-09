import AVFoundation

struct SongComposition {
    let asset: AVMutableComposition
    let duration: Double
    let videoDuration: Double
    let hasAudio: Bool
    let videoURL: URL?
    let accompanimentURL: URL?

    static func build(videoURL: URL?, accompanimentURL: URL?, audioOverrideURL: URL? = nil) async throws -> SongComposition {
        guard videoURL != nil || accompanimentURL != nil else { throw AppFailure(message: "请先导入伴奏或 MV。") }
        let video = videoURL.map { AVURLAsset(url: $0) }
        let accompaniment = (audioOverrideURL ?? accompanimentURL).map { AVURLAsset(url: $0) }
        var videoTrack: AVAssetTrack?
        var audioTrack: AVAssetTrack?
        var videoRange: CMTimeRange?
        var audioRange: CMTimeRange?
        if let video {
            guard try await video.load(.isPlayable), let track = try await video.loadTracks(withMediaType: .video).first else {
                throw AppFailure(message: "MV 没有可播放的视频轨道，请使用 MP4 或 MOV。")
            }
            videoTrack = track
            videoRange = try await track.load(.timeRange)
            // Original vocal audio is never inserted when separate accompaniment exists.
            if accompaniment == nil, let original = try await video.loadTracks(withMediaType: .audio).first {
                audioTrack = original
                audioRange = try await original.load(.timeRange)
            }
        }
        if let accompaniment {
            guard try await accompaniment.load(.isPlayable), let track = try await accompaniment.loadTracks(withMediaType: .audio).first else {
                throw AppFailure(message: "伴奏没有可播放的音轨，请使用 MP3、M4A、WAV 或 AIFF。")
            }
            audioTrack = track
            audioRange = try await track.load(.timeRange)
        }
        let length = accompaniment != nil ? audioRange?.duration : videoRange?.duration
        guard let length, length.seconds.isFinite, length.seconds > 0 else { throw AppFailure(message: "文件的播放时长无效。") }
        let composition = AVMutableComposition()
        var pictureDuration = 0.0
        if let videoTrack, let range = videoRange {
            let count = CMTimeMinimum(range.duration, length)
            guard let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AppFailure(message: "无法准备 MV 视频轨道。")
            }
            try destination.insertTimeRange(CMTimeRange(start: range.start, duration: count), of: videoTrack, at: .zero)
            destination.preferredTransform = try await videoTrack.load(.preferredTransform)
            pictureDuration = count.seconds
        }
        if let audioTrack, let range = audioRange {
            guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AppFailure(message: "无法准备伴奏音轨。")
            }
            try destination.insertTimeRange(CMTimeRange(start: range.start, duration: CMTimeMinimum(range.duration, length)), of: audioTrack, at: .zero)
        }
        return SongComposition(asset: composition, duration: length.seconds, videoDuration: pictureDuration,
                               hasAudio: audioTrack != nil, videoURL: videoURL, accompanimentURL: accompanimentURL)
    }
}
