import Foundation

/// SysDVR 线协议常量（依据上游 protocol.md / proto.h / capture.h，协议版本 02 / 03）
enum SysDVR {
    static let videoPort: UInt16 = 9911
    static let audioPort: UInt16 = 9922
    static let discoveryPort: UInt16 = 19999

    static let requestMagic: UInt32 = 0xAAAA_AAAA
    static let packetMagic: UInt32 = 0xCCCC_CCCC
    static let handshakeOK: UInt32 = 6

    static let headerSize = 18
    static let helloSize = 10
    static let requestSize = 16

    /// 视频包最大负载 VbufSz
    static let maxVideoPayload = 0x54000
    /// 音频包最大负载 AbufSz * (1 + MaxABatching)
    static let maxAudioPayload = 0x1000 * 6

    static let defaultAudioBatching: UInt8 = 3

    /// 包标记位
    enum PacketFlag {
        static let video: UInt8 = 1 << 0
        static let audio: UInt8 = 1 << 1
        static let data: UInt8 = 1 << 2
        static let replay: UInt8 = 1 << 3
        static let multiNal: UInt8 = 1 << 4
        static let error: UInt8 = 1 << 5
    }

    /// 小端手工拼装版本码：内存中必须出现 '0' '2'
    static func versionCode(from string: String) -> UInt16? {
        let bytes = Array(string.utf8)
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    static func versionString(from code: UInt16) -> String {
        String(UnicodeScalar(UInt8(code & 0xFF))) + String(UnicodeScalar(UInt8(code >> 8)))
    }

    static func isSupported(versionCode: UInt16) -> Bool {
        versionString(from: versionCode) == "02" || versionString(from: versionCode) == "03"
    }
}

// MARK: - 数据包

struct PacketHeader {
    let dataSize: Int
    let timestamp: UInt64
    let flags: UInt8
    let slot: UInt8

    var isVideo: Bool { flags & SysDVR.PacketFlag.video != 0 }
    var isAudio: Bool { flags & SysDVR.PacketFlag.audio != 0 }
    var isError: Bool { flags & SysDVR.PacketFlag.error != 0 }
    var isReplay: Bool { flags & SysDVR.PacketFlag.replay != 0 }
    var isMultiNal: Bool { flags & SysDVR.PacketFlag.multiNal != 0 }

    init?(data: Data) {
        guard data.count >= SysDVR.headerSize else { return nil }
        let parsed: (UInt32, UInt32, UInt64, UInt8, UInt8) = data.withUnsafeBytes { raw in
            (
                raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                raw.loadUnaligned(fromByteOffset: 16, as: UInt8.self),
                raw.loadUnaligned(fromByteOffset: 17, as: UInt8.self)
            )
        }
        guard parsed.0 == SysDVR.packetMagic else { return nil }
        let size = Int(parsed.1)
        guard size >= 0, size <= max(SysDVR.maxVideoPayload, SysDVR.maxAudioPayload) else { return nil }
        dataSize = size
        timestamp = parsed.2
        flags = parsed.3
        slot = parsed.4
    }
}

// MARK: - Socket

enum SocketError: LocalizedError {
    case resolveFailed
    case connectFailed(String)
    case timeout
    case closed
    case io(String)

    var errorDescription: String? {
        switch self {
        case .resolveFailed: return "无法解析主机地址"
        case .connectFailed(let detail): return "连接失败：\(detail)"
        case .timeout: return "连接超时"
        case .closed: return "连接已被主机断开"
        case .io(let detail): return "网络错误：\(detail)"
        }
    }
}

/// 阻塞式 TCP 连接，读线程里顺序读固定长度即可，比回调式状态机好维护
final class TCPSocket {
    private(set) var fd: Int32 = -1
    private var isClosed = false

    init(host: String, port: UInt16, connectTimeout: TimeInterval = 4) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let list = result else {
            throw SocketError.resolveFailed
        }
        defer { freeaddrinfo(list) }

        var lastError = ""
        var pointer: UnsafeMutablePointer<addrinfo>? = list
        var connected: Int32 = -1

        while let info = pointer {
            let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if sock < 0 {
                pointer = info.pointee.ai_next
                continue
            }

            let originalFlags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, originalFlags | O_NONBLOCK)

            let rc = connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if rc == 0 {
                connected = sock
            } else if errno == EINPROGRESS {
                var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&pfd, 1, Int32(connectTimeout * 1000))
                if pollResult > 0 {
                    var soError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &length)
                    if soError == 0 {
                        connected = sock
                    } else {
                        lastError = String(cString: strerror(soError))
                        Darwin.close(sock)
                    }
                } else {
                    lastError = "超时"
                    Darwin.close(sock)
                }
            } else {
                lastError = String(cString: strerror(errno))
                Darwin.close(sock)
            }

            if connected >= 0 { break }
            pointer = info.pointee.ai_next
        }

        guard connected >= 0 else {
            throw SocketError.connectFailed(lastError.isEmpty ? "未知原因" : lastError)
        }

        let currentFlags = fcntl(connected, F_GETFL, 0)
        _ = fcntl(connected, F_SETFL, currentFlags & ~O_NONBLOCK)

        var noDelay: Int32 = 1
        setsockopt(connected, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        fd = connected
    }

    func readExactly(_ count: Int) throws -> Data {
        precondition(count > 0)
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while received < count {
                let n = recv(fd, base + received, count - received, 0)
                if n > 0 {
                    received += n
                } else if n == 0 {
                    throw SocketError.closed
                } else {
                    if errno == EINTR { continue }
                    throw SocketError.io(String(cString: strerror(errno)))
                }
            }
        }
        return data
    }

    /// 丢弃字节直到找到 4 字节 0xCC 魔数（流错位后重新同步）
    func resyncToMagic(maxSkip: Int = 1 << 20) throws {
        var window: [UInt8] = []
        for _ in 0..<maxSkip {
            let byte = try readExactly(1)
            window.append(byte[0])
            if window.count > 4 { window.removeFirst(window.count - 4) }
            if window.count == 4 && window[0] == 0xCC && window[1] == 0xCC && window[2] == 0xCC && window[3] == 0xCC {
                return
            }
        }
        throw SocketError.io("数据流错位，无法重新同步")
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base + sent, data.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw SocketError.io(String(cString: strerror(errno)))
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        fd = -1
    }

    deinit { close() }
}
