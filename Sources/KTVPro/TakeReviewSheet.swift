import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
private final class TakeReviewModel: ObservableObject {
    enum Mode: String, CaseIterable { case dry = "只听人声", mix = "带伴奏" }

    let request: TakeReviewRequest
    private let player = AVPlayer()
    @Published private(set) var duration: Double
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isExporting = false
    @Published private(set) var hasMix = false
    @Published private(set) var canAlign = false
    @Published private(set) var notice = ""
    @Published private(set) var exportNotice = ""
    @Published private(set) var isPreparingEffects = false
    @Published private(set) var effectsNotice = ""
    @Published var mode: Mode = .dry { didSet { updateMix() } }
    @Published var vocal: Float = 1 { didSet { updateMix() } }
    @Published var backing: Float { didSet { updateMix() } }
    @Published var effects: VocalSettings {
        didSet {
            updateMix()
            let toneChanged = tone != Tone(oldValue)
            if toneChanged || !effects.enabled { cancelEffectsPreparation() }
            if effects.enabled, toneChanged || !oldValue.enabled {
                effectsNotice = ""
                prepareEffectsIfNeeded(debounce: toneChanged)
            }
        }
    }
    @Published var offsetMS = 0
    @Published var selectedPatchID: UUID? {
        didSet {
            if let patch = selectedPatch {
                markA = patch.range.start
                markB = patch.range.end
            }
        }
    }
    @Published private(set) var adoptedPatchID: UUID?
    @Published private(set) var markA: Double?
    @Published private(set) var markB: Double?
    var selectedPatch: TakePatch? { request.versions.first { $0.id == selectedPatchID } }
    var markedRange: PracticeRange? {
        guard let markA, let markB else { return nil }
        let range = PracticeRange(start: markA, end: markB)
        return range.isValid ? range : nil
    }
    private var auditionRange: PracticeRange?
    private var mix: TakeMix?
    private var effectsPreview: TakeEffectsPreview?
    private var renderedTone: Tone?
    private var effectsTask: Task<Void, Never>?
    private var effectsGeneration = UUID()
    private struct Tone: Equatable {
        let brightness: Float
        let compression: Float
        init(_ settings: VocalSettings) { brightness = settings.brightness; compression = settings.compression }
    }
    private var tone: Tone { Tone(effects) }
    private var preparedBackingURL: URL?
    private var timeObserver: Any?
    private var finishObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var exportTask: Task<Void, Never>?
    private var initialized = false

    init(request: TakeReviewRequest) {
        self.request = request
        duration = request.take.duration
        let adopted = request.versions.first { $0.id == request.take.adoptedPunchID }
        adoptedPatchID = adopted?.id
        selectedPatchID = adopted?.id
        markA = adopted?.range.start
        markB = adopted?.range.end
        let volume = request.take.backingVolume ?? 0.65
        backing = volume.isFinite ? min(1, max(0, volume)) : 0.65
        effects = request.reviewEffects.bounded
        player.audioOutputDeviceUniqueID = request.outputUID
    }

    func prepare() async {
        let initial = !initialized
        if initial {
            initialized = true
            installDry(at: 0)
            observePlayer()
        }
        let dryPosition = max(0, position - (mix?.vocalStart ?? 0))
        let wasPlaying = isPlaying
        pause()
        guard let source = request.backingURL else {
            notice = "这条录音没有伴奏。"
            prepareEffectsIfNeeded()
            return
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            notice = "找不到这次录音使用的伴奏。"
            prepareEffectsIfNeeded()
            return
        }
        cancelEffectsPreparation()
        isPreparing = true
        defer {
            if !Task.isCancelled {
                isPreparing = false
                prepareEffectsIfNeeded()
            }
        }
        do {
            let backingURL: URL
            if let preparedBackingURL { backingURL = preparedBackingURL }
            else if request.take.accompanimentPath != nil, let semitones = request.take.pitchSemitones, semitones != 0 {
                backingURL = try await PitchRenderer.prepare(source: source, semitones: semitones)
            } else { backingURL = source }
            try Task.checkCancellation()
            preparedBackingURL = backingURL
            let plan = try await TakeMix.build(for: request, backingURL: backingURL, vocalDelayMS: offsetMS, patch: selectedPatch)
            try Task.checkCancellation()
            mix = plan
            hasMix = true
            canAlign = true
            duration = plan.duration
            if initial { mode = .mix }
            let item = AVPlayerItem(asset: plan.asset)
            player.replaceCurrentItem(with: item)
            effectsPreview = nil
            renderedTone = nil
            updateMix()
            if let auditionRange { item.forwardPlaybackEndTime = time(auditionRange.end + plan.vocalStart) }
            movePlayhead(to: dryPosition + plan.vocalStart)
            if wasPlaying, position < (auditionRange.map { $0.end + plan.vocalStart } ?? duration) - 0.04 {
                player.play()
                isPlaying = true
            }
            notice = request.take.captureSongSeconds == nil ? "旧录音按当时的播放位置估算对齐，可手动微调。" :
                                                            "已按录制时钟对齐，可微调声卡带来的偏差。"
        } catch {
            guard !Task.isCancelled else { return }
            mix = nil
            hasMix = false
            mode = .dry
            auditionRange = nil
            installDry(at: dryPosition)
            notice = "伴奏回听不可用：\(error.localizedDescription)"
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, time.seconds.isFinite, self.player.rate > 0 else { return }
                self.position = min(self.duration, max(0, time.seconds))
                if let audition = self.auditionRange, self.position >= audition.end + (self.mix?.vocalStart ?? 0) {
                    self.finishAudition()
                }
            }
        }
        finishObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] event in
            guard let item = event.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if self.auditionRange != nil { self.finishAudition() }
                else { self.pause(); self.position = self.duration }
            }
        }
        errorObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] event in
            guard let item = event.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.pause()
                self.notice = "无法播放这条录音，请检查音频文件和输出设备。"
            }
        }
    }

    private func installDry(at time: Double) {
        duration = request.take.duration
        player.replaceCurrentItem(with: AVPlayerItem(url: request.vocalURL))
        effectsPreview = nil
        renderedTone = nil
        updateMix()
        seek(to: time)
    }

    private func updateMix() {
        let reviewLevels = TakeMixLevels(vocal: vocal, backing: backing, includesBacking: mode == .mix)
        player.volume = mix == nil && effectsPreview == nil ? vocal : 1
        player.currentItem?.audioMix = effectsPreview?.audioMix(reviewLevels, enabled: effects.enabled, reverb: effects.reverb)
            ?? mix?.audioMix(reviewLevels)
    }

    private func prepareEffectsIfNeeded(debounce: Bool = false) {
        guard initialized, effects.enabled, !isPreparing, tone != renderedTone, effectsTask == nil else { return }
        let generation = effectsGeneration
        let settings = effects
        let targetTone = tone
        let plan = mix
        let request = request
        isPreparingEffects = true
        effectsTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(220)) }
                let base: TakeMix
                if let plan { base = plan }
                else { base = try await TakeMix.build(for: request, backingURL: nil, vocalDelayMS: 0) }
                try Task.checkCancellation()
                let preview = try await TakeEffectsPreview.prepare(from: base, settings: settings)
                guard let self, !Task.isCancelled, self.effectsGeneration == generation else { return }
                self.effectsTask = nil
                self.isPreparingEffects = false
                self.installEffects(preview, tone: targetTone)
            } catch {
                guard let self, !Task.isCancelled, self.effectsGeneration == generation else { return }
                self.effectsTask = nil
                self.isPreparingEffects = false
                self.effects.enabled = false
                self.effectsNotice = "无法应用人声效果，仍可回听干声。"
            }
        }
    }

    private func installEffects(_ preview: TakeEffectsPreview, tone: Tone) {
        let playhead = position
        let resume = isPlaying
        player.pause()
        let item = AVPlayerItem(asset: preview.asset)
        player.replaceCurrentItem(with: item)
        effectsPreview = preview
        renderedTone = tone
        updateMix()
        if let auditionRange { item.forwardPlaybackEndTime = time(auditionRange.end + (mix?.vocalStart ?? 0)) }
        movePlayhead(to: playhead)
        if resume { player.play() }
    }

    private func cancelEffectsPreparation() {
        effectsGeneration = UUID()
        effectsTask?.cancel()
        effectsTask = nil
        isPreparingEffects = false
    }

    private var levels: TakeMixLevels { TakeMixLevels(vocal: vocal, backing: backing) }

    func seek(to time: Double) {
        clearAudition()
        movePlayhead(to: time)
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private func movePlayhead(to seconds: Double) {
        position = min(duration, max(0, seconds))
        player.seek(to: time(position), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setMarkA() {
        markA = min(max(0, request.take.duration - 0.25), dryPosition)
        if let markA, let markB, markB < markA + 0.25 { self.markB = nil }
    }

    func setMarkB() {
        guard let markA, dryPosition >= markA + 0.25 else {
            exportNotice = "B 点至少要比 A 点晚 0.25 秒。"
            return
        }
        markB = dryPosition
        exportNotice = ""
    }

    private var dryPosition: Double { min(request.take.duration, max(0, position - (mix?.vocalStart ?? 0))) }

    func audition() {
        guard let markedRange else { return }
        auditionRange = markedRange
        let shift = mix?.vocalStart ?? 0
        player.currentItem?.forwardPlaybackEndTime = time(markedRange.end + shift)
        movePlayhead(to: markedRange.start + shift)
        player.play()
        isPlaying = true
    }

    private func finishAudition() {
        guard let auditionRange else { return }
        pause()
        position = min(duration, auditionRange.end + (mix?.vocalStart ?? 0))
        clearAudition()
    }

    private func clearAudition() {
        auditionRange = nil
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    func rememberVersion(using adopt: (UUID?) throws -> Void) {
        do {
            try adopt(selectedPatchID)
            adoptedPatchID = selectedPatchID
            exportNotice = selectedPatchID == nil ? "已恢复默认回听原版。" : "已采用补录，原始 WAV 保留。"
        } catch { exportNotice = error.localizedDescription }
    }

    func toggle() {
        if isPlaying { pause() }
        else {
            if position >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    private func pause() { player.pause(); isPlaying = false }

    func export() {
        guard let mix, !isPreparing, !isExporting else { return }
        pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = request.vocalURL.deletingPathExtension().lastPathComponent +
            (selectedPatchID == nil ? " - 混音.wav" : " - 补录混音.wav")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let takeRoot = request.vocalURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let protectedSources = [request.backingURL, preparedBackingURL].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !resolved.hasPrefix(takeRoot + "/"), !protectedSources.contains(resolved) else {
            exportNotice = "请选择录音文件夹以外的位置，避免覆盖原始音频。"
            return
        }
        isExporting = true
        exportNotice = ""
        let settings = levels
        exportTask = Task {
            defer { isExporting = false }
            do {
                try await mix.exportWAV(to: destination, levels: settings)
                exportNotice = "已导出：\(destination.lastPathComponent)"
            } catch {
                if !Task.isCancelled { exportNotice = "导出失败：\(error.localizedDescription)" }
            }
        }
    }

    func close() {
        exportTask?.cancel()
        cancelEffectsPreparation()
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver); self.finishObserver = nil }
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver); self.errorObserver = nil }
        player.replaceCurrentItem(with: nil)
        effectsPreview = nil
    }
}

struct TakeReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TakeReviewModel
    @State private var seeking = false
    @State private var seekPosition = 0.0
    private let cuePunch: (PracticeRange) -> Void
    private let adopt: (UUID?) throws -> Void

    init(request: TakeReviewRequest, cuePunch: @escaping (PracticeRange) -> Void, adopt: @escaping (UUID?) throws -> Void) {
        _model = StateObject(wrappedValue: TakeReviewModel(request: request))
        self.cuePunch = cuePunch
        self.adopt = adopt
    }

    private struct BuildKey: Equatable { let delay: Int; let version: UUID? }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("录音回听").font(.title2.bold())
                Text(model.request.take.songName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("回听模式", selection: $model.mode) {
                Text(TakeReviewModel.Mode.dry.rawValue).tag(TakeReviewModel.Mode.dry)
                Text(TakeReviewModel.Mode.mix.rawValue).tag(TakeReviewModel.Mode.mix)
            }.pickerStyle(.segmented).labelsHidden().disabled(!model.hasMix || model.isPreparing)
            HStack(spacing: 12) {
                Button { model.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 26, height: 21)
                }.accessibilityLabel(model.isPlaying ? "暂停回听" : "播放录音").disabled(model.isPreparing || model.isExporting)
                Text(preciseTimeLabel(seeking ? seekPosition : model.position)).monospacedDigit()
                Slider(value: Binding(get: { seeking ? seekPosition : model.position }, set: {
                    if seeking { seekPosition = $0 } else { model.seek(to: $0) }
                }),
                       in: 0...max(model.duration, 0.001), onEditingChanged: { active in
                    if active { seekPosition = model.position; seeking = true }
                    else { model.seek(to: seekPosition); seeking = false }
                }).accessibilityLabel("回听进度").disabled(model.isPreparing || model.isExporting)
                Text(preciseTimeLabel(model.duration)).monospacedDigit()
            }.font(.callout)
            if model.request.take.parentTakeID == nil, model.request.backingURL != nil {
                patchControls
            }
            Divider()
            VStack(spacing: 12) {
                gainSlider("人声音量", value: $model.vocal).disabled(model.isExporting)
                gainSlider("伴奏音量", value: $model.backing)
                    .disabled(!model.hasMix || model.mode == .dry || model.isExporting)
            }
            effectsControls
            HStack {
                Text("人声对齐").font(.callout)
                Spacer()
                Text(String(format: "%+d ms", model.offsetMS)).monospacedDigit()
                    .accessibilityLabel("人声偏移 \(model.offsetMS) 毫秒")
                Stepper("微调人声对齐", value: $model.offsetMS, in: -500...500, step: 10).labelsHidden()
                Button("归零") { model.offsetMS = 0 }.disabled(model.offsetMS == 0)
            }.disabled(!model.canAlign || model.isExporting)
                .help("正值让人声变晚，负值让人声提前。")
            if model.isPreparing { ProgressView("正在准备伴奏…").controlSize(.small) }
            else { Text(model.notice).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Text(model.exportNotice.isEmpty ? "混音为立体声 WAV；原始人声保留。" : model.exportNotice)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isExporting)
                Button(model.isExporting ? "正在导出…" : "导出混音 WAV…") { model.export() }
                    .buttonStyle(.borderedProminent).disabled(!model.hasMix || model.isPreparing || model.isExporting)
            }
        }
        .padding(22)
        .frame(width: 550)
        .studioSheet()
        .task(id: BuildKey(delay: model.offsetMS, version: model.selectedPatchID)) { await model.prepare() }
        .onDisappear { model.close() }
        .interactiveDismissDisabled(model.isExporting)
    }

    private var patchControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.request.versions.isEmpty {
                HStack {
                    Picker("回听版本", selection: $model.selectedPatchID) {
                        Text("A · 原版").tag(UUID?.none)
                        ForEach(Array(model.request.versions.enumerated()), id: \.element.id) { index, patch in
                            Text("B\(index + 1) · 补录 \(patch.range.label)").tag(Optional(patch.id))
                        }
                    }
                    Button(model.selectedPatchID == nil ? "默认听原版" : "采用此补录") { model.rememberVersion(using: adopt) }
                        .disabled(model.selectedPatchID == model.adoptedPatchID ||
                                  (model.selectedPatchID != nil && (!model.hasMix || model.isPreparing)))
                }
            }
            HStack(spacing: 8) {
                Button(model.markA.map { "A \(preciseTimeLabel($0))" } ?? "设 A") { model.setMarkA() }
                Button(model.markB.map { "B \(preciseTimeLabel($0))" } ?? "设 B") { model.setMarkB() }.disabled(model.markA == nil)
                Button("试听 A–B") { model.audition() }.disabled(model.markedRange == nil)
                Spacer()
                Button("准备补录…") {
                    guard let range = model.markedRange else { return }
                    cuePunch(range)
                    dismiss()
                }
                .disabled(!model.request.microphoneReady || !model.hasMix || model.markedRange == nil)
                .help(model.request.microphoneReady ? "用原伴奏和录制调性补录 A 到 B" : "先在工作台启用麦克风")
            }
        }.font(.callout).disabled(model.isPreparing || model.isExporting)
    }

    private func gainSlider(_ title: String, value: Binding<Float>) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...1).accessibilityLabel(title)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 45, alignment: .trailing)
        }.font(.callout)
    }

    private var effectsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("人声效果", isOn: $model.effects.enabled).toggleStyle(.switch).controlSize(.small)
                    .help("关闭后回听干声，方便对比。")
                Spacer()
                Button(model.request.take.recordedEffects == nil ? "恢复初始设置" : "恢复录制设置") {
                    model.effects = model.request.reviewEffects.bounded
                }.disabled(model.effects == model.request.reviewEffects.bounded)
            }
            VStack(spacing: 8) {
                effectSlider("明亮度", value: $model.effects.brightness, range: -4...6, step: 0.5,
                             label: String(format: "%+.1f dB", model.effects.brightness))
                effectSlider("压缩", value: $model.effects.compression, range: 0...1, step: 0.01,
                             label: "\(Int((model.effects.compression * 100).rounded()))%")
                effectSlider("混响", value: $model.effects.reverb, range: 0...45, step: 1,
                             label: "\(Int(model.effects.reverb.rounded()))%")
            }.disabled(!model.effects.enabled)
            HStack(spacing: 6) {
                if model.isPreparingEffects { ProgressView().controlSize(.small) }
                Text(model.isPreparingEffects ? "正在更新人声效果…" : model.effectsNotice.isEmpty
                     ? "效果仅用于回听，原始录音和导出保留干声。" : model.effectsNotice)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 16)
        }.font(.callout).disabled(model.isPreparing || model.isExporting)
    }

    private func effectSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, step: Float, label: String) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
            Text(label).monospacedDigit().frame(width: 65, alignment: .trailing)
        }
    }
}
