import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit
import CryptoKit

struct LyricSearchContext: Identifiable {
    let id = UUID()
    let songID: String?
    let sourceURL: URL
    let title: String
    let artist: String
    let duration: Double
}

enum RecordLeadIn: String, CaseIterable, Identifiable {
    case immediate = "直接录制", three = "倒数 3 秒", five = "倒数 5 秒", listen = "提前听 3 秒"
    var id: Self { self }
}

enum LibraryAudioVersion: String, Codable, CaseIterable {
    case original, standard, highQuality, instHQ3, mdx23c, smallKaraoke

    static let extracted: [Self] = allCases.filter { $0 != .original }

    var label: String {
        switch self {
        case .original: "原唱 / 原音频"
        case .standard: "标准伴奏"
        case .highQuality: "Kim Vocal 2 伴奏"
        case .instHQ3: "UVR Inst HQ 3 伴奏"
        case .smallKaraoke: "Small Karaoke（去主唱、保留和声）"
        case .mdx23c: "MDX23C-InstVoc HQ 伴奏"
        }
    }

    var extractionModel: AccompanimentExtractor.Model? {
        switch self {
        // Retired models remain valid audio versions for existing selections and WAVs.
        case .original, .standard, .mdx23c: nil
        case .highQuality: .highQuality
        case .instHQ3: .instHQ3
        case .smallKaraoke: .smallKaraoke
        }
    }
}

struct ModelDownloadRequest {
    let song: LibrarySong
    let version: LibraryAudioVersion
    let model: AccompanimentExtractor.Model
    let directory: URL
}

private struct SongPracticeSettings: Codable, Equatable {
    let semitones: Int
    let lyricDelay: Double
    let position: Double
    let lyricsPath: String?
    var usesExtractedAccompaniment: Bool? = nil
    var audioVersion: LibraryAudioVersion? = nil
}

private struct SongPracticeFile: Codable {
    var songs: [String: SongPracticeSettings] = [:]
    var lastSongID: String?
}

private struct MonitorPreferences: Codable {
    static let key = "monitorPreferences"

    let preset: String
    let effects: VocalSettings
}

struct MicTestResult {
    let url: URL
    let level: MicTestLevel
    let frames: AVAudioFramePosition
    let issue: String?

    var summary: String {
        if let issue { return issue }
        if frames == 0 { return "没有收到音频，请检查输入设备和通道。" }
        if level.nearClipping { return "电平接近爆音，请调低声卡增益。" }
        if level.peakDB < -48 { return "输入很弱，请检查麦克风和增益。" }
        return String(format: "收到声音，峰值 %.1f dBFS。", level.peakDB)
    }
}

@MainActor
final class SessionModel: ObservableObject {
    private static let playbackTimescale: CMTimeScale = 48_000
    let player = AVPlayer()
    let audio = AudioEngine()
    private let takePlayer = TakePlayer()
    @Published var devices: [AudioDevice] = []
    @Published var inputID: UInt32 = 0
    @Published var outputID: UInt32 = 0
    @Published var inputChannel = 0
    @Published var microphoneEnabled = false
    @Published var enablingMicrophone = false
    @Published var monitoring = false { didSet { updateEffects() } }
    @Published var monitorGain: Float = 0.8 { didSet { monitorParametersChanged() } }
    @Published var brightness: Float = 2 { didSet { monitorParametersChanged() } }
    @Published var compression: Float = 0.35 { didSet { monitorParametersChanged() } }
    @Published var reverb: Float = 18 { didSet { monitorParametersChanged() } }
    @Published var videoVolume: Float = 0.65 { didSet { player.volume = videoVolume } }
    @Published private(set) var preset = "自然人声"
    @Published var mediaURL: URL?
    @Published var accompanimentURL: URL?
    @Published var lyricsURL: URL?
    @Published var lyrics = Lyrics.empty
    @Published var lyricDelay = 0.0 { didSet { savePracticeSettings() } }
    @Published var videoDuration = 0.0
    @Published var mediaReady = false
    @Published var loadingMedia = false
    @Published var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var isRecording = false
    @Published var isFinalizing = false
    @Published var recordingSeconds = 0.0
    @Published var meter = AudioMeter()
    @Published var takes: [Take] = []
    @Published var playingTakeID: UUID?
    @Published var recordLeadIn: RecordLeadIn = .three
    @Published private(set) var recordCountdown: Int?
    @Published private(set) var isRecordArmed = false
    @Published private(set) var loopA: Double?
    @Published private(set) var loopB: Double?
    @Published private(set) var loopEnabled = false
    @Published private(set) var punchRange: PracticeRange?
    @Published private(set) var isTestingMic = false
    @Published private(set) var isFinishingMicTest = false
    @Published private(set) var playingMicTest = false
    @Published private(set) var micTestResult: MicTestResult?
    @Published private(set) var micTestRemaining = 5
    @Published var status = "导入一首 MV，准备开始。"
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published private(set) var songs: [LibrarySong] = []
    @Published private(set) var hiddenSongIDs: Set<String> = []
    @Published private(set) var selectedSongID: String?
    @Published private(set) var semitones = 0
    @Published private(set) var preparingPitch = false
    @Published private(set) var pitchProgress = 0.0
    @Published private(set) var extractedAccompaniments: [String: [LibraryAudioVersion: URL]] = [:]
    @Published private(set) var separatingSongID: String?
    @Published private(set) var accompanimentProgress: AccompanimentExtractor.Progress?
    @Published var modelDownloadRequest: ModelDownloadRequest?
    private(set) var separatingModel: AccompanimentExtractor.Model?
    @Published private(set) var pendingAudioVersion: LibraryAudioVersion?
    private var separationTask: Task<Void, Never>?
    private var separationGeneration: UUID?
    private var audioVersionTask: Task<Void, Never>?
    private let libraryRoot: URL?
    private var songLibraries: [String: SongLibrary] = [:]
    private let userLibraryRoot: URL?
    let musicDLImporter: MusicDLImporter?
    @Published private(set) var musicDLDownloadDirectory: URL?
    private let takesDirectory: URL
    private let moveToTrash: (URL) throws -> URL
    private let monitorDefaults: UserDefaults
    private let practiceSettingsURL: URL?
    private var practice = SongPracticeFile()
    private var lastPracticeWrite = Date.distantPast
    private var writer: RecordingWriter?
    private var activeTake: Take?
    private var recordingAnchor: (host: CMTime, song: Double)?
    private var recordArm: (id: UUID, start: Double)?
    private var recordArmTask: Task<Void, Never>?
    private var recordBoundary: Any?
    private var loopBoundary: Any?
    private var loopingSeek = false
    private var punch: (take: Take, sourceRange: PracticeRange, restore: () -> Void)?
    private var micTestWriter: RecordingWriter?
    private var micTestURL: URL?
    private var micTestStarted = 0.0
    private var recordStarted = Date()
    private var timer: Timer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var loadingGeneration = UUID()
    private var installedSong: SongComposition?
    private var takePlaybackRestoresMonitoring = false
    private var takeReviewActive = false
    private var takeReviewRestoresMonitoring = false
    private var captureBusy: Bool { isRecording || isFinalizing || enablingMicrophone || isTestingMic || isFinishingMicTest || takeReviewActive }
    var busy: Bool { captureBusy || isRecordArmed || punchRange != nil }
    var canPressRecord: Bool {
        isRecording || isRecordArmed || (microphoneEnabled && !captureBusy && separatingSongID == nil
            && pendingAudioVersion == nil && !loadingMedia && (!hasSong || mediaReady))
    }
    var practiceRange: PracticeRange? {
        guard let loopA, let loopB else { return nil }
        let range = PracticeRange(start: loopA, end: loopB)
        return range.isValid ? range : nil
    }
    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }
    var inputDevice: AudioDevice? { inputs.first { $0.id == inputID } }
    var outputDevice: AudioDevice? { outputs.first { $0.id == outputID } }
    var librarySong: LibrarySong? { songs.first { $0.id == selectedSongID } }
    var songTitle: String { librarySong?.displayName ?? (accompanimentURL ?? mediaURL)?.deletingPathExtension().lastPathComponent ?? "未选择歌曲" }
    var pitchLabel: String { semitones == 0 ? "原调" : String(format: "%+d 半音", semitones) }
    var audioSourceLabel: String {
        if accompanimentURL != nil {
            let source = selectedSongID.flatMap { id in
                extractedAccompaniments[id].map { _ in libraryAudioVersion(for: id).label }
            } ?? "独立伴奏"
            return source + (mediaURL != nil ? " · MV 原音已关闭" : " · 人声单独录制")
        }
        return mediaURL != nil ? "播放 MV 自带音轨" : "导入伴奏后即可跟唱"
    }
    var currentLyricIndex: Int? {
        // AVPlayer can report an exact seek one 48 kHz tick before the requested time.
        lyrics.index(at: position - lyricDelay + 2.0 / Double(Self.playbackTimescale))
    }
    var showsVideo: Bool { mediaReady && mediaURL != nil && position < videoDuration }
    var hasSong: Bool { mediaURL != nil || accompanimentURL != nil }
    var canSearchLyrics: Bool { hasSong && !busy && !loadingMedia }

    init(libraryRoot: URL? = SongLibrary.bundledRoot, userLibraryRoot: URL? = SongLibrary.userRoot,
         takesDirectory: URL = Take.directory, musicDLImporter: MusicDLImporter? = nil,
         monitorDefaults: UserDefaults = .standard,
         moveToTrash: @escaping (URL) throws -> URL = Take.moveToSystemTrash) {
        self.libraryRoot = libraryRoot
        self.userLibraryRoot = userLibraryRoot
        self.musicDLImporter = musicDLImporter ?? userLibraryRoot.map { MusicDLImporter(libraryRoot: $0) }
        self.musicDLDownloadDirectory = self.musicDLImporter?.downloadLocation.customDirectory
        self.takesDirectory = takesDirectory
        self.moveToTrash = moveToTrash
        self.monitorDefaults = monitorDefaults
        practiceSettingsURL = userLibraryRoot?.appendingPathComponent("practice-settings.json")
        if let data = monitorDefaults.data(forKey: MonitorPreferences.key),
           let saved = try? JSONDecoder().decode(MonitorPreferences.self, from: data) {
            let effects = saved.effects.bounded
            preset = saved.preset
            monitorGain = effects.gain
            brightness = effects.brightness
            compression = effects.compression
            reverb = effects.reverb
        }
        if let practiceSettingsURL, let data = try? Data(contentsOf: practiceSettingsURL) {
            practice = (try? JSONDecoder().decode(SongPracticeFile.self, from: data)) ?? SongPracticeFile()
        }
        player.volume = videoVolume
        takes = Take.loadAll(in: takesDirectory)
        refreshDevices()
        audio.configurationChanged = { [weak self] in self?.handleDeviceChange() }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mediaReady, !self.loadingMedia else { return }
                // A callback queued before a track switch can carry the old item's timestamp.
                let time = self.player.currentTime().seconds
                if time.isFinite { self.position = time }
                self.isPlaying = self.player.rate > 0
                if self.isRecording, let punch = self.punchRange, self.position >= punch.end {
                    self.stopRecording()
                } else if let arm = self.recordArm, self.recordLeadIn == .listen, self.player.rate > 0 {
                    self.recordCountdown = max(0, Int(ceil(arm.start - self.position)))
                    if self.position >= arm.start { self.commitArmedRecording(arm.id, continuingPlayback: true) }
                } else if self.loopEnabled, self.isPlaying, let range = self.practiceRange, self.position >= range.end {
                    self.restartLoop()
                }
                if self.isPlaying, Date().timeIntervalSince(self.lastPracticeWrite) >= 5 {
                    self.savePracticeSettings()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.isPlaying = false
                if self.isRecording { self.stopRecording() }
                else if self.isRecordArmed { self.cancelRecordPreparation() }
                else if self.loopEnabled { self.restartLoop(resume: true) }
                else { self.position = self.duration; self.savePracticeSettings() }
            }
        }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if self.isRecording { self.stopRecording(interrupted: true, reason: "伴奏播放中断，已保留目前录到的人声。") }
                else if self.isRecordArmed { self.cancelRecordPreparation() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshLibrary(autoSelect: true)
    }

    func setMusicDLDownloadDirectory(_ url: URL?) async throws {
        guard let musicDLImporter else { return }
        musicDLDownloadDirectory = try await musicDLImporter.setDownloadDirectory(url)
    }

    func refreshLibrary(autoSelect: Bool = false) {
        guard !busy, !loadingMedia else { return }
        do {
            let hidden: Set<String>
            if let file = hiddenSongsFile, FileManager.default.fileExists(atPath: file.path) {
                hidden = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
            } else { hidden = [] }
            var loadedSongs: [LibrarySong] = []
            var libraries: [String: SongLibrary] = [:]
            for root in [libraryRoot, userLibraryRoot].compactMap({ $0 }) {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path) else { continue }
                let loaded = try SongLibrary(root: root)
                for song in loaded.songs where libraries[song.id] == nil && !hidden.contains(song.id) {
                    // Keep the entry in its catalog so Finder's “Put Back” can restore a trashed track.
                    guard song.musicDL != nil || (try? loaded.url(song.accompaniment)) != nil else { continue }
                    libraries[song.id] = loaded
                    loadedSongs.append(song)
                }
            }
            songLibraries = libraries
            extractedAccompaniments = loadedSongs.reduce(into: [:]) { tracks, song in
                for version in LibraryAudioVersion.extracted {
                    guard let destination = extractedDestination(for: song, version: version),
                          let info = try? destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                          info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) > 44 else { continue }
                    tracks[song.id, default: [:]][version] = destination
                }
            }
            hiddenSongIDs = hidden
            songs = loadedSongs
            if autoSelect {
                let recent = songs.first(where: { $0.id == practice.lastSongID })
                let canOpenImmediately: (LibrarySong) -> Bool = { song in
                    self.extractedAccompaniments[song.id]?[self.preferredAudioVersion(for: song.id)] != nil
                        || self.availableLibraryAudio(for: song) != nil
                }
                if let recent, canOpenImmediately(recent) {
                    selectSong(recent.id)
                } else if let song = songs.first(where: canOpenImmediately) {
                    selectSong(song.id)
                }
            }
        } catch { errorMessage = "无法读取曲库：\(error.localizedDescription)" }
    }

    private var hiddenSongsFile: URL? { userLibraryRoot?.appendingPathComponent("hidden-songs.json") }

    private func saveHiddenSongs(_ ids: Set<String>) throws {
        guard let file = hiddenSongsFile else { throw AppFailure(message: "无法访问本地曲库。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: file, options: .atomic)
    }

    private func managedSongFolder(_ song: LibrarySong) -> URL? {
        guard let library = songLibraries[song.id], let userLibraryRoot,
              library.root.resolvingSymlinksInPath().path == userLibraryRoot.resolvingSymlinksInPath().path else { return nil }
        return library.managedFolder(for: song)
    }

    func canTrashLibrarySong(_ song: LibrarySong) -> Bool { managedSongFolder(song) != nil }

    func removeLibrarySong(_ id: String, moveFiles: Bool) {
        guard !busy, !loadingMedia, separatingSongID != id, let song = songs.first(where: { $0.id == id }) else { return }
        do {
            if moveFiles {
                guard let folder = managedSongFolder(song) else {
                    throw AppFailure(message: "曲目文件已变动。请刷新曲库后重试。")
                }
                _ = try moveToTrash(folder)
            } else {
                try saveHiddenSongs(hiddenSongIDs.union([id]))
            }
            if selectedSongID == id {
                selectedSongID = nil
                rebuildSong(videoURL: nil, accompanimentURL: nil)
                clearLyrics()
            }
            refreshLibrary()
            status = moveFiles ? "已将曲目移到废纸篓。" : "已隐藏曲目，可从曲库菜单恢复。"
        } catch { errorMessage = "无法移出曲目：\(error.localizedDescription)" }
    }

    func restoreHiddenSongs() {
        guard !busy, !loadingMedia, !hiddenSongIDs.isEmpty else { return }
        do {
            try saveHiddenSongs([])
            refreshLibrary()
            status = "已恢复隐藏的曲目。"
        } catch { errorMessage = "无法恢复曲目：\(error.localizedDescription)" }
    }

    func revealLibrarySong(_ song: LibrarySong) {
        let url = extractedAccompaniments[song.id]?[libraryAudioVersion(for: song.id)] ?? availableLibraryAudio(for: song)
        guard let url else {
            errorMessage = song.musicDL == nil ? "找不到曲目的伴奏文件。" : "这首歌暂无本地音频。请先在曲库中打开它。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func availableLibraryAudio(for song: LibrarySong) -> URL? {
        guard let library = songLibraries[song.id] else { return nil }
        if song.musicDL != nil { return musicDLImporter?.availableAudio(for: song, library: library) }
        return try? library.url(song.accompaniment)
    }

    func selectSong(_ id: String, audioVersion: LibraryAudioVersion? = nil) {
        guard !busy, !loadingMedia, let library = songLibraries[id], let song = songs.first(where: { $0.id == id }) else { return }
        if id == selectedSongID, let audioVersion {
            setLibraryAudioVersion(for: song, version: audioVersion)
            return
        }
        cancelAudioVersionSwitch()
        let version = audioVersion ?? preferredAudioVersion(for: id)
        if let audio = extractedAccompaniments[id]?[version] ?? availableLibraryAudio(for: song) {
            openLibrarySong(song, in: library, audio: audio)
            return
        }
        guard song.musicDL != nil, let musicDLImporter else {
            errorMessage = "找不到曲目的伴奏文件。"
            return
        }
        guard separatingSongID != id else { return }
        if isPlaying { togglePlayback() }
        loadingMedia = true
        status = "正在准备「\(song.title)」的播放音频…"
        loadTask?.cancel()
        let generation = UUID()
        loadingGeneration = generation
        loadTask = Task {
            do {
                let audio = try await musicDLImporter.prepareAudio(for: song, library: library)
                guard !Task.isCancelled, generation == loadingGeneration else { return }
                loadingMedia = false
                if selectedSongID == id {
                    rebuildSong(videoURL: mediaURL, accompanimentURL: audio, preservePlayback: true)
                } else {
                    openLibrarySong(song, in: library, audio: audio)
                }
            } catch {
                guard !Task.isCancelled, generation == loadingGeneration else { return }
                loadingMedia = false
                status = "未能打开「\(song.title)」。"
                errorMessage = "无法打开曲目：\(error.localizedDescription)"
            }
        }
    }

    private func openLibrarySong(_ song: LibrarySong, in library: SongLibrary, audio: URL) {
        do {
            let video = try song.video.map { try library.url($0) }
            let manualLyric = savedSearchLyricsURL(key: "song:\(song.id)")
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let lyric = try manualLyric ?? song.lyrics.map { try library.url($0) }
            changePracticeSong(to: song.id, videoURL: video, accompanimentURL: audio, defaultLyrics: lyric)
        } catch { errorMessage = "无法打开曲目：\(error.localizedDescription)" }
    }

    private func extractedDestination(for song: LibrarySong, version: LibraryAudioVersion) -> URL? {
        guard let userLibraryRoot else { return nil }
        let filenames: (managed: String, separate: String)
        switch version {
        case .original: return nil
        case .standard: filenames = ("KTake Instrumental.wav", "instrumental.wav")
        case .highQuality: filenames = ("KTake Instrumental HQ.wav", "instrumental-hq.wav")
        case .instHQ3: filenames = ("KTake Instrumental UVR.wav", "instrumental-uvr.wav")
        case .smallKaraoke: filenames = ("KTake Small Karaoke.wav", "small-karaoke.wav")
        case .mdx23c: filenames = ("KTake Instrumental MDX23C.wav", "instrumental-mdx23c.wav")
        }
        if let folder = managedSongFolder(song) {
            return folder.appendingPathComponent(filenames.managed)
        }
        // Bundled songs live in the signed app and use separate writable storage.
        let key = SHA256.hash(data: Data(song.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return userLibraryRoot.appendingPathComponent("ExtractedAccompaniments", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(filenames.separate)
    }

    private func preferredAudioVersion(for id: String) -> LibraryAudioVersion {
        let saved = practice.songs["song:\(id)"]
        let versions = extractedAccompaniments[id]
        if let version = saved?.audioVersion {
            if version == .original || versions?[version] != nil { return version }
        } else if saved?.usesExtractedAccompaniment == false { return .original }
        return LibraryAudioVersion.extracted.first { versions?[$0] != nil } ?? .original
    }

    func libraryAudioVersion(for id: String) -> LibraryAudioVersion {
        if selectedSongID == id {
            return extractedAccompaniments[id]?.first { $0.value == accompanimentURL }?.key ?? .original
        }
        return preferredAudioVersion(for: id)
    }

    func availableAudioVersions(for id: String) -> [LibraryAudioVersion] {
        [.original] + LibraryAudioVersion.extracted.filter { extractedAccompaniments[id]?[$0] != nil }
    }

    private func cancelAudioVersionSwitch() {
        audioVersionTask?.cancel()
        audioVersionTask = nil
        pendingAudioVersion = nil
    }

    func setLibraryAudioVersion(for song: LibrarySong, version: LibraryAudioVersion) {
        guard !busy, !loadingMedia, let library = songLibraries[song.id],
              version == .original || extractedAccompaniments[song.id]?[version] != nil else { return }
        if selectedSongID != song.id {
            selectSong(song.id, audioVersion: version)
            return
        }
        if pendingAudioVersion == version { return }
        cancelAudioVersionSwitch()
        if libraryAudioVersion(for: song.id) == version { return }

        let target = extractedAccompaniments[song.id]?[version] ?? availableLibraryAudio(for: song)
        let video = mediaURL
        let pitch = semitones
        pendingAudioVersion = version
        audioVersionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled { self.cancelAudioVersionSwitch() }
            }
            do {
                let audio: URL
                if let target { audio = target }
                else if song.musicDL != nil, self.separatingSongID != song.id, let importer = self.musicDLImporter {
                    audio = try await importer.prepareAudio(for: song, library: library)
                } else {
                    throw AppFailure(message: "原音频暂不可用。")
                }
                let prepared = try await self.prepareSong(videoURL: video, accompanimentURL: audio, semitones: pitch)
                guard !Task.isCancelled, self.selectedSongID == song.id, !self.busy, !self.loadingMedia else { return }
                let previous = self.installedSong
                let previousPosition = self.player.currentTime().seconds
                let wasPlaying = self.player.rate > 0
                self.audioVersionTask = nil
                self.pendingAudioVersion = nil
                self.rebuildSong(videoURL: video, accompanimentURL: audio, preservePlayback: true, preparedSong: prepared,
                                 onFailure: { [weak self] in
                    guard let self, let previous else { return }
                    self.rebuildSong(videoURL: previous.videoURL, accompanimentURL: previous.accompanimentURL,
                                     restorePosition: previousPosition, preparedSong: previous, onReady: { [weak self] in
                        if wasPlaying { self?.togglePlayback() }
                    })
                })
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "无法切换音轨：\(error.localizedDescription)"
            }
        }
    }

    func extractAccompaniment(for song: LibrarySong, version: LibraryAudioVersion, approvedModelDirectory: URL? = nil) {
        guard let model = version.extractionModel, model.isSupported, !busy, !loadingMedia, separatingSongID == nil,
              extractedAccompaniments[song.id]?[version] == nil, let library = songLibraries[song.id],
              let destination = extractedDestination(for: song, version: version),
              let userLibraryRoot else { return }
        let available = availableLibraryAudio(for: song)
        guard available != nil || (song.musicDL != nil && musicDLImporter != nil) else {
            errorMessage = "找不到曲目的原音频。"
            return
        }
        let engineDirectory = userLibraryRoot.deletingLastPathComponent().appendingPathComponent("Separation", isDirectory: true)
        let location: AccompanimentExtractor.ModelLocation
        do {
            location = try AccompanimentExtractor.modelLocation(for: model, engineDirectory: engineDirectory,
                                                               modelDirectory: StorageLocations.modelRoot)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if location.installed == nil && approvedModelDirectory != location.destination {
            modelDownloadRequest = ModelDownloadRequest(song: song, version: version, model: model, directory: location.destination)
            return
        }
        let startingVersion = libraryAudioVersion(for: song.id)
        let generation = UUID()
        separationGeneration = generation
        separatingModel = model
        separatingSongID = song.id
        status = "正在准备提取「\(song.title)」的伴奏…"
        separationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.accompanimentProgress = nil
                self.separatingModel = nil
                self.separatingSongID = nil
                self.separationGeneration = nil
                self.separationTask = nil
            }
            do {
                if location.installed == nil {
                    self.accompanimentProgress = .init(phase: .downloadingModel, completed: nil, total: nil, remainingSeconds: nil)
                    try await AccompanimentExtractor.downloadModel(model, to: location.destination, engineDirectory: engineDirectory) { _ in }
                    self.accompanimentProgress = nil
                }
                let source: URL
                if let available { source = available }
                else if let importer = self.musicDLImporter { source = try await importer.prepareAudio(for: song, library: library) }
                else { throw AppFailure(message: "找不到曲目的原音频。") }
                try await AccompanimentExtractor.extract(source: source, destination: destination,
                                                         engineDirectory: engineDirectory, model: model,
                                                         weights: location.installed ?? location.destination,
                                                         progress: { [weak self] progress in
                    guard let self, self.separationGeneration == generation,
                          self.separationTask?.isCancelled == false else { return }
                    self.accompanimentProgress = progress
                }) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.separationGeneration == generation,
                              self.separationTask?.isCancelled == false else { return }
                        self.status = message
                    }
                }
                self.extractedAccompaniments[song.id, default: [:]][version] = destination
                self.status = "「\(song.title)」的\(version.label)已就绪。"
                if !Task.isCancelled, self.selectedSongID == song.id, !self.isPlaying, self.pendingAudioVersion == nil,
                   self.libraryAudioVersion(for: song.id) == startingVersion {
                    self.setLibraryAudioVersion(for: song, version: version)
                }
            } catch is CancellationError {
                self.status = "已取消提取伴奏。"
            } catch {
                self.status = "提取伴奏失败。"
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelAccompanimentExtraction() { separationTask?.cancel() }

    func downloadedSongAdded(_ song: LibrarySong) {
        guard !busy, !loadingMedia else { status = "已下载到曲库，录音结束后刷新曲库即可选择。"; return }
        refreshLibrary()
        selectSong(song.id)
    }

    func musicDLSongAdded(_ song: LibrarySong) {
        guard !busy, !loadingMedia else { status = "已加入曲库，录音结束后刷新曲库即可选择。"; return }
        do {
            if hiddenSongIDs.contains(song.id) { try saveHiddenSongs(hiddenSongIDs.subtracting([song.id])) }
            refreshLibrary()
            status = "已加入曲库：\(song.displayName)"
        } catch { errorMessage = "无法显示已加入的曲目：\(error.localizedDescription)" }
    }

    func setPitch(_ value: Int) {
        guard !busy, !loadingMedia, mediaReady, accompanimentURL != nil,
              PitchRenderer.range.contains(value), value != semitones else { return }
        rebuildSong(videoURL: mediaURL, accompanimentURL: accompanimentURL, targetSemitones: value, preservePlayback: true)
    }

    private func practiceKey(songID: String?, videoURL: URL?, accompanimentURL: URL?) -> String? {
        if let songID { return "song:\(songID)" }
        return (accompanimentURL ?? videoURL).map { "file:\($0.resolvingSymlinksInPath().standardizedFileURL.path)" }
    }

    private func savePracticeSettings() {
        guard !loadingMedia, mediaReady, !busy, let file = practiceSettingsURL,
              let key = practiceKey(songID: selectedSongID, videoURL: mediaURL, accompanimentURL: accompanimentURL) else { return }
        // Returning to a completed song should leave it ready to sing again.
        let resume = position.isFinite && position < duration - 0.15 ? max(0, position) : 0
        let version = selectedSongID.flatMap { id in
            extractedAccompaniments[id].map { _ in libraryAudioVersion(for: id) }
        }
        let value = SongPracticeSettings(semitones: semitones, lyricDelay: lyricDelay,
                                         position: resume, lyricsPath: lyricsURL?.path,
                                         audioVersion: version)
        lastPracticeWrite = Date()
        guard practice.songs[key] != value || practice.lastSongID != selectedSongID else { return }
        var updated = practice
        updated.songs[key] = value
        updated.lastSongID = selectedSongID
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            practice = updated
        } catch { status = "无法保存这首歌的练唱设置。" }
    }

    private func changePracticeSong(to id: String?, videoURL: URL?, accompanimentURL: URL?,
                                    defaultLyrics: URL? = nil, keepUnassignedLyrics: Bool = false) {
        savePracticeSettings()
        clearPracticeLoop()
        let saved = practiceKey(songID: id, videoURL: videoURL, accompanimentURL: accompanimentURL).flatMap { practice.songs[$0] }
        let previous = (selectedSongID, lyrics, lyricsURL, lyricDelay)
        selectedSongID = id
        let pitch = saved?.semitones ?? 0
        rebuildSong(videoURL: videoURL, accompanimentURL: accompanimentURL,
                    targetSemitones: PitchRenderer.range.contains(pitch) ? pitch : 0,
                    restorePosition: saved?.position, onFailure: { [weak self] in
            guard let self else { return }
            (self.selectedSongID, self.lyrics, self.lyricsURL, self.lyricDelay) = previous
        })
        if !keepUnassignedLyrics || saved != nil { clearLyrics() }
        let savedLyrics = saved?.lyricsPath.flatMap {
            let url = Take.recordedMediaURL($0)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let lyric = savedLyrics ?? defaultLyrics { loadLyrics(lyric) }
        if let delay = saved?.lyricDelay, delay.isFinite, lyricsURL != nil { lyricDelay = min(10, max(-10, delay)) }
    }

    func refreshDevices() {
        guard !busy else { return }
        devices = AudioDevice.all()
        if !inputs.contains(where: { $0.id == inputID }) { inputID = AudioDevice.defaultID(input: true); inputChannel = 0 }
        if !outputs.contains(where: { $0.id == outputID }) { outputID = AudioDevice.defaultID(input: false) }
        routeVideo()
        if inputs.isEmpty { status = "未检测到音频输入。连接声卡或麦克风后点击刷新。" }
    }

    func deviceSelectionChanged(input: Bool) {
        guard !busy else { return }
        stopTakePlayback()
        if input { inputChannel = 0 }
        if microphoneEnabled {
            stopTakePlayback()
            monitoring = false
            audio.stop()
            microphoneEnabled = false
            status = "设备已切换，请重新启用麦克风。"
        }
        routeVideo()
    }

    private func routeVideo() { player.audioOutputDeviceUniqueID = outputDevice?.uid }

    func enableMicrophone() {
        guard !enablingMicrophone, !microphoneEnabled else { return }
        enablingMicrophone = true
        Task {
            defer { enablingMicrophone = false }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: allowed = false
            }
            guard allowed else {
                permissionDenied = true
                errorMessage = "请在系统设置 → 隐私与安全性 → 麦克风中允许 KTake 访问麦克风。"
                return
            }
            guard let input = inputDevice, let output = outputDevice else { errorMessage = "没有可用的音频输入或输出，请连接设备后刷新。"; return }
            do {
                try audio.start(input: input, output: output, channel: inputChannel)
                microphoneEnabled = true
                monitoring = false
                updateEffects()
                status = "麦克风已就绪。戴上耳机后可开启监听。"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func disableMicrophone() {
        guard !busy else { return }
        stopTakePlayback()
        monitoring = false
        audio.stop()
        microphoneEnabled = false
        meter = AudioMeter()
        status = "麦克风已关闭。"
    }

    func selectPreset(_ value: String) {
        preset = value
        switch value {
        case "温暖抒情": brightness = 0; compression = 0.45; reverb = 26
        case "清晰干声": brightness = 3; compression = 0.25; reverb = 0
        default: brightness = 2; compression = 0.35; reverb = 18
        }
    }

    func updateEffects() {
        audio.update(monitoring: monitoring && playingTakeID == nil, gain: monitorGain,
                     brightness: brightness, compression: compression, space: reverb)
    }

    private func monitorParametersChanged() {
        updateEffects()
        let preferences = MonitorPreferences(preset: preset, effects: monitorEffects)
        if let data = try? JSONEncoder().encode(preferences) {
            monitorDefaults.set(data, forKey: MonitorPreferences.key)
        }
    }

    private var monitorEffects: VocalSettings {
        VocalSettings(brightness: brightness, compression: compression, reverb: reverb, gain: monitorGain).bounded
    }

    var vocalSettings: VocalSettings {
        var settings = monitorEffects
        settings.enabled = monitoring
        return settings
    }

    func importVideo() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "选择本地 MV；导入独立伴奏后将关闭 MV 原音"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func loadVideo(_ url: URL) {
        guard !busy else { return }
        if accompanimentURL != nil { rebuildSong(videoURL: url, accompanimentURL: accompanimentURL, preservePlayback: true) }
        else { changePracticeSong(to: nil, videoURL: url, accompanimentURL: nil, keepUnassignedLyrics: !hasSong) }
    }

    func importAccompaniment() {
        guard !busy, !loadingMedia else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "选择本地伴奏（MP3、M4A、WAV、AIFF 等）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadAccompaniment(url)
    }

    func loadAccompaniment(_ url: URL) {
        guard !busy else { return }
        changePracticeSong(to: nil, videoURL: mediaURL, accompanimentURL: url, keepUnassignedLyrics: !hasSong || accompanimentURL == nil)
    }

    func importLyrics() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "lrc") ?? .text]
        panel.message = "选择带时间戳的 LRC 歌词"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadLyrics(url)
    }

    func lyricSearchContext() -> LyricSearchContext? {
        guard canSearchLyrics, let sourceURL = accompanimentURL ?? mediaURL else { return nil }
        let title = librarySong?.title ?? sourceURL.deletingPathExtension().lastPathComponent
        return LyricSearchContext(songID: selectedSongID, sourceURL: sourceURL, title: LyricMatcher.queryTitle(title),
                                  artist: LyricMatcher.searchArtist(librarySong?.artist ?? ""), duration: duration)
    }

    func importSearchedLyrics(_ record: LyricRecord, for context: LyricSearchContext) throws {
        guard canSearchLyrics, selectedSongID == context.songID, (accompanimentURL ?? mediaURL) == context.sourceURL else {
            throw AppFailure(message: "当前曲目已切换或正在录音。请关闭后重新打开歌词搜索。")
        }
        guard let lrc = record.timedLRC else { throw AppFailure(message: "这条结果没有可用的同步歌词。") }
        let parsed = try Lyrics.parse(lrc)
        let key = context.songID.map { "song:\($0)" } ?? "record:\(record.id)"
        guard let url = savedSearchLyricsURL(key: key) else { throw AppFailure(message: "无法访问本地歌词目录。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lrc.write(to: url, atomically: true, encoding: .utf8)
        applyLyrics(parsed, url: url)
        status = "已从 LRCLIB 导入 \(parsed.lines.count) 行同步歌词。"
    }

    private func savedSearchLyricsURL(key: String) -> URL? {
        // Keep manual choices separate from the catalogs, including the read-only bundled library.
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return userLibraryRoot?.appendingPathComponent("ManualLyrics/\(digest)/LRCLIB.lrc")
    }

    func loadLyrics(_ url: URL, forPunch: Bool = false) {
        guard !busy || (forPunch && punch != nil && !captureBusy) else { return }
        do {
            let data = try Data(contentsOf: url)
            let encodingGB18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            let unicodeBOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
            let unicodeText = unicodeBOM ? String(data: data, encoding: .utf16) : nil
            guard let text = String(data: data, encoding: .utf8) ?? unicodeText ?? String(data: data, encoding: String.Encoding(rawValue: encodingGB18030)) else {
                throw AppFailure(message: "无法读取歌词编码，请保存为 UTF-8 的 LRC 文件。")
            }
            applyLyrics(try Lyrics.parse(text), url: url)
        } catch { errorMessage = "歌词导入失败：\(error.localizedDescription)" }
    }

    private func applyLyrics(_ parsed: Lyrics, url: URL) {
        lyrics = parsed
        lyricsURL = url
        lyricDelay = 0
        status = "已导入 \(parsed.lines.count) 行同步歌词。"
    }

    func loadDroppedFile(_ url: URL) {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if url.pathExtension.lowercased() == "lrc" || type?.conforms(to: .plainText) == true { loadLyrics(url) }
        else if type?.conforms(to: .audio) == true { loadAccompaniment(url) }
        else { loadVideo(url) }
    }

    func clearVideo() {
        guard !busy else { return }
        if accompanimentURL != nil { rebuildSong(videoURL: nil, accompanimentURL: accompanimentURL, preservePlayback: true) }
        else { savePracticeSettings(); rebuildSong(videoURL: nil, accompanimentURL: nil) }
    }
    func clearAccompaniment() {
        guard !busy else { return }
        savePracticeSettings()
        selectedSongID = nil
        rebuildSong(videoURL: mediaURL, accompanimentURL: nil, targetSemitones: 0)
    }
    func clearLyrics() {
        guard !busy else { return }
        lyrics = .empty; lyricsURL = nil; lyricDelay = 0
    }

    private func prepareSong(videoURL: URL?, accompanimentURL: URL?, semitones: Int,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SongComposition {
        var audioOverride: URL?
        if let accompanimentURL {
            audioOverride = try await PitchRenderer.prepare(source: accompanimentURL, semitones: semitones, progress: progress)
        }
        try Task.checkCancellation()
        return try await SongComposition.build(videoURL: videoURL, accompanimentURL: accompanimentURL, audioOverrideURL: audioOverride)
    }

    private func rebuildSong(videoURL: URL?, accompanimentURL: URL?, targetSemitones: Int? = nil,
                             preservePlayback: Bool = false, restorePosition: Double? = nil,
                             preparedSong: SongComposition? = nil,
                             forPunch: Bool = false, onReady: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        guard !busy || (forPunch && !captureBusy && !isRecordArmed) else { return }
        cancelAudioVersionSwitch()
        if let loopBoundary { player.removeTimeObserver(loopBoundary); self.loopBoundary = nil }
        loopingSeek = false
        if videoURL == nil && accompanimentURL == nil { clearPracticeLoop() }
        let desiredPitch = accompanimentURL == nil ? 0 : (targetSemitones ?? semitones)
        let savedPosition = restorePosition ?? (preservePlayback && player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        let resumePlaying = preservePlayback && player.rate > 0
        loadTask?.cancel()
        stopTakePlayback()
        player.pause()
        isPlaying = false
        mediaReady = false
        let generation = UUID()
        loadingGeneration = generation
        mediaURL = videoURL
        self.accompanimentURL = accompanimentURL
        guard videoURL != nil || accompanimentURL != nil else {
            player.replaceCurrentItem(with: nil)
            itemStatusObservation = nil
            installedSong = nil
            semitones = 0; preparingPitch = false; pitchProgress = 0
            loadingMedia = false; position = 0; duration = 0; videoDuration = 0
            status = "导入伴奏后，可以配合歌词或 MV 录唱。"
            return
        }
        loadingMedia = true
        preparingPitch = desiredPitch != 0 && preparedSong == nil
        pitchProgress = 0
        loadTask = Task {
            do {
                let song: SongComposition
                if let preparedSong { song = preparedSong }
                else {
                    song = try await prepareSong(videoURL: videoURL, accompanimentURL: accompanimentURL, semitones: desiredPitch) { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.loadingGeneration == generation else { return }
                            self.pitchProgress = value
                        }
                    }
                }
                guard !Task.isCancelled, generation == loadingGeneration else { return }
                duration = song.duration
                videoDuration = song.videoDuration
                let restoredPosition = min(max(0, savedPosition.isFinite ? savedPosition : 0), duration)
                position = restoredPosition
                installedSong = song
                let item = AVPlayerItem(asset: song.asset)
                let hasAudio = song.hasAudio
                itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.loadingGeneration == generation, self.player.currentItem === item else { return }
                        if item.status == .readyToPlay {
                            self.player.seek(to: CMTime(seconds: restoredPosition, preferredTimescale: Self.playbackTimescale),
                                             toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                                Task { @MainActor in
                                    guard let self, self.loadingGeneration == generation else { return }
                                    self.preparingPitch = false
                                    self.mediaReady = completed
                                    self.loadingMedia = false
                                    self.semitones = desiredPitch
                                    self.position = restoredPosition
                                    self.status = hasAudio ? "歌曲已就绪。\(self.accompanimentURL != nil ? "独立伴奏 · \(self.pitchLabel)" : "正在使用 MV 原音轨。")" : "MV 没有音轨，请导入独立伴奏。"
                                    if completed {
                                        self.savePracticeSettings()
                                        self.configureLoopObserver()
                                        onReady?()
                                    } else { onFailure?() }
                                    if completed && resumePlaying { self.player.play(); self.isPlaying = true }
                                }
                            }
                        } else if item.status == .failed {
                            self.loadingMedia = false; self.mediaReady = false; self.preparingPitch = false
                            if self.isRecording { self.stopRecording(interrupted: true, reason: "歌曲播放失败，录音已提前结束。") }
                            onFailure?()
                            self.errorMessage = item.error?.localizedDescription ?? "歌曲加载失败。"
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                routeVideo()
            } catch {
                guard !Task.isCancelled, generation == loadingGeneration else { return }
                loadingMedia = false
                preparingPitch = false
                mediaURL = installedSong?.videoURL
                self.accompanimentURL = installedSong?.accompanimentURL
                mediaReady = player.currentItem?.status == .readyToPlay
                onFailure?()
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    func togglePlayback() {
        guard mediaReady, !busy, !loadingMedia else { return }
        stopTakePlayback()
        if player.rate > 0 { player.pause(); isPlaying = false; savePracticeSettings() }
        else {
            if loopEnabled, let range = practiceRange, !range.contains(position) {
                performSeek(to: range.start)
            } else if position >= duration - 0.15 { seek(to: 0) }
            player.play(); isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard !busy, seconds.isFinite else { return }
        let target = min(max(0, seconds), duration)
        if loopEnabled, let range = practiceRange, !range.contains(target) { stopPracticeLoop() }
        performSeek(to: target)
        savePracticeSettings()
    }

    private func performSeek(to target: Double, completion: ((Bool) -> Void)? = nil) {
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: Self.playbackTimescale),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion?(finished) }
        }
    }

    func seekToLyric(_ line: LyricLine) { seek(to: line.time + lyricDelay) }

    func setLoopA() {
        guard !busy, mediaReady else { return }
        stopPracticeLoop()
        loopA = min(max(0, position), max(0, duration - 0.25))
        if let loopB, let loopA, loopB < loopA + 0.25 { self.loopB = nil }
    }

    func setLoopB() {
        guard !busy, mediaReady, let loopA else { return }
        let end = min(position, duration)
        guard end >= loopA + 0.25 else { status = "B 点要比 A 点晚至少 0.25 秒。"; return }
        stopPracticeLoop()
        loopB = end
        togglePracticeLoop()
    }

    func togglePracticeLoop() {
        guard !busy, mediaReady, let range = practiceRange else { return }
        if loopEnabled { stopPracticeLoop() }
        else {
            loopEnabled = true
            if !range.contains(position) { performSeek(to: range.start) }
            configureLoopObserver()
        }
    }

    func clearPracticeLoop() {
        stopPracticeLoop()
        loopA = nil
        loopB = nil
    }

    private func stopPracticeLoop() {
        loopEnabled = false
        if let loopBoundary { player.removeTimeObserver(loopBoundary); self.loopBoundary = nil }
    }

    private func configureLoopObserver() {
        guard loopEnabled, let range = practiceRange, range.end <= duration else {
            stopPracticeLoop()
            return
        }
        if let loopBoundary { player.removeTimeObserver(loopBoundary) }
        loopBoundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: range.end, preferredTimescale: 48_000))], queue: .main) { [weak self] in
            Task { @MainActor in self?.restartLoop() }
        }
    }

    private func restartLoop(resume: Bool = false) {
        guard loopEnabled, !busy, !loopingSeek, let range = practiceRange,
              resume || player.rate > 0 else { return }
        loopingSeek = true
        performSeek(to: range.start) { [weak self] finished in
            guard let self else { return }
            self.loopingSeek = false
            if finished && resume && self.loopEnabled && !self.busy { self.player.play() }
        }
    }

    func startRecording() {
        guard microphoneEnabled, audio.isRunning, !captureBusy, !isRecordArmed, separatingSongID == nil else { return }
        if loadingMedia || pendingAudioVersion != nil || (hasSong && !mediaReady) { errorMessage = "请等待歌曲加载完成。"; return }
        let livePosition = player.currentTime().seconds
        let start = punchRange?.start ?? (mediaReady ? min(duration, max(0, player.rate > 0 && livePosition.isFinite ? livePosition : position)) : 0)
        if mediaReady, start >= duration - 0.1 {
            errorMessage = "歌曲已播放结束，请回到开头或选择录唱位置。"
            return
        }
        stopPracticeLoop()
        stopTakePlayback()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        isPlaying = false
        if recordLeadIn == .immediate {
            beginRecording(at: start, continuingPlayback: false)
            return
        }
        let id = UUID()
        recordArm = (id, start)
        isRecordArmed = true
        if recordLeadIn == .listen, mediaReady, start >= 0.25 {
            let lead = min(3, start)
            recordCountdown = Int(ceil(lead))
            status = "提前听伴奏，进度到起点时开始录音。"
            performSeek(to: start - lead) { [weak self] finished in
                guard let self, self.recordArm?.id == id else { return }
                guard finished else { self.cancelRecordPreparation(); return }
                self.recordBoundary = self.player.addBoundaryTimeObserver(
                    forTimes: [NSValue(time: CMTime(seconds: start, preferredTimescale: 48_000))], queue: .main
                ) { [weak self] in Task { @MainActor in self?.commitArmedRecording(id, continuingPlayback: true) } }
                self.player.play()
            }
            recordArmTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(lead + 5)) } catch { return }
                guard let self, self.recordArm?.id == id else { return }
                self.cancelRecordPreparation()
                self.status = "伴奏未到达起点，已取消录制。"
            }
        } else {
            let count = recordLeadIn == .five ? 5 : 3
            recordCountdown = count
            status = "准备开录。"
            recordArmTask = Task { [weak self] in
                for remaining in stride(from: count - 1, through: 0, by: -1) {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.recordArm?.id == id else { return }
                    if remaining == 0 { self.commitArmedRecording(id, continuingPlayback: false) }
                    else { self.recordCountdown = remaining }
                }
            }
        }
    }

    private func clearRecordingArm() {
        recordArm = nil
        isRecordArmed = false
        recordCountdown = nil
        recordArmTask?.cancel()
        recordArmTask = nil
        if let recordBoundary { player.removeTimeObserver(recordBoundary); self.recordBoundary = nil }
    }

    func cancelRecordPreparation() {
        guard let arm = recordArm else { return }
        clearRecordingArm()
        player.pause()
        isPlaying = false
        if mediaReady { performSeek(to: arm.start) }
        status = "已取消录前准备。"
    }

    private func commitArmedRecording(_ id: UUID, continuingPlayback: Bool) {
        guard let arm = recordArm, arm.id == id else { return }
        clearRecordingArm()
        beginRecording(at: arm.start, continuingPlayback: continuingPlayback)
    }

    private func beginRecording(at start: Double, continuingPlayback: Bool) {
        guard microphoneEnabled, audio.isRunning, !captureBusy, let format = audio.captureFormat else {
            player.pause()
            errorMessage = "麦克风未就绪，请重新启用后再录制。"
            return
        }
        do {
            try StorageLocations.requireDataDirectory(for: takesDirectory)
            try FileManager.default.createDirectory(at: takesDirectory, withIntermediateDirectories: true)
            let id = UUID()
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let name = "Take-\(stamp.string(from: Date()))-\(id.uuidString.prefix(6)).wav"
            let take = Take(id: id, createdAt: Date(), filename: name,
                            songName: punch?.take.songName ?? (hasSong ? songTitle : "自由录音"),
                            mediaPath: mediaURL?.path, videoStartSeconds: start,
                            duration: 0, sampleRate: format.sampleRate, interrupted: true, issue: "录音未正常完成",
                            accompanimentPath: accompanimentURL?.path, lyricsPath: lyricsURL?.path,
                            pitchSemitones: semitones, librarySongID: punch?.take.librarySongID ?? selectedSongID,
                            backingVolume: videoVolume, hasBacking: installedSong?.hasAudio == true && mediaReady,
                            parentTakeID: punch?.take.id, punchRange: punch?.sourceRange,
                            recordedLyricDelay: lyricDelay, recordedEffects: vocalSettings)
            let writer = try RecordingWriter(url: take.url(in: takesDirectory), format: format)
            do { try take.save(in: takesDirectory) } catch {
                writer.finish { _ in }
                throw error
            }
            self.writer = writer
            activeTake = take
            recordStarted = Date()
            recordingSeconds = 0
            audio.bridge.writer = writer
            isRecording = true
            if mediaReady {
                let anchor = CMClockGetTime(CMClockGetHostTimeClock())
                let live = player.currentTime().seconds
                recordingAnchor = (anchor, continuingPlayback && live.isFinite ? live : start)
                player.automaticallyWaitsToMinimizeStalling = false
                if let range = punchRange {
                    player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 48_000)
                }
                if !continuingPlayback { player.setRate(1, time: CMTime(seconds: start, preferredTimescale: 48_000), atHostTime: anchor) }
                isPlaying = true
            } else { recordingAnchor = nil }
            status = punch == nil ? "正在录制原始人声。" : "正在补录，到 B 点自动结束。"
        } catch {
            player.pause()
            isPlaying = false
            errorMessage = "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stopRecording(interrupted: Bool = false, reason: String? = nil, completion: (() -> Void)? = nil) {
        guard isRecording, let writer, var take = activeTake else { completion?(); return }
        isRecording = false
        isFinalizing = true
        audio.bridge.writer = nil
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        player.automaticallyWaitsToMinimizeStalling = true
        isPlaying = false
        let anchor = recordingAnchor
        recordingAnchor = nil
        self.writer = nil
        activeTake = nil
        writer.finish { [weak self] result in
            guard let self else { completion?(); return }
            take.duration = Double(result.frames) / take.sampleRate
            if let anchor, let firstHostTime = result.firstHostTime {
                let capturedAt = CMClockMakeHostTimeFromSystemUnits(firstHostTime)
                let delta = CMTimeSubtract(capturedAt, anchor.host).seconds
                if delta.isFinite { take.captureSongSeconds = anchor.song + delta }
            }
            take.interrupted = interrupted || result.issue != nil || result.frames == 0
            take.issue = result.issue ?? (result.frames == 0 ? "没有收到麦克风音频，请检查设备和输入通道。" : interrupted ? reason ?? "音频设备发生变化，录音已提前结束。" : nil)
            do { try take.save(in: self.takesDirectory) } catch { self.errorMessage = "音频已保存，但录音信息保存失败：\(error.localizedDescription)" }
            self.takes = Take.loadAll(in: self.takesDirectory)
            self.isFinalizing = false
            self.savePracticeSettings()
            self.status = take.interrupted ? "录音提前结束，已保留收到的人声。" : "录音已保存，可在「我的录音」中直接回听。"
            if self.punch != nil {
                self.restorePunchWorkspace()
                if !take.interrupted { self.status = "补录已单独保存，打开原录音即可比较。" }
            }
            if let issue = take.issue { self.errorMessage = issue }
            completion?()
        }
    }

    func toggleTake(_ take: Take) {
        guard !busy else { return }
        if playingTakeID == take.id { stopTakePlayback(); return }
        guard let output = outputDevice else { errorMessage = "没有可用的音频输出设备。"; return }
        stopTakePlayback()
        player.pause(); isPlaying = false
        let settings = take.quickPlaybackEffects(fallback: vocalSettings)
        takePlaybackRestoresMonitoring = monitoring
        monitoring = false
        do {
            playingTakeID = take.id
            try takePlayer.play(url: take.url(in: takesDirectory), output: output, effects: settings,
                                reverbOnly: take.recordedEffects == nil) { [weak self] error in
                self?.stopTakePlayback()
                if let error { self?.errorMessage = error.localizedDescription }
            }
            if settings.enabled, take.recordedEffects != nil {
                status = "正在回听 · 录制时的人声效果"
            } else if settings.enabled {
                let source = take.recordedReverb == nil ? "当前混响" : "录制时混响"
                status = "正在回听 · \(source) \(Int(settings.reverb.rounded()))%"
            } else { status = "正在回听干声。" }
        } catch { stopTakePlayback(); errorMessage = error.localizedDescription }
    }

    func stopTakePlayback() {
        guard playingTakeID != nil || playingMicTest else { return }
        if playingTakeID != nil { status = "回听已结束。" }
        takePlayer.stop()
        playingTakeID = nil
        playingMicTest = false
        monitoring = takePlaybackRestoresMonitoring
        takePlaybackRestoresMonitoring = false
    }

    func garageBandExportRequest(for take: Take) -> GarageBandExportRequest? {
        guard !busy, !loadingMedia, let anchor = takes.first(where: { $0.id == take.id }), anchor.duration > 0 else { return nil }
        stopTakePlayback()
        player.pause()
        isPlaying = false
        savePracticeSettings()
        return GarageBandExportRequest(anchor: anchor, takes: takes.filter { $0.songGroupKey == anchor.songGroupKey },
                                       takesDirectory: takesDirectory)
    }

    func beginTakeReview(_ take: Take) -> TakeReviewRequest? {
        guard !busy, !loadingMedia, take.duration > 0, takes.contains(where: { $0.id == take.id }) else { return nil }
        var settings = take.recordedEffects?.bounded ?? vocalSettings
        if take.recordedEffects == nil {
            settings.reverb = take.quickPlaybackEffects(fallback: settings).reverb
            settings.enabled = false
        }
        stopTakePlayback()
        player.pause()
        isPlaying = false
        savePracticeSettings()
        takeReviewRestoresMonitoring = monitoring
        takeReviewActive = true
        monitoring = false
        let versions = takes.compactMap { child -> TakePatch? in
            guard child.parentTakeID == take.id, child.duration > 0, let range = child.punchRange, range.isValid else { return nil }
            return TakePatch(take: child, url: child.url(in: takesDirectory), range: range)
        }
        return TakeReviewRequest(take: take, vocalURL: take.url(in: takesDirectory), outputUID: outputDevice?.uid,
                                 versions: versions, microphoneReady: microphoneEnabled && audio.isRunning,
                                 reviewEffects: settings)
    }

    func endTakeReview() {
        guard takeReviewActive else { return }
        takeReviewActive = false
        monitoring = takeReviewRestoresMonitoring && microphoneEnabled
        takeReviewRestoresMonitoring = false
    }

    func stagePunch(_ original: Take, range: PracticeRange) {
        guard !busy, !loadingMedia, microphoneEnabled, audio.isRunning, original.parentTakeID == nil,
              takes.contains(where: { $0.id == original.id }), range.isValid, range.end <= original.duration + 0.001 else {
            errorMessage = "请先启用麦克风，并从原录音选择至少 0.25 秒的片段。"
            return
        }
        func existing(_ path: String?) -> URL? {
            path.flatMap {
                let url = Take.recordedMediaURL($0)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        let backing = existing(original.accompanimentPath)
        let video = existing(original.mediaPath)
        guard original.hasBacking != false, original.accompanimentPath != nil ? backing != nil : video != nil else {
            errorMessage = "找不到原录音使用的伴奏，无法补录这段。"
            return
        }
        let origin = original.captureSongSeconds.flatMap { $0.isFinite ? $0 : nil } ?? original.videoStartSeconds
        let songRange = PracticeRange(start: max(0, origin + range.start), end: origin + range.end)
        guard origin.isFinite, songRange.isValid else { errorMessage = "这段没有足够的伴奏可供补录。"; return }
        savePracticeSettings()
        let previous = (songID: selectedSongID, video: mediaURL, backing: accompanimentURL,
                        position: position, pitch: semitones, lyrics: lyrics, lyricsURL: lyricsURL,
                        lyricDelay: lyricDelay, volume: videoVolume)
        clearPracticeLoop()
        punch = (original, range, { [weak self] in
            guard let self else { return }
            self.selectedSongID = previous.songID
            self.videoVolume = previous.volume
            self.rebuildSong(videoURL: previous.video, accompanimentURL: previous.backing,
                             targetSemitones: previous.pitch, restorePosition: previous.position)
            self.lyrics = previous.lyrics
            self.lyricsURL = previous.lyricsURL
            self.lyricDelay = previous.lyricDelay
        })
        punchRange = songRange
        selectedSongID = original.librarySongID
        if let volume = original.backingVolume, volume.isFinite { videoVolume = min(1, max(0, volume)) }
        lyrics = .empty
        lyricsURL = nil
        lyricDelay = 0
        if let lyric = existing(original.lyricsPath) { loadLyrics(lyric, forPunch: true) }
        if let delay = original.recordedLyricDelay, delay.isFinite { lyricDelay = min(10, max(-10, delay)) }
        rebuildSong(videoURL: video, accompanimentURL: backing, targetSemitones: original.pitchSemitones ?? 0,
                    restorePosition: songRange.start, forPunch: true, onReady: { [weak self] in
            guard let self else { return }
            let bounds = PracticeRange(start: songRange.start, end: min(songRange.end, self.duration))
            guard bounds.isValid, self.installedSong?.hasAudio == true else {
                self.restorePunchWorkspace()
                self.errorMessage = "所选片段超出可用伴奏，无法补录。"
                return
            }
            self.punchRange = bounds
            self.status = "补录就绪：\(bounds.label)。到 B 点自动结束。"
        }, onFailure: { [weak self] in self?.restorePunchWorkspace() })
    }

    func cancelPunch() {
        guard !isRecording, !isFinalizing, punch != nil else { return }
        cancelRecordPreparation()
        restorePunchWorkspace()
        status = "已取消补录。"
    }

    private func restorePunchWorkspace() {
        guard let restore = punch?.restore else { return }
        punch = nil
        punchRange = nil
        restore()
    }

    func saveTakeNote(_ id: UUID, _ note: String) {
        guard !busy, let take = takes.first(where: { $0.id == id }) else { return }
        var updated = take
        let value = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        updated.note = value.isEmpty ? nil : value
        do { try updated.save(in: takesDirectory); refreshTakes() }
        catch { errorMessage = "无法保存备注：\(error.localizedDescription)" }
    }

    func togglePreferredTake(_ id: UUID) {
        guard !busy, let take = takes.first(where: { $0.id == id }) else { return }
        var updated = take
        updated.preferred = take.preferred != true ? true : nil
        var written: [Take] = []
        do {
            if updated.preferred == true {
                for previous in takes where previous.songGroupKey == take.songGroupKey && previous.id != take.id && previous.preferred == true {
                    var cleared = previous
                    cleared.preferred = nil
                    try cleared.save(in: takesDirectory)
                    written.append(previous)
                }
            }
            try updated.save(in: takesDirectory)
        } catch {
            for previous in written { try? previous.save(in: takesDirectory) }
            errorMessage = "无法保存首选录音：\(error.localizedDescription)"
        }
        refreshTakes()
    }

    func adoptPunch(parentID: UUID, versionID: UUID?) throws {
        guard let original = takes.first(where: { $0.id == parentID }), original.parentTakeID == nil else {
            throw AppFailure(message: "找不到原录音。")
        }
        if let versionID, !takes.contains(where: { $0.id == versionID && $0.parentTakeID == parentID }) {
            throw AppFailure(message: "找不到这条补录。")
        }
        var updated = original
        updated.adoptedPunchID = versionID
        try updated.save(in: takesDirectory)
        takes = Take.loadAll(in: takesDirectory)
    }

    func startMicTest() {
        guard microphoneEnabled, audio.isRunning, !busy, !loadingMedia, let format = audio.captureFormat else { return }
        stopTakePlayback()
        player.pause()
        isPlaying = false
        savePracticeSettings()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ktv-mic-test-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("试音.wav")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writer = try RecordingWriter(url: url, format: format)
            if let old = micTestResult { try? FileManager.default.removeItem(at: old.url.deletingLastPathComponent()) }
            micTestResult = nil
            micTestWriter = writer
            micTestURL = url
            micTestStarted = ProcessInfo.processInfo.systemUptime
            micTestRemaining = 5
            audio.bridge.beginMicTest(writer)
            isTestingMic = true
            status = "正在试音，请用平时唱歌的音量唱几秒。"
        } catch {
            try? FileManager.default.removeItem(at: folder)
            errorMessage = "无法开始试音：\(error.localizedDescription)"
        }
    }

    func stopMicTest() {
        guard let writer = micTestWriter, let url = micTestURL, isTestingMic else { return }
        let level = audio.bridge.endMicTest()
        micTestWriter = nil
        micTestURL = nil
        isTestingMic = false
        isFinishingMicTest = true
        writer.finish { [weak self] output in
            guard let self else { return }
            let result = MicTestResult(url: url, level: level, frames: output.frames, issue: output.issue)
            self.micTestResult = result
            self.isFinishingMicTest = false
            self.status = "试音：\(result.summary)"
        }
    }

    func toggleMicTestPlayback() {
        guard !busy, let test = micTestResult, test.frames > 0 else { return }
        if playingMicTest { stopTakePlayback(); return }
        stopTakePlayback()
        player.pause()
        isPlaying = false
        takePlaybackRestoresMonitoring = monitoring
        monitoring = false
        playingMicTest = true
        do {
            try takePlayer.play(url: test.url, outputUID: outputDevice?.uid) { [weak self] error in
                self?.stopTakePlayback()
                if let error { self?.errorMessage = error.localizedDescription }
            }
        } catch { stopTakePlayback(); errorMessage = "试音回听失败：\(error.localizedDescription)" }
    }

    func exportTake(_ take: Take) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = take.filename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: take.url(in: takesDirectory), options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
            status = "已导出 \(destination.lastPathComponent)。"
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }

    func revealTakes() {
        try? FileManager.default.createDirectory(at: takesDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(takesDirectory)
    }

    func refreshTakes() {
        guard !busy else { return }
        takes = Take.loadAll(in: takesDirectory)
        if let id = playingTakeID, !takes.contains(where: { $0.id == id }) { stopTakePlayback() }
    }

    func removeTake(_ id: UUID) {
        guard !busy, let take = takes.first(where: { $0.id == id }) else { return }
        if playingTakeID == id { stopTakePlayback() }
        do {
            try take.trash(in: takesDirectory, using: moveToTrash)
            status = "已将录音移到废纸篓。"
        } catch { errorMessage = "无法移除录音：\(error.localizedDescription)" }
        refreshTakes()
    }

    private func tick() {
        if microphoneEnabled { meter = audio.bridge.meter }
        if isTestingMic {
            let remaining = max(0, Int(ceil(5 - (ProcessInfo.processInfo.systemUptime - micTestStarted))))
            if micTestRemaining != remaining { micTestRemaining = remaining }
            if remaining == 0 || micTestWriter?.issue != nil || !audio.isRunning { stopMicTest() }
        }
        if isRecording {
            recordingSeconds = Date().timeIntervalSince(recordStarted)
            if writer?.issue != nil { stopRecording(interrupted: true) }
            else if !audio.isRunning { handleDeviceChange() }
        }
    }

    private func handleDeviceChange() {
        if isRecordArmed { cancelRecordPreparation() }
        if !isRecording, punch != nil { cancelPunch() }
        guard microphoneEnabled else { return }
        stopTakePlayback()
        monitoring = false
        if isRecording { stopRecording(interrupted: true) }
        if isTestingMic { stopMicTest() }
        audio.stop()
        microphoneEnabled = false
        meter = AudioMeter()
        status = "音频设备发生变化，请刷新设备并重新启用麦克风。"
    }

    func prepareToQuit(_ completion: @escaping () -> Void) {
        cancelAudioVersionSwitch()
        if let separationTask {
            separationTask.cancel()
            Task {
                await separationTask.value
                prepareToQuit(completion)
            }
            return
        }
        cancelRecordPreparation()
        stopPracticeLoop()
        savePracticeSettings()
        loadTask?.cancel()
        player.pause()
        stopTakePlayback()
        timer?.invalidate()
        if isTestingMic { stopMicTest() }
        let finish: () -> Void = { [musicDLImporter] in
            Task {
                await musicDLImporter?.stopService()
                completion()
            }
        }
        if isRecording { stopRecording { [weak self] in self?.audio.stop(); finish() } }
        else if isFinalizing || isFinishingMicTest {
            // Termination is deferred until the outstanding WAV close has completed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.prepareToQuit(completion) }
        } else {
            audio.stop()
            if let test = micTestResult { try? FileManager.default.removeItem(at: test.url.deletingLastPathComponent()) }
            finish()
        }
    }
}
