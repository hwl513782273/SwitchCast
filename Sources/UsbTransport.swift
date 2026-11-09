import Foundation
import IOUSBHost
import IOKit

/// SysDVR USB 传输层
/// 设备伪装成 Google fastboot（VID 18D1 / PID 4EE0），靠 serial 描述符前缀 "SysDVR|" 区分真机
/// 单一接口 + 单对 bulk 端点（0x81 IN / 0x01 OUT），音视频复用同一流，由包头 MetaData 区分
///
/// 注意：macOS 的 IOUSBHostInterface 服务**不携带 idVendor/idProduct**，
/// 直接按 VID/PID 匹配 interface 会得到 0 个结果；必须按 VID/PID 匹配 IOUSBHostDevice，
/// 再顺着 kIOServicePlane 找它的子接口服务。
final class UsbTransport: StreamTransport {
    private static let vendorID = 0x18D1
    private static let productID = 0x4EE0
    private static let serialPrefix = "SysDVR|"

    /// 单次 bulk 传输上限：包头 + max(VbufSz, AbufSz * (1 + MaxABatching))
    private static let transferSize = SysDVR.headerSize + max(SysDVR.maxVideoPayload, SysDVR.maxAudioPayload)

    private var device: IOUSBHostDevice?
    private var hostInterface: IOUSBHostInterface?
    private var inPipe: IOUSBHostPipe?
    private var outPipe: IOUSBHostPipe?
    private var readBuffer: NSMutableData?
    private var serial = ""
    private let opLock = NSLock()
    private var closed = false

    var onLog: ((String) -> Void)?

    /// 只读探测：列出当前插着的 SysDVR 设备（不打开、不占用）
    static func detectDevices() -> [String] {
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        match["idVendor"] = vendorID
        match["idProduct"] = productID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match as CFMutableDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var serials: [String] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let serial = Self.serialString(forService: service)
            if serial.hasPrefix(serialPrefix) { serials.append(serial) }
        }
        return serials
    }


    var name: String {
        serial.isEmpty ? "USB" : "USB · \(serial)"
    }

    // MARK: - 连接

    func connect() throws {
        let service = try findDeviceService()
        defer { IOObjectRelease(service) }

        serial = Self.serialString(forService: service)
        guard serial.hasPrefix(Self.serialPrefix) else {
            throw UsbError.notFound
        }
        log("找到设备 \(serial)")

        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw UsbError.openFailed("\(error.localizedDescription)。若官方 SysDVR-Client 正在运行，请先退出它（同一时间只能有一个程序占用设备）")
        }

        guard let interface = try openChildInterface(of: service) else {
            throw UsbError.noEndpoints
        }
        hostInterface = interface

        let endpoints = Self.bulkEndpoints(configuration: interface.configurationDescriptor)
        guard let inAddress = endpoints.input, let outAddress = endpoints.output else {
            throw UsbError.noEndpoints
        }
        log("端点 IN=0x\(String(inAddress, radix: 16)) OUT=0x\(String(outAddress, radix: 16))")

        do {
            inPipe = try interface.copyPipe(withAddress: Int(inAddress))
            outPipe = try interface.copyPipe(withAddress: Int(outAddress))
        } catch {
            throw UsbError.pipeFailed(error.localizedDescription)
        }

        readBuffer = try interface.ioData(withCapacity: Self.transferSize)
    }

    func close() {
        opLock.lock()
        closed = true
        opLock.unlock()
        inPipe = nil
        outPipe = nil
        readBuffer = nil
        hostInterface?.destroy()
        hostInterface = nil
        device?.destroy()
        device = nil
    }

    // MARK: - I/O

    func readHandshakeBytes(_ count: Int) throws -> Data {
        do {
            let data = try readUnitInternal(timeout: 2)
            guard data.count >= count else { throw UsbError.shortRead }
            return data.prefix(count)
        } catch UsbError.timeout {
            throw UsbError.noHello
        }
    }

    func readUnit() throws -> Data? {
        while true {
            do {
                return try readUnitInternal(timeout: 1)
            } catch UsbError.timeout {
                if isClosed { return nil }
                continue    // 没数据（例如还没进游戏），继续等
            }
        }
    }

    func write(_ data: Data) throws {
        guard let outPipe else { throw UsbError.notConnected }

        // 写入的缓冲必须与设备 ioData 对齐；短包用普通 NSMutableData 即可
        let payload = NSMutableData(data: data)

        opLock.lock()
        defer { opLock.unlock() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: IOReturn = kIOReturnError
        var transferred = 0

        try outPipe.enqueueIORequest(with: payload, completionTimeout: 2) { status, bytes in
            result = status
            transferred = bytes
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            throw UsbError.timeout
        }
        guard result == kIOReturnSuccess, transferred == data.count else {
            throw UsbError.ioFailed(result)
        }
    }

    private var isClosed: Bool {
        opLock.lock(); defer { opLock.unlock() }
        return closed
    }

    private func readUnitInternal(timeout: TimeInterval) throws -> Data {
        guard let inPipe, let readBuffer else { throw UsbError.notConnected }
        guard !isClosed else { throw UsbError.closed }

        opLock.lock()
        defer { opLock.unlock() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: IOReturn = kIOReturnError
        var transferred = 0

        try inPipe.enqueueIORequest(with: readBuffer, completionTimeout: timeout) { status, bytes in
            result = status
            transferred = bytes
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            throw UsbError.timeout
        }
        switch result {
        case kIOReturnSuccess:
            guard transferred > 0 else { throw UsbError.timeout }
            return Data(bytes: readBuffer.bytes, count: transferred)
        case kIOReturnTimeout:
            throw UsbError.timeout
        default:
            throw UsbError.ioFailed(result)
        }
    }

    // MARK: - 设备查找

    /// 按 VID/PID 拿 IOUSBHostDevice 服务（interface 服务没有 VID/PID 属性）
    private func findDeviceService() throws -> io_service_t {
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        match["idVendor"] = Self.vendorID
        match["idProduct"] = Self.productID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match as CFMutableDictionary, &iterator) == KERN_SUCCESS else {
            throw UsbError.notFound
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if Self.serialString(forService: service).hasPrefix(Self.serialPrefix) {
                return service        // 交给调用方释放
            }
            IOObjectRelease(service)
        }
        throw UsbError.notFound
    }

    /// 设备子节点里找 IOUSBHostInterface 并打开
    private func openChildInterface(of deviceService: io_service_t) throws -> IOUSBHostInterface? {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while true {
            let child = IOIteratorNext(childIterator)
            if child == 0 { break }

            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(child, &className)
            guard String(cString: className) == "IOUSBHostInterface" else {
                IOObjectRelease(child)
                continue
            }

            do {
                // 成功后不释放 child：IOUSBHostInterface 会持有该 io_service
                return try IOUSBHostInterface(__ioService: child, options: [], queue: nil, interestHandler: nil)
            } catch {
                IOObjectRelease(child)
                throw UsbError.openFailed("\(error.localizedDescription)。若官方 SysDVR-Client 正在运行，请先退出它（同一时间只能有一个程序占用设备）")
            }
        }
        return nil
    }

    /// sysmodule 把序列号写成 "SysDVR|6.3|03|SERIAL"
    private static func serialString(forService service: io_service_t) -> String {
        let key = "USB Serial Number" as CFString
        if let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return value
        }
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            if let value = IORegistryEntryCreateCFProperty(parent, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                return value
            }
        }
        return ""
    }

    private static func bulkEndpoints(configuration: UnsafePointer<IOUSBConfigurationDescriptor>) -> (input: UInt8?, output: UInt8?) {
        let total = Int(configuration.pointee.wTotalLength)
        guard total > 0 else { return (nil, nil) }

        let bytes = UnsafeRawPointer(configuration).bindMemory(to: UInt8.self, capacity: total)
        var index = 0
        var input: UInt8?
        var output: UInt8?

        while index + 2 <= total {
            let length = Int(bytes[index])
            let type = bytes[index + 1]
            if length <= 0 { break }

            if type == 5, length >= 7, index + 6 < total {
                let address = bytes[index + 2]
                let attributes = bytes[index + 3]
                if attributes & 0x03 == 0x02 {          // bulk
                    if address & 0x80 != 0 {
                        if input == nil { input = address }
                    } else {
                        if output == nil { output = address }
                    }
                }
            }
            index += length
        }
        return (input, output)
    }

    private func log(_ message: String) {
        onLog?("[USB] \(message)")
    }
}

// MARK: - 错误

enum UsbError: LocalizedError {
    case notFound
    case openFailed(String)
    case noEndpoints
    case pipeFailed(String)
    case bufferFailed
    case notConnected
    case closed
    case timeout
    case shortRead
    case noHello
    case ioFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到 SysDVR USB 设备（确认已插线、未在底座上、Switch 端 SysDVR 设为 USB 模式）"
        case .openFailed(let detail):
            return "USB 设备打开失败：\(detail)"
        case .noEndpoints:
            return "USB 接口缺少 bulk 端点"
        case .pipeFailed(let detail):
            return "USB 端点打开失败：\(detail)"
        case .bufferFailed:
            return "USB 缓冲区分配失败"
        case .notConnected:
            return "USB 未连接"
        case .closed:
            return "USB 连接已关闭"
        case .timeout:
            return "USB 传输超时"
        case .shortRead:
            return "USB 握手数据不完整"
        case .noHello:
            return "已找到 USB 设备，但控制台没有回应。请确认 Switch 上 SysDVR 设置里的模式是 USB（不是 TCP Bridge），然后重新插拔一次数据线"
        case .ioFailed(let code):
            return String(format: "USB 传输错误 0x%08X", code)
        }
    }
}
