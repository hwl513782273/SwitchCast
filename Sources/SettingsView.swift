import SwiftUI

struct SettingsView: View {
    @AppStorage("rememberHost") private var rememberHost = true
    @AppStorage("defaultTransport") private var defaultTransport = "network"
    @AppStorage("audioEnabledDefault") private var audioEnabledDefault = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("常规")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Toggle("记住上次连接的地址", isOn: $rememberHost)
            Toggle("默认开启音频", isOn: $audioEnabledDefault)

            Picker("默认连接方式", selection: $defaultTransport) {
                Text("网络").tag("network")
                Text("USB").tag("usb")
            }
            .pickerStyle(.segmented)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("提示")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("· Switch 端需在 SysDVR 设置里把网络模式切到 TCP Bridge\n· USB 模式只在掌机状态可用，线材用 USB-A→C 更稳\n· 首次连接会请求「本地网络」权限，拒绝后只能手填 IP 也连不上")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 380, height: 320, alignment: .topLeading)
    }
}
