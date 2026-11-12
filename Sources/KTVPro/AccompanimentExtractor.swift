@preconcurrency import AVFoundation
import Darwin
import Foundation

enum AccompanimentExtractor {
    struct Progress: Decodable, Equatable, Sendable {
        enum Phase: String, Decodable, Sendable {
            case downloadingModel, preparingModel, loadingModel, separating, saving
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

    struct ModelLocation: Sendable {
        let destination: URL
        let installed: URL?
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

        var downloadSize: String {
            switch self {
            case .highQuality: "约 456 MB"
            case .instHQ3: "约 67 MB"
            case .smallKaraoke: "约 202 MB"
            }
        }

        var weightsSize: Int {
            switch self {
            case .highQuality: 456_483_463
            case .instHQ3: 66_871_394
            case .smallKaraoke: 202_371_435
            }
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

    static func modelLocation(for model: Model, engineDirectory: URL, modelDirectory: URL?) throws -> ModelLocation {
        let cache = model.scriptSettings.cache
        let modelRoot = try modelDirectory.map { try StorageLocations.existingDirectory($0) }
        let destination = (modelRoot?.appendingPathComponent("KTake Models/v1", isDirectory: true) ?? engineDirectory)
            .appendingPathComponent(cache, isDirectory: true)
        let originalCache = (modelRoot ?? engineDirectory).appendingPathComponent(cache, isDirectory: true)
        var candidates = [destination, originalCache]
        if let modelRoot { candidates.append(modelRoot) }
        if model == .highQuality {
            let snapshot = "models--mlx-community--mel-roformer-kim-vocal-2-mlx/snapshots/64cbfcb004e39430e5f584552c05949440ec39ce"
            candidates.append(originalCache.appendingPathComponent(snapshot, isDirectory: true))
        }
        return ModelLocation(destination: destination, installed: candidates.first { modelIsReady(model, in: $0) })
    }

    private static func modelIsReady(_ model: Model, in directory: URL) -> Bool {
        let weights = directory.appendingPathComponent("model.safetensors").resolvingSymlinksInPath()
        guard let attributes = try? weights.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.fileSize == model.weightsSize else { return false }
        if model == .smallKaraoke { return true }
        let config = directory.appendingPathComponent("config.json")
        return FileManager.default.isReadableFile(atPath: config.path)
            && ((try? config.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    static func downloadModel(_ model: Model, to destination: URL, engineDirectory: URL,
                              status: @escaping @Sendable (String) -> Void) async throws {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if modelIsReady(model, in: destination) { return }
            let files = FileManager.default
            let parent = destination.deletingLastPathComponent()
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".model-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }
            let weights = staging.appendingPathComponent("weights", isDirectory: true)
            let executable = try await runtime(for: model, in: engineDirectory, staging: staging, status: status)
            let script = try modelScript(model)
            status("正在下载「\(model.rawValue)」模型…")
            try await run(executable, ["-E", "-s", "-B", script.path, "--download", weights.path],
                          in: staging, errorTitle: "无法下载「\(model.rawValue)」模型")
            try Task.checkCancellation()
            guard modelIsReady(model, in: weights) else { throw AppFailure(message: "下载的模型文件不完整。") }
            if modelIsReady(model, in: destination) { return }
            do {
                if files.fileExists(atPath: destination.path) {
                    _ = try files.replaceItemAt(destination, withItemAt: weights)
                } else {
                    try files.moveItem(at: weights, to: destination)
                }
            } catch {
                guard modelIsReady(model, in: destination) else { throw error }
            }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func extract(source: URL, destination: URL, engineDirectory: URL, model: Model, weights: URL,
                        progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in },
                        status: @escaping @Sendable (String) -> Void) async throws {
        let work = Task.detached(priority: .utility) {
            guard model.isSupported else {
                throw AppFailure(message: "此模型需要搭载 Apple 芯片的 Mac。")
            }
            guard modelIsReady(model, in: weights) else {
                throw AppFailure(message: "找不到完整的「\(model.rawValue)」模型，请重新连接模型目录或下载。")
            }
            try StorageLocations.requireDataDirectory(for: destination)
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

            let script = try modelScript(model)
            let output = staging.appendingPathComponent("instrumental.wav")
            let progressFile = staging.appendingPathComponent("progress.json")
            let arguments = ["-E", "-s", "-B", script.path, input.path, output.path, weights.path, progressFile.path]
            let executable = try await runtime(for: model, in: engineDirectory, staging: staging, status: status)
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

    private static func modelScript(_ model: Model) throws -> URL {
        guard let script = Bundle.main.url(forResource: model.scriptSettings.resource, withExtension: "py") else {
            throw AppFailure(message: "应用缺少 \(model.rawValue) 分离组件。")
        }
        return script
    }

    private static func runtime(for model: Model, in directory: URL, staging: URL,
                                status: @Sendable (String) -> Void) async throws -> URL {
        let files = FileManager.default
        if Bundle.main.object(forInfoDictionaryKey: "KTakeBundledSeparation") as? Bool == true,
           let resources = Bundle.main.resourceURL {
            let executable = resources.appendingPathComponent("SeparationRuntime/bin/python3.12")
            guard files.isExecutableFile(atPath: executable.path) else {
                throw AppFailure(message: "安装包内的分离引擎不完整，请重新安装 KTake。")
            }
            return executable
        }
        let runtime = directory.appendingPathComponent(model.runtimeName, isDirectory: true)
        let executable = runtime.appendingPathComponent("bin/python")
        let marker = runtime.appendingPathComponent(model.scriptSettings.readyMarker)
        if files.isExecutableFile(atPath: executable.path), files.fileExists(atPath: marker.path) { return executable }
        status("首次使用，正在安装本地分离引擎…")
        guard let uv = findUV() else {
            throw AppFailure(message: "此模型的首次提取需要 uv。请先安装 uv（brew install uv），再重试。")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try await run(uv, ["venv", "--allow-existing", "--python", "3.12", runtime.path],
                      in: staging, errorTitle: "无法准备本地 Python")
        try await run(uv, ["pip", "install", "--python", executable.path,
                           "--index-url", "https://pypi.org/simple"] + model.packages,
                      in: staging, errorTitle: "无法安装本地分离引擎")
        try Data().write(to: marker, options: .atomic)
        return executable
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
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
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
