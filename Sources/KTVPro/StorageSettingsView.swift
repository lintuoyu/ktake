import AppKit
import SwiftUI

struct StorageSettingsView: View {
    @ObservedObject var model: SessionModel
    @State private var migration = StorageLocations.pendingDataMigration
    @State private var modelDirectory = StorageLocations.modelRoot
    @State private var savingDownloadDirectory = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("KTake 数据") {
                location(StorageLocations.dataRoot.path)
                Text("存放曲库、伴奏、歌词和录音。换目录时，下次启动会复制现有数据。")
                    .foregroundStyle(.secondary)
                if let migration {
                    Text("下次启动将迁移到 \(migration.destination.path)")
                    Button("取消迁移") {
                        StorageLocations.cancelDataMigration()
                        self.migration = nil
                    }
                }
                Button("选择文件夹…") {
                    chooseDirectory(title: "选择用于存放 KTake 数据的文件夹", initial: StorageLocations.dataRoot) { folder in
                        try StorageLocations.scheduleDataMigration(to: folder)
                        migration = StorageLocations.pendingDataMigration
                    }
                }
            }

            if let importer = model.musicDLImporter {
                Section("music-dl 下载") {
                    let current = model.musicDLDownloadDirectory ?? importer.downloadLocation.defaultDirectory
                    location(current.path)
                    Text("此设置用于 music-dl 的主动下载。已下载的文件保留在原位置。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("选择文件夹…") {
                            chooseDirectory(title: "选择 music-dl 下载文件夹", initial: current) { saveDownloadDirectory($0) }
                        }
                        Button("恢复默认") { saveDownloadDirectory(nil) }
                            .disabled(model.musicDLDownloadDirectory == nil)
                    }
                    .disabled(savingDownloadDirectory)
                }
            }

            Section("伴奏分离模型") {
                location((modelDirectory ?? StorageLocations.dataRoot.appendingPathComponent("Separation")).path)
                Text("提取伴奏前会检查模型。确认下载后，模型保存在此目录。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("选择文件夹…") {
                        chooseDirectory(title: "选择伴奏分离模型存放文件夹", initial: modelDirectory) { folder in
                            try StorageLocations.setModelRoot(folder)
                            modelDirectory = StorageLocations.modelRoot
                        }
                    }
                    Button("恢复默认") {
                        try? StorageLocations.setModelRoot(nil)
                        modelDirectory = nil
                    }
                    .disabled(modelDirectory == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .padding(.vertical, 8)
        .alert("无法更改存放位置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func location(_ path: String) -> some View {
        Text(path)
            .textSelection(.enabled)
            .lineLimit(2)
            .help(path)
    }

    private func chooseDirectory(title: String, initial: URL?, use: (URL) throws -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initial
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try use(folder) }
        catch { self.error = error.localizedDescription }
    }

    private func saveDownloadDirectory(_ folder: URL?) {
        savingDownloadDirectory = true
        Task {
            defer { savingDownloadDirectory = false }
            do { try await model.setMusicDLDownloadDirectory(folder) }
            catch { self.error = error.localizedDescription }
        }
    }
}
