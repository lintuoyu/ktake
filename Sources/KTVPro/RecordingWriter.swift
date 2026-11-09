@preconcurrency import AVFoundation
import os

/// A bounded, preallocated handoff. The audio tap never waits for the disk queue.
/// A full pool is reported as an interrupted take instead of silently losing audio.
final class RecordingWriter: @unchecked Sendable {
    struct Result {
        let frames: AVAudioFramePosition
        let issue: String?
        let firstHostTime: UInt64?
    }
    private struct State {
        var free: [AVAudioPCMBuffer]
        var accepting = true
        var issue: String?
        var frames: AVAudioFramePosition = 0
        var firstHostTime: UInt64?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "studio.ktvpro.recording", qos: .userInitiated)
    private var file: AVAudioFile?
    let format: AVAudioFormat

    init(url: URL, format: AVAudioFormat, capacity: AVAudioFrameCount = 8192, poolSize: Int = 32) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved, format.channelCount == 1 else {
            throw AppFailure(message: "录音格式必须是单声道浮点音频。")
        }
        self.format = format
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<poolSize {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AppFailure(message: "无法准备录音缓冲区。")
            }
            buffers.append(buffer)
        }
        state = OSAllocatedUnfairLock(initialState: State(free: buffers))
        // 24-bit PCM WAV on disk; float32 in the processing graph.
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var issue: String? { state.withLock { $0.issue } }

    func append(_ input: AVAudioPCMBuffer, at time: AVAudioTime) {
        // Tap buffers belong to the engine and must be copied before returning.
        guard let destination = state.withLock({ state -> AVAudioPCMBuffer? in
            guard state.accepting else { return nil }
            guard let buffer = state.free.popLast(), input.frameLength <= buffer.frameCapacity else {
                state.issue = "磁盘写入跟不上录音，或设备缓冲区发生变化。录音已停止，请检查保存空间和音频设备。"
                state.accepting = false
                return nil
            }
            return buffer
        }) else { return }
        let hostTime = time.isHostTimeValid ? time.hostTime : nil
        destination.frameLength = input.frameLength
        guard let source = input.floatChannelData?[0], let target = destination.floatChannelData?[0] else {
            state.withLock { $0.free.append(destination); $0.accepting = false; $0.issue = "无法读取麦克风音频。" }
            return
        }
        target.update(from: source, count: Int(input.frameLength))
        // Enqueue while holding the state lock so finish cannot overtake an accepted buffer.
        state.withLock { state in
            guard state.accepting else { state.free.append(destination); return }
            queue.async { [self] in
                do {
                    try file?.write(from: destination)
                    self.state.withLock {
                        if $0.frames == 0 { $0.firstHostTime = hostTime }
                        $0.frames += AVAudioFramePosition(destination.frameLength)
                    }
                } catch {
                    self.state.withLock { $0.issue = "保存录音失败：\(error.localizedDescription)"; $0.accepting = false }
                }
                self.state.withLock { $0.free.append(destination) }
            }
        }
    }

    func finish(_ completion: @escaping (Result) -> Void) {
        state.withLock { state in
            state.accepting = false
            queue.async { [self] in
                file = nil // Flush and close the WAV before publishing it to the UI.
                let result = self.state.withLock { Result(frames: $0.frames, issue: $0.issue, firstHostTime: $0.firstHostTime) }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}
