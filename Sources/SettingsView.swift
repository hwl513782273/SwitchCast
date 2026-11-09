import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("rememberHost") private var rememberHost = true
    @AppStorage("defaultTransport") private var defaultTransport = "usb"
    @AppStorage("audioEnabledDefault") private var audioEnabledDefault = true
    @AppStorage("recordFolderPath") private var recordFolderPath = ""

    private var folderDisplay: String {
        if recordFolderPath.isEmpty {
            return "影片（默认）"
        }
        return recordFolderPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("常规")

            Toggle("记住上次连接的地址", isOn: $rememberHost)
            Toggle("默认开启音频", isOn: $audioEnabledDefault)

            Picker("默认连接方式", selection: $defaultTransport) {
                Text("USB").tag("usb")
                Text("网络").tag("network")
            }
            .pickerStyle(.segmented)

            Divider()

            sectionTitle("保存位置")

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(folderDisplay)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folderDisplay)
                Spacer(minLength: 6)
                Button("选择…") { chooseFolder() }
                    .controlSize(.small)
                Button("默认") { recordFolderPath = "" }
                    .controlSize(.small)
                    .disabled(recordFolderPath.isEmpty)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("· 录屏（MP4）保存在上面这个文件夹，默认是「影片」")
                Text("· 截图（PNG）固定在桌面，方便随手取")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            Divider()

            sectionTitle("提示")

            Text("· Switch 端需在 SysDVR 设置里把模式设为 USB 或 TCP Bridge\n· USB 只在掌机状态可用，线材用 USB-A→C 更稳\n· 首次连接会请求「本地网络」权限，拒绝后连局域网会失败")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 400, height: 400, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择录屏保存文件夹"
        panel.directoryURL = Recorder.recordFolder
        if panel.runModal() == .OK, let url = panel.url {
            recordFolderPath = url.path
        }
    }
}
