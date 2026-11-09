import Foundation
import CoreGraphics
import AppKit

// 离线解码验证：把 mock 素材按访问单元喂给 H264Decoder，看是否有帧产出
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/sc_test.h264"
let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/harness_frame.png"

let data = try Data(contentsOf: URL(fileURLWithPath: path))
let nals = H264Decoder.nalUnits(in: [UInt8](data))

var units: [Data] = []
var current: [UInt8] = []

for nal in nals {
    guard let header = nal.first else { continue }
    let type = header & 0x1F
    if type == 9 {
        if !current.isEmpty {
            units.append(Data(current))
            current = []
        }
        continue
    }
    current.append(contentsOf: [0, 0, 0, 1])
    current.append(contentsOf: nal)
}
if !current.isEmpty { units.append(Data(current)) }

print("NAL \(nals.count) 个，访问单元 \(units.count) 个，首个 \(units.first?.count ?? 0) 字节")

var frameCount = 0
var lastImage: CGImage?
let decoder = H264Decoder()
decoder.onFrame = { image in
    frameCount += 1
    lastImage = image
}
decoder.onResolution = { size in
    print("分辨率 \(Int(size.width))x\(Int(size.height))")
}
decoder.onFailure = { message in
    print("解码失败：\(message)")
}

for unit in units {
    decoder.handle(packet: unit)
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
}
RunLoop.main.run(until: Date().addingTimeInterval(1.5))

print("解出帧数：\(frameCount)")
if let lastImage {
    let bitmap = NSBitmapImageRep(cgImage: lastImage)
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: output))
        print("已写入 \(output) \(lastImage.width)x\(lastImage.height)")
    }
} else {
    print("没有帧可写")
}
