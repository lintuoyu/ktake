import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: SessionModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        DispatchQueue.main.async {
            model.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
struct KTakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: SessionModel?
    @State private var storageError: String?

    var body: some Scene {
        Window("KTake", id: "studio") {
            Group {
                if let model {
                    ContentView(model: model)
                } else if let storageError {
                    ContentUnavailableView {
                        Label("数据目录暂不可用", systemImage: "externaldrive")
                    } description: {
                        Text(storageError)
                    } actions: {
                        Button("重新检查") { Task { await loadSession() } }
                    }
                } else {
                    ProgressView(StorageLocations.pendingDataMigration == nil ? "正在打开 KTake…" : "正在复制曲库和录音…")
                }
            }
            .task { await loadSession() }
        }
        .defaultSize(width: 1240, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .saveItem) {
                Button("打开录音文件夹") { model?.revealTakes() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model == nil)
            }
        }
        Settings {
            if let model { StorageSettingsView(model: model) }
        }
    }

    @MainActor private func loadSession() async {
        guard model == nil else { return }
        storageError = nil
        var migrationError: String?
        if let migration = StorageLocations.pendingDataMigration {
            do { try await Task.detached(priority: .userInitiated) { try StorageLocations.applyDataMigration(migration) }.value }
            catch { migrationError = "未能迁移 KTake 数据：\(error.localizedDescription)" }
        }
        if StorageLocations.dataRoot != StorageLocations.defaultDataRoot {
            do { _ = try StorageLocations.existingDirectory(StorageLocations.dataRoot) }
            catch {
                storageError = error.localizedDescription
                return
            }
        }
        let importer = MusicDLImporter(libraryRoot: SongLibrary.userRoot, serviceDirectory: StorageLocations.musicDLRoot)
        let session = SessionModel(musicDLImporter: importer)
        session.errorMessage = migrationError
        delegate.model = session
        model = session
    }
}
