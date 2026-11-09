import Foundation

/// macOS 12 及更早的 USB 通道：设备挂在老 IOKit USB 栈上，用 IOUSBLib 访问。
/// 实际调用在 LegacyUSBShim.c 里完成（Swift 直接调那些 vtable 会崩）。
final class LegacyUSBTransport: StreamTransport {
    private var handle: UnsafeMutableRawPointer?
    private var serial = ""
    private let lock = NSLock()
    private var closed = false
    /// 复用读缓冲：每个包重新 malloc 344KB 在老机器上会造成明显抖动
    private var readBuffer: [UInt8] = []

    var onLog: ((String) -> Void)?

    private static let transferSize = SysDVR.headerSize + max(SysDVR.maxVideoPayload, SysDVR.maxAudioPayload)

    var name: String {
        serial.isEmpty ? "USB" : "USB · \(serial)"
    }

    // MARK: - 连接

    func connect() throws {
        var code: Int32 = 0
        guard let opened = sc_usb_open("SysDVR|", &code) else {
            throw Self.error(for: code)
        }
        handle = opened

        var buffer = [CChar](repeating: 0, count: 160)
        if sc_usb_serial(opened, &buffer, 160) == 0 {
            serial = String(cString: buffer)
        }
        onLog?("[USB 老栈] 已打开 \(serial)")
    }

    func close() {
        lock.lock()
        let current = handle
        handle = nil
        closed = true
        lock.unlock()
        if let current {
            sc_usb_close(current)
        }
    }

    deinit { close() }

    // MARK: - I/O

    func readHandshakeBytes(_ count: Int) throws -> Data {
        do {
            let data = try readChunk(timeout: 2000)
            guard data.count >= count else { throw UsbError.shortRead }
            return data.prefix(count)
        } catch UsbError.timeout {
            throw UsbError.noHello
        }
    }

    func readUnit() throws -> Data? {
        while true {
            do {
                return try readChunk(timeout: 1000)
            } catch UsbError.timeout {
                if isClosed { return nil }
                continue
            }
        }
    }

    func write(_ data: Data) throws {
        guard let handle else { throw UsbError.notConnected }
        let written = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return sc_usb_write(handle, base, Int32(data.count))
        }
        guard written == Int32(data.count) else {
            throw UsbError.ioFailed(IOReturn(bitPattern: sc_usb_last_status(handle)))
        }
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func readChunk(timeout: Int32) throws -> Data {
        guard let handle else { throw UsbError.notConnected }
        if readBuffer.isEmpty {
            readBuffer = [UInt8](repeating: 0, count: Self.transferSize)
        }
        let read = readBuffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return sc_usb_read(handle, base, Int32(Self.transferSize), timeout)
        }
        if read > 0 {
            return Data(readBuffer[0..<Int(read)])
        }
        if read == Int32(SC_USB_ERR_TIMEOUT) { throw UsbError.timeout }
        if read == Int32(SC_USB_ERR_CLOSED) { throw UsbError.closed }
        throw UsbError.ioFailed(IOReturn(bitPattern: sc_usb_last_status(handle)))
    }

    private static func error(for code: Int32) -> UsbError {
        switch code {
        case Int32(SC_USB_ERR_NOT_FOUND): return .notFound
        case Int32(SC_USB_ERR_NO_INTERFACE): return .noInterface
        case Int32(SC_USB_ERR_NO_ENDPOINT): return .noEndpoints
        case Int32(SC_USB_ERR_BUSY):
            return .openFailed("设备被占用（官方客户端可能正在运行）")
        default:
            return .openFailed("IOUSBLib 打不开设备（错误码 \(code)）")
        }
    }
}

/// USB 传输入口：先走现代 IOUSBHost，失败再退回 IOUSBLib 老栈。
/// macOS 13+ 上接口会以 IOUSBHostInterface 发布；macOS 12 上只有老式 IOUSBInterface。
final class USBTransportFacade: StreamTransport {
    private var impl: StreamTransport?

    var onLog: ((String) -> Void)? {
        didSet {
            (impl as? UsbTransport)?.onLog = onLog
            (impl as? LegacyUSBTransport)?.onLog = onLog
        }
    }

    var name: String {
        if let modern = impl as? UsbTransport { return modern.name }
        if let legacy = impl as? LegacyUSBTransport { return legacy.name }
        return "USB"
    }

    func connect() throws {
        // macOS 12 及更早：接口被 AppleUSBHostLegacyClient 占着，现代路径能"打开"但一读就报
        // "Unable to enqueue IO"，所以这里按系统版本选路，而不是等失败再回退。
        let preferModern: Bool
        if #available(macOS 13.0, *) {
            preferModern = true
        } else {
            preferModern = false
        }

        let modern = UsbTransport()
        modern.onLog = onLog
        let legacy = LegacyUSBTransport()
        legacy.onLog = onLog

        if preferModern {
            do {
                try modern.connect()
                impl = modern
                return
            } catch {
                onLog?("[USB] 现代路径不可用（\(error.localizedDescription)），改用 IOUSBLib 老栈")
                try legacy.connect()
                impl = legacy
            }
        } else {
            // 这台系统上绝不能回退到现代路径：IOUSBHost 一碰这个设备就会触发重新枚举，
            // 设备直接从总线上消失（实测过两次），所以老栈失败就直接报错。
            try legacy.connect()
            impl = legacy
        }
    }

    func close() {
        impl?.close()
        impl = nil
    }

    func write(_ data: Data) throws {
        guard let impl else { throw UsbError.notConnected }
        try impl.write(data)
    }

    func readHandshakeBytes(_ count: Int) throws -> Data {
        guard let impl else { throw UsbError.notConnected }
        return try impl.readHandshakeBytes(count)
    }

    func readUnit() throws -> Data? {
        guard let impl else { return nil }
        return try impl.readUnit()
    }
}
