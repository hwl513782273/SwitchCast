import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var controller: StreamController

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                playerArea
                Divider()
                sidePanel
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 品牌头

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = NSImage(named: NSImage.Name("AppIcon")) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .cornerRadius(8)
            }
            Text("Switch Cast")
                .font(.title2.bold())
            Text("v\(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { (NSApp.delegate as? AppDelegate)?.showSettings() }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")

            Button(action: { (NSApp.delegate as? AppDelegate)?.showAbout() }) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("关于")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 画面区

    private var playerArea: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            playerContent
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerContent: some View {
        ZStack {
            Color.black
            VideoDisplay(sink: controller.sink)

            switch controller.phase {
            case .idle:
                idleOverlay()
            case .failed(let message):
                idleOverlay(error: message)
            case .connecting:
                connectingOverlay
            case .live:
                liveOverlay
            }
        }
    }

    private var liveOverlay: some View {
        VStack {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())

                if controller.resolution.width > 0 {
                    Text("\(Int(controller.resolution.width))×\(Int(controller.resolution.height)) · \(Int(controller.stats.fps)) fps")
                        .font(.system(size: 11, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45))
                        .clipShape(Capsule())
                }

                if controller.isRecording {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text("REC \(formatDuration(controller.recordingElapsed))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(12)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    controller.takeScreenshot()
                } label: {
                    Label("截图", systemImage: "camera")
                }
                .help("保存 PNG 到桌面（⌘⇧S）")
                .buttonStyle(.bordered)

                Button {
                    controller.toggleRecording()
                } label: {
                    Label(controller.isRecording ? "停止录制" : "录屏",
                          systemImage: controller.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .help(controller.recordAudio ? "录制画面与声音（⌘⇧R）" : "录制无声画面（⌘⇧R）")
                .buttonStyle(.bordered)

                Button {
                    (NSApp.delegate as? AppDelegate)?.enterImmersive()
                } label: {
                    Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("只看画面（Esc 退出）")
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive) {
                    controller.disconnect()
                } label: {
                    Label("断开", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.black.opacity(0.35))
        }
        .transition(.opacity)
    }

    private var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.1)
            Text("正在连接 \(controller.host.isEmpty ? "USB 设备" : controller.host)…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
            Text("若提示「本地网络」权限，请在系统设置中允许本 App 访问局域网")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - 未连接状态

    private func idleOverlay(error: String? = nil) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.85))

            VStack(spacing: 6) {
                Text(error == nil ? "把 Switch 画面接到 Mac" : "没连上")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                } else {
                    Text("720p30 直采，无需采集卡。局域网或 USB 直连均可")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if !controller.consoles.isEmpty {
                VStack(spacing: 6) {
                    ForEach(controller.consoles) { console in
                        Button {
                            controller.select(console: console)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "wifi")
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(console.serial)
                                        .font(.system(size: 12, weight: .medium))
                                    Text("\(console.address) · 协议 \(console.protocolVersion)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer()
                                Text("连接")
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(width: 320)
                            .background(.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
            }

            if !controller.usbDevices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(controller.usbDevices, id: \.self) { serial in
                        Button {
                            controller.connectUSB()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "cable.connector")
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(serial)
                                        .font(.system(size: 12, weight: .medium))
                                    Text("USB 直连 · 已识别")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer()
                                Text("连接")
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(width: 320)
                            .background(.white.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("192.168.1.x", text: $controller.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 168)
                Button("连接") {
                    controller.connect()
                }
                .keyboardShortcut(.return, modifiers: [])
            }

            Text("Switch 端：SysDVR 设置 → 网络模式选 TCP Bridge；USB 模式需掌机状态且用 USB-A→C 线")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
    }

    // MARK: - 侧栏

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionSection
                Divider()
                statusSection
                Divider()
                audioSection
                Divider()
                logSection
            }
            .padding(14)
        }
        .frame(width: 272)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("连接方式")

            Picker("", selection: $controller.transport) {
                ForEach(SysDVRConnection.TransportKind.allCases) { kind in
                    Text(kind == .network ? "网络" : "USB").tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.phase == .live)

            if controller.transport == .network {
                TextField("Switch IP", text: $controller.host)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.phase == .live)
            } else {
                Text("USB 仅掌机模式可用，插底座不走该通道")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if controller.phase == .live || controller.phase == .connecting {
                    Button("断开") { controller.disconnect() }
                        .frame(maxWidth: .infinity)
                } else {
                    Button("开始串流") { controller.connect() }
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
            .controlSize(.regular)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("状态")

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(controller.phase.title)
                    .font(.system(size: 12, weight: .medium))
            }

            statRow("分辨率", controller.resolution.width > 0
                    ? "\(Int(controller.resolution.width))×\(Int(controller.resolution.height))"
                    : "—")
            statRow("帧率", controller.stats.fps > 0 ? String(format: "%.0f fps", controller.stats.fps) : "—")
            statRow("码率", controller.stats.mbps > 0 ? String(format: "%.1f Mbps", controller.stats.mbps) : "—")
            statRow("累计帧", "\(controller.stats.frames)")
            statRow("协议", controller.protocolVersion.isEmpty ? "—" : controller.protocolVersion)
            statRow("运行", formatDuration(controller.stats.elapsed))
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("音频")
            Toggle("启用音频", isOn: $controller.audioEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)

            HStack(spacing: 8) {
                Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Slider(value: $controller.volume, in: 0...1)
            }
            Toggle("静音", isOn: $controller.muted)
                .toggleStyle(.checkbox)
                .font(.caption)

            Divider()

            Toggle("录屏包含音频", isOn: $controller.recordAudio)
                .toggleStyle(.checkbox)
                .font(.caption)
            Text("录制文件保存到桌面（MP4，H.264 直通不重编码）")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("日志")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logs.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(height: 128)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - 小工具

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return .gray
        case .connecting: return .orange
        case .live: return .green
        case .failed: return .red
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
