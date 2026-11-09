import Foundation

/// 一次串流会话：握手 + 拆包。
/// 传输层可替换（TCP Bridge / USB），两侧共用同一套协议解析。
protocol StreamTransport: AnyObject {
    var name: String { get }
    func connect() throws
    func close()
    func write(_ data: Data) throws
    /// 握手阶段读取固定字节数（TCP 精确读；USB 读一次 bulk 传输）
    func readHandshakeBytes(_ count: Int) throws -> Data
    /// 读取一个逻辑数据单元：TCP 为「18 字节头 + 负载」，USB 为一次 bulk 传输
    func readUnit() throws -> Data?
}

// MARK: - TCP Bridge

final class TCPTransport: StreamTransport {
    private let host: String
    private let port: UInt16
    private var socket: TCPSocket?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    var name: String { "\(host):\(port)" }

    func connect() throws {
        socket = try TCPSocket(host: host, port: port)
    }

    func close() {
        socket?.close()
        socket = nil
    }

    func write(_ data: Data) throws {
        guard let socket else { throw SocketError.closed }
        try socket.write(data)
    }

    func readHandshakeBytes(_ count: Int) throws -> Data {
        guard let socket else { throw SocketError.closed }
        return try socket.readExactly(count)
    }

    func readUnit() throws -> Data? {
        guard let socket else { return nil }
        var headerData = try socket.readExactly(SysDVR.headerSize)
        if PacketHeader(data: headerData) == nil {
            try socket.resyncToMagic()
            _ = try socket.readExactly(SysDVR.headerSize - 4)
            headerData = try socket.readExactly(SysDVR.headerSize)
        }
        guard let header = PacketHeader(data: headerData) else { return nil }
        let payload = header.dataSize > 0 ? try socket.readExactly(header.dataSize) : Data()
        return headerData + payload
    }
}

// MARK: - 会话

final class SysDVRConnection {
    struct Handshake {
        let protocolVersion: String
    }

    enum TransportKind: String, CaseIterable, Identifiable {
        case network = "网络（TCP Bridge）"
        case usb = "USB 直连"

        var id: String { rawValue }
        var short: String { self == .network ? "网络" : "USB" }
    }

    private var videoTransport: StreamTransport?
    private var audioTransport: StreamTransport?
    private let lock = NSLock()
    private var active = false

    var onVideo: ((Data) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onHandshake: ((Handshake) -> Void)?
    var onFailure: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onLog: ((String) -> Void)?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    // MARK: - 连接

    func connect(host: String, kind: TransportKind, withAudio: Bool) {
        lock.lock()
        if active {
            lock.unlock()
            return
        }
        active = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var video: StreamTransport?
            var audio: StreamTransport?
            var version = ""

            do {
                let transport = self.makeVideoTransport(host: host, kind: kind)
                try transport.connect()
                // USB 单端点承载音视频，握手同时订阅两路
                let meta: UInt8 = kind == .usb ? (withAudio ? 0b11 : 0b01) : 0b01
                version = try self.handshake(transport: transport, stream: .video, metaFlags: meta)
                video = transport
                self.log("\(kind.short) 通道就绪：\(transport.name)，协议版本 \(version)")
            } catch {
                self.fail("\(kind.short) 连接失败：\(error.localizedDescription)")
            }

            // USB 音视频复用同一端点，只有网络模式才有独立音频 socket
            if video != nil, withAudio, kind == .network {
                do {
                    let transport = TCPTransport(host: host, port: SysDVR.audioPort)
                    try transport.connect()
                    _ = try self.handshake(transport: transport, stream: .audio, metaFlags: 0b10)
                    audio = transport
                } catch {
                    self.fail("音频通道连接失败（画面可继续）：\(error.localizedDescription)")
                }
            }

            guard let videoTransport = video else {
                self.teardown()
                return
            }

            self.lock.lock()
            self.videoTransport = videoTransport
            self.audioTransport = audio
            self.lock.unlock()

            self.onHandshake?(Handshake(protocolVersion: version))

            DispatchQueue(label: "switchcast.video.read").async {
                self.readLoop(transport: videoTransport, kind: kind)
            }
            if let audio {
                DispatchQueue(label: "switchcast.audio.read").async {
                    self.readLoop(transport: audio, kind: kind)
                }
            }
        }
    }

    func disconnect() {
        teardown()
    }

    private func teardown() {
        lock.lock()
        let wasActive = active
        active = false
        let video = videoTransport
        let audio = audioTransport
        videoTransport = nil
        audioTransport = nil
        lock.unlock()

        video?.close()
        audio?.close()

        if wasActive {
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnect?()
            }
        }
    }

    // MARK: - 传输层构造

    private enum Stream {
        case video, audio

        var metaFlag: UInt8 { self == .video ? 1 : 2 }
        var name: String { self == .video ? "视频" : "音频" }
    }

    private func makeVideoTransport(host: String, kind: TransportKind) -> StreamTransport {
        switch kind {
        case .network:
            return TCPTransport(host: host, port: SysDVR.videoPort)
        case .usb:
            let transport = UsbTransport()
            transport.onLog = { [weak self] message in self?.log(message) }
            return transport
        }
    }

    // MARK: - 握手

    private func handshake(transport: StreamTransport, stream: Stream, metaFlags: UInt8) throws -> String {
        // 主机先发 hello："SysDVR|02\0"
        // USB 侧 sysmodule 是「写不出去就 1 秒后重试」，这里同频重试，避免一超时就关设备触发重新枚举
        var helloData = Data()
        var lastError: Error?
        let attempts = stream == .video ? 3 : 1
        for attempt in 0..<attempts {
            do {
                helloData = try transport.readHandshakeBytes(SysDVR.helloSize)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        if let lastError { throw lastError }
        let hello = [UInt8](helloData)
        guard hello.count >= SysDVR.helloSize,
              String(decoding: hello[0..<7], as: UTF8.self) == "SysDVR|" else {
            throw SocketError.io("未收到有效的握手响应（确认 Switch 端已切到 TCP Bridge 模式）")
        }
        let versionString = String(decoding: hello[7..<9], as: UTF8.self)
        guard let version = SysDVR.versionCode(from: versionString), SysDVR.isSupported(versionCode: version) else {
            throw SocketError.io("协议版本 \(versionString) 不受支持")
        }

        var request = Data()
        request.append(uint32: SysDVR.requestMagic)
        request.append(uint16: version)
        request.append(metaFlags)
        request.append(0b10)                        // InjectPPSSPS
        request.append(SysDVR.defaultAudioBatching)
        request.append(0)                           // FeatureFlags
        request.append(contentsOf: [UInt8](repeating: 0, count: 6))
        try transport.write(request)

        let responseSize = versionString == "03" ? 72 : 4
        let response = try transport.readHandshakeBytes(responseSize)
        guard response.count >= 4 else { throw SocketError.io("握手应答长度异常") }
        let code = response.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard code == SysDVR.handshakeOK else {
            throw SocketError.io("\(stream.name)通道被主机拒绝（错误码 \(code)）")
        }
        return versionString
    }

    // MARK: - 拆包

    private func readLoop(transport: StreamTransport, kind: TransportKind) {
        while isActive {
            do {
                guard let unit = try transport.readUnit() else { break }
                guard unit.count > SysDVR.headerSize, let header = PacketHeader(data: unit) else { continue }
                let end = min(unit.count, SysDVR.headerSize + header.dataSize)
                guard end > SysDVR.headerSize else { continue }
                let payload = unit.subdata(in: SysDVR.headerSize..<end)

                if header.isError {
                    reportErrorPacket(payload)
                    continue
                }
                if header.isReplay { continue }

                if header.isVideo {
                    onVideo?(payload)
                } else if header.isAudio {
                    onAudio?(payload)
                }
            } catch {
                if isActive {
                    fail("\(kind.short) 通道中断：\(error.localizedDescription)")
                }
                break
            }
        }

        if isActive { teardown() }
    }

    private func reportErrorPacket(_ payload: Data) {
        guard payload.count >= 8 else {
            fail("主机返回错误包")
            return
        }
        let type = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let code = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let text: String
        switch type {
        case 1: text = "视频采集失败（确认已进入游戏）"
        case 2, 3: text = "音频采集失败"
        case 4: text = "视频编码器初始化失败"
        case 5: text = "音频编码器初始化失败"
        default: text = "未知错误"
        }
        fail("\(text)，代码 \(code)")
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message)
        }
    }
}

// MARK: - Data 辅助

extension Data {
    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(uint16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
