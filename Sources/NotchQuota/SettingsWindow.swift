import AppKit
import ServiceManagement

// 设置窗口:开机自启开关 + 完全退出按钮
// 关窗口不会退出 app(刘海功能继续运行),只有点"完全退出"才终止进程
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var launchSwitch: NSSwitch?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 固定合理的窗口尺寸(经过布局计算,比例协调)
        let W: CGFloat = 380, H: CGFloat = 470
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .vibrantDark)
        let bg = NSColor(white: 0.09, alpha: 1)
        w.backgroundColor = bg
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = bg.cgColor

        // ════════ 用 frame 精确定位每个元素(不用 Auto Layout,避免 fittingSize 不确定) ════════
        // 坐标系:root 左下角为原点,y 向上

        // ── 头部:图标 + 名称 + 副标题(顶部 36pt 起) ──
        let iconSize: CGFloat = 88
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: (W - iconSize) / 2, y: H - 36 - iconSize,
                            width: iconSize, height: iconSize)

        let nameLbl = NSTextField(labelWithString: "NotchQuota")
        nameLbl.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLbl.textColor = .white
        nameLbl.alignment = .center
        nameLbl.sizeToFit()
        nameLbl.frame.origin = NSPoint(x: (W - nameLbl.frame.width) / 2,
                                       y: icon.frame.minY - 28)

        let subLbl = NSTextField(labelWithString: "刘海用量监控")
        subLbl.font = .systemFont(ofSize: 12)
        subLbl.textColor = NSColor(white: 0.6, alpha: 1)
        subLbl.alignment = .center
        subLbl.sizeToFit()
        subLbl.frame.origin = NSPoint(x: (W - subLbl.frame.width) / 2,
                                      y: nameLbl.frame.minY - 20)

        // ── 卡片通用绘制函数 ──
        let cardInset: CGFloat = 28
        let cardW = W - cardInset * 2
        func makeCard(y: CGFloat, h: CGFloat) -> NSView {
            let v = NSView(frame: NSRect(x: cardInset, y: y, width: cardW, height: h))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
            v.layer?.cornerRadius = 14
            v.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
            v.layer?.borderWidth = 0.5
            return v
        }

        // ── 开机自启卡片 ──
        let launchH: CGFloat = 72
        let launchY = subLbl.frame.minY - 32 - launchH
        let launchCard = makeCard(y: launchY, h: launchH)

        let launchTitle = NSTextField(labelWithString: "通用")
        launchTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        launchTitle.textColor = NSColor(white: 0.45, alpha: 1)
        launchTitle.sizeToFit()
        launchTitle.frame.origin = NSPoint(x: 16, y: launchH - 26)

        let mainLbl = NSTextField(labelWithString: "开机时自动启动")
        mainLbl.font = .systemFont(ofSize: 14, weight: .medium)
        mainLbl.textColor = .white
        mainLbl.sizeToFit()
        mainLbl.frame.origin = NSPoint(x: 16, y: 22)

        let hintLbl = NSTextField(labelWithString: "登录后自动常驻")
        hintLbl.font = .systemFont(ofSize: 11)
        hintLbl.textColor = NSColor(white: 0.5, alpha: 1)
        hintLbl.sizeToFit()
        hintLbl.frame.origin = NSPoint(x: 16, y: 6)

        let sw = NSSwitch()
        sw.target = self
        sw.action = #selector(toggleLaunchAtLogin)
        sw.state = launchAtLoginEnabled() ? .on : .off
        sw.sizeToFit()
        sw.frame.origin = NSPoint(x: cardW - sw.frame.width - 16, y: 22)
        self.launchSwitch = sw

        [launchTitle, mainLbl, hintLbl, sw].forEach { launchCard.addSubview($0) }

        // ── 退出卡片 ──
        let quitH: CGFloat = 96
        let quitY = launchY - 16 - quitH
        let quitCard = makeCard(y: quitY, h: quitH)

        let quitTitle = NSTextField(labelWithString: "操作")
        quitTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        quitTitle.textColor = NSColor(white: 0.45, alpha: 1)
        quitTitle.sizeToFit()
        quitTitle.frame.origin = NSPoint(x: 16, y: quitH - 26)

        let quitBtn = NSButton(title: "完全退出 NotchQuota",
                               target: self, action: #selector(quitApp))
        quitBtn.font = .systemFont(ofSize: 13, weight: .medium)
        quitBtn.bezelColor = NSColor.systemRed.withAlphaComponent(0.6)
        quitBtn.contentTintColor = .white
        quitBtn.sizeToFit()
        quitBtn.frame.origin = NSPoint(x: (cardW - quitBtn.frame.width) / 2, y: 32)

        let quitHint = NSTextField(labelWithString: "退出后停止监控,可再次点击图标启动")
        quitHint.font = .systemFont(ofSize: 11)
        quitHint.textColor = NSColor(white: 0.5, alpha: 1)
        quitHint.sizeToFit()
        quitHint.frame.origin = NSPoint(x: (cardW - quitHint.frame.width) / 2, y: 12)

        [quitTitle, quitBtn, quitHint].forEach { quitCard.addSubview($0) }

        // ── 版本号 ──
        let versionLbl = NSTextField(labelWithString: "v0.1")
        versionLbl.font = .systemFont(ofSize: 10)
        versionLbl.textColor = NSColor(white: 0.4, alpha: 1)
        versionLbl.sizeToFit()
        versionLbl.frame.origin = NSPoint(x: (W - versionLbl.frame.width) / 2,
                                          y: quitY - 22)

        for v in [icon, nameLbl, subLbl, launchCard, quitCard, versionLbl] {
            root.addSubview(v)
        }

        w.contentView = root
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── 开机自启:用 SMAppService(macOS 13+) ──
    private func launchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
    @objc private func toggleLaunchAtLogin() {
        let enabled = launchAtLoginEnabled()
        do {
            if enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            launchSwitch?.state = enabled ? .on : .off
            NSSound.beep()
        }
    }

    @objc private func quitApp() {
        window?.close()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        launchSwitch = nil
    }
}
