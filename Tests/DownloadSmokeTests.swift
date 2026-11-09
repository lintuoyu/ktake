import Foundation
import AppKit
import AVFoundation
import WebKit
import CryptoKit

@main
struct DownloadSmokeTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = URL(fileURLWithPath: CommandLine.arguments[2])
        let endpoint = URL(string: CommandLine.arguments[3])!
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = root.deletingLastPathComponent().appendingPathComponent("login.html")
        try "<html>Login required</html>".write(to: invalid, atomically: true, encoding: .utf8)
        do {
            _ = try LibraryImporter.add(file: invalid, title: "bad", artist: "", sourceURL: nil, root: root)
            fatalError("HTML must not enter the audio library")
        } catch { }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path))
        let expectedHash = SHA256.hash(data: try Data(contentsOf: original))
        let lyricEndpoint = endpoint.deletingLastPathComponent().appendingPathComponent("lyrics")
        let browser = FiveSingBrowser(libraryRoot: root, lyricClient: LyricSearchClient(baseURL: lyricEndpoint))
        browser.songName = "下载测试 Ref:rain"
        browser.artist = "Aimer"
        browser.onAdded = { song in
            do {
                let library = try SongLibrary(root: root)
                precondition(library.songs.count == 1 && library.songs[0].id == song.id)
                precondition(song.title == "下载测试 Ref:rain" && song.artist == "Aimer")
                let file = try library.url(song.accompaniment)
                let downloadedHash = SHA256.hash(data: try Data(contentsOf: file))
                precondition(downloadedHash == expectedHash)
                precondition((song.duration ?? 0) > 120)
                precondition(file.lastPathComponent == "Aimer - 下载测试 Ref：rain (伴奏).mp3")
                guard let lrcPath = song.lyrics else { fatalError("matched lyrics must be associated") }
                let lrcURL = try library.url(lrcPath)
                precondition(lrcURL.deletingPathExtension().lastPathComponent == file.deletingPathExtension().lastPathComponent)
                let parsed = try Lyrics.parse(String(contentsOf: lrcURL, encoding: .utf8))
                precondition(parsed.lines.count == 3 && song.lyricsSourceURL?.contains("lrclib.net") == true)
                let second = try LibraryImporter.add(file: original, title: "第二首", artist: "", sourceURL: endpoint, root: root)
                let reloaded = try SongLibrary(root: root)
                precondition(reloaded.songs.count == 2 && second.sourceURL == endpoint.absoluteString)
                precondition(reloaded.songs[0].lyrics == song.lyrics)
                print("PASS: WKDownload → automatic naming → lyric query → LRC sidecar → persisted association; original bytes preserved; catalog append; HTML rejection")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        browser.webView.load(URLRequest(url: endpoint))
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: download timeout: \(browser.status)\n", stderr)
            exit(1)
        }
        withExtendedLifetime(browser) { app.run() }
    }
}
