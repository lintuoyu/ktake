@preconcurrency import AVFoundation
import Foundation

struct GarageBandExportRequest: Identifiable {
    let anchor: Take
    let takes: [Take]
    let takesDirectory: URL

    var id: UUID { anchor.id }
    var pitch: Int { anchor.pitchSemitones ?? 0 }
    var backingURL: URL? { Self.source(for: anchor) }
    var compatibleTakes: [Take] {
        guard let backingURL else { return [] }
        return takes.filter { take in
            take.duration > 0 && take.songGroupKey == anchor.songGroupKey &&
            (take.pitchSemitones ?? 0) == pitch && Self.source(for: take) == backingURL
        }
    }

    private static func source(for take: Take) -> URL? {
        guard take.hasBacking != false, let path = take.accompanimentPath ?? take.mediaPath else { return nil }
        return Take.recordedMediaURL(path).resolvingSymlinksInPath().standardizedFileURL
    }

    static func hasCaptureTime(_ take: Take) -> Bool { take.captureSongSeconds?.isFinite == true }
    static func start(of take: Take) -> Double {
        if let captured = take.captureSongSeconds, captured.isFinite { return captured }
        return take.videoStartSeconds.isFinite ? max(0, take.videoStartSeconds) : 0
    }
}

struct GarageBandStems {
    let folder: URL
    let files: [URL]

    static func export(_ request: GarageBandExportRequest, selected: Set<UUID>, to parent: URL) async throws -> Self {
        let job = Task.detached(priority: .userInitiated) {
            try await render(request, selected: selected, parent: parent)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    private static func render(_ request: GarageBandExportRequest, selected: Set<UUID>, parent: URL) async throws -> Self {
        let takes = request.compatibleTakes.filter { selected.contains($0.id) }
        guard !takes.isEmpty, takes.count == selected.count else {
            throw AppFailure(message: "请选择使用同一份伴奏和调性的录音。")
        }
        let files = FileManager.default
        guard let source = request.backingURL, files.fileExists(atPath: source.path) else {
            throw AppFailure(message: "找不到录唱时使用的伴奏。")
        }
        let backing = request.anchor.accompanimentPath == nil ? source :
            try await PitchRenderer.prepare(source: source, semitones: request.pitch)
        let staging = parent.appendingPathComponent(".KTV-Stems-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        // Retain any captured audio before the song's first sample by moving the shared origin earlier.
        let origin = min(0, takes.map(GarageBandExportRequest.start).min() ?? 0)
        let backingName = request.anchor.accompanimentPath == nil ? "00 MV 音轨.wav" : "00 伴奏.wav"
        var names = [backingName]
        try await renderTrack(backing, to: staging.appendingPathComponent(backingName), lead: -origin, channels: 2)
        for (index, take) in takes.enumerated() {
            try Task.checkCancellation()
            let label = take.parentTakeID == nil ? "人声" : "补录"
            let name = String(format: "%02d", index + 1) + " \(label).wav"
            try await renderTrack(take.url(in: request.takesDirectory), to: staging.appendingPathComponent(name),
                                  lead: GarageBandExportRequest.start(of: take) - origin, channels: 1)
            names.append(name)
        }

        let title = LibraryImporter.safeFilename(request.anchor.songName + " - GarageBand 分轨")
        var folder = parent.appendingPathComponent(title, isDirectory: true)
        var version = 2
        while files.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(title) \(version)", isDirectory: true)
            version += 1
        }
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: folder)
        return Self(folder: folder, files: names.map { folder.appendingPathComponent($0) })
    }

    fileprivate static func renderTrack(_ source: URL, to destination: URL, lead: Double, channels: UInt32) async throws {
        let rate: Int32 = 44_100
        let frames = (lead * Double(rate)).rounded()
        guard frames.isFinite, (0...Double(UInt32.max)).contains(frames) else {
            throw AppFailure(message: "录音的对齐时间无效。")
        }
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let composition = AVMutableComposition()
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppFailure(message: "无法读取音频：\(source.lastPathComponent)")
        }
        let range = try await sourceTrack.load(.timeRange)
        try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        try WAVRenderer.write(asset: composition, tracks: [track], to: destination,
                              sampleRate: rate, channels: channels, duration: range.duration.seconds, leadingFrames: Int64(frames))
    }
}

enum GarageBandProject {
    static let templateURL = Bundle.main.url(forResource: "GarageBandTemplate", withExtension: "band")

    static func export(_ request: GarageBandExportRequest, selected: Set<UUID>, to parent: URL) async throws -> URL {
        let job = Task.detached(priority: .userInitiated) {
            try await render(request, selected: selected, parent: parent)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    private static var invalidTemplate: AppFailure {
        AppFailure(message: "GarageBand 工程模板无效，请重新安装 KTake。")
    }

    private static func render(_ request: GarageBandExportRequest, selected: Set<UUID>, parent: URL) async throws -> URL {
        guard selected.count == 1, let take = request.compatibleTakes.first(where: { selected.contains($0.id) }) else {
            throw AppFailure(message: "GarageBand 工程暂时支持一条人声，多条录音请选择分轨 WAV。")
        }
        let files = FileManager.default
        guard let source = request.backingURL, files.fileExists(atPath: source.path) else {
            throw AppFailure(message: "找不到录唱时使用的伴奏。")
        }
        guard let template = templateURL else {
            throw AppFailure(message: "此版本未附带 GarageBand 工程模板，请导出分轨 WAV。")
        }
        let backing = request.anchor.accompanimentPath == nil ? source :
            try await PitchRenderer.prepare(source: source, semitones: request.pitch)
        try Task.checkCancellation()
        let staging = parent.appendingPathComponent(".KTV-Project-\(UUID().uuidString).band", isDirectory: true)
        try files.copyItem(at: template, to: staging)
        defer { try? files.removeItem(at: staging) }

        let alternative = staging.appendingPathComponent("Alternatives/000", isDirectory: true)
        let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: alternative.appendingPathComponent("MetaData.plist")), format: nil)
        guard let metadata = metadata as? [String: Any], metadata["BeatsPerMinute"] as? Double == 120,
              metadata["SongSignatureNumerator"] as? Int == 4, metadata["SongSignatureDenominator"] as? Int == 4 else {
            throw invalidTemplate
        }
        let projectDataURL = alternative.appendingPathComponent("ProjectData")
        var data = try Data(contentsOf: projectDataURL)
        guard data.count >= 24, data.littleEndian(at: 16, count: 8) == UInt64(data.count - 24) else { throw invalidTemplate }
        var names: [Int: String] = [:]
        var frameOffsets: [(pool: Int, offset: Int)] = []
        var regionPools = Set<Int>()
        var songEndOffset: Int?
        var rangeOffsets: [Int] = []
        var position = 24
        while position < data.count {
            guard data.count - position >= 36 else { throw invalidTemplate }
            let start = position + 36
            let length = data.littleEndian(at: position + 28, count: 8)
            guard length <= UInt64(data.count - start) else { throw invalidTemplate }
            let end = start + Int(length)
            let tag = String(decoding: data[position..<position + 4], as: UTF8.self)
            let firstKey = data.littleEndian(at: position + 6, count: 4)
            let secondKey = data.littleEndian(at: position + 10, count: 4)
            if tag == "gnoS" {
                guard length >= 1092 else { throw invalidTemplate }
                rangeOffsets = [start + 384, start + 1084]
            } else if tag == "qeSM", firstKey == 23, secondKey == 4 {
                guard length >= 18 else { throw invalidTemplate }
                let nameBytes = Int(data.littleEndian(at: start + 16, count: 2))
                let bodyStart = start + ((18 + nameBytes + 3) / 4) * 4
                guard bodyStart + 68 <= end else { throw invalidTemplate }
                songEndOffset = bodyStart + 60
            } else if tag == "lFuA" || tag == "gRuA" {
                guard secondKey == 0 || secondKey == 4 else { throw invalidTemplate }
                let pool = Int(secondKey)
                if tag == "lFuA" {
                    guard length >= 10 else { throw invalidTemplate }
                    let nameBytes = Int(data.littleEndian(at: start + 8, count: 2)) * 2
                    guard start + 10 + nameBytes <= end,
                          let name = String(data: data.subdata(in: start + 10..<start + 10 + nameBytes), encoding: .utf16LittleEndian),
                          !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
                          names[pool] == nil,
                          let marker = data.range(of: Data("EVAW".utf8), in: start..<end), marker.lowerBound + 28 <= end else {
                        throw invalidTemplate
                    }
                    names[pool] = name
                    frameOffsets.append((pool, marker.lowerBound + 12))
                } else {
                    guard length >= 30 else { throw invalidTemplate }
                    regionPools.insert(pool)
                    frameOffsets.append((pool, start + 22))
                }
            }
            position = end
        }
        guard let backingName = names[0], let vocalName = names[4], names.count == 2,
              regionPools == Set([0, 4]), let songEndOffset, rangeOffsets.count == 2 else { throw invalidTemplate }
        let oldEnd = data.littleEndian(at: songEndOffset, count: 8)
        guard oldEnd <= UInt64(UInt32.max) - 38_400,
              rangeOffsets.allSatisfy({ data.littleEndian(at: $0, count: 8) == oldEnd + 38_400 }) else { throw invalidTemplate }

        let audioDirectory = staging.appendingPathComponent("Media/Audio Files", isDirectory: true)
        try files.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let origin = min(0, GarageBandExportRequest.start(of: take))
        try await GarageBandStems.renderTrack(backing, to: audioDirectory.appendingPathComponent(backingName), lead: -origin, channels: 2)
        try Task.checkCancellation()
        try await GarageBandStems.renderTrack(take.url(in: request.takesDirectory), to: audioDirectory.appendingPathComponent(vocalName),
                                             lead: GarageBandExportRequest.start(of: take) - origin, channels: 1)
        var frames: [Int: UInt64] = [:]
        for (pool, name) in names {
            let audio = try AVAudioFile(forReading: audioDirectory.appendingPathComponent(name))
            guard audio.length > 0, audio.fileFormat.sampleRate == 44_100,
                  audio.fileFormat.channelCount == (pool == 0 ? 2 : 1),
                  audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24 else {
                throw AppFailure(message: "无法生成 GarageBand 所需的音频格式。")
            }
            frames[pool] = UInt64(audio.length)
        }
        for field in frameOffsets { data.setLittleEndian(frames[field.pool]!, at: field.offset) }
        let songEnd = ((frames.values.max()! + 88_199) / 88_200) * 3_840
        guard songEnd <= UInt64(UInt32.max) - 38_400 else { throw AppFailure(message: "音频超出 GarageBand 工程的时间范围。") }
        data.setLittleEndian(songEnd, at: songEndOffset)
        for offset in rangeOffsets { data.setLittleEndian(songEnd + 38_400, at: offset) }
        try data.write(to: projectDataURL, options: .atomic)

        let title = LibraryImporter.safeFilename(request.anchor.songName + " - GarageBand")
        var destination = parent.appendingPathComponent(title + ".band", isDirectory: true)
        var version = 2
        while files.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(title) \(version).band", isDirectory: true)
            version += 1
        }
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: destination)
        return destination
    }
}

private extension Data {
    func littleEndian(at offset: Int, count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }

    mutating func setLittleEndian(_ value: UInt64, at offset: Int) {
        for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
