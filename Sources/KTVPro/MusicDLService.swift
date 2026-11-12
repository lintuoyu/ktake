import Foundation

struct MusicDLDownloadLocation: Sendable {
    let serviceDirectory: URL
    var defaultDirectory: URL { serviceDirectory.appendingPathComponent("data/downloads", isDirectory: true) }
    var settingsFile: URL { serviceDirectory.appendingPathComponent("ktake-download-directory.json") }

    var customDirectory: URL? {
        guard let data = try? Data(contentsOf: settingsFile),
              let path = try? JSONDecoder().decode(String.self, from: data), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func setCustomDirectory(_ url: URL?) throws -> URL? {
        let folder = try url.map { try StorageLocations.writableDirectory($0) }
        if let folder, folder.path.last?.isWhitespace == true {
            throw AppFailure(message: "请选择路径末尾没有空格的文件夹。")
        }
        try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(folder?.path).write(to: settingsFile, options: .atomic)
        return folder
    }
}

actor MusicDLService {
    private let directory: URL
    private let executable: URL?
    private var process: Process?
    private var input: FileHandle?
    private var startup: Task<URL, Error>?

    init(directory: URL, executable: URL? = Bundle.main.url(forAuxiliaryExecutable: "KTakeMusicDL")) {
        self.directory = directory
        self.executable = executable
    }

    func baseURL() async throws -> URL {
        if let startup, process?.isRunning == true {
            return try await startup.value
        }
        stop()
        let files = FileManager.default
        guard let executable, files.isExecutableFile(atPath: executable.path) else {
            throw AppFailure(message: "安装包缺少 music-dl 服务，请重新安装 KTake。")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.createDirectory(at: directory.appendingPathComponent("data/downloads", isDirectory: true),
                                  withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let path = "/ktake-\(id)/music"
        let ready = directory.appendingPathComponent(".port-\(id)")
        let child = Process()
        let pipe = Pipe()
        child.executableURL = executable
        child.arguments = [path, ready.path]
        child.currentDirectoryURL = directory
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("MUSIC_DL_") && !$0.key.hasPrefix("DYLD_")
        }
        environment["KTAKE_MUSIC_DL_DIRECTORY_FILE"] = MusicDLDownloadLocation(serviceDirectory: directory).settingsFile.path
        child.environment = environment
        do { try child.run() }
        catch { throw AppFailure(message: "无法启动内置 music-dl：\(error.localizedDescription)") }
        process = child
        input = pipe.fileHandleForWriting

        let task = Task {
            defer { try? files.removeItem(at: ready) }
            do {
                for _ in 0..<150 {
                    guard child.isRunning else { break }
                    if let value = try? String(contentsOf: ready, encoding: .utf8),
                       value.hasSuffix("\n"), let port = Int(value.dropLast()), (1...65535).contains(port) {
                        return URL(string: "http://127.0.0.1:\(port)\(path)")!
                    }
                    try await Task.sleep(for: .milliseconds(80))
                }
                throw AppFailure(message: "内置 music-dl 启动失败，请重试。")
            } catch {
                if self.process === child { self.stop() }
                throw error
            }
        }
        startup = task
        return try await task.value
    }

    func stop() {
        startup?.cancel()
        startup = nil
        try? input?.close()
        input = nil
        process = nil
    }
}
