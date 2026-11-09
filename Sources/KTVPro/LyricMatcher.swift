import Foundation
import AVFoundation

struct LyricAttachment {
    let lrc: String
    let sourceURL: String
}

struct LyricRecord: Decodable, Identifiable {
    let id: Int
    let trackName: String
    let artistName: String
    let duration: Double
    let instrumental: Bool
    let syncedLyrics: String?
    var albumName: String? = nil

    var timedLRC: String? {
        guard !instrumental, let lrc = syncedLyrics, lrc.utf8.count <= 512_000,
              let lyrics = try? Lyrics.parse(lrc),
              lyrics.lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return lrc
    }
}

enum LyricMatcher {
    static func queryTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)[\(\[（【][^\)\]）】]*(?:伴奏|instrumental|off\s*vocal|karaoke|カラオケ)[^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func normalized(_ value: String) -> String {
        queryTitle(value).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func searchArtist(_ value: String) -> String {
        let artist = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", "5sing", "未知歌手", "无", "纯音乐"].contains(normalized(artist)) ? "" : artist
    }
    static func usable(_ lrc: String, duration: Double) -> Bool {
        guard lrc.utf8.count <= 512_000, let parsed = try? Lyrics.parse(lrc),
              parsed.lines.filter({ !$0.text.isEmpty }).count >= 2,
              let last = parsed.lines.last, last.time <= duration + 3,
              (parsed.lines.first?.time ?? -1) >= -3 else { return false }
        return true
    }
    static func best(_ records: [LyricRecord], title: String, artist: String, duration: Double) -> LyricRecord? {
        let titleKey = normalized(title), artistKey = normalized(artist)
        let knownArtist = !searchArtist(artist).isEmpty
        let candidates = records.filter {
            !$0.instrumental && normalized($0.trackName) == titleKey &&
            (!knownArtist || normalized($0.artistName) == artistKey) &&
            $0.duration.isFinite && abs($0.duration - duration) <= 3 &&
            $0.syncedLyrics.map { usable($0, duration: duration) } == true
        }.sorted { abs($0.duration - duration) < abs($1.duration - duration) }
        // Unknown artist with multiple artists is ambiguous, even if the titles match.
        guard knownArtist || Set(candidates.map { normalized($0.artistName) }).count == 1 else { return nil }
        return candidates.first
    }

    static func audioIdentity(file: URL, title: String, artist: String) async -> (String, String) {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || artist.isEmpty {
            let asset = AVURLAsset(url: file)
            if let metadata = try? await asset.load(.commonMetadata) {
                for item in metadata {
                    guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                    if title.isEmpty && item.commonKey == .commonKeyTitle { title = value }
                    if artist.isEmpty && item.commonKey == .commonKeyArtist { artist = value }
                }
            }
        }
        if title.isEmpty { title = file.deletingPathExtension().lastPathComponent }
        return (title, artist)
    }
}

/// Serializes anonymous read-only searches and keeps a small cache for repeat downloads.
actor LyricSearchClient {
    static let shared = LyricSearchClient()
    private let baseURL: URL
    private let session: URLSession
    private var cache: [String: [LyricRecord]] = [:]
    private var lastRequest = Date.distantPast
    private var cooldown = Date.distantPast
    private var inFlight = false
    init(baseURL: URL = URL(string: "https://lrclib.net/api/search")!, session: URLSession? = nil) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: configuration)
    }

    func find(title: String, artist: String, duration: Double) async throws -> LyricAttachment? {
        let title = LyricMatcher.queryTitle(title)
        guard !LyricMatcher.normalized(title).isEmpty else { return nil }
        let records = try await search(title: title, artist: LyricMatcher.searchArtist(artist))
        guard let record = LyricMatcher.best(records, title: title, artist: artist, duration: duration),
              let lrc = record.syncedLyrics else { return nil }
        return LyricAttachment(lrc: lrc, sourceURL: "https://lrclib.net/api/get/\(record.id)")
    }

    func search(title: String, artist: String) async throws -> [LyricRecord] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        let key = title + "\n" + artist
        if let records = cache[key] { return records }
        while inFlight { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if let records = cache[key] { return records }
        guard Date() >= cooldown else { throw AppFailure(message: "歌词服务请求较多，请稍后再试。") }
        inFlight = true
        defer { inFlight = false; lastRequest = Date() }
        let delay = 0.3 - Date().timeIntervalSince(lastRequest)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { components.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("KTake/0.9.3 (local macOS app)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppFailure(message: "歌词服务响应无效。") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let value = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            cooldown = Date().addingTimeInterval(max(1, Double(value) ?? formatter.date(from: value)?.timeIntervalSinceNow ?? 60))
            throw AppFailure(message: "歌词服务繁忙，请稍后再试。")
        }
        guard http.statusCode == 200, data.count <= 8_000_000 else { throw AppFailure(message: "歌词服务暂时不可用（\(http.statusCode)）。") }
        let records = try JSONDecoder().decode([LyricRecord].self, from: data)
        if cache.count >= 40 { cache.removeAll() }
        cache[key] = records
        return records
    }
}
