import Foundation

private final class LyricSearchFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        precondition(components.queryItems?.first?.value == "青花瓷+")
        precondition(components.queryItems?.last?.value == "周杰伦")
        precondition(components.percentEncodedQuery?.contains("%2B") == true)
        let data = Data(#"[{"id":42,"trackName":"青花瓷+","artistName":"周杰伦","albumName":"现场版","duration":240,"instrumental":false,"syncedLyrics":"[00:05]测试第一句\n[00:10]测试第二句"},{"id":43,"trackName":"青花瓷+","artistName":"周杰伦","duration":120,"instrumental":false,"syncedLyrics":null}]"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct LyricMatchSmokeTests {
    static func main() async throws {
        let goodLRC = "[00:01.00]Line one\n[00:10.00]Line two\n[01:59.00]Line three"
        func record(_ id: Int, _ title: String = "Ref:rain", _ artist: String = "Aimer", _ duration: Double = 121, _ lrc: String? = nil) -> LyricRecord {
            LyricRecord(id: id, trackName: title, artistName: artist, duration: duration, instrumental: false, syncedLyrics: lrc ?? goodLRC)
        }
        precondition(LyricMatcher.best([record(1)], title: "Ref：rain (伴奏)", artist: "AIMER", duration: 120.99)?.id == 1)
        precondition(LyricMatcher.best([record(1, "Ref:rain", "Aimer", 290)], title: "Ref:rain", artist: "Aimer", duration: 121) == nil)
        precondition(LyricMatcher.best([record(1, "Ref:rain", "Other")], title: "Ref:rain", artist: "Aimer", duration: 121) == nil)
        precondition(LyricMatcher.best([record(1, "Ref:rain TV size")], title: "Ref:rain", artist: "Aimer", duration: 121) == nil)
        precondition(LyricMatcher.best([record(1), record(2, "Ref:rain", "Other")], title: "Ref:rain", artist: "5sing", duration: 121) == nil)
        precondition(LyricMatcher.best([record(1), record(2, "Ref:rain", "Aimer", 123)], title: "Ref:rain", artist: "", duration: 121)?.id == 1)
        precondition(!LyricMatcher.usable("<html>Login required</html>", duration: 121))
        precondition(!LyricMatcher.usable("[00:01]One\n[05:00]Wrong version", duration: 121))
        precondition(LyricMatcher.normalized("夜に駆ける（off vocal）") == LyricMatcher.normalized("夜に駆ける"))
        precondition(LyricMatcher.normalized("青花瓷【伴奏】") == LyricMatcher.normalized("青花瓷"))
        precondition(LyricMatcher.queryTitle("今生你作伴（陈慧琳 带和声 伴奏）") == "今生你作伴")
        precondition(LibraryImporter.safeFilename("../Aimer/Ref:rain\n?*") == "Aimer Ref：rain")
        precondition(LibraryImporter.safeFilename(String(repeating: "歌", count: 200)).utf8.count <= 180)
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let actual = try JSONDecoder().decode([LyricRecord].self, from: data)
            precondition(LyricMatcher.best(actual, title: "Ref:rain", artist: "Aimer", duration: 121.0) == nil)
            precondition(LyricMatcher.best(actual, title: "Ref:rain", artist: "Aimer", duration: 290.0) != nil)
            print("PASS: actual Ref:rain search results select full-length lyrics and reject incorrect 2:01 pairing")
        }
        print("PASS: title/artist/duration matching, wrong artist/version rejection, ambiguity, valid LRC timing, Chinese/Japanese normalization, safe filenames")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricSearchFixture.self]
        let client = LyricSearchClient(session: URLSession(configuration: config))
        let results = try await client.search(title: " 青花瓷+ ", artist: "周杰伦")
        precondition(results.count == 2 && results[0].albumName == "现场版")
        precondition(results.filter { $0.timedLRC != nil }.map(\.id) == [42])
        let strictMatch = try await client.find(title: "青花瓷+", artist: "周杰伦", duration: 120)
        precondition(strictMatch == nil)
        print("PASS: manual search exposes timed versions rejected by automatic matching, omits untimed lyrics, and encodes search fields")
    }
}
