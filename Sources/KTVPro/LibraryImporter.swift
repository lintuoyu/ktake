import Foundation
import AVFoundation

enum LibraryImporter {
    private static let catalogLock = NSLock()

    static func musicDLSong(reference: MusicDLReference, origin: URL, duration: Double?, root: URL) throws -> LibrarySong? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path) else { return nil }
        let library = try SongLibrary(root: root)
        return library.songs.first { song in
            if let saved = song.musicDL {
                return (saved.id == reference.id && saved.source == reference.source)
                    || (saved.localPath != nil && saved.localPath == reference.localPath)
            }
            // Previous versions kept a playable copy but did not store the provider track ID.
            guard song.sourceURL == origin.absoluteString, (try? library.url(song.accompaniment)) != nil else { return false }
            return duration.map { expected in song.duration.map { abs($0 - expected) <= 3 } ?? false } ?? true
        }
    }

    static func addMusicDL(reference: MusicDLReference, origin: URL, title: String, artist: String,
                           duration: Double?, attachment: LyricAttachment?, root: URL) throws -> LibrarySong {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        if let existing = try musicDLSong(reference: reference, origin: origin, duration: duration, root: root) { return existing }
        let files = FileManager.default
        let catalog = root.appendingPathComponent("catalog.json")
        let songs = files.fileExists(atPath: catalog.path) ? try SongLibrary(root: root).songs : []
        let id = "musicdl-" + UUID().uuidString.lowercased()
        let path = "Songs/\(id)"
        let folder = root.appendingPathComponent(path, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let lyricPath = attachment.map { _ in path + "/Lyrics.lrc" }
            if let attachment, let lyricPath {
                _ = try Lyrics.parse(attachment.lrc)
                try attachment.lrc.write(to: root.appendingPathComponent(lyricPath), atomically: true, encoding: .utf8)
            }
            let song = LibrarySong(id: id, title: title, artist: artist, accompaniment: path + "/Playback",
                                   video: nil, lyrics: lyricPath, duration: duration, sourceURL: origin.absoluteString,
                                   lyricsSourceURL: attachment?.sourceURL,
                                   lyricStatus: attachment == nil ? "未找到匹配的同步歌词" : "已导入同步歌词", musicDL: reference)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(SongLibrary.Catalog(version: 1, songs: songs + [song])).write(to: catalog, options: .atomic)
            return song
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    /// Copies validated audio first; atomically publishes the catalog only after the copy succeeds.
    static func add(file: URL, title: String, artist: String, sourceURL: URL?, root: URL,
                    attachment: LyricAttachment? = nil, lyricStatus: String? = nil,
                    markAsAccompaniment: Bool = true) throws -> LibrarySong {
        let audio = try AVAudioFile(forReading: file)
        guard audio.length > 0, audio.processingFormat.sampleRate > 0 else {
            throw AppFailure(message: "下载的文件不是可用的音频。")
        }
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        let fm = FileManager.default
        catalogLock.lock()
        defer { catalogLock.unlock() }
        let existing = fm.fileExists(atPath: root.appendingPathComponent("catalog.json").path)
            ? try SongLibrary(root: root).songs : []
        let id = "download-" + UUID().uuidString.lowercased()
        let folder = root.appendingPathComponent("Songs/\(id)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = file.pathExtension.lowercased()
        let safeExtension = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "audio"
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? file.deletingPathExtension().lastPathComponent : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedArtist = artistName.isEmpty ? (markAsAccompaniment ? "5sing" : "未知歌手") : artistName
        let cleanTitle = markAsAccompaniment ? LyricMatcher.queryTitle(resolvedTitle) : resolvedTitle
        let filenameTitle = cleanTitle.isEmpty ? resolvedTitle : cleanTitle
        let suffix = markAsAccompaniment ? " (伴奏)" : ""
        let base = "Songs/\(id)/\(safeFilename("\(resolvedArtist) - \(filenameTitle)\(suffix)"))"
        let relative = "\(base).\(safeExtension)"
        do {
            try fm.copyItem(at: file, to: root.appendingPathComponent(relative))
            let lyricPath = attachment.map { _ in base + ".lrc" }
            if let attachment, let lyricPath {
                _ = try Lyrics.parse(attachment.lrc)
                try attachment.lrc.write(to: root.appendingPathComponent(lyricPath), atomically: true, encoding: .utf8)
            }
            let song = LibrarySong(id: id, title: resolvedTitle,
                                   artist: resolvedArtist,
                                   accompaniment: relative, video: nil, lyrics: lyricPath, duration: seconds,
                                   sourceURL: sourceURL?.absoluteString, lyricsSourceURL: attachment?.sourceURL,
                                   lyricStatus: lyricStatus)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(SongLibrary.Catalog(version: 1, songs: existing + [song]))
                .write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
            return song
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\<>\"|?*").union(.controlCharacters)
        let clean = value.replacingOccurrences(of: ":", with: "：").unicodeScalars.map { invalid.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var result = ""
        for character in clean {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return result.isEmpty ? "未命名伴奏" : result
    }

    static func saveLyrics(songID: String, attachment: LyricAttachment?, status: String, root: URL) throws -> LibrarySong {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        var songs = try SongLibrary(root: root).songs
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { throw AppFailure(message: "曲目已不在曲库中。") }
        var song = songs[index]
        if let attachment {
            _ = try Lyrics.parse(attachment.lrc)
            let relative = (song.accompaniment as NSString).deletingPathExtension + ".lrc"
            let destination = root.appendingPathComponent(relative)
            try attachment.lrc.write(to: destination, atomically: true, encoding: .utf8)
            song.lyrics = relative
            song.lyricsSourceURL = attachment.sourceURL
        }
        song.lyricStatus = status
        songs[index] = song
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(SongLibrary.Catalog(version: 1, songs: songs)).write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
        return song
    }

    static func rename(songID: String, title: String, artist: String, root: URL) throws -> LibrarySong {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        let library = try SongLibrary(root: root)
        var songs = library.songs
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { throw AppFailure(message: "找不到待整理的曲目。") }
        var song = songs[index]
        let oldAudio = try library.url(song.accompaniment)
        let folder = (song.accompaniment as NSString).deletingLastPathComponent
        let name = safeFilename("\(artist) - \(title) (伴奏)")
        let relative = "\(folder)/\(name).\(oldAudio.pathExtension)"
        let newAudio = root.appendingPathComponent(relative)
        var moves: [(URL, URL)] = []
        do {
            if oldAudio.standardizedFileURL != newAudio.standardizedFileURL {
                try FileManager.default.moveItem(at: oldAudio, to: newAudio)
                moves.append((oldAudio, newAudio))
            }
            if let oldPath = song.lyrics {
                let oldLyric = try library.url(oldPath)
                let lyricPath = "\(folder)/\(name).lrc"
                let newLyric = root.appendingPathComponent(lyricPath)
                if oldLyric.standardizedFileURL != newLyric.standardizedFileURL {
                    try FileManager.default.moveItem(at: oldLyric, to: newLyric)
                    moves.append((oldLyric, newLyric))
                }
                song.lyrics = lyricPath
            }
            song.title = title; song.artist = artist; song.accompaniment = relative
            songs[index] = song
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(SongLibrary.Catalog(version: 1, songs: songs)).write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
            return song
        } catch {
            for (old, new) in moves.reversed() { try? FileManager.default.moveItem(at: new, to: old) }
            throw error
        }
    }
}
