import Foundation
import AVFoundation

/// SysDVR 音频是 16bit PCM 48kHz 立体声交错；
/// AVAudioEngine 的标准格式是 float32 非交错，这里做一次转换再播放。
final class PCMAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let bytesPerSecond = 48000 * 4
    private var pendingBytes = 0
    private let lock = NSLock()

    private(set) var isRunning = false
    private(set) var droppedPackets = 0

    /// 允许的最大积压（秒），超过就丢新包，避免延迟越滚越大
    private let maxBacklogSeconds: Double = 0.45

    init?() {
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return nil }
        format = pcmFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    func start() throws {
        guard !isRunning else { return }
        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        lock.lock(); pendingBytes = 0; lock.unlock()
    }

    func enqueue(_ data: Data) {
        guard isRunning else { return }
        let frames = data.count / 4
        guard frames > 0 else { return }

        lock.lock()
        if pendingBytes > Int(Double(bytesPerSecond) * maxBacklogSeconds) {
            droppedPackets += 1
            lock.unlock()
            return
        }
        pendingBytes += frames * 4
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return }

        data.withUnsafeBytes { raw in
            let left = channels[0]
            let right = channels[1]
            for index in 0..<frames {
                let l = raw.loadUnaligned(fromByteOffset: index * 4, as: Int16.self)
                let r = raw.loadUnaligned(fromByteOffset: index * 4 + 2, as: Int16.self)
                left[index] = Float(l) / 32768.0
                right[index] = Float(r) / 32768.0
            }
        }

        let consumed = frames * 4
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.pendingBytes = max(0, self.pendingBytes - consumed)
            self.lock.unlock()
        }
    }
}
