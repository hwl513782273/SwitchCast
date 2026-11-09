import Foundation
import AVFoundation
import CoreMedia
import AppKit

/// 录屏：视频走 H.264 直通（不重编码），音频从 PCM 编码成 AAC
final class Recorder {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private let lock = NSLock()
    var onLog: ((String) -> Void)?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var sessionStart: CMTime?
    private var audioFrames: Int64 = 0
    private var videoFrames: Int64 = 0

    private(set) var url: URL?
    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// - Parameter withAudio: 是否写入音轨
    func start(withAudio: Bool, videoFormat: CMFormatDescription) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRecording else { return }

        let target = Self.outputURL(extension: "mp4")
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)

        // 轨道必须在 startWriting 之前添加
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.setupFailed }
        writer.add(video)
        videoInput = video

        if withAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000
            ]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "无法开始写入")
        }
        onLog?("录制已开始：\(target.lastPathComponent)（音频：\(withAudio ? "开" : "关")）")

        self.writer = writer
        self.url = target
        self.isRecording = true
        self.startedAt = Date()
        self.sessionStart = nil
        self.audioFrames = 0
        self.videoFrames = 0
    }

    /// 追加一帧压缩视频（直接复用解码前的 CMSampleBuffer）
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let writer, let videoInput else { return }

        if sessionStart == nil {
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            sessionStart = start
            writer.startSession(atSourceTime: start)
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) {
            videoFrames += 1
        }
    }

    /// 追加 PCM（16bit / 48kHz / 立体声交错）
    func appendAudio(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let audioInput, let sessionStart else { return }
        let frames = data.count / 4
        guard frames > 0 else { return }

        if audioFormat == nil {
            audioFormat = Self.makePCMFormatDescription()
        }
        guard let format = audioFormat, audioInput.isReadyForMoreMediaData else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTimeAdd(sessionStart, CMTime(value: audioFrames, timescale: 48000)),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return }

        if audioInput.append(sample) {
            audioFrames += Int64(frames)
        }
    }

    /// 结束并落盘，返回文件地址
    @discardableResult
    func stop() -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let writer else { return nil }
        isRecording = false

        // 一帧都没收到（例如刚开就停、或没画面）→ 取消并删掉空文件
        if videoFrames == 0 {
            writer.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            self.writer = nil
            videoInput = nil
            audioInput = nil
            audioFormat = nil
            sessionStart = nil
            self.url = nil
            startedAt = nil
            return nil
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)

        let output = url
        self.writer = nil
        videoInput = nil
        audioInput = nil
        audioFormat = nil
        sessionStart = nil
        startedAt = nil
        return writer.status == .completed ? output : nil
    }

    var durationText: String {
        guard let startedAt else { return "00:00" }
        let total = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var recordedFrames: Int64 { videoFrames + audioFrames }

    // MARK: - 辅助

    private static func makePCMFormatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return description
    }

    static func outputURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "SwitchCast-\(formatter.string(from: Date())).\(ext)"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(name)
    }
}

enum RecorderError: LocalizedError {
    case setupFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed: return "录屏初始化失败"
        case .writerFailed(let detail): return "录屏失败：\(detail)"
        }
    }
}
