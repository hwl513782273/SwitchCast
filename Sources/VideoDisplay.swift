import SwiftUI
import AppKit
import QuartzCore

/// 承载解码帧的视图（避免 SwiftUI 每帧重绘，直接写 CALayer.contents）
final class VideoDisplayView: NSView {
    private let imageLayer = CALayer()

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

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }
}

/// 控制器与视图之间的帧通道
final class VideoSink {
    private weak var view: VideoDisplayView?
    private(set) var lastImage: CGImage?

    func attach(_ view: VideoDisplayView) {
        self.view = view
        if let lastImage {
            view.show(lastImage)
        }
    }

    func push(_ image: CGImage) {
        lastImage = image
        view?.show(image)
    }

    func clear() {
        lastImage = nil
        view?.clear()
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
