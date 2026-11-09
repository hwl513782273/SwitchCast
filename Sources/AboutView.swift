import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: NSImage.Name("AppIcon")) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 88, height: 88)
            }

            VStack(spacing: 4) {
                Text("Switch Cast")
                    .font(.title2.bold())
                Text("v\(version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("把 Nintendo Switch 的画面低延迟接到 Mac。\n基于 SysDVR 公开的线路协议实现，无任何第三方二进制依赖。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 4) {
                bullet("720p30 H.264 硬件解码，PCM 48kHz 音频")
                bullet("网络走 TCP Bridge（9911/9922），USB 走 IOUSBHost")
                bullet("自动发现局域网主机，无需手填 IP")
            }
            .frame(maxWidth: 320, alignment: .leading)

            Divider()

            Text("本项目以 GPL-2.0 发布。协议实现参考 exelix11/SysDVR（GPL-2.0）的公开文档与 sysmodule 源码，为独立的 Swift 原生重写。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Link("打开 SysDVR 项目主页", destination: URL(string: "https://github.com/exelix11/SysDVR")!)
                .font(.caption)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 440)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
