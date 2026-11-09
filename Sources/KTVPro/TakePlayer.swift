import AVFoundation

/// Playback uses the chosen output without opening a microphone.
@MainActor
final class TakePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var reverbEngine: AVAudioEngine?
    private var reverbFile: AVAudioFile?
    private var configurationObserver: NSObjectProtocol?
    private var playbackID: UUID?
    private var completion: ((Error?) -> Void)?

    func play(url: URL, outputUID: String?, completion: @escaping (Error?) -> Void) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.currentDevice = outputUID
        player.delegate = self
        player.volume = 0.85
        guard player.prepareToPlay(), player.play() else { throw AppFailure(message: "无法回放此录音，请确认输出设备可用。") }
        self.player = player
        self.completion = completion
    }

    func play(url: URL, output: AudioDevice, effects settings: VocalSettings, reverbOnly: Bool = false,
              completion: @escaping (Error?) -> Void) throws {
        guard settings.enabled else {
            try play(url: url, outputUID: output.uid, completion: completion)
            return
        }
        stop()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        try AudioEngine.selectDevice(output.id, node: engine.outputNode)
        let source = AVAudioPlayerNode()
        if reverbOnly {
            try Self.connectReverb(in: engine, source: source, format: format, amount: settings.reverb)
        } else {
            try Self.checkFormat(format)
            engine.attach(source)
            let effects = VocalEffects()
            effects.update(brightness: settings.brightness, compression: settings.compression, space: settings.reverb)
            effects.connect(in: engine, from: source, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = 0.85 * settings.gain

        // Continue rendering briefly after the file ends so the reverb can decay.
        let tailFrames = AVAudioFrameCount(max(1, format.sampleRate * (settings.reverb > 0 ? 0.75 : 0.02)))
        guard file.length > 0, let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: tailFrames) else {
            throw AppFailure(message: "录音文件没有可播放的音频。")
        }
        tail.frameLength = tailFrames
        for buffer in UnsafeMutableAudioBufferListPointer(tail.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let id = UUID()
        source.scheduleFile(file, at: nil)
        source.scheduleBuffer(tail, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finishReverb(id: id, error: nil) }
        }
        engine.prepare()
        try engine.start()
        playbackID = id
        reverbEngine = engine
        reverbFile = file
        self.completion = completion
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                       object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.finishReverb(id: id, error: AppFailure(message: "输出设备发生变化，回听已停止。"))
            }
        }
        source.play()
    }

    static func connectReverb(in engine: AVAudioEngine, source: AVAudioPlayerNode,
                              format: AVAudioFormat, amount: Float) throws {
        try checkFormat(format)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        let effect = AVAudioUnitReverb()
        effect.loadFactoryPreset(.plate)
        effect.wetDryMix = amount
        engine.attach(source)
        engine.attach(effect)
        engine.connect(source, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: stereo)
    }

    private static func checkFormat(_ format: AVAudioFormat) throws {
        guard (1...2).contains(format.channelCount), format.sampleRate.isFinite, format.sampleRate > 0,
              AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) != nil else {
            throw AppFailure(message: "此录音的音频格式无法使用人声效果。")
        }
    }

    private func finishReverb(id: UUID, error: Error?) {
        guard playbackID == id else { return }
        let onFinish = completion
        stop()
        onFinish?(error)
    }

    func stop() {
        playbackID = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        reverbEngine?.stop()
        reverbEngine = nil
        reverbFile = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        completion = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.completion?(flag ? nil : AppFailure(message: "录音回放提前结束。"))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.completion?(error ?? AppFailure(message: "录音文件无法解码。"))
        }
    }
}
