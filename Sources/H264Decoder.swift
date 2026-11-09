import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage

/// H.264 Annex-B 流 → VideoToolbox 解码 → CGImage
/// SysDVR 视频包内是裸 H.264（可能含多个 NAL），参数集靠 InjectPPSSPS 周期性注入
final class H264Decoder {
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var frameIndex: Int64 = 0
    private var currentSize: CGSize = .zero

    var onFrame: ((CGImage) -> Void)?
    /// 解码前的压缩样本（录屏直通复用，避免重新编码）
    var onSample: ((CMSampleBuffer) -> Void)?
    var onResolution: ((CGSize) -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var isConfigured = false
    /// 当前 H.264 格式描述（录屏建直通轨用）
    private(set) var videoFormatDescription: CMVideoFormatDescription?

    func reset() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        videoFormatDescription = nil
        sps = nil
        pps = nil
        frameIndex = 0
        currentSize = .zero
        isConfigured = false
    }

    func handle(packet: Data) {
        let bytes = [UInt8](packet)
        let nals = Self.nalUnits(in: bytes)
        guard !nals.isEmpty else { return }

        var vcl: [ArraySlice<UInt8>] = []
        var paramsChanged = false

        for nal in nals {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7:
                let value = Array(nal)
                if sps != value { sps = value; paramsChanged = true }
            case 8:
                let value = Array(nal)
                if pps != value { pps = value; paramsChanged = true }
            case 1, 5, 6:
                vcl.append(nal)
            default:
                break
            }
        }

        if paramsChanged || session == nil {
            configureIfPossible()
        }

        guard !vcl.isEmpty else { return }
        guard isConfigured else { return }
        guard let sample = makeSampleBuffer(nals: vcl) else {
            onFailure?("采样缓冲创建失败")
            return
        }
        onSample?(sample)
        decode(sample)
    }

    // MARK: - 参数集 / 会话

    private func configureIfPossible() {
        guard let sps, let pps else { return }

        var description: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                guard let spsBase = spsBuffer.baseAddress, let ppsBase = ppsBuffer.baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }

        guard let description else { return }
        formatDescription = description
        videoFormatDescription = description

        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )

        guard status == noErr, let newSession else {
            onFailure?("解码器初始化失败（\(status)）")
            return
        }
        session = newSession
        isConfigured = true

        let size = CMVideoFormatDescriptionGetDimensions(description)
        let resolved = CGSize(width: Int(size.width), height: Int(size.height))
        if resolved != currentSize {
            currentSize = resolved
            DispatchQueue.main.async { [weak self] in
                self?.onResolution?(resolved)
            }
        }
    }

    // MARK: - 采样

    private func makeSampleBuffer(nals: [ArraySlice<UInt8>]) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var payload = [UInt8]()
        payload.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            // AVCC 长度前缀必须是大端（network order）
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: nal)
        }

        let total = payload.count
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: total,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: total,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: total
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )
        frameIndex += 1

        var sampleSize = total
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }

    private func decode(_ sampleBuffer: CMSampleBuffer) {
        guard let session else { return }
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            infoFlagsOut: nil
        ) { [weak self] status, flags, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                self.onFailure?("解码回调失败 status=\(status) flags=\(flags.rawValue)")
                return
            }
            let image = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = self.ciContext.createCGImage(image, from: image.extent) else {
                self.onFailure?("帧转换 CGImage 失败")
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(cgImage)
            }
        }

        if status != noErr {
            onFailure?("送帧解码失败（\(status)）")
        }
    }

    // MARK: - NAL 切分

    /// 返回 Annex-B 起始码之间的 NAL 单元（已去掉起始码与尾部零字节）
    static func nalUnits(in bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var markers: [(start: Int, codeLength: Int)] = []
        var index = 0
        let count = bytes.count
        while index + 3 <= count {
            if index + 4 <= count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                markers.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                markers.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !markers.isEmpty else { return [] }

        var units: [ArraySlice<UInt8>] = []
        for (offset, marker) in markers.enumerated() {
            let start = marker.start + marker.codeLength
            let limit = offset + 1 < markers.count ? markers[offset + 1].start : count
            var end = limit
            while end > start && bytes[end - 1] == 0 { end -= 1 }
            if end > start { units.append(bytes[start..<end]) }
        }
        return units
    }
}
