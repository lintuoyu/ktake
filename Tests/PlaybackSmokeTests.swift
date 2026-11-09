import Foundation
import ImageIO
@preconcurrency import AVFoundation

struct PlaybackFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PlaybackFailure(message: message) }
}

@main
struct PlaybackSmokeTests {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let demo = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let longAudio = directory.appendingPathComponent("伴奏演示.wav")
        let shortAudio = directory.appendingPathComponent("短伴奏.wav")
        try silentAudio(longAudio, seconds: 20)
        try silentAudio(shortAudio, seconds: 3)
        let lrcURL = directory.appendingPathComponent("伴奏演示.lrc")
        try """
        [ar:KTV Pro]
        [00:00.00]歌词已准备好
        [00:02.00]跟随伴奏逐句高亮
        [00:04.00]没有 MV 也能录唱
        [00:06.00]进度与歌词保持同步
        [00:08.00]原始人声单独保存
        [00:10.00]混响只用于耳机监听
        [00:12.00]视频结束，继续歌词
        [00:16.00]这一段伴奏还在继续
        [00:19.00]准备结束
        """.write(to: lrcURL, atomically: true, encoding: .utf8)

        let parsed = try Lyrics.parse("\u{feff}[ar:test]\r\n[offset:-250]\n[00:01.5][00:03.050]重复句\n[00:02.00]\n[00:03.050]翻译\n[00:61.0]invalid")
        try expect(parsed.lines.count == 3, "multiple stamps, empty interval, duplicate-time merge, invalid seconds")
        try expect(abs(parsed.lines[0].time - 1.25) < 0.000001, "decimal timestamp and file offset")
        try expect(parsed.lines[1].text.isEmpty, "timed blank line must preserve instrumental interval")
        try expect(parsed.lines[2].text == "重复句 / 翻译", "stable duplicate-time merge")
        try expect(parsed.index(at: 1.24) == nil && parsed.index(at: 1.25) == 0, "lyric boundary")
        try expect(parsed.index(at: 100) == 2 && parsed.index(at: 1.5) == 0, "seeking forward and backward")
        try expect(parsed.index(at: .nan) == nil, "invalid playhead")
        do { _ = try Lyrics.parse("没有时间戳"); throw PlaybackFailure(message: "untimed lyrics must fail") }
        catch is AppFailure { }
        print("PASS: LRC timing, offsets, repeated timestamps, instrumental breaks, seek lookup")

        let audioOnly = try await SongComposition.build(videoURL: nil, accompanimentURL: longAudio)
        try expect(abs(audioOnly.duration - 20) < 0.01 && audioOnly.videoDuration == 0, "audio-only duration")
        let audioTracks = try await audioOnly.asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await audioOnly.asset.loadTracks(withMediaType: .video)
        try expect(audioTracks.count == 1 && videoTracks.isEmpty, "audio-only composition")

        // Make a true MV with its own audio before checking replacement.
        let mvURL = directory.appendingPathComponent("带原音的测试MV.mov")
        let mvPlan = try await SongComposition.build(videoURL: demo, accompanimentURL: longAudio)
        if FileManager.default.fileExists(atPath: mvURL.path) { try FileManager.default.removeItem(at: mvURL) }
        let export = AVAssetExportSession(asset: mvPlan.asset, presetName: AVAssetExportPresetHighestQuality)!
        export.outputURL = mvURL
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else { throw export.error ?? PlaybackFailure(message: "fixture export failed") }
        let mvAsset = AVURLAsset(url: mvURL)
        let originalAudio = try await mvAsset.loadTracks(withMediaType: .audio)
        try expect(originalAudio.count == 1, "test MV must have original audio")

        let replacement = try await SongComposition.build(videoURL: mvURL, accompanimentURL: shortAudio)
        let replacementAudio = try await replacement.asset.loadTracks(withMediaType: .audio)
        try expect(replacementAudio.count == 1, "MV original and accompaniment must never play together")
        let segments = try await replacementAudio[0].load(.segments)
        try expect(segments.allSatisfy { $0.isEmpty || ($0 as? AVCompositionTrackSegment)?.sourceURL?.standardizedFileURL == shortAudio.standardizedFileURL }, "audio must come exclusively from independent accompaniment")
        try expect(abs(replacement.duration - 3) < 0.01 && abs(replacement.videoDuration - 3) < 0.01, "short accompaniment trims MV")
        let longPlan = try await SongComposition.build(videoURL: demo, accompanimentURL: longAudio)
        try expect(abs(longPlan.duration - 20) < 0.01 && abs(longPlan.videoDuration - 12) < 0.01, "long accompaniment survives end of MV")
        let originalPlan = try await SongComposition.build(videoURL: mvURL, accompanimentURL: nil)
        try expect(originalPlan.hasAudio, "MV-only original audio fallback")
        print("PASS: accompaniment-only, actual MV original removal, common timeline, unequal durations")

        let model = SessionModel(libraryRoot: nil, userLibraryRoot: nil,
                                 takesDirectory: directory.appendingPathComponent("EmptyTakes", isDirectory: true))
        model.videoVolume = 0 // Integration checks never play sound or enable the microphone.
        model.loadAccompaniment(longAudio)
        try await loaded(model)
        try expect(model.mediaReady && model.mediaURL == nil && model.duration > 19.9, "model accompaniment-only readiness")
        model.loadLyrics(lrcURL)
        try expect(model.lyrics.lines.count == 9, "model lyric import")
        model.seek(to: 5)
        try expect(model.currentLyricIndex == 2, "lyric follows playhead")
        model.lyricDelay = 2
        try expect(model.currentLyricIndex == 1, "positive delay displays lyrics later")
        model.seekToLyric(model.lyrics.lines[1])
        try expect(model.position == 4 && model.currentLyricIndex == 1, "choosing a lyric seeks to its adjusted timestamp")
        model.seek(to: 4 - 1.0 / 48_000)
        try expect(model.currentLyricIndex == 1, "a one-sample rounding error does not highlight the previous lyric after seeking")
        model.seek(to: 0.25)
        model.setLoopA()
        model.seek(to: 0.80)
        model.setLoopB()
        try expect(model.practiceRange == PracticeRange(start: 0.25, end: 0.80) && model.position == 0.25 && model.loopEnabled,
                   "marking B begins practice at A")
        model.togglePlayback()
        var approachedB = false, wrapped = false
        for _ in 0..<100 {
            if approachedB && model.position < 0.50 { wrapped = true; break }
            if model.position >= 0.58 { approachedB = true }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(wrapped && model.isPlaying, "practice loop wraps while playback continues")
        model.togglePlayback()
        model.seek(to: 5)
        try expect(!model.loopEnabled && model.position == 5, "seeking out of the loop disables it")
        model.clearPracticeLoop()
        model.loadVideo(demo)
        try await loaded(model)
        try expect(model.mediaReady && model.showsVideo, "MV can be attached to existing accompaniment")
        model.seek(to: 13)
        try expect(!model.showsVideo && model.position == 13, "after short MV, show lyrics while accompaniment continues")
        model.seek(to: 1)
        try expect(model.showsVideo, "seeking backwards returns to MV")
        model.clearVideo()
        try await loaded(model)
        try expect(model.mediaReady && model.mediaURL == nil && model.accompanimentURL == longAudio, "remove MV retains accompaniment")
        model.loadAccompaniment(directory.appendingPathComponent("missing.wav"))
        try await loaded(model)
        try expect(model.errorMessage != nil && model.mediaReady && model.accompanimentURL == longAudio, "failed import retains working song")
        model.clearAccompaniment()
        try expect(!model.mediaReady && model.duration == 0, "clear final source resets transport")
        await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume() } }
        print("PASS: session transitions, lyric seek/delay, video removal, short-MV fallback, failed import recovery")
        let catalog: [String: Any] = ["version": 1, "songs": [[
            "id": "test-song", "title": "Test title", "artist": "Test artist",
            "accompaniment": "伴奏演示.wav", "lyrics": "伴奏演示.lrc", "duration": 20
        ]]]
        try JSONSerialization.data(withJSONObject: catalog).write(to: directory.appendingPathComponent("catalog.json"))
        let library = try SongLibrary(root: directory)
        try expect(library.songs.count == 1, "library catalog")
        do { _ = try library.url("../outside.wav"); throw PlaybackFailure(message: "library traversal must fail") }
        catch is AppFailure { }
        let libraryModel = SessionModel(libraryRoot: directory, userLibraryRoot: nil,
                                        takesDirectory: directory.appendingPathComponent("EmptyTakes", isDirectory: true))
        libraryModel.videoVolume = 0
        try await loaded(libraryModel)
        try expect(libraryModel.mediaReady && libraryModel.selectedSongID == "test-song" && libraryModel.songTitle == "Test artist — Test title", "bundled song autoselection")
        try expect(libraryModel.lyrics.lines.count == 9, "library lyric association")
        libraryModel.seek(to: 5)
        for _ in 0..<100 {
            if abs(libraryModel.player.currentTime().seconds - 5) < 0.01 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        libraryModel.setPitch(-2)
        try await loaded(libraryModel)
        try expect(libraryModel.semitones == -2 && abs(libraryModel.position - 5) < 0.1, "pitch change keeps playhead")
        try expect(libraryModel.currentLyricIndex == 2 && !libraryModel.isPlaying, "pitch change keeps lyrics and paused state")
        try expect(libraryModel.accompanimentURL?.standardizedFileURL == longAudio.standardizedFileURL && libraryModel.selectedSongID == "test-song", "pitch keeps source and song identity")
        libraryModel.setPitch(0)
        try await loaded(libraryModel)
        try expect(libraryModel.semitones == 0 && abs(libraryModel.position - 5) < 0.1, "original-key reset")
        await withCheckedContinuation { continuation in libraryModel.prepareToQuit { continuation.resume() } }
        print("PASS: library selection, associated lyrics, pitch changes preserve playhead and original source")
        let userRoot = directory.appendingPathComponent("Downloads")
        let downloaded = try LibraryImporter.add(file: shortAudio, title: "下载伴奏", artist: "测试歌手", sourceURL: URL(string: "http://5sing.kugou.com/bz/3019645.html"), root: userRoot)
        let takesRoot = directory.appendingPathComponent("Takes")
        let trash = directory.appendingPathComponent("FixtureTrash")
        try FileManager.default.createDirectory(at: takesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let take = Take(id: UUID(), createdAt: Date(), filename: "Take-test.wav", songName: downloaded.title,
                        mediaPath: nil, videoStartSeconds: 0, duration: 3, sampleRate: 48000, interrupted: false)
        try FileManager.default.copyItem(at: shortAudio, to: take.url(in: takesRoot))
        try take.save(in: takesRoot)
        var refuseMetadata = false
        let mergedModel = SessionModel(libraryRoot: directory, userLibraryRoot: userRoot, takesDirectory: takesRoot) { source in
            if refuseMetadata && source.pathExtension == "json" { throw PlaybackFailure(message: "fixture refused metadata move") }
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        mergedModel.videoVolume = 0
        try await loaded(mergedModel)
        try expect(mergedModel.songs.count == 2, "bundled and downloaded catalogs merge")
        mergedModel.downloadedSongAdded(downloaded)
        try await loaded(mergedModel)
        try expect(mergedModel.selectedSongID == downloaded.id && mergedModel.duration > 2.9, "downloaded song selects and plays from persistent storage")
        try expect(mergedModel.librarySong?.sourceURL?.contains("5sing.kugou.com") == true, "retain source page")
        guard let search = mergedModel.lyricSearchContext() else { throw PlaybackFailure(message: "manual lyric search is unavailable") }
        try expect(search.title == "下载伴奏" && search.artist == "测试歌手", "prefill from current track")
        mergedModel.seek(to: 1.5)
        let alternate = LyricRecord(id: 1, trackName: "手选版本", artistName: "测试歌手", duration: 90,
                                   instrumental: false, syncedLyrics: "[00:01]手选歌词\n[00:45]第二句")
        try mergedModel.importSearchedLyrics(alternate, for: search)
        try expect(mergedModel.lyrics.lines.first?.text == "手选歌词" && mergedModel.currentLyricIndex == 0 && mergedModel.position == 1.5,
                   "manual import loads the chosen version without moving the playhead")
        let manualURL = mergedModel.lyricsURL
        mergedModel.lyricDelay = 0.75
        mergedModel.setPitch(1)
        try await loaded(mergedModel)
        mergedModel.selectSong("test-song")
        try await loaded(mergedModel)
        try expect(mergedModel.semitones == 0 && mergedModel.lyricDelay == 0, "practice settings are scoped to each accompaniment")
        do {
            try mergedModel.importSearchedLyrics(alternate, for: search)
            throw PlaybackFailure(message: "manual result must not attach to a different song")
        } catch is AppFailure {}
        mergedModel.selectSong(downloaded.id)
        try await loaded(mergedModel)
        try expect(mergedModel.lyricsURL == manualURL && mergedModel.lyrics.lines.first?.text == "手选歌词", "manual lyric selection persists when returning to a track")
        try expect(mergedModel.semitones == 1 && abs(mergedModel.position - 1.5) < 0.1 && mergedModel.lyricDelay == 0.75,
                   "pitch, playback position and lyric delay restore together")

        guard let bundled = mergedModel.songs.first(where: { $0.id == "test-song" }) else { throw PlaybackFailure(message: "bundled song missing") }
        try expect(!mergedModel.canTrashLibrarySong(bundled) && mergedModel.canTrashLibrarySong(downloaded), "trash only managed download folders")
        mergedModel.removeLibrarySong(bundled.id, moveFiles: false)
        try expect(mergedModel.songs.count == 1 && mergedModel.selectedSongID == downloaded.id, "hiding a different track leaves current playback unchanged")
        mergedModel.refreshLibrary()
        try expect(mergedModel.hiddenSongIDs.contains(bundled.id), "hidden songs survive catalog reload")
        mergedModel.restoreHiddenSongs()
        try expect(mergedModel.songs.count == 2 && mergedModel.hiddenSongIDs.isEmpty, "hidden songs can be restored")
        let managedPath = userRoot.appendingPathComponent("Songs/\(downloaded.id)")
        let trashedPath = trash.appendingPathComponent(managedPath.lastPathComponent)
        mergedModel.removeLibrarySong(downloaded.id, moveFiles: true)
        try expect(mergedModel.songs.count == 1 && mergedModel.selectedSongID == nil && !mergedModel.hasSong && mergedModel.lyrics.lines.isEmpty,
                   "removing the selected track clears transport and lyrics")
        try expect(FileManager.default.fileExists(atPath: trashedPath.path) && FileManager.default.fileExists(atPath: shortAudio.path),
                   "only the managed copy moves; the original survives")
        try FileManager.default.moveItem(at: trashedPath, to: managedPath)
        mergedModel.refreshLibrary()
        mergedModel.selectSong(downloaded.id)
        try await loaded(mergedModel)
        try expect(mergedModel.selectedSongID == downloaded.id && mergedModel.lyricsURL == manualURL,
                   "putting the song folder back restores it with its manual lyrics")

        refuseMetadata = true
        mergedModel.removeTake(take.id)
        try expect(mergedModel.errorMessage != nil && mergedModel.takes.count == 1 && FileManager.default.fileExists(atPath: take.url(in: takesRoot).path),
                   "failed metadata move rolls back the WAV move")
        refuseMetadata = false
        mergedModel.removeTake(take.id)
        let trashedWAV = trash.appendingPathComponent(take.filename)
        let trashedJSON = trashedWAV.deletingPathExtension().appendingPathExtension("json")
        try expect(mergedModel.takes.isEmpty && FileManager.default.fileExists(atPath: trashedWAV.path) && FileManager.default.fileExists(atPath: trashedJSON.path),
                   "take deletion moves both audio and metadata")
        try FileManager.default.moveItem(at: trashedWAV, to: take.url(in: takesRoot))
        try FileManager.default.moveItem(at: trashedJSON, to: take.url(in: takesRoot).deletingPathExtension().appendingPathExtension("json"))
        mergedModel.refreshTakes()
        try expect(mergedModel.takes.first?.id == take.id, "a restored recording can be reloaded")
        let child = Take(id: UUID(), createdAt: Date(), filename: "Punch-test.wav", songName: take.songName,
                         mediaPath: nil, videoStartSeconds: 0.5, duration: 1, sampleRate: 48000, interrupted: false,
                         parentTakeID: take.id, punchRange: PracticeRange(start: 0.5, end: 1.5),
                         recordedEffects: VocalSettings(brightness: 3, compression: 0.5, reverb: 26, gain: 0.7))
        try FileManager.default.copyItem(at: shortAudio, to: child.url(in: takesRoot))
        try child.save(in: takesRoot)
        let dry = try Data(contentsOf: take.url(in: takesRoot))
        mergedModel.refreshTakes()
        mergedModel.saveTakeNote(take.id, "  副歌待重唱  ")
        mergedModel.togglePreferredTake(take.id)
        try expect(mergedModel.takes.first(where: { $0.id == take.id })?.preferred == true, "first take becomes preferred")
        mergedModel.togglePreferredTake(child.id)
        try mergedModel.adoptPunch(parentID: take.id, versionID: child.id)
        let saved = Take.loadAll(in: takesRoot)
        try expect(saved.filter { $0.preferred == true }.map(\.id) == [child.id], "only one take per song stays preferred")
        guard let original = saved.first(where: { $0.id == take.id }) else { throw PlaybackFailure(message: "missing original") }
        let savedChild = saved.first(where: { $0.id == child.id })
        let fallback = VocalSettings(reverb: 12)
        try expect(original.recordedEffects == nil && original.quickPlaybackEffects(fallback: fallback).reverb == 12,
                   "old take metadata uses the current setting")
        try expect(savedChild?.recordedEffects == child.recordedEffects && savedChild?.quickPlaybackEffects(fallback: fallback) == child.recordedEffects,
                   "a saved take keeps its recording setting after reload and metadata edits")
        var dryTake = original
        dryTake.recordedReverb = 0
        let reloadedDry = try JSONDecoder().decode(Take.self, from: JSONEncoder().encode(dryTake))
        try expect(reloadedDry.recordedReverb == 0 && !reloadedDry.quickPlaybackEffects(fallback: fallback).enabled,
                   "explicit dry recording bypasses the current setting")
        try expect(original.note == "副歌待重唱" && original.adoptedPunchID == child.id, "note and adopted version persist")
        let afterAdoption = try Data(contentsOf: take.url(in: takesRoot))
        try expect(afterAdoption == dry, "adoption leaves the original WAV untouched")
        let review = mergedModel.beginTakeReview(original)
        try expect(review?.versions.map { $0.take.id } == [child.id], "review presents the linked punch version")
        mergedModel.endTakeReview()
        await withCheckedContinuation { continuation in mergedModel.prepareToQuit { continuation.resume() } }
        let reopened = SessionModel(libraryRoot: directory, userLibraryRoot: userRoot, takesDirectory: takesRoot)
        try await loaded(reopened)
        try expect(reopened.selectedSongID == downloaded.id && reopened.semitones == 1 &&
                   abs(reopened.position - 1.5) < 0.1 && reopened.lyricDelay == 0.75 && !reopened.isPlaying,
                   "a new session restores the last song and practice settings without playing")
        await withCheckedContinuation { continuation in reopened.prepareToQuit { continuation.resume() } }
        try await checkGarageBandStems(in: directory)
        print("PASS: downloaded library merge, refresh, selection, duration and source attribution")
        print("PASS: manual lyric import keeps playback position, persists to track, and rejects stale search targets")
        print("PASS: recoverable song and recording removal, hidden tracks, untouched source files, and rollback")
        print("PASS: lyric selection, A/B practice, and non-destructive take notes, preferences and adoption")
        print("All playback smoke tests passed. Microphone was never enabled. Fixtures: \(directory.path)")
    }

    static func checkGarageBandStems(in directory: URL) async throws {
        let input = directory.appendingPathComponent("GarageBand-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let backing = input.appendingPathComponent("backing.wav")
        let first = Take(id: UUID(), createdAt: .now, filename: "voice1.wav", songName: "GarageBand 对齐测试",
                         mediaPath: nil, videoStartSeconds: 0.9, duration: 1, sampleRate: 48_000, interrupted: false,
                         accompanimentPath: backing.path, captureSongSeconds: -0.125)
        let legacy = Take(id: UUID(), createdAt: .now, filename: "voice2.wav", songName: first.songName,
                          mediaPath: nil, videoStartSeconds: 0.5, duration: 1, sampleRate: 48_000, interrupted: false,
                          accompanimentPath: backing.path)
        let differentKey = Take(id: UUID(), createdAt: .now, filename: "different-key.wav", songName: first.songName,
                                mediaPath: nil, videoStartSeconds: 0, duration: 1, sampleRate: 48_000, interrupted: false,
                                accompanimentPath: backing.path, pitchSemitones: 2)
        try tone(backing, rate: 44_100, channels: 2, seconds: 2)
        try tone(first.url(in: input), channels: 1, seconds: 1)
        try tone(legacy.url(in: input), channels: 1, seconds: 1)
        let request = GarageBandExportRequest(anchor: first, takes: [first, legacy, differentKey], takesDirectory: input)
        try expect(request.compatibleTakes.map(\.id) == [first.id, legacy.id], "a different recording key is excluded")
        let exported = try await GarageBandStems.export(request, selected: [first.id, legacy.id], to: directory)
        try expect(exported.files.count == 3, "one backing WAV and one WAV for each selected recording")
        let starts = try exported.files.map { url -> Int? in
            let audio = try AVAudioFile(forReading: url)
            let channels: UInt32 = url == exported.files[0] ? 2 : 1
            try expect(audio.fileFormat.channelCount == channels && audio.fileFormat.sampleRate == 44_100 &&
                       audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24, "GarageBand stem format and channel counts")
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
            try audio.read(into: buffer)
            let data = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            return data.firstIndex { abs($0) > 0.02 }
        }
        let expected = [5_513, 0, 27_563]
        for (observed, frame) in zip(starts, expected) {
            guard let observed else { throw PlaybackFailure(message: "exported stem was silent") }
            // Resampling can soften the first few samples of the synthetic onset.
            try expect(abs(observed - frame) <= 20, "capture and legacy timing share the same origin: \(observed) vs \(frame)")
        }
        print("PASS: GarageBand WAV stems, mono/stereo, independent capture times, and legacy timing")
        print("GarageBand import fixtures: \(exported.folder.path)")

        let project = try await GarageBandProject.export(request, selected: [first.id], to: directory)
        let media = try checkGarageBandProject(project, leads: [5_513, 0], lengths: [93_713, 44_100])
        let originals = [project.appendingPathComponent("Alternatives/000/ProjectData")] + media
        let beforeRepeat = try originals.map { try Data(contentsOf: $0) }
        let repeated = try await GarageBandProject.export(request, selected: [first.id], to: directory)
        var isDirectory: ObjCBool = false
        try expect(repeated != project && repeated.pathExtension == "band" &&
                   FileManager.default.fileExists(atPath: repeated.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                   "repeated project export creates a separate .band directory")
        let afterRepeat = try originals.map { try Data(contentsOf: $0) }
        try expect(beforeRepeat == afterRepeat, "repeated export must not overwrite the first project or its media")

        let legacyProject = try await GarageBandProject.export(request, selected: [legacy.id], to: directory)
        _ = try checkGarageBandProject(legacyProject, leads: [0, 22_050], lengths: [88_200, 66_150])
        let beforeRejection = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let rejectedSelections: [Set<UUID>] = [[], [first.id, legacy.id], [first.id, differentKey.id]]
        for selected in rejectedSelections {
            do {
                _ = try await GarageBandProject.export(request, selected: selected, to: directory)
                throw PlaybackFailure(message: "a two-track project must reject empty or multiple selections, not merge/filter them")
            } catch is AppFailure { }
        }
        let afterRejection = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        try expect(beforeRejection == afterRejection, "rejected selections leave no project or staging directory")

        let longBacking = input.appendingPathComponent("long-backing.wav")
        let late = Take(id: UUID(), createdAt: .now, filename: "late-voice.wav", songName: "GarageBand 长工程测试",
                        mediaPath: nil, videoStartSeconds: 0, duration: 1, sampleRate: 48_000, interrupted: false,
                        accompanimentPath: longBacking.path, captureSongSeconds: 75.75)
        try tone(longBacking, rate: 44_100, channels: 2, seconds: 98)
        try tone(late.url(in: input), channels: 1, seconds: 1)
        let longRequest = GarageBandExportRequest(anchor: late, takes: [late], takesDirectory: input)
        let longProject = try await GarageBandProject.export(longRequest, selected: [late.id], to: directory)
        let longMedia = try checkGarageBandProject(longProject, leads: [0, 3_340_575], lengths: [4_321_800, 3_384_675])
        let lengths = try longMedia.map { UInt64(try AVAudioFile(forReading: $0).length) }
        let lengthsByPool = [0: lengths[0], 4: lengths[1]]
        let projectData = try Data(contentsOf: longProject.appendingPathComponent("Alternatives/000/ProjectData"))
        let chunks = try garageBandChunks(projectData)
        let fileChunks = chunks.filter { $0.tag == "lFuA" }
        let regionChunks = chunks.filter { $0.tag == "gRuA" }
        try expect(fileChunks.count == 2 &&
                   Set(fileChunks.map { $0.key[1] }) == Set([0, 4]) &&
                   Set(regionChunks.map { $0.key[1] }) == Set([0, 4]),
                   "project describes two audio pools, including the template's cached region definitions")
        let timelines = chunks.filter { $0.tag == "qSvE" && Array($0.key.prefix(2)) == [23, 4] }
        try expect(timelines.count == 1 && timelines[0].payload.count == 176,
                   "the main timeline has two active 80-byte regions and one terminator")
        for offset in [0, 80] {
            let pool = Int(try projectInteger(timelines[0].payload, at: offset + 44, width: 4))
            let region = Int(try projectInteger(timelines[0].payload, at: offset + 40, width: 4))
            try expect(regionChunks.contains { $0.key[1] == pool && $0.key[2] == region },
                       "each active timeline region refers to an existing audio region")
        }
        for chunk in fileChunks {
            guard let wave = chunk.payload.range(of: Data("EVAW".utf8)) else {
                throw PlaybackFailure(message: "lFuA is missing its WAVE descriptor")
            }
            let frames = try projectInteger(chunk.payload, at: wave.lowerBound + 12)
            try expect(frames == lengthsByPool[chunk.key[1]], "lFuA sample count matches its exported WAV, including silence")
        }
        for chunk in regionChunks {
            let frames = try projectInteger(chunk.payload, at: 22)
            try expect(frames == lengthsByPool[chunk.key[1]], "gRuA sample count matches its exported WAV, including silence")
        }
        let sequences = chunks.filter { $0.tag == "qeSM" && Array($0.key.prefix(2)) == [23, 4] }
        try expect(sequences.count == 1, "locate the project sequence, not a track's qeSM")
        let sequence = sequences[0].payload
        let nameBytes = Int(try projectInteger(sequence, at: 16, width: 2))
        let alignedNameEnd = (18 + nameBytes + 3) & ~3
        let endTicks = try projectInteger(sequence, at: alignedNameEnd + 60)
        // The fixed template uses 120 BPM, 4/4, 960 ticks/beat: 88,200 frames per 3,840 ticks.
        try expect(endTicks * 88_200 >= lengths.max()! * 3_840,
                   "project end must cover the full 98-second backing and late vocal, not truncate at the template end")
        let songs = chunks.filter { $0.tag == "gnoS" }
        try expect(songs.count == 1, "one song range in the two-track project")
        for offset in [384, 1084] {
            let rangeEnd = try projectInteger(songs[0].payload, at: offset)
            try expect(rangeEnd == endTicks + 38_400, "gnoS range end follows the extended project end")
        }
        print("PASS: GarageBand two-track projects, selection rejection, non-overwrite, negative/legacy sync, and long-project metadata")
        print("GarageBand project fixtures: \(project.path) | \(legacyProject.path) | \(longProject.path)")
    }

    static func checkGarageBandProject(_ project: URL, leads: [Int64], lengths: [Int64]) throws -> [URL] {
        var isDirectory: ObjCBool = false
        try expect(project.pathExtension == "band" &&
                   FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                   "project export returns a .band directory")
        let previewURL = project.appendingPathComponent("Alternatives/000/WindowImage.jpg")
        guard let preview = CGImageSourceCreateWithURL(previewURL as CFURL, nil),
              CGImageSourceCreateImageAtIndex(preview, 0, nil) != nil else {
            throw PlaybackFailure(message: "GarageBand Quick Look requires a decodable project preview")
        }
        guard let entries = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else {
            throw PlaybackFailure(message: "cannot enumerate project media")
        }
        let urls = entries.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "wav" }
        try expect(urls.count == 2, "a fixed two-track project contains exactly two WAVs")
        let tracks = try urls.map { (url: $0, audio: try AVAudioFile(forReading: $0)) }
            .sorted { $0.audio.fileFormat.channelCount > $1.audio.fileFormat.channelCount }
        for (index, track) in tracks.enumerated() {
            let audio = track.audio
            let channels: UInt32 = index == 0 ? 2 : 1
            try expect(audio.fileFormat.channelCount == channels && audio.fileFormat.sampleRate == 44_100 &&
                       audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24,
                       "project media is 44.1 kHz, 24-bit, stereo backing / mono vocal")
            try expect(audio.length == lengths[index], "WAV length includes the exact synchronized leading silence")
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384)!
            var remaining = leads[index]
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity)))
                try audio.read(into: buffer, frameCount: count)
                try expect(buffer.frameLength == count, "leading silence must not end prematurely")
                for channel in 0..<Int(channels) {
                    let samples = UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(count))
                    try expect(samples.allSatisfy { abs($0) < 0.000001 }, "every leading frame is silent")
                }
                remaining -= Int64(count)
            }
            try audio.read(into: buffer, frameCount: 512)
            let onset = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                .firstIndex { abs($0) > 0.02 }
            try expect(onset != nil && onset! <= 20, "synthetic audio starts immediately after its synchronized silence")
        }
        return tracks.map { $0.url }
    }

    static func projectInteger(_ data: Data, at offset: Int, width: Int = 8) throws -> UInt64 {
        try expect(offset >= 0 && offset <= data.count - width, "ProjectData integer is within its payload")
        return (0..<width).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    static func garageBandChunks(_ data: Data) throws -> [(key: [Int], tag: String, payload: Data)] {
        let fileLength = try projectInteger(data, at: 16)
        try expect(fileLength == UInt64(data.count - 24), "ProjectData file+16 equals filesize-24")
        var result: [(key: [Int], tag: String, payload: Data)] = []
        var offset = 24
        while offset < data.count {
            try expect(data.count - offset >= 36, "complete 36-byte chunk header")
            let length = try projectInteger(data, at: offset + 28)
            let payloadStart = offset + 36
            try expect(length <= UInt64(data.count - payloadStart), "chunk payload length stays inside ProjectData")
            let payloadEnd = payloadStart + Int(length)
            let tag = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let key = try [6, 10, 14, 18].map { Int(try projectInteger(data, at: offset + $0, width: 4)) }
            result.append((key, tag, data.subdata(in: payloadStart..<payloadEnd)))
            offset = payloadEnd
        }
        return result
    }

    static func tone(_ url: URL, rate: Double = 48_000, channels: AVAudioChannelCount, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let count = Int(rate) * seconds
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<count {
                samples[frame] = Float(0.12 * cos(2 * Double.pi * 440 * Double(frame) / rate))
            }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    static func silentAudio(_ url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48000))!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @MainActor static func loaded(_ model: SessionModel) async throws {
        for _ in 0..<300 {
            if !model.loadingMedia { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PlaybackFailure(message: "media load timed out")
    }
}
