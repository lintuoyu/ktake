import Foundation

struct LibrarySong: Identifiable, Codable {
    let id: String
    var title: String
    var artist: String
    var accompaniment: String
    let video: String?
    var lyrics: String?
    let duration: Double?
    var sourceURL: String? = nil
    var lyricsSourceURL: String? = nil
    var lyricStatus: String? = nil
    var displayName: String { "\(artist) — \(title)" }
}

struct SongLibrary {
    struct Catalog: Codable { let version: Int; let songs: [LibrarySong] }
    let root: URL
    let songs: [LibrarySong]
    static var bundledRoot: URL? { Bundle.main.resourceURL?.appendingPathComponent("SongLibrary", isDirectory: true) }
    static var userRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KTV Pro/SongLibrary", isDirectory: true)
    }

    init(root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.version == 1 else { throw AppFailure(message: "不支持此曲库版本。") }
        guard Set(catalog.songs.map(\.id)).count == catalog.songs.count else { throw AppFailure(message: "曲库中存在重复的曲目编号。") }
        self.root = root
        self.songs = catalog.songs
    }

    func url(_ relativePath: String) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw AppFailure(message: "曲库文件不存在或路径无效：\(relativePath)")
        }
        return url
    }

    /// Only folders created by the downloader are owned by the app.
    func managedFolder(for song: LibrarySong) -> URL? {
        let prefix = "download-"
        guard song.id.hasPrefix(prefix), UUID(uuidString: String(song.id.dropFirst(prefix.count))) != nil else { return nil }
        let relative = "Songs/\(song.id)"
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let folder = base.appendingPathComponent(relative, isDirectory: true)
        let pathPrefix = folder.path + "/"
        guard folder.resolvingSymlinksInPath().path == folder.path,
              let audio = try? url(song.accompaniment), audio.path.hasPrefix(pathPrefix),
              [song.video, song.lyrics].compactMap({ $0 }).allSatisfy({
                  $0.hasPrefix(relative + "/") &&
                  base.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(pathPrefix)
              }),
              !songs.contains(where: { other in
                  other.id != song.id && [other.accompaniment, other.video, other.lyrics].compactMap { $0 }.contains {
                      base.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(pathPrefix)
                  }
              }) else { return nil }
        return folder
    }
}
