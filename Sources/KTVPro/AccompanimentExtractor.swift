@preconcurrency import AVFoundation
import Darwin
import Foundation

enum AccompanimentExtractor {
    struct Progress: Decodable, Equatable, Sendable {
        enum Phase: String, Decodable, Sendable {
            case preparingModel, loadingModel, separating, saving
        }

        let phase: Phase
        let completed: Int?
        let total: Int?
        let remainingSeconds: Double?

        var fraction: Double? {
            if phase == .saving { return 1 }
            guard let completed, let total, total > 0, (0...total).contains(completed) else { return nil }
            return Double(completed) / Double(total)
        }
    }

    enum Model: String {
        case highQuality = "Kim Vocal 2"
        case instHQ3 = "Inst HQ 3"
        case smallKaraoke = "Small Karaoke"

        var isSupported: Bool {
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }

        var runtimeName: String {
            switch self {
            case .highQuality: "roformer-runtime"
            case .instHQ3: "inst-hq3-runtime"
            case .smallKaraoke: "small-karaoke-runtime"
            }
        }

        var scriptSettings: (resource: String, cache: String, readyMarker: String) {
            switch self {
            case .highQuality: ("ExtractRoFormer", "roformer-models", "ktake-roformer-ready")
            case .instHQ3: ("ExtractInstHQ3", "inst-hq3-model", "ktake-inst-hq3-ready")
            case .smallKaraoke: ("ExtractSmallKaraoke", "small-karaoke-model", "ktake-small-karaoke-ready")
            }
        }

        var packages: [String] {
            switch self {
            case .highQuality: ["mlx-audio==0.4.3", "mlx==0.31.1", "soundfile==0.13.1"]
            case .instHQ3, .smallKaraoke:
                ["mlx-audio-separator==0.1.20", "mlx==0.32.3", "soundfile==0.13.1"]
                    + (self == .smallKaraoke ? ["torch==2.10.0"] : [])
            }
        }
    }

    static func extract(source: URL, destination: URL, engineDirectory: URL, model: Model,
                        progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in },
                        status: @escaping @Sendable (String) -> Void) async throws {
        let work = Task.detached(priority: .utility) {
            guard model.isSupported else {
                throw AppFailure(message: "此模型需要搭载 Apple 芯片的 Mac。")
            }
            let files = FileManager.default
            let parent = destination.deletingLastPathComponent()
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".separating-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }

            status("正在准备音频…")
            let song = try await SongComposition.build(videoURL: nil, accompanimentURL: source)
            let tracks = try await song.asset.loadTracks(withMediaType: .audio)
            let input = staging.appendingPathComponent("input.wav")
            try WAVRenderer.write(asset: song.asset, tracks: tracks, to: input, sampleRate: 44_100, channels: 2,
                                  duration: song.duration)

            let runtime = engineDirectory.appendingPathComponent(model.runtimeName, isDirectory: true)
            let settings = model.scriptSettings
            let executable = runtime.appendingPathComponent("bin/python")
            let marker = runtime.appendingPathComponent(settings.readyMarker)
            if !files.isExecutableFile(atPath: executable.path) || !files.fileExists(atPath: marker.path) {
                status("首次使用，正在安装本地分离引擎…")
                guard let uv = findUV() else {
                    throw AppFailure(message: "首次提取需要 uv。请先安装 uv（brew install uv），再重试。")
                }
                try files.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
                try await run(uv, ["venv", "--allow-existing", "--python", "3.12", runtime.path],
                              in: staging, errorTitle: "无法准备本地 Python")
                try await run(uv, ["pip", "install", "--python", runtime.appendingPathComponent("bin/python").path,
                                   "--index-url", "https://pypi.org/simple"] + model.packages,
                              in: staging, errorTitle: "无法安装本地分离引擎")
                try Data().write(to: marker, options: .atomic)
            }

            guard let script = Bundle.main.url(forResource: settings.resource, withExtension: "py") else {
                throw AppFailure(message: "应用缺少 \(model.rawValue) 分离组件。")
            }
            let models = engineDirectory.appendingPathComponent(settings.cache, isDirectory: true)
            let output = staging.appendingPathComponent("instrumental.wav")
            let progressFile = staging.appendingPathComponent("progress.json")
            let arguments = ["-B", script.path, input.path, output.path, models.path, progressFile.path]
            try await run(executable, arguments, in: staging, errorTitle: "\(model.rawValue) 未能完成提取",
                          progress: (file: progressFile, update: progress))
            let result = try AVAudioFile(forReading: output)
            let rate = result.processingFormat.sampleRate
            let seconds = Double(result.length) / rate
            guard result.length > 0, seconds.isFinite, abs(song.duration - seconds) < 0.1 else {
                throw AppFailure(message: "提取结果与原曲时长不一致，未保存伴奏。")
            }
            try Task.checkCancellation()
            try files.moveItem(at: output, to: destination)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func findUV() -> URL? {
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = [user, "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/uv" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private static func run(_ executable: URL, _ arguments: [String], in folder: URL, errorTitle: String,
                            progress: (file: URL, update: @MainActor @Sendable (Progress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let log = folder.appendingPathComponent("run.log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        environment["HF_HUB_DISABLE_XET"] = "1"
        environment["HF_HUB_DOWNLOAD_TIMEOUT"] = "90"
        environment["UV_HTTP_TIMEOUT"] = "60"
        process.environment = environment
        do { try process.run() }
        catch { throw AppFailure(message: "\(errorTitle)：\(error.localizedDescription)") }

        var lastProgress: Progress?
        func readProgress() async {
            guard let progress, let data = try? Data(contentsOf: progress.file),
                  let latest = try? JSONDecoder().decode(Progress.self, from: data),
                  latest != lastProgress else { return }
            lastProgress = latest
            await progress.update(latest)
        }
        do {
            while process.isRunning {
                await readProgress()
                try await Task.sleep(for: .milliseconds(160))
            }
            try Task.checkCancellation()
            await readProgress()
        } catch {
            if process.isRunning {
                process.terminate()
                // Wait for the child before releasing its staging files.
                for _ in 0..<10 where process.isRunning { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let reader = try? FileHandle(forReadingFrom: log)
            defer { try? reader?.close() }
            let size = (try? reader?.seekToEnd()) ?? 0
            try? reader?.seek(toOffset: size > 4096 ? size - 4096 : 0)
            let tail = (try? reader?.readToEnd()).flatMap { String(decoding: $0, as: UTF8.self) }
            let detail = tail?.split(whereSeparator: \.isNewline).last.map { String($0.prefix(240)) }
            throw AppFailure(message: errorTitle + (detail.map { "：\($0)" } ?? "。"))
        }
    }
}
