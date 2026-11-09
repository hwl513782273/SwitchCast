import SwiftUI
import AppKit
import QuartzCore

/// 承载解码帧的视图（避免 SwiftUI 每帧重绘，直接写 CALayer.contents）
final class VideoDisplayView: NSView {
    private let imageLayer = CALayer()
    private var lastImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    /// 视图被移出/移回窗口（例如进出全屏、窗口重建）时，自动重放最后一帧
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let lastImage {
            show(lastImage)
        }
    }

    func show(_ image: CGImage) {
        lastImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func clear() {
        lastImage = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }
}

/// 控制器与视图之间的帧通道
final class VideoSink {
    /// 主窗口和全屏窗口可能同时存在同一个 sink，必须广播给所有活着的视图。
    /// 只留一个 weak 引用会导致「退出全屏后主窗口一片黑」。
    private final class WeakView {
        weak var value: VideoDisplayView?
        init(_ value: VideoDisplayView) { self.value = value }
    }

    private var views: [WeakView] = []
    private(set) var lastImage: CGImage?

    func attach(_ view: VideoDisplayView) {
        views.removeAll { $0.value == nil }
        if !views.contains(where: { $0.value === view }) {
            views.append(WeakView(view))
        }
        if let lastImage {
            view.show(lastImage)
        }
    }

    func push(_ image: CGImage) {
        lastImage = image
        views.removeAll { $0.value == nil }
        for entry in views {
            entry.value?.show(image)
        }
    }

    func clear() {
        lastImage = nil
        views.removeAll { $0.value == nil }
        for entry in views {
            entry.value?.clear()
        }
    }
}

struct VideoDisplay: NSViewRepresentable {
    let sink: VideoSink

    func makeNSView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView(frame: .zero)
        sink.attach(view)
        return view
    }

    func updateNSView(_ nsView: VideoDisplayView, context: Context) {
        sink.attach(nsView)
    }
}
