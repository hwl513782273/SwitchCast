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
    @Published var host: String = ""
    @Published var transport: SysDVRConnection.TransportKind = .network
    @Published var audioEnabled = true {
        didSet { applyAudioState() }
    }
    @Published private(set) var stats = StreamStats()
    @Published private(set) var resolution: CGSize = .zero
    @Published private(set) var protocolVersion: String = ""
    @Published private(set) var logs: [String] = []
    @Published private(set) var lastFrameAt: Date?
    @Published var volume: Double = 0.8 {
        didSet { applyVolume() }
    }
    @Published var muted = false {
        didSet { applyVolume() }
    }

    let sink = VideoSink()

    private let connection = SysDVRConnection()
    private let decoder = H264Decoder()
    private let audio = PCMAudioPlayer()
    private let discovery = DiscoveryService()
    private var statsTimer: Timer?
    private var sessionStart: Date?
    private var framesThisTick = 0
    private var bytesThisTick = 0
    private var totalFrames = 0
    private var totalBytes = 0

    init() {
        configureCallbacks()
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

    func disconnect() {
        connection.disconnect()
        audio?.stop()
        decoder.reset()
        sink.clear()
        phase = .idle
        protocolVersion = ""
        log("已断开")
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
            self.decoder.handle(packet: payload)
        }

        connection.onAudio = { [weak self] payload in
            self?.audio?.enqueue(payload)
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

        decoder.onFrame = { [weak self] image in
            guard let self else { return }
            self.sink.push(image)
            self.framesThisTick += 1
            self.totalFrames += 1
            self.lastFrameAt = Date()
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

    private func tick() {
        var stats = StreamStats()
        stats.fps = Double(framesThisTick)
        stats.mbps = Double(bytesThisTick) * 8 / 1_000_000
        stats.frames = totalFrames
        stats.droppedAudio = audio?.droppedPackets ?? 0
        stats.elapsed = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        self.stats = stats
        framesThisTick = 0
        bytesThisTick = 0
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

    private func applyVolume() {
        audio?.volume = muted ? 0 : Float(volume)
    }

    private func log(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
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
            if env["AUTOCONNECT_TRANSPORT"] == "usb" { transport = .usb }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.connect()
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
