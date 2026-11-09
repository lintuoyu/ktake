import Foundation
import CryptoKit

@main
struct OrganizeSong {
    static func main() async throws {
        guard CommandLine.arguments.count >= 5 else { fatalError("Pass root, song ID, title, artist, optional lyrics response JSON.") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let id = CommandLine.arguments[2], title = CommandLine.arguments[3], artist = CommandLine.arguments[4]
        let library = try SongLibrary(root: root)
        guard let old = library.songs.first(where: { $0.id == id }) else { fatalError("Missing song") }
        let oldFile = try library.url(old.accompaniment)
        let before = SHA256.hash(data: try Data(contentsOf: oldFile))
        let backup = root.appendingPathComponent("catalog-before-organize-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: root.appendingPathComponent("catalog.json"), to: backup)
        let renamed = try LibraryImporter.rename(songID: id, title: title, artist: artist, root: root)
        let attachment: LyricAttachment?
        if CommandLine.arguments.count > 5 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5]))
            let records = try JSONDecoder().decode([LyricRecord].self, from: data)
            let best = LyricMatcher.best(records, title: title, artist: artist, duration: renamed.duration ?? 0)
            attachment = best.flatMap { record in record.syncedLyrics.map { LyricAttachment(lrc: $0, sourceURL: "https://lrclib.net/api/get/\(record.id)") } }
        } else {
            attachment = try await LyricSearchClient.shared.find(title: title, artist: artist, duration: renamed.duration ?? 0)
        }
        let status = attachment == nil ? "未找到曲名、歌手和时长匹配的同步歌词，可手动导入 LRC" : "同步歌词已匹配"
        let updated = try LibraryImporter.saveLyrics(songID: id, attachment: attachment, status: status, root: root)
        let afterFile = try SongLibrary(root: root).url(updated.accompaniment)
        let after = SHA256.hash(data: try Data(contentsOf: afterFile))
        precondition(before == after)
        print("Renamed: \(afterFile.lastPathComponent)")
        print("Lyrics: \(status)")
        print("Audio SHA256 preserved: \(after)")
    }
}
