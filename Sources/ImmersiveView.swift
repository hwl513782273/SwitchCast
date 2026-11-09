import SwiftUI
import AppKit

/// 无边框窗口：borderless 默认不能成为 key window，这里打开
final class ImmersiveWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 只显示游戏画面的独占全屏
struct ImmersiveView: View {
    @ObservedObject var controller: StreamController
    let sink: VideoSink

    @State private var hudVisible = true
    @State private var hideToken = UUID()

    var body: some View {
        ZStack {
            Color.black
            VideoDisplay(sink: sink)
                .ignoresSafeArea()

            if hudVisible {
                overlay
                    .transition(.opacity)
            }

            if controller.phase != .live {
                disconnectedHint
            }
        }
        .background(Color.black)
        .onAppear { pokeHUD() }
        .onReceive(NotificationCenter.default.publisher(for: .immersiveMouseMoved)) { _ in
            pokeHUD()
        }
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.phase == .live ? Color.red : Color.gray)
                    .frame(width: 7, height: 7)
                Text(controller.phase == .live ? "LIVE" : "已断开")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                if controller.resolution.width > 0 {
                    Text("\(Int(controller.resolution.width))×\(Int(controller.resolution.height)) · \(Int(controller.stats.fps)) fps")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    (NSApp.delegate as? AppDelegate)?.exitImmersive()
                } label: {
                    Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))

                Button {
                    controller.disconnect()
                    (NSApp.delegate as? AppDelegate)?.exitImmersive()
                } label: {
                    Label("断开", systemImage: "stop.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Text("Esc 退出 · 移动鼠标显示控制条")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.35))
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var disconnectedHint: some View {
        VStack(spacing: 10) {
            Text("画面已停止")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Text("按 Esc 或点下方按钮退出全屏")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Button("退出全屏") {
                (NSApp.delegate as? AppDelegate)?.exitImmersive()
            }
            .controlSize(.regular)
        }
        .padding(20)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 显示控制条并在 2.5 秒后自动淡出
    private func pokeHUD() {
        withAnimation(.easeOut(duration: 0.15)) { hudVisible = true }
        let token = UUID()
        hideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard hideToken == token else { return }
            withAnimation(.easeIn(duration: 0.35)) { hudVisible = false }
        }
    }
}

extension Notification.Name {
    static let immersiveMouseMoved = Notification.Name("SwitchCastImmersiveMouseMoved")
}
