import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = StreamController()

    private var mainWC: NSWindowController?
    private var settingsWC: NSWindowController?
    private var aboutWC: NSWindowController?
    private var immersiveWindow: ImmersiveWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildMainWindow()

        let env = ProcessInfo.processInfo.environment
        if env["OPEN_ABOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showAbout() }
        }
        if env["OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showSettings() }
        }
        if let raw = env["IMMERSIVE_AFTER"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enterImmersive()
            }
        }
        if let shotPath = env["WINDOW_SHOT"], !shotPath.isEmpty {
            let delay = Double(env["WINDOW_SHOT_AFTER"] ?? "6") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.captureWindow(to: shotPath)
            }
        }
    }

    /// 自渲染窗口截图（不依赖屏幕录制权限），仅用于构建验证
    private func captureWindow(to path: String) {
        let target = NSApp.keyWindow ?? immersiveWindow ?? mainWC?.window
        guard let window = target, let view = window.contentView else { return }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window.backingScaleFactor
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width * scale),
            height: Int(bounds.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        context.scaleBy(x: scale, y: scale)
        // CGContext 原点在左下，CALayer 渲染需要翻转成左上原点
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        if let layer = view.layer {
            layer.render(in: context)
        } else {
            view.draw(bounds)
        }

        guard let image = context.makeImage() else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("[SwitchCast] window shot saved \(path) \(image.width)x\(image.height)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSApp.presentationOptions = []
        controller.disconnect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 菜单

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Switch Cast", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Switch Cast", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Switch Cast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "开始串流", action: #selector(startStreaming), keyEquivalent: "r")
        let fullScreenItem = NSMenuItem(title: "全屏", action: #selector(toggleFullScreen), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.insertItem(fullScreenItem, at: 0)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - 主窗口

    private func buildMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Switch Cast"
        window.minSize = NSSize(width: 900, height: 560)
        window.titlebarAppearsTransparent = false
        window.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingController(
            rootView: ContentView().environmentObject(controller)
        )
        window.contentView = hosting.view
        window.center()

        let holder = NSWindowController(window: window)
        mainWC = holder
        holder.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 真正的「只看游戏」全屏：无边框窗口铺满屏幕，隐藏标题栏/侧栏，控制条自动淡出
    @objc func enterImmersive() {
        guard immersiveWindow == nil else { return }
        guard let screen = mainWC?.window?.screen ?? NSScreen.main else { return }

        let window = ImmersiveWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(
            rootView: ImmersiveView(controller: controller, sink: controller.sink)
        )
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        NSApp.activate(ignoringOtherApps: true)
        mainWC?.window?.orderOut(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {          // Esc
                self?.exitImmersive()
                return nil
            }
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            NotificationCenter.default.post(name: .immersiveMouseMoved, object: nil)
            return event
        }

        immersiveWindow = window
    }

    @objc func exitImmersive() {
        guard immersiveWindow != nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil

        NSApp.presentationOptions = []
        immersiveWindow?.orderOut(nil)
        immersiveWindow = nil

        mainWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleFullScreen() {
        if immersiveWindow != nil {
            exitImmersive()
        } else {
            enterImmersive()
        }
    }

    @objc func startStreaming() {
        controller.connect()
    }

    // MARK: - 设置 / 关于

    @objc func showSettings() {
        if settingsWC == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置"
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingController(rootView: SettingsView()).view
            settingsWC = NSWindowController(window: window)
        }
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        let _ = try? "opened at \(Date())\n".write(
            to: URL(fileURLWithPath: "/tmp/switchcast_about_opened.txt"),
            atomically: true, encoding: .utf8
        )
        if aboutWC == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "关于 Switch Cast"
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingController(rootView: AboutView()).view
            aboutWC = NSWindowController(window: window)
        }
        aboutWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
