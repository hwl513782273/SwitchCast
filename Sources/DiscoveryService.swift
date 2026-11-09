import Foundation

struct DiscoveredConsole: Identifiable, Equatable {
    let id: String
    var serial: String
    var address: String
    var protocolVersion: String
    var systemVersion: String
    var lastSeen: Date
}

/// 监听 19999 端口的 UDP 广播（sysmodule 每 2 秒发一次）
/// 用 DispatchSourceRead 做事件驱动读取：阻塞式 recv 在后台队列上实测收不到包
final class DiscoveryService {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var running = false
    private var consoles: [String: DiscoveredConsole] = [:]

    var onChange: (([DiscoveredConsole]) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        guard !running else { return }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }

        // 不用 SO_REUSEPORT：否则多个 SysDVR 客户端会互相抢广播包，谁都收不全
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = SysDVR.discoveryPort.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(sock, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(sock)
            onError?("自动发现不可用（端口 19999 绑定失败：\(reason)），请手动填写 IP；若官方客户端正在运行请先退出")
            return
        }

        // 非阻塞，由 DispatchSource 通知可读
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        fd = sock
        running = true

        let stream = DispatchSource.makeReadSource(fileDescriptor: sock, queue: DispatchQueue(label: "switchcast.discovery"))
        stream.setEventHandler { [weak self] in
            self?.drain(socket: sock)
        }
        stream.setCancelHandler {
            Darwin.close(sock)
        }
        stream.resume()
        source = stream

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.prune()
        }
    }

    func stop() {
        running = false
        source?.cancel()
        source = nil
        fd = -1
    }

    // MARK: - 读取

    private func drain(socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)

        while running {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    recvfrom(socket, &buffer, buffer.count, 0, socketAddress, &senderLength)
                }
            }
            if count <= 0 { return }   // EAGAIN：本轮读空

            guard let text = String(bytes: buffer[0..<count], encoding: .utf8) else { continue }
            let trimmed = text.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let fields = trimmed.components(separatedBy: "|")
            guard fields.count >= 3, fields[0] == "SysDVR" else { continue }

            let serial = fields.count >= 4 ? fields[3] : fields[2]
            let console = DiscoveredConsole(
                id: serial,
                serial: serial,
                address: Self.ipString(from: sender),
                protocolVersion: fields[2],
                systemVersion: fields[1],
                lastSeen: Date()
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.consoles[serial] = console
                self.publish()
            }
        }
    }

    private func prune() {
        guard running else { return }
        let threshold = Date().addingTimeInterval(-6)
        consoles = consoles.filter { $0.value.lastSeen > threshold }
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.prune()
        }
    }

    private func publish() {
        onChange?(consoles.values.sorted { $0.serial < $1.serial })
    }

    private static func ipString(from address: sockaddr_in) -> String {
        var addr = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }
}
