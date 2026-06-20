import AppKit
import ServiceManagement

// 简易设置窗口:开机自启开关 + 完全退出按钮
// 关窗口不会退出 app(功能继续运行),只有点"完全退出"才终止进程
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var launchToggle: NSButton?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "NotchQuota"
        w.titlebarAppearsTransparent = false
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self

        let root = NSView(frame: w.contentView!.bounds)
        root.autoresizingMask = [.width, .height]

        // ── 头部图标 + 名称 ──
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        let nameLbl = NSTextField(labelWithString: "NotchQuota")
        nameLbl.font = .systemFont(ofSize: 15, weight: .semibold)
        let subLbl = NSTextField(labelWithString: "刘海用量监控 · v0.1")
        subLbl.font = .systemFont(ofSize: 11)
        subLbl.textColor = .secondaryLabelColor

        let head = NSStackView(views: [icon, nameLbl])
        head.orientation = .horizontal
        head.spacing = 10
        head.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(head)

        let subWrap = NSView()
        subWrap.translatesAutoresizingMaskIntoConstraints = false
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        subWrap.addSubview(subLbl)
        root.addSubview(subWrap)

        // ── 开机自启开关 ──
        let toggle = NSButton(checkboxWithTitle: "开机时自动启动",
                              target: self, action: #selector(toggleLaunchAtLogin))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.state = launchAtLoginEnabled() ? .on : .off
        root.addSubview(toggle)
        self.launchToggle = toggle

        let toggleHint = NSTextField(labelWithString: "登录后自动常驻,刘海监控持续可用")
        toggleHint.font = .systemFont(ofSize: 10)
        toggleHint.textColor = .tertiaryLabelColor
        toggleHint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toggleHint)

        // ── 分隔线 ──
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sep)

        // ── 完全退出按钮 ──
        let quitBtn = NSButton(title: "完全退出 NotchQuota",
                               target: self, action: #selector(quitApp))
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        quitBtn.bezelColor = NSColor.systemRed.withAlphaComponent(0.45)
        root.addSubview(quitBtn)

        let quitHint = NSTextField(labelWithString: "退出后将停止监控,可再次点击图标启动")
        quitHint.font = .systemFont(ofSize: 10)
        quitHint.textColor = .tertiaryLabelColor
        quitHint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(quitHint)

        // ── 约束 ──
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            subLbl.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 2),
            subLbl.leadingAnchor.constraint(equalTo: nameLbl.leadingAnchor),
            toggle.topAnchor.constraint(equalTo: subLbl.bottomAnchor, constant: 22),
            toggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            toggleHint.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 2),
            toggleHint.leadingAnchor.constraint(equalTo: toggle.leadingAnchor),
            sep.topAnchor.constraint(equalTo: toggleHint.bottomAnchor, constant: 16),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            quitBtn.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 16),
            quitBtn.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            quitHint.topAnchor.constraint(equalTo: quitBtn.bottomAnchor, constant: 4),
            quitHint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])

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
            // 失败 → 回滚开关状态并提示
            launchToggle?.state = enabled ? .on : .off
            NSSound.beep()
        }
    }

    @objc private func quitApp() {
        window?.close()
        NSApp.terminate(nil)
    }

    // 关窗 → 只移除设置窗口,不退出、不隐藏 app(刘海功能继续可用)
    func windowWillClose(_ notification: Notification) {
        window = nil
        launchToggle = nil
    }
}
