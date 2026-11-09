import Foundation
import SwiftUI
import AppKit

struct StreamStats {
    var fps: Double = 0
    var mbps: Double = 0
    var frames: Int = 0
    var droppedAudio: Int = 0
    var elapsed: TimeInterval = 0
}

final class StreamController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "正在连接"
            case .live: return "串流中"
            case .failed: return "连接失败"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var consoles: [DiscoveredConsole] = []
    @Published private(set) var usbDevices: [String] = []
    @Published var host: String = ""
    @Published var transport: SysDVRConnection.TransportKind = .usb
    @Published var audioEnabled = true {
        didSet { applyAudioState() }
    }
    @Published private(set) var stats = StreamStats()
    @Published private(set) var resolution: CGSize = .zero
    @Published private(set) var protocolVersion: String = ""
    @Published private(set) var logs: [String] = []
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published var recordAudio = true
    @Published var volume: Double = 0.8 {
        didSet { applyVolume() }
    }
    @Published var muted = false {
        didSet { applyVolume() }
    }

    let sink = VideoSink()

    private let connection = SysDVRConnection()
    private let decoder = H264Decoder()

    // MARK: - 解码管线：收包线程只负责收，解码在专用队列，避免互相阻塞
    private let decodeQueue = DispatchQueue(label: "switchcast.video.decode", qos: .userInteractive)
    private var decodeBacklog = 0
    private var skippingUntilKeyframe = false
    private let backlogLock = NSLock()

    // 显示合并：主线程忙时只保留最新一帧，避免积压后一次性抖出来
    private var latestImage: CGImage?
    private var imageFlushScheduled = false
    private let imageLock = NSLock()
    private let audio = PCMAudioPlayer()
    private let discovery = DiscoveryService()
    private let recorder = Recorder()
    private var statsTimer: Timer?
    private var sessionStart: Date?
    private var framesThisTick = 0
    private var bytesThisTick = 0
    private var totalFrames = 0
    private var totalBytes = 0

    init() {
        configureCallbacks()
        recorder.onLog = { [weak self] message in
            DispatchQueue.main.async { self?.log(message) }
        }
        discovery.onChange = { [weak self] list in
            guard let self else { return }
            self.consoles = list
            if self.host.isEmpty, let first = list.first {
                self.host = first.address
            }
        }
        discovery.onError = { [weak self] message in
            DispatchQueue.main.async { self?.log(message) }
        }
        discovery.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        applyVolume()
        applyStoredDefaults()
        runDebugHooks()
    }

    deinit {
        statsTimer?.invalidate()
        discovery.stop()
        connection.disconnect()
    }

    // MARK: - 对外操作

    func connect() {
        guard phase != .connecting, phase != .live else { return }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty || transport == .usb else {
            phase = .failed("请先填写 Switch 的 IP 地址，或等待自动发现")
            return
        }

        phase = .connecting
        protocolVersion = ""
        resolution = .zero
        totalFrames = 0
        totalBytes = 0
        decoder.reset()
        sink.clear()
        log("开始连接（\(transport.short)）")

        if audioEnabled, audio != nil {
            do {
                try audio?.start()
            } catch {
                log("音频启动失败：\(error.localizedDescription)")
            }
        }

        connection.connect(host: target, kind: transport, withAudio: audioEnabled)
    }

    // MARK: - 截图 / 录屏

    func takeScreenshot() {
        guard let image = sink.lastImage else {
            log("还没有画面，无法截图")
            return
        }
        let url = Recorder.screenshotURL()
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            log("截图编码失败")
            return
        }
        do {
            try data.write(to: url)
            log("截图已保存：\(url.path)")
        } catch {
            log("截图保存失败：\(error.localizedDescription)")
        }
    }

    func toggleRecording() {
        if isRecording {
            let url = recorder.stop()
            isRecording = false
            recordingElapsed = 0
            if let url {
                log("录屏已保存：\(url.path)")
            } else {
                log("录屏结束，但文件未能完成写入")
            }
        } else {
            guard let format = decoder.videoFormatDescription else {
                log("还没有画面，稍后再录")
                return
            }
            do {
                try recorder.start(withAudio: recordAudio && audioEnabled, videoFormat: format)
                isRecording = true
                recordingElapsed = 0
                log(recordAudio ? "开始录屏（含音频）" : "开始录屏（无声）")
            } catch {
                log("录屏失败：\(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        backlogLock.lock()
        decodeBacklog = 0
        skippingUntilKeyframe = false
        backlogLock.unlock()
        imageLock.lock()
        latestImage = nil
        imageFlushScheduled = false
        imageLock.unlock()
        if isRecording {
            _ = recorder.stop()
            isRecording = false
            recordingElapsed = 0
        }
        connection.disconnect()
        audio?.stop()
        decoder.reset()
        sink.clear()
        phase = .idle
        protocolVersion = ""
        log("已断开")
    }

    func connectUSB() {
        transport = .usb
        connect()
    }

    func select(console: DiscoveredConsole) {
        transport = .network
        host = console.address
        connect()
    }

    // MARK: - 回调

    private func configureCallbacks() {
        connection.onVideo = { [weak self] payload in
            guard let self else { return }
            self.totalBytes += payload.count
            self.bytesThisTick += payload.count
            self.enqueueForDecode(payload)
        }

        connection.onAudio = { [weak self] payload in
            guard let self else { return }
            self.audio?.enqueue(payload)
            self.recorder.appendAudio(payload)      // 未录制时内部直接返回
        }

        connection.onHandshake = { [weak self] info in
            guard let self else { return }
            DispatchQueue.main.async {
                self.phase = .live
                self.sessionStart = Date()
                self.protocolVersion = info.protocolVersion
                self.log("已连接，协议版本 \(info.protocolVersion)")
            }
        }

        connection.onFailure = { [weak self] message in
            guard let self else { return }
            DispatchQueue.main.async {
                self.log(message)
                if self.phase != .live {
                    self.phase = .failed(message)
                }
            }
        }

        connection.onLog = { [weak self] message in
            DispatchQueue.main.async { self?.log(message) }
        }

        connection.onDisconnect = { [weak self] in
            guard let self else { return }
            self.audio?.stop()
            if self.phase == .live {
                self.phase = .failed("连接已断开")
                self.log("主机断开了连接")
            }
        }

        decoder.onSample = { [weak self] sample in
            self?.recorder.appendVideo(sample)
        }

        decoder.onFrame = { [weak self] image in
            guard let self else { return }
            self.framesThisTick += 1
            self.totalFrames += 1
            self.lastFrameAt = Date()
            self.present(image)
        }

        decoder.onResolution = { [weak self] size in
            guard let self else { return }
            self.resolution = size
            self.log("视频尺寸 \(Int(size.width))×\(Int(size.height))")
        }

        decoder.onFailure = { [weak self] message in
            guard let self else { return }
            DispatchQueue.main.async { self.log(message) }
        }
    }

    /// 收包线程调用：只做队列调度，绝不在这里解码
    private func enqueueForDecode(_ payload: Data) {
        let isKeyframe = H264Decoder.containsIDR(payload)

        backlogLock.lock()
        if skippingUntilKeyframe {
            guard isKeyframe else { backlogLock.unlock(); return }
            skippingUntilKeyframe = false
            decodeBacklog = 0
            backlogLock.unlock()
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.decoder.reset()
                self.decoder.handle(packet: payload)
            }
            return
        }
        // 落后超过约 1 秒的帧量：直接丢弃，等下一个 IDR 重建，保证低延迟
        if decodeBacklog >= 30, !isKeyframe {
            skippingUntilKeyframe = true
            decodeBacklog = 0
            backlogLock.unlock()
            return
        }
        decodeBacklog += 1
        backlogLock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.decoder.handle(packet: payload)
            self.backlogLock.lock()
            self.decodeBacklog = max(0, self.decodeBacklog - 1)
            self.backlogLock.unlock()
        }
    }

    /// 主线程忙时合并显示：只保留最新一帧
    private func present(_ image: CGImage) {
        imageLock.lock()
        latestImage = image
        let needSchedule = !imageFlushScheduled
        imageFlushScheduled = true
        imageLock.unlock()

        guard needSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageLock.lock()
            let frame = self.latestImage
            self.latestImage = nil
            self.imageFlushScheduled = false
            self.imageLock.unlock()
            if let frame { self.sink.push(frame) }
        }
    }

    private func tick() {
        var stats = StreamStats()
        stats.fps = Double(framesThisTick)
        stats.mbps = Double(bytesThisTick) * 8 / 1_000_000
        stats.frames = totalFrames
        stats.droppedAudio = audio?.droppedPackets ?? 0
        stats.elapsed = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        if isRecording, let started = recorder.startedAt {
            recordingElapsed = Date().timeIntervalSince(started)
        }
        self.stats = stats
        framesThisTick = 0
        bytesThisTick = 0

        // USB 设备是物理插拔事件，1 秒一探足够
        let detected = UsbTransport.detectDevices()
        if detected != usbDevices {
            usbDevices = detected
        }
    }

    /// 音频开关热生效：关闭即停止播放，打开则重启引擎
    private func applyAudioState() {
        guard phase == .live else { return }
        if audioEnabled {
            do {
                try audio?.start()
                log("音频已开启")
            } catch {
                log("音频启动失败：\(error.localizedDescription)")
            }
        } else {
            audio?.stop()
            log("音频已关闭")
        }
    }

    /// 启动时套用设置里的默认值（连接方式、音频）
    private func applyStoredDefaults() {
        if let stored = UserDefaults.standard.string(forKey: "defaultTransport") {
            transport = stored == "network" ? .network : .usb
        }
        if UserDefaults.standard.object(forKey: "audioEnabledDefault") != nil {
            audioEnabled = UserDefaults.standard.bool(forKey: "audioEnabledDefault")
        }
        log("录屏保存位置：\(Recorder.ensureRecordFolder().path)")
    }

    private func applyVolume() {
        audio?.volume = muted ? 0 : Float(volume)
    }

    func log(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if let path = ProcessInfo.processInfo.environment["SC_LOG_FILE"], !path.isEmpty {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data("[\(stamp)] \(message)\n".utf8))
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data("[\(stamp)] \(message)\n".utf8))
            }
        }
        logs.append("[\(stamp)] \(message)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    // MARK: - 调试钩子（构建验证用）

    private func runDebugHooks() {
        let env = ProcessInfo.processInfo.environment

        if let target = env["AUTOCONNECT"], !target.isEmpty {
            host = target
            transport = env["AUTOCONNECT_TRANSPORT"] == "usb" ? .usb : .network
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.connect()
            }
        }

        if let raw = env["AUTO_SHOT_AFTER"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.takeScreenshot()
            }
        }
        if env["RECORD_SILENT"] == "1" {
            recordAudio = false
        }
        if let raw = env["AUTO_RECORD_AFTER"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.toggleRecording()
            }
        }
        if let raw = env["AUTO_RECORD_STOP_AFTER"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.toggleRecording()
            }
        }
        if let path = env["SNAPSHOT_PATH"], !path.isEmpty {
            let delay = Double(env["SNAPSHOT_AFTER"] ?? "8") ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.writeSnapshot(to: path)
            }
        }
    }

    private func writeSnapshot(to path: String) {
        guard let image = sink.lastImage else {
            print("[SwitchCast] snapshot: no frame decoded yet")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("[SwitchCast] snapshot saved \(path) \(image.width)x\(image.height) fps=\(stats.fps) frames=\(totalFrames)")
        } catch {
            print("[SwitchCast] snapshot failed: \(error)")
        }
    }
}
