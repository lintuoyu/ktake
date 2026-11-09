import Foundation

struct LyricLine: Identifiable, Equatable {
    var id: Int
    let time: Double
    let text: String
}

struct Lyrics {
    let lines: [LyricLine]
    static let empty = Lyrics(lines: [])

    static func parse(_ source: String) throws -> Lyrics {
        let stamp = try NSRegularExpression(pattern: #"\[(\d{1,6}):([0-5]?\d)(?:[\.:](\d{1,3}))?\]"#)
        let offsetTag = try NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#)
        let wordStamp = try NSRegularExpression(pattern: #"<\d+:\d+(?:\.\d+)?>"#)
        let source = source.replacingOccurrences(of: "\u{feff}", with: "")
        let wholeRange = NSRange(source.startIndex..., in: source)
        var offset = 0.0
        if let match = offsetTag.firstMatch(in: source, range: wholeRange), let range = Range(match.range(at: 1), in: source) {
            offset = (Double(source[range]) ?? 0) / 1000
        }
        var entries: [(time: Double, text: String, order: Int)] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            let matches = stamp.matches(in: line, range: range)
            guard let last = matches.last, let end = Range(last.range, in: line)?.upperBound else { continue }
            var text = String(line[end...]).trimmingCharacters(in: .whitespaces)
            text = wordStamp.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            for match in matches {
                func number(_ group: Int) -> String {
                    Range(match.range(at: group), in: line).map { String(line[$0]) } ?? ""
                }
                guard let minutes = Double(number(1)), let seconds = Double(number(2)) else { continue }
                let fraction = number(3)
                let decimal = fraction.isEmpty ? 0 : (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
                entries.append((minutes * 60 + seconds + decimal + offset, text, entries.count))
            }
        }
        guard !entries.isEmpty else { throw AppFailure(message: "没有找到带时间戳的歌词。请导入 LRC 文件，例如 [00:12.50]这一句歌词。") }
        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var lines: [LyricLine] = []
        for entry in entries {
            if let last = lines.last, last.time == entry.time {
                if last.text != entry.text {
                    lines[lines.count - 1] = LyricLine(id: last.id, time: last.time, text: [last.text, entry.text].filter { !$0.isEmpty }.joined(separator: " / "))
                }
            } else { lines.append(LyricLine(id: lines.count, time: entry.time, text: entry.text)) }
        }
        return Lyrics(lines: lines)
    }

    /// Last line at or before the playback time, including when seeking backwards.
    func index(at seconds: Double) -> Int? {
        guard seconds.isFinite, !lines.isEmpty else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
