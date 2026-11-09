import SwiftUI

struct LyricSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: LyricSearchContext
    let onImport: (LyricRecord) throws -> Void
    @State private var title: String
    @State private var artist: String
    @State private var state = SearchState.idle
    @State private var searchTask: Task<Void, Never>?
    @State private var importError: String?

    private enum SearchState {
        case idle, loading, results([LyricRecord]), failed(String)
    }

    init(context: LyricSearchContext, onImport: @escaping (LyricRecord) throws -> Void) {
        self.context = context
        self.onImport = onImport
        _title = State(initialValue: context.title)
        _artist = State(initialValue: context.artist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("从 LRCLIB 搜索歌词").font(.title2.bold())
                Text(targetDescription).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                TextField("歌名", text: $title).accessibilityLabel("歌名")
                TextField("歌手（选填）", text: $artist).accessibilityLabel("歌手（选填）")
                    .frame(width: 160)
                Button("搜索", action: search)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder)

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(importError ?? "仅显示带时间轴的结果。导入后可在播放画面调节「歌词延后」。")
                    .font(.caption).foregroundStyle(importError == nil ? Color.secondary : StudioTheme.amber)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 435)
        .studioSheet()
        .onAppear { search() }
        .onChange(of: title) { resetSearch() }
        .onChange(of: artist) { resetSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    private var targetDescription: String {
        let song = [context.artist, context.title].filter { !$0.isEmpty }.joined(separator: " — ")
        return context.duration > 0 ? "当前曲目：\(song) · \(timeLabel(context.duration.rounded()))" : "当前曲目：\(song)"
    }

    @ViewBuilder private var results: some View {
        switch state {
        case .idle:
            ContentUnavailableView("搜索同步歌词", systemImage: "magnifyingglass", description: Text("输入歌名后按回车搜索。歌手可以留空。"))
        case .loading:
            ProgressView("正在搜索 LRCLIB…")
        case .results(let records) where !records.isEmpty:
            List(records) { record in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.trackName).fontWeight(.medium).lineLimit(1)
                        Text([record.artistName, record.albumName ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if record.duration.isFinite, record.duration > 0, record.duration < 86_400 {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(timeLabel(record.duration.rounded())).monospacedDigit()
                            let difference = record.duration - context.duration
                            if context.duration > 0, abs(difference) > 3 {
                                Text(String(format: "与当前曲目差 %+.0f 秒", difference))
                                    .font(.caption2).foregroundStyle(StudioTheme.amber)
                            }
                        }
                    }
                    Button("导入") {
                        do {
                            try onImport(record)
                            dismiss()
                        } catch { importError = error.localizedDescription }
                    }.buttonStyle(.borderless)
                        .accessibilityLabel("导入 \(record.trackName)，\(record.artistName)")
                }.padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            .background(StudioTheme.library, in: RoundedRectangle(cornerRadius: 8))
        case .results:
            ContentUnavailableView("没有找到同步歌词", systemImage: "text.magnifyingglass", description: Text("试试删掉歌手、缩短歌名，或换一个写法。"))
        case .failed(let message):
            ContentUnavailableView("搜索失败", systemImage: "exclamationmark.circle", description: Text(message))
        }
    }

    private func resetSearch() {
        searchTask?.cancel()
        state = .idle
        importError = nil
    }

    private func search() {
        resetSearch()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist
        guard !title.isEmpty else { return }
        state = .loading
        searchTask = Task {
            do {
                let records = try await LyricSearchClient.shared.search(title: title, artist: artist)
                try Task.checkCancellation()
                var seen: Set<Int> = []
                state = .results(records.filter { $0.timedLRC != nil && seen.insert($0.id).inserted })
            } catch {
                if !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
        }
    }
}
