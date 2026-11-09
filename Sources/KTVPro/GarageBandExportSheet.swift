import AppKit
import SwiftUI

struct GarageBandExportSheet: View {
    private enum ExportFormat: Hashable {
        case project
        case stems
    }

    let request: GarageBandExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .project
    @State private var selected: Set<UUID>
    @State private var task: Task<Void, Never>?
    @State private var resultURL: URL?
    @State private var stemFiles: [URL] = []
    @State private var message: String?

    init(request: GarageBandExportRequest) {
        self.request = request
        _selected = State(initialValue: [request.anchor.id])
    }

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.garageband10")
    }
    private var takes: [Take] { request.compatibleTakes }
    private var hasBacking: Bool {
        request.backingURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    private var pitchLabel: String {
        request.pitch == 0 ? "原调" : String(format: "%+d 半音", request.pitch)
    }
    private var canExport: Bool {
        hasBacking && !selected.isDisjoint(with: takes.map(\.id)) &&
            (format == .stems || selected.count == 1)
    }
    private var exportButtonTitle: String {
        if format == .project {
            return appURL == nil ? "导出 .band 工程…" : "导出工程并打开 GarageBand…"
        }
        return appURL == nil ? "导出分轨 WAV…" : "导出分轨并打开 GarageBand…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出到 GarageBand").font(.title2.weight(.semibold))
            Text(request.anchor.songName).font(.headline)
            if let resultURL {
                Text(format == .project ? "已导出GarageBand工程" : "已导出 \(stemFiles.count) 轨 WAV")
                    .font(.headline)
                Text(resultURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if format == .project {
                    Text(".band 工程已保存，包含伴奏、1 条人声及模板保留的空轨，可直接用 GarageBand 打开。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("在 GarageBand 新建空白项目，把 WAV 拖到轨道区最左侧的同一位置，每个文件各占一轨，然后按 ⌘S 保存 .band。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting(format == .project ? [resultURL] : stemFiles)
                    }
                    Button(format == .project ? "打开 GarageBand 工程" : "打开 GarageBand") {
                        openGarageBand()
                    }.disabled(appURL == nil)
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Picker("导出格式", selection: $format) {
                    Text("GarageBand工程（伴奏+1条人声）").tag(ExportFormat.project)
                    Text("分轨WAV（多条人声）").tag(ExportFormat.stems)
                }
                .disabled(task != nil)
                .onChange(of: format) { _, newFormat in
                    guard newFormat == .project else { return }
                    let retained = takes.first { $0.id == request.anchor.id && selected.contains($0.id) }
                        ?? takes.first { selected.contains($0.id) }
                    selected = retained.map { Set([$0.id]) } ?? []
                }
                if hasBacking {
                    Text("\(request.anchor.accompanimentPath == nil ? "MV 音轨" : "录唱伴奏") · \(pitchLabel) · 选择要导出的人声")
                        .foregroundStyle(.secondary)
                    List(takes) { take in
                        Toggle(isOn: selection(for: take.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(take.createdAt.formatted(.dateTime.month().day().hour().minute().second()) +
                                     (take.parentTakeID == nil ? " · 人声" : " · 补录") +
                                     (take.preferred == true ? " · 首选" : ""))
                                Text(detail(for: take)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    .scrollContentBackground(.hidden)
                    .background(StudioTheme.library, in: RoundedRectangle(cornerRadius: 8))
                    .frame(height: 190).disabled(task != nil)
                    if takes.count < request.takes.count {
                        Text("只显示使用同一伴奏和调性的录音。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(format == .project
                         ? "工程格式目前仅支持单条人声；需要选择多条人声，请切换为分轨 WAV。"
                         : "导出后，在 GarageBand 导入这些已对齐的 WAV，再保存为 .band。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("找不到这条录音当时使用的伴奏。").foregroundStyle(.secondary)
                }
                HStack {
                    Button(task == nil ? "取消" : "取消导出") {
                        if let task { task.cancel() } else { dismiss() }
                    }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if task != nil { ProgressView().controlSize(.small) }
                    Button(exportButtonTitle, action: chooseFolder)
                        .disabled(!canExport || task != nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(StudioTheme.amber) }
        }
        .padding(22).frame(width: 510)
        .studioSheet()
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
    }

    private func selection(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { checked in
            guard task == nil else { return }
            if checked {
                if format == .project { selected = [id] }
                else { selected.insert(id) }
            } else {
                selected.remove(id)
            }
        })
    }

    private func detail(for take: Take) -> String {
        let start = GarageBandExportRequest.start(of: take)
        var details = [timeLabel(take.duration), "起点 " + preciseTimeLabel(max(0, start))]
        if !GarageBandExportRequest.hasCaptureTime(take) { details.append("按旧录音记录估算") }
        if let note = take.note { details.append(note) }
        return details.joined(separator: " · ")
    }

    private func chooseFolder() {
        guard canExport, task == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        panel.message = format == .project ? "选择保存 GarageBand .band 工程的位置" : "选择保存 GarageBand 分轨 WAV 的位置"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        message = nil
        let chosen = selected
        let chosenFormat = format
        task = Task { @MainActor in
            defer { task = nil }
            do {
                switch chosenFormat {
                case .project:
                    let exported = try await GarageBandProject.export(request, selected: chosen, to: folder)
                    resultURL = exported
                    stemFiles = []
                    NSWorkspace.shared.activateFileViewerSelecting([exported])
                case .stems:
                    let exported = try await GarageBandStems.export(request, selected: chosen, to: folder)
                    resultURL = exported.folder
                    stemFiles = exported.files
                    NSWorkspace.shared.activateFileViewerSelecting(exported.files)
                }
                openGarageBand()
            } catch is CancellationError {
                message = "已取消导出。"
            } catch {
                message = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func openGarageBand() {
        let savedMessage = format == .project ? "GarageBand 工程已保存。" : "分轨文件已保存。"
        guard let appURL else {
            message = "当前 Mac 未找到 GarageBand。\(savedMessage)"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let completionHandler: (NSRunningApplication?, Error?) -> Void = { _, error in
            guard let error else { return }
            Task { @MainActor in
                message = "\(savedMessage)无法打开 GarageBand：\(error.localizedDescription)"
            }
        }
        if format == .project {
            guard let resultURL else { return }
            NSWorkspace.shared.open([resultURL], withApplicationAt: appURL,
                                    configuration: configuration, completionHandler: completionHandler)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration,
                                               completionHandler: completionHandler)
        }
    }
}
