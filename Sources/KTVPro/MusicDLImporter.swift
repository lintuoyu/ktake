import AVFoundation
import Foundation

struct MusicDLTrack: Sendable {
    let id: String
    let source: String
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let extra: String?
    let metadata: [String: String]
    let originalURL: URL?

    init?(fields: [String: String]) {
        func field(_ key: String, limit: Int = 300) -> String {
            String((fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        id = field("id", limit: 512)
        source = field("source", limit: 40)
        title = field("title")
        let performer = field("artist")
        artist = performer.isEmpty ? "未知歌手" : performer
        album = field("album")
        duration = Double(field("duration")).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard !id.isEmpty, id == fields["id"], !source.isEmpty, source == fields["source"], !title.isEmpty,
              source.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        if let value = fields["extra"], !value.isEmpty && value != "null" {
            guard value.utf8.count <= 16_384,
                  let object = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] else { return nil }
            metadata = object.compactMapValues { $0 as? String }
            extra = value
        } else {
            metadata = [:]
            extra = nil
        }
        originalURL = fields["link"].flatMap { value in
            guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return url
        }
    }

    var query: [URLQueryItem] {
        Self.query(id: id, source: source, title: title, artist: artist, album: album, duration: duration, extra: extra)
    }

    static func query(id: String, source: String, title: String, artist: String, album: String,
                      duration: Double?, extra: String?) -> [URLQueryItem] {
        var values = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "source", value: source),
                      URLQueryItem(name: "name", value: title), URLQueryItem(name: "artist", value: artist),
                      URLQueryItem(name: "album", value: album)]
        if let extra { values.append(URLQueryItem(name: "extra", value: extra)) }
        if let duration { values.append(URLQueryItem(name: "duration", value: String(Int(min(duration, 1_000_000))))) }
        return values
    }
}

actor MusicDLImporter {
    static let baseURL = URL(string: "http://127.0.0.1:18080/music")!
    static let downloadFolder = URL(fileURLWithPath: "/Volumes/Elements/DownloadedMusic", isDirectory: true)
    private let baseURL: URL
    private let folder: URL
    private let libraryRoot: URL
    private let session: URLSession
    private let lyricClient: LyricSearchClient

    init(baseURL: URL = MusicDLImporter.baseURL, folder: URL = MusicDLImporter.downloadFolder,
         libraryRoot: URL = SongLibrary.userRoot, lyricClient: LyricSearchClient = .shared) {
        self.baseURL = baseURL
        self.folder = folder
        self.libraryRoot = libraryRoot
        self.lyricClient = lyricClient
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
    }

    func add(_ track: MusicDLTrack) async throws -> LibrarySong {
        try Task.checkCancellation()
        let origin = track.originalURL ?? endpoint("search", query: [URLQueryItem(name: "q", value: track.title + " " + track.artist),
                                                                      URLQueryItem(name: "sources", value: track.source)])
        let local: URL?
        let path: String?
        if track.source == "local" || track.source == "local-file" {
            let base64 = track.id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = base64.padding(toLength: (base64.count + 3) / 4 * 4, withPad: "=", startingAt: 0)
            let decoded = Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf8) }
            path = track.metadata["rel_path"] ?? decoded
            local = path.flatMap { localFile(at: $0) }
        } else {
            local = await matchingLocalFile(title: track.title, artist: track.artist, duration: track.duration)
            path = local.map { String($0.path.dropFirst(folder.resolvingSymlinksInPath().standardizedFileURL.path.count + 1)) }
        }
        // Keep stable media identifiers only. The web page may also carry short-lived URLs or credentials.
        let identifierKeys: Set<String> = ["album_id", "media_mid", "mid", "songmid", "hash", "cid", "bvid", "aid", "audio_id", "isrc"]
        let reference = MusicDLReference(id: track.id, source: track.source, album: track.album,
                                         identifiers: track.metadata.filter { identifierKeys.contains($0.key) }, localPath: path)
        if let existing = try LibraryImporter.musicDLSong(reference: reference, origin: origin,
                                                           duration: track.duration, root: libraryRoot) { return existing }
        let seconds = local.flatMap { Self.audioDuration($0) } ?? track.duration
        var lyrics: LyricAttachment?
        if let local {
            let sidecar = local.deletingPathExtension().appendingPathExtension("lrc")
            if let data = try? Data(contentsOf: sidecar), data.count <= 512_000,
               let lrc = String(data: data, encoding: .utf8), LyricMatcher.usable(lrc, duration: seconds ?? .infinity) {
                lyrics = LyricAttachment(lrc: lrc, sourceURL: sidecar.absoluteString)
            }
        }
        if lyrics == nil, let source = await sourceLyric(for: track), LyricMatcher.usable(source.lrc, duration: seconds ?? .infinity) {
            lyrics = source
        }
        if lyrics == nil, let seconds {
            lyrics = try? await lyricClient.find(title: track.title, artist: track.artist, duration: seconds)
        }
        try Task.checkCancellation()
        return try LibraryImporter.addMusicDL(reference: reference, origin: origin, title: track.title, artist: track.artist,
                                              duration: seconds, attachment: lyrics, root: libraryRoot)
    }

    private func sourceLyric(for track: MusicDLTrack) async -> LyricAttachment? {
        let url = endpoint("lyric", query: track.query + [URLQueryItem(name: "format", value: "lrc")])
        guard let (data, response) = try? await session.data(from: url),
              let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              data.count <= 512_000, let lrc = String(data: data, encoding: .utf8) else { return nil }
        // Preserve source attribution without storing provider tokens that may be in extra.
        return LyricAttachment(lrc: lrc, sourceURL: endpoint("lyric", query: [
            URLQueryItem(name: "id", value: track.id), URLQueryItem(name: "source", value: track.source)
        ]).absoluteString)
    }

    nonisolated func availableAudio(for song: LibrarySong, library: SongLibrary) -> URL? {
        guard let reference = song.musicDL else { return try? library.url(song.accompaniment) }
        if let local = reference.localPath.flatMap({ localFile(at: $0) }) { return local }
        guard let folder = playbackFolder(for: song, library: library),
              let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        return entries.first {
            $0.deletingPathExtension().lastPathComponent == "Playback"
                && Self.audioExtensions.contains($0.pathExtension.lowercased()) && Self.isRegularFile($0)
        }
    }

    func prepareAudio(for song: LibrarySong, library: SongLibrary) async throws -> URL {
        if let file = availableAudio(for: song, library: library) { return file }
        guard let reference = song.musicDL, !reference.isLocal,
              let cache = playbackFolder(for: song, library: library) else {
            throw AppFailure(message: "找不到原音频，请确认外置盘已连接、文件仍在原位置。")
        }
        if let local = await matchingLocalFile(title: song.title, artist: song.artist, duration: song.duration) { return local }
        if let file = availableAudio(for: song, library: library) { return file }
        try Task.checkCancellation()
        let extra = reference.identifiers.isEmpty ? nil : try String(data: JSONEncoder().encode(reference.identifiers), encoding: .utf8)
        let query = MusicDLTrack.query(id: reference.id, source: reference.source, title: song.title, artist: song.artist,
                                       album: reference.album, duration: song.duration, extra: extra)
        // This is the service's playback route. It does not enqueue or save a music-dl download.
        let url = endpoint("download", query: query + [URLQueryItem(name: "stream", value: "1")])
        let (temporary, response) = try await session.download(from: url)
        let files = FileManager.default
        defer { try? files.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let suffix = Self.audioExtension(response) else {
            throw AppFailure(message: "该来源暂时无法播放，请确认 music-dl 已启动或换一个来源。")
        }
        if let file = availableAudio(for: song, library: library) { return file }
        let staging = cache.appendingPathComponent(".playback-\(UUID().uuidString)").appendingPathExtension(suffix)
        defer { try? files.removeItem(at: staging) }
        try files.moveItem(at: temporary, to: staging)
        guard let seconds = Self.audioDuration(staging) else { throw AppFailure(message: "该来源没有可用的音轨。") }
        if let expected = song.duration, expected > 75, seconds <= 60, expected - seconds > 20 {
            throw AppFailure(message: "该来源只提供试听片段，请选择其他来源。")
        }
        try Task.checkCancellation()
        let destination = cache.appendingPathComponent("Playback").appendingPathExtension(suffix)
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    private nonisolated func playbackFolder(for song: LibrarySong, library: SongLibrary) -> URL? {
        let relative = "Songs/\(song.id)"
        guard song.id.hasPrefix("musicdl-"), UUID(uuidString: String(song.id.dropFirst(8))) != nil,
              song.accompaniment == relative + "/Playback", let cache = try? library.url(relative),
              cache.path == library.root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(relative).path else {
            return nil
        }
        return cache
    }

    private nonisolated func localFile(at relative: String) -> URL? {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), Self.audioExtensions.contains(url.pathExtension.lowercased()),
              Self.isRegularFile(url) else { return nil }
        return url
    }

    private struct IndexedTracks: Decodable {
        struct Track: Decodable {
            let name: String
            let artist: String
            let rel_path: String
        }
        let tracks: [Track]
    }

    private func matchingLocalFile(title: String, artist: String, duration: Double?) async -> URL? {
        guard !LyricMatcher.searchArtist(artist).isEmpty else { return nil }
        func key(_ value: String) -> String {
            value.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let names = Set(["\(artist) - \(title)", "\(title) - \(artist)"].map { key(LibraryImporter.safeFilename($0)) })
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path),
              let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var matches: [(URL, Double, Int)] = []
        func addMatch(_ relative: String) {
            guard let url = localFile(at: relative), let seconds = Self.audioDuration(url) else { return }
            let difference = duration.map { abs(seconds - $0) } ?? 0
            if difference <= 5 {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                matches.append((url, difference, size))
            }
        }
        while let entry = entries.nextObject() as? URL {
            if Task.isCancelled { return nil }
            if Self.audioExtensions.contains(entry.pathExtension.lowercased()),
               names.contains(key(entry.deletingPathExtension().lastPathComponent)) {
                addMatch(String(entry.path.dropFirst(root.path.count + 1)))
            }
        }
        if matches.isEmpty {
            // The service's index also recognizes tracks with a custom filename or subfolder.
            let request = URLRequest(url: endpoint("local_music", query: []), timeoutInterval: 5)
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let index = try? JSONDecoder().decode(IndexedTracks.self, from: data) {
                let titleKey = key(title), artistKey = key(artist)
                for track in index.tracks where key(track.name) == titleKey && key(track.artist) == artistKey {
                    addMatch(track.rel_path)
                }
            }
        }
        return matches.sorted { ($0.1, -$0.2, $0.0.path) < ($1.1, -$1.2, $1.0.path) }.first?.0
    }

    private static func audioDuration(_ url: URL) -> Double? {
        guard let audio = try? AVAudioFile(forReading: url), audio.processingFormat.sampleRate > 0 else { return nil }
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
            .map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }

    private func endpoint(_ name: String, query: [URLQueryItem]) -> URL {
        var url = URLComponents(url: baseURL.appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        url.queryItems = query
        return url.url!
    }

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "aif", "aiff", "caf", "ogg", "opus", "alac", "wma"]

    private static func audioExtension(_ response: URLResponse) -> String? {
        let ext = ((response.suggestedFilename ?? "") as NSString).pathExtension.lowercased()
        if audioExtensions.contains(ext) { return ext }
        let mimeExtensions = ["audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                              "audio/flac": "flac", "audio/x-flac": "flac", "audio/wav": "wav",
                              "audio/x-wav": "wav", "audio/aac": "aac", "audio/ogg": "ogg"]
        return response.mimeType.flatMap { mimeExtensions[$0.lowercased()] }
    }
}
