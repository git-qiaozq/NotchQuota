import AppKit

// 刘海专用窗口：不可成为 key/main
final class NotchWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppController: NSObject, NSApplicationDelegate {
    private var hotZone: NotchWindow!
    private var panelWindow: NotchWindow!
    private var panelView: PanelView!
    private var services: [QuotaService] = []
    private var lastUpdate = Date()
    private var refreshTimer: Timer?
    private var isOpen = false
    private var closeWorkItem: DispatchWorkItem?   // 延迟收起任务
    private var notchHotRect: NSRect = .zero        // 收起态刘海热区矩形
    private var currentTargetFrame: NSRect?         // 展开后面板目标矩形
    private var pollTimer: Timer?                   // 兜底:打开后轮询光标真实位置,防止 tracking area 失效导致不收回

    private let panelWidth: CGFloat = 360
    private let hideInset: CGFloat = 8             // 收起时藏到屏幕顶外的余量
    private let hoverSlop: CGFloat = 24            // 热区比刘海左右各宽容多少
    private let closeDelay: TimeInterval = 0.0     // 鼠标移出后立即收起(0延迟,下一tick执行避免过渡抖动)

    // ── 本机真实刘海几何(动态读取,换机器也对) ──
    private struct NotchGeom {
        let left: CGFloat; let right: CGFloat; let height: CGFloat
        var center: CGFloat { (left + right) / 2 }
        var width: CGFloat { right - left }
    }
    private var cachedGeom: NotchGeom?

    private func notchGeom(_ screen: NSScreen) -> NotchGeom {
        if let g = cachedGeom { return g }
        let sf = screen.frame
        let g: NotchGeom
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            g = NotchGeom(left: l.maxX, right: r.minX, height: l.height)
        } else {
            // 无刘海:顶部正中造一个假刘海区
            let w: CGFloat = 200
            g = NotchGeom(left: sf.midX - w / 2, right: sf.midX + w / 2, height: 0)
        }
        cachedGeom = g
        return g
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { return }
        setupHotZone(screen: screen)
        setupPanel(screen: screen)
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self] _ in self?.refresh()
        }
    }

    // ── 再次点击 app 图标(运行中) → 弹出设置窗口 ──
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // ── 关掉设置窗口不要退出 app(刘海功能继续可用) ──
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // ── 热区:覆盖刘海本身 + 下方一小条,左右宽容 ──
    // 鼠标划过刘海即触发,无需停留
    private func setupHotZone(screen: NSScreen) {
        let sf = screen.frame
        let g = notchGeom(screen)
        let belowExtra: CGFloat = 10
        let rect = NSRect(x: g.left - hoverSlop,
                          y: sf.maxY - g.height - belowExtra,
                          width: g.width + hoverSlop * 2,
                          height: g.height + belowExtra)
        notchHotRect = rect
        hotZone = NotchWindow(contentRect: rect, styleMask: .borderless,
                              backing: .buffered, defer: false)
        hotZone.level = .statusBar
        hotZone.backgroundColor = .clear
        hotZone.isOpaque = false
        hotZone.hasShadow = false
        hotZone.ignoresMouseEvents = false
        hotZone.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hv = HoverView(frame: hotZone.contentView!.bounds)
        hv.autoresizingMask = [.width, .height]
        hv.onEnter = { [weak self] in self?.openPanel() }
        hv.onExit  = { [weak self] in self?.requestClose() }
        hotZone.contentView = hv
        hotZone.orderFrontRegardless()
    }

    // ── 面板:初始藏在屏幕顶外 ──
    private func setupPanel(screen: NSScreen) {
        let sf = screen.frame
        let g = notchGeom(screen)
        let rect = NSRect(x: g.center - panelWidth / 2,
                          y: sf.maxY + hideInset,
                          width: panelWidth, height: 400)
        panelWindow = NotchWindow(contentRect: rect, styleMask: .borderless,
                                  backing: .buffered, defer: false)
        panelWindow.level = .statusBar
        panelWindow.backgroundColor = .clear
        panelWindow.isOpaque = false
        panelWindow.hasShadow = true
        panelWindow.isMovable = false
        panelWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // notchInset = 刘海高度 → 顶部留出刘海融合区,内容沉到刘海底边以下
        panelView = PanelView(
            onClickURL: { [weak self] url in self?.openURL(url) },
            notchInset: g.height
        )
        let container = HoverView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        container.onEnter = { [weak self] in self?.cancelClose() }     // 进面板 → 保持
        container.onExit  = { [weak self] in self?.requestClose() }    // 离面板 → 查活跃区后决定
        panelView.frame = container.bounds
        panelView.autoresizingMask = [.width, .height]
        container.addSubview(panelView)
        panelWindow.contentView = container
        panelWindow.alphaValue = 1
        panelWindow.orderFrontRegardless()
        debugLog("SETUP screen.frame=\(screen.frame) visibleFrame=\(screen.visibleFrame) notch=\(g.left),\(g.right) h=\(g.height) panelW=\(panelWidth)")
    }

    // ── 展开:面板顶部顶到屏幕顶(包裹刘海),从顶外下滑 ──
    private func openPanel() {
        cancelClose()
        guard !isOpen else { return }
        isOpen = true
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let g = notchGeom(screen)

        panelView.render(services, updated: lastUpdate)
        // fittingSize 已含 notchInset → 总高度 = 刘海融合区 + 内容
        let totalH = panelView.fittingSize.height

        // 目标:顶部 y = sf.maxY(贴屏幕顶,包裹刘海) → origin.y = sf.maxY - totalH
        let target = NSRect(x: g.center - panelWidth / 2,
                            y: sf.maxY - totalH,
                            width: panelWidth, height: totalH)
        currentTargetFrame = target
        // 起始:完全藏在屏幕顶外
        let start = NSRect(x: target.origin.x, y: sf.maxY + hideInset,
                           width: panelWidth, height: totalH)
        panelWindow.setFrame(start, display: false)
        debugLog("OPEN totalH=\(totalH) target=\(target.origin.x),\(target.origin.y) \(target.width)x\(target.height) | topY=\(target.origin.y+target.height) sfMaxY=\(sf.maxY) actualBefore=\(panelWindow.frame)")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panelWindow.animator().setFrame(target, display: true)
        }, completionHandler: {
            self.debugLog("OPENED actualFrame=\(self.panelWindow.frame) topY=\(self.panelWindow.frame.maxY)")
            self.startPolling()   // 展开完成后启动兜底轮询
        })
    }

    // ── 收起:滑回屏幕顶外(藏到刘海后) ──
    private func closePanel() {
        guard isOpen else { return }
        isOpen = false
        currentTargetFrame = nil
        stopPolling()   // 收起后停止轮询
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let cur = panelWindow.frame
        let hidden = NSRect(x: cur.origin.x, y: sf.maxY + hideInset,
                            width: cur.width, height: cur.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelWindow.animator().setFrame(hidden, display: true)
        }
    }

    // ── 光标是否还在「刘海热区 ∪ 面板」连续活跃区内 ──
    private func isCursorInActiveArea() -> Bool {
        let p = NSEvent.mouseLocation
        var active = notchHotRect
        if let t = currentTargetFrame { active = active.union(t) }
        active = active.insetBy(dx: -3, dy: -3)   // 容错:四周膨胀 3pt
        return active.contains(p)
    }

    // ── 鼠标可能离开 → 查光标实际位置决定收不收 ──
    private func requestClose() {
        if isCursorInActiveArea() { return }      // 还在活跃区 → 保持打开
        // 真正离开了 → 下一 tick 收起(避免同一帧抖动)
        closeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.closePanel() }
        closeWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    // ── 兜底轮询:tracking area 可能因长时间静止/刷新/省电失效 ──
    // 每 0.15s 主动查光标真实位置,离开即收。即时性靠 requestClose,可靠性靠这里。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) {
            [weak self] _ in
            guard let self = self, self.isOpen else { return }
            if !self.isCursorInActiveArea() { self.closePanel() }
        }
    }
    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func cancelClose() {
        closeWorkItem?.cancel(); closeWorkItem = nil
    }

    private func refresh() {
        QuotaFetcher.fetch { [weak self] svcs in
            guard let self = self else { return }
            self.services = svcs
            self.lastUpdate = Date()
            if self.isOpen { self.panelView.render(svcs, updated: self.lastUpdate) }
        }
    }

    private func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    // ── 诊断:把几何坐标写到文件,便于排查贴合问题 ──
    private func debugLog(_ s: String) {
        let path = FileManager.default.homeDirectoryForCurrentUser.path
            + "/NotchQuota/debug.log"
        let line = "\(Date()) | \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// 用 tracking area 检测鼠标进/出
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var ta: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = ta { removeTrackingArea(ta) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways,
                                            .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); ta = area
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
