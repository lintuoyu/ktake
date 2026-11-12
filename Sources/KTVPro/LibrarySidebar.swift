import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    let reviewTake: (Take) -> Void
    let openFiveSing: () -> Void
    let openMusicDL: () -> Void
    @State private var section: Section = .songs
    @State private var songQuery = ""
    @State private var takeQuery = ""
    @State private var songOrder: SongOrder = .recent
    @State private var visibleSongs: [LibrarySong] = []
    @State private var visibleTakes: [Take] = []
    @State private var pendingRemoval: Removal?
    @State private var editingNote: Take?
    @State private var garageBandExport: GarageBandExportRequest?

    private enum Section: Hashable { case songs, takes }
    private enum SongOrder: String, CaseIterable { case recent = "最近加入", title = "歌名", artist = "歌手" }
    private enum Removal: Identifiable {
        case song(LibrarySong, moveFiles: Bool)
        case take(Take)
        var id: String {
            switch self {
            case .song(let song, _): return song.id
            case .take(let take): return take.id.uuidString
            }
        }
    }

    private var libraryLocked: Bool { model.busy || model.loadingMedia }
    private var query: Binding<String> { section == .songs ? $songQuery : $takeQuery }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if section == .songs { songList } else { takeList }
            Divider()
            tools
        }
        .background(StudioTheme.library)
        .onReceive(model.$songs) { updateSongs($0) }
        .onReceive(model.$takes) { updateTakes($0) }
        .onChange(of: songQuery) { _, _ in updateSongs(model.songs) }
        .onChange(of: songOrder) { _, _ in updateSongs(model.songs) }
        .onChange(of: takeQuery) { _, _ in updateTakes(model.takes) }
        .alert(item: $pendingRemoval, content: removalAlert)
        .sheet(item: $editingNote) { take in
            TakeNoteSheet(take: take) { model.saveTakeNote(take.id, $0) }
        }
        .sheet(item: $garageBandExport) { request in
            GarageBandExportSheet(request: request)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("资料库", selection: $section) {
                Text("曲库").tag(Section.songs)
                Text("我的录音").tag(Section.takes)
            }.pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(section == .songs ? "搜索歌名或歌手" : "搜索录音", text: query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(section == .songs ? "搜索歌名或歌手" : "搜索录音")
                if !query.wrappedValue.isEmpty {
                    Button { query.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9).frame(height: 32)
            .background(StudioTheme.inset, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).strokeBorder(StudioTheme.separator).allowsHitTesting(false)
            }

            HStack {
                let count = section == .songs ? visibleSongs.count : visibleTakes.count
                let total = section == .songs ? model.songs.count : model.takes.count
                Text("\(count == total ? "\(total)" : "\(count) / \(total)") \(section == .songs ? "首" : "条录音")")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if section == .songs {
                    Menu {
                        Picker("排序", selection: $songOrder) {
                            ForEach(SongOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(songOrder.rawValue, systemImage: "arrow.up.arrow.down")
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .fixedSize().help("曲库排序")
                } else {
                    Text("按曲目分组").foregroundStyle(.secondary)
                }
            }.font(.system(size: 11))
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var songList: some View {
        Group {
            if visibleSongs.isEmpty {
                emptyList(songQuery.isEmpty ? "曲库暂无歌曲" : "没有找到曲目",
                          detail: songQuery.isEmpty ? "可以从 5sing 找伴奏。" : "试试歌名或歌手的部分文字。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleSongs) { song in songRow(song) }
                    }.padding(.horizontal, 7).padding(.vertical, 7)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var takeList: some View {
        Group {
            if visibleTakes.isEmpty {
                emptyList(takeQuery.isEmpty ? "还没有录音" : "没有找到录音",
                          detail: takeQuery.isEmpty ? "完成录制后会显示在这里。" : "试试录音所用的歌名。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(takeGroups, id: \.key) { group in
                            HStack(spacing: 6) {
                                Text(group.takes[0].songName).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(group.takes.count) 版").monospacedDigit()
                            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 9).padding(.bottom, 3)
                            ForEach(group.takes) { take in takeRow(take) }
                        }
                    }.padding(.horizontal, 7).padding(.vertical, 7)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var takeGroups: [(key: String, takes: [Take])] {
        var seen = Set<String>()
        let groups = Dictionary(grouping: visibleTakes, by: \.songGroupKey)
        return visibleTakes.compactMap { take in
            guard seen.insert(take.songGroupKey).inserted, let group = groups[take.songGroupKey] else { return nil }
            return (take.songGroupKey, group.filter { $0.preferred == true } + group.filter { $0.preferred != true })
        }
    }

    private func songRow(_ song: LibrarySong) -> some View {
        let selected = model.selectedSongID == song.id
        let version = model.libraryAudioVersion(for: song.id)
        return HStack(spacing: 2) {
            Button {
                if !selected { model.selectSong(song.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "waveform" : song.musicDL != nil ? "music.note.list" : "music.note")
                        .font(.system(size: 12)).foregroundStyle(selected ? accent : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                        Text(song.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if model.separatingSongID == song.id {
                        ProgressView().controlSize(.small).accessibilityLabel("正在提取伴奏")
                    } else if version != .original {
                        Image(systemName: "waveform.badge.minus")
                            .font(.system(size: 11)).foregroundStyle(accent)
                            .accessibilityLabel(version.label).help("正在使用\(version.label)")
                    } else if let seconds = song.duration { durationLabel(seconds) }
                }
                .padding(.leading, 9).frame(height: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(libraryLocked)
                .accessibilityLabel(song.displayName)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(song.displayName)
            Menu {
                if model.separatingSongID == song.id {
                    Button("取消提取伴奏", systemImage: "xmark.circle") { model.cancelAccompanimentExtraction() }
                } else {
                    let versions = model.extractedAccompaniments[song.id] ?? [:]
                    if !versions.isEmpty {
                        ForEach(model.availableAudioVersions(for: song.id), id: \.self) { option in
                            Button("使用 \(option.label)", systemImage: version == option ? "checkmark" : "waveform") {
                                model.setLibraryAudioVersion(for: song, version: option)
                            }.disabled(libraryLocked)
                        }
                    }
                    ForEach(LibraryAudioVersion.extracted.filter {
                        versions[$0] == nil && $0.extractionModel?.isSupported == true
                    }, id: \.self) { option in
                        Button("提取 \(option.label)", systemImage: "waveform.badge.minus") {
                            model.extractAccompaniment(for: song, version: option)
                        }.disabled(libraryLocked || model.separatingSongID != nil)
                    }
                }
                Divider()
                Button("在 Finder 中显示", systemImage: "folder") { model.revealLibrarySong(song) }
                Divider()
                Button("移出曲库…", systemImage: "trash", role: .destructive) {
                    pendingRemoval = .song(song, moveFiles: model.canTrashLibrarySong(song))
                }.disabled(libraryLocked || model.separatingSongID == song.id)
            } label: { rowMenuIcon }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("曲目操作：\(song.title)").help("曲目操作")
        }
        .background(selected ? accent.opacity(0.105) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Capsule().fill(StudioTheme.action).frame(width: 3, height: 22)
                .opacity(selected ? 1 : 0).allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : StudioTheme.quick, value: selected)
    }

    private func takeRow(_ take: Take) -> some View {
        let playing = model.playingTakeID == take.id
        let effects = take.quickPlaybackEffects(fallback: model.vocalSettings)
        let playHelp: String
        if take.recordedEffects != nil {
            playHelp = effects.enabled ? "按录制时的人声效果回听" : "回听干声"
        } else if let reverb = take.recordedReverb {
            playHelp = reverb > 0 ? "按录制时的混响回听（\(Int(effects.reverb.rounded()))%）" : "回听干声"
        } else {
            playHelp = "旧录音未保存混响，使用当前设置（\(Int(effects.reverb.rounded()))%）"
        }
        return HStack(spacing: 8) {
            Button { model.toggleTake(take) } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26)
                    .background(StudioTheme.inset, in: Circle())
                    .foregroundStyle(playing ? accent : .primary)
            }.buttonStyle(.plain).disabled(model.busy || take.duration <= 0)
                .accessibilityLabel(playing ? "停止回听" : "回听 \(take.songName)")
                .help(playing ? "停止回听" : playHelp)
            Button { reviewTake(take) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if take.preferred == true { Image(systemName: "star.fill").foregroundStyle(accent).accessibilityLabel("首选") }
                        Text(take.createdAt, format: .dateTime.month().day().hour().minute())
                        if take.parentTakeID != nil { Text("补录").foregroundStyle(accent) }
                    }.font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(take.pitchSemitones.map { $0 == 0 ? "原调" : String(format: "%+d 半音", $0) } ?? "调性未记录")
                        if take.interrupted { Text("提前结束").foregroundStyle(StudioTheme.amber) }
                        if let note = take.note { Text(note).lineLimit(1) }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy || model.loadingMedia || take.duration <= 0)
                .accessibilityLabel("\(take.songName) · \(take.createdAt.formatted(.dateTime.month().day().hour().minute()))\(take.parentTakeID != nil ? " · 补录" : "")\(take.preferred == true ? " · 首选" : "")")
                .help("打开回听与混音")
            Spacer(minLength: 2)
            durationLabel(take.duration)
            Menu {
                Button("回听与混音…", systemImage: "slider.horizontal.3") { reviewTake(take) }
                    .disabled(model.busy || model.loadingMedia || take.duration <= 0)
                Button("导出原始 WAV…", systemImage: "square.and.arrow.up") { model.exportTake(take) }
                    .disabled(model.busy)
                Button("导出到 GarageBand…", systemImage: "music.note.list") {
                    garageBandExport = model.garageBandExportRequest(for: take)
                }.disabled(libraryLocked || take.duration <= 0)
                Button(take.preferred == true ? "取消首选" : "标为首选", systemImage: "star") { model.togglePreferredTake(take.id) }
                    .disabled(model.busy)
                Button("编辑备注…", systemImage: "square.and.pencil") { editingNote = take }
                    .disabled(model.busy)
                Divider()
                Button("删除录音…", systemImage: "trash", role: .destructive) { pendingRemoval = .take(take) }
                    .disabled(model.busy)
            } label: { rowMenuIcon }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("录音操作：\(take.songName)").help("录音操作")
        }.padding(.leading, 8).frame(height: 52)
            .background(playing ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .animation(reduceMotion ? nil : StudioTheme.quick, value: playing)
    }

    private var rowMenuIcon: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: 24, height: 26)
    }

    private func durationLabel(_ seconds: Double) -> some View {
        Text(timeLabel(seconds.rounded())).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
    }

    private func emptyList(_ title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(16)
    }

    private var tools: some View {
        HStack(spacing: 7) {
            if section == .songs {
                Button(action: openFiveSing) { Label("5sing 找伴奏", systemImage: "magnifyingglass") }
                    .fixedSize().disabled(libraryLocked)
                Button("music-dl 聚合搜索", action: openMusicDL)
                    .fixedSize().disabled(libraryLocked)
                Spacer(minLength: 0)
                if !model.hiddenSongIDs.isEmpty {
                    Menu {
                        Button("恢复隐藏曲目（\(model.hiddenSongIDs.count)）") { model.restoreHiddenSongs() }
                    } label: { rowMenuIcon }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(libraryLocked).accessibilityLabel("管理隐藏曲目")
                }
                refresh("刷新曲库", disabled: libraryLocked) { model.refreshLibrary() }
            } else {
                Button { model.revealTakes() } label: { Label("打开录音文件夹", systemImage: "folder") }
                Spacer()
                refresh("刷新录音", disabled: model.busy) { model.refreshTakes() }
            }
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 15).frame(height: 43)
    }

    private func refresh(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "arrow.clockwise").frame(width: 24, height: 26) }
            .disabled(disabled).accessibilityLabel(title).help(title)
    }

    private func removalAlert(_ removal: Removal) -> Alert {
        switch removal {
        case .song(let song, let moveFiles):
            return Alert(title: Text("移出曲库？"),
                         message: Text(moveFiles ? "「\(song.displayName)」的曲库副本将移到废纸篓。" :
                                        "「\(song.displayName)」将从曲库中隐藏。你可以稍后恢复。"),
                         primaryButton: .destructive(Text(moveFiles ? "移到废纸篓" : "隐藏曲目")) {
                             model.removeLibrarySong(song.id, moveFiles: moveFiles)
                         }, secondaryButton: .cancel(Text("取消")))
        case .take(let take):
            let date = take.createdAt.formatted(.dateTime.month().day().hour().minute())
            return Alert(title: Text("删除录音？"),
                         message: Text("「\(take.songName)」 · \(date) · \(timeLabel(take.duration))\n这条录音将移到废纸篓。"),
                         primaryButton: .destructive(Text("移到废纸篓")) { model.removeTake(take.id) },
                         secondaryButton: .cancel(Text("取消")))
        }
    }

    private func updateSongs(_ songs: [LibrarySong]) {
        let tokens = searchTokens(songQuery)
        let filtered = tokens.isEmpty ? songs : songs.filter { matches([$0.title, $0.artist], tokens: tokens) }
        switch songOrder {
        case .recent: visibleSongs = Array(filtered.reversed())
        case .title: visibleSongs = filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: visibleSongs = filtered.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        }
    }

    private func updateTakes(_ takes: [Take]) {
        let tokens = searchTokens(takeQuery)
        visibleTakes = tokens.isEmpty ? takes : takes.filter { matches([$0.songName, $0.note ?? ""], tokens: tokens) }
    }

    private func searchTokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { searchKey(String($0)) }.filter { !$0.isEmpty }
    }

    private func matches(_ fields: [String], tokens: [String]) -> Bool {
        let keys = fields.map(searchKey)
        return tokens.allSatisfy { token in keys.contains(where: { $0.contains(token) }) }
    }

    private func searchKey(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

private struct TakeNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    let take: Take
    let save: (String) -> Void

    init(take: Take, save: @escaping (String) -> Void) {
        self.take = take
        self.save = save
        _note = State(initialValue: take.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("录音备注").font(.title2.bold())
            Text(take.songName).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $note).frame(height: 110).accessibilityLabel("录音备注")
                .scrollContentBackground(.hidden)
                .padding(4).background(StudioTheme.inset, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(note); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 400).studioSheet()
    }
}
