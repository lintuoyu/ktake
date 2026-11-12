import Foundation

enum StorageLocations {
    struct DataMigration: Codable {
        let id: UUID
        let destination: URL
    }

    private static let dataKey = "storage.dataDirectory"
    private static let modelKey = "storage.modelDirectory"
    private static let previousKey = "storage.previousDataDirectories"
    private static let migrationKey = "storage.pendingDataMigration"

    static var defaultDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KTV Pro", isDirectory: true)
    }

    static var dataRoot: URL { storedDirectory(dataKey) ?? defaultDataRoot }
    static var modelRoot: URL? { storedDirectory(modelKey) }
    static var musicDLRoot: URL { defaultDataRoot.appendingPathComponent("MusicDL", isDirectory: true) }

    static var pendingDataMigration: DataMigration? {
        guard let data = UserDefaults.standard.data(forKey: migrationKey) else { return nil }
        return try? JSONDecoder().decode(DataMigration.self, from: data)
    }

    static func scheduleDataMigration(to parent: URL) throws {
        let parent = try writableDirectory(parent)
        let destination = parent.appendingPathComponent("KTake Data", isDirectory: true)
        let source = dataRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !contains(parent, in: source), !contains(source, in: destination) else {
            throw AppFailure(message: "请选择当前 KTake 数据目录以外的文件夹。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AppFailure(message: "所选文件夹已有「KTake Data」。请选择其他文件夹，以免覆盖已有数据。")
        }
        let migration = DataMigration(id: UUID(), destination: destination)
        UserDefaults.standard.set(try JSONEncoder().encode(migration), forKey: migrationKey)
    }

    static func cancelDataMigration() { UserDefaults.standard.removeObject(forKey: migrationKey) }

    static func applyDataMigration(_ migration: DataMigration) throws {
        let files = FileManager.default
        let source = dataRoot
        let destination = migration.destination
        if source == destination {
            cancelDataMigration()
            return
        }
        let parent = try writableDirectory(destination.deletingLastPathComponent())
        let staging = parent.appendingPathComponent(".ktake-data-\(migration.id.uuidString)", isDirectory: true)
        let marker = ".ktake-data-origin"
        if files.fileExists(atPath: destination.path) {
            let copiedID = try? String(contentsOf: destination.appendingPathComponent(marker), encoding: .utf8)
            guard copiedID == migration.id.uuidString else {
                throw AppFailure(message: "目标数据目录已存在，迁移已停止。")
            }
        } else {
            if source.path != defaultDataRoot.path { _ = try existingDirectory(source) }
            if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }
            for name in ["SongLibrary", "Takes"] {
                let original = source.appendingPathComponent(name, isDirectory: true)
                if files.fileExists(atPath: original.path) {
                    try files.copyItem(at: original, to: staging.appendingPathComponent(name, isDirectory: true))
                }
            }
            try migration.id.uuidString.write(to: staging.appendingPathComponent(marker), atomically: true, encoding: .utf8)
            try files.moveItem(at: staging, to: destination)
        }
        let defaults = UserDefaults.standard
        var previous = defaults.stringArray(forKey: previousKey) ?? []
        for path in [source.path, source.resolvingSymlinksInPath().path] where !previous.contains(path) {
            previous.append(path)
        }
        defaults.set(previous, forKey: previousKey)
        defaults.set(destination.path, forKey: dataKey)
        cancelDataMigration()
    }

    static func relocatedMedia(_ original: URL) -> URL? {
        let previous = UserDefaults.standard.stringArray(forKey: previousKey) ?? []
        let path = original.standardizedFileURL.path
        for old in previous where path.hasPrefix(old + "/SongLibrary/") {
            let relative = String(path.dropFirst(old.count + 1))
            let relocated = dataRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: relocated.path) { return relocated }
        }
        return nil
    }

    static func setModelRoot(_ parent: URL?) throws {
        let directory = try parent.map { try writableDirectory($0) }
        UserDefaults.standard.set(directory?.path, forKey: modelKey)
    }

    static func requireDataDirectory(for destination: URL) throws {
        let active = dataRoot
        if active != defaultDataRoot && contains(destination.standardizedFileURL, in: active) {
            _ = try existingDirectory(active)
        }
    }

    static func existingDirectory(_ url: URL) throws -> URL {
        let directory = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppFailure(message: "无法访问文件夹「\(url.lastPathComponent)」。如果它在外置硬盘上，请先连接硬盘。")
        }
        return directory
    }

    static func writableDirectory(_ url: URL) throws -> URL {
        let directory = try existingDirectory(url)
        let probe = directory.appendingPathComponent(".ktake-write-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch {
            throw AppFailure(message: "无法写入文件夹「\(url.lastPathComponent)」，请选择可写的文件夹。")
        }
        return directory
    }

    private static func storedDirectory(_ key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }
}
