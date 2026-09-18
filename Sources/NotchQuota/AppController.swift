import AppKit

// 刘海专用窗口:不可成为 key/main
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
    private var isRefreshing = false
    private var isOpen = false
    private var openedInCornerMode = false   // 本次展开使用的触发方式(决定收起动画形态)
    private var animationGeneration = 0      // 展开/收起共用代次,防止旧回调隐藏重新打开的面板
    private var closeWorkItem: DispatchWorkItem?   // 延迟收起任务
    private var notchHotRect: NSRect = .zero        // 收起态刘海热区矩形
    private var currentTargetFrame: NSRect?         // 展开后面板目标矩形
    private var pollTimer: Timer?                   // 兜底:打开后轮询光标真实位置,防止 tracking area 失效导致不收回

    private let panelWidth: CGFloat = 362
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cardVisibilityChanged),
            name: .quotaCardVisibilityDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(triggerModeChanged),
            name: .quotaTriggerModeDidChange,
            object: nil
        )
        refresh()
        startRefreshTimer()
        setupActivityGates()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self] _ in self?.refresh(force: false)
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // ── 层2: 活跃度门控 ──
    // 睡眠/锁屏/显示器睡眠时暂停后台定时器(四家全部不发请求,省电+省风险)
    // 唤醒/解锁时恢复,并立即刷一次
    private var isPaused = false
    private func setupActivityGates() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemSleeping),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemWoke),
                       name: NSWorkspace.didWakeNotification, object: nil)
        // 屏幕睡眠(锁屏/显示器关)用分布式通知
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenSlept),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenWoke),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    @objc private func systemSleeping() { pauseForSleep() }
    @objc private func systemWoke() { resumeFromSleep() }
    @objc private func screenSlept() { pauseForSleep() }
    @objc private func screenWoke() { resumeFromSleep() }

    private func pauseForSleep() {
        guard !isPaused else { return }
        isPaused = true
        stopRefreshTimer()
    }
    private func resumeFromSleep() {
        guard isPaused else { return }
        isPaused = false
        startRefreshTimer()
        refresh(force: true)   // 唤醒后立即取一次实时数据
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

    // ── app 退出时优雅关闭 agy daemon,避免遗留孤儿进程 ──
    // daemon 收到 shutdown 会终止它托管的 agy 会话并清理 socket
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        QuotaFetcher.shutdownDaemon()
    }

    // ── 热区矩形:按触发方式计算 ──
    // 刘海模式:覆盖刘海本身 + 下方一小条,左右宽容
    // 右上角模式:贴死屏幕右上角的一小块,光标甩进角落即触发(类触发角)
    private func hotZoneRect(for screen: NSScreen) -> NSRect {
        let sf = screen.frame
        switch QuotaDisplayPreferences.triggerMode {
        case .notch:
            let g = notchGeom(screen)
            let belowExtra: CGFloat = 10
            return NSRect(x: g.left - hoverSlop,
                          y: sf.maxY - g.height - belowExtra,
                          width: g.width + hoverSlop * 2,
                          height: g.height + belowExtra)
        case .topRightCorner:
            let s: CGFloat = 16
            return NSRect(x: sf.maxX - s, y: sf.maxY - s, width: s, height: s)
        }
    }

    private func setupHotZone(screen: NSScreen) {
        let rect = hotZoneRect(for: screen)
        notchHotRect = rect
        hotZone = NotchWindow(contentRect: rect, styleMask: .borderless,
                              backing: .buffered, defer: false)
        hotZone.level = .statusBar
        hotZone.backgroundColor = .clear
        hotZone.isOpaque = false
        hotZone.hasShadow = false
        hotZone.ignoresMouseEvents = false
        // transient 在调度中心隐藏;stationary 会保留窗口参与显示。
        hotZone.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]

        let hv = HoverView(frame: hotZone.contentView!.bounds)
        hv.autoresizingMask = [.width, .height]
        hv.onEnter = { [weak self] in self?.openPanel() }
        hv.onExit  = { [weak self] in self?.requestClose() }
        hotZone.contentView = hv
        hotZone.orderFrontRegardless()
    }

    // ── 面板:初始不加入显示列表,屏幕外坐标只用于展开/收起动画 ──
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
        // 自定义阴影:四边都有投影形成自然边界,但顶部投影会被刘海实体遮挡
        // (窗口顶部紧贴屏幕顶,顶部阴影被刘海盖住 → 不会出现割裂白线)
        if let cl = panelWindow.contentView?.layer {
            cl.shadowColor = NSColor.black.cgColor
            cl.shadowOpacity = 0.45
            cl.shadowRadius = 12
            cl.shadowOffset = NSSize(width: 0, height: -4)
        }
        panelWindow.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panelWindow.animationBehavior = .none   // 显隐由自定义动画负责,orderOut 不再追加系统动画

        // notchInset = 刘海高度 → 顶部留出刘海融合区,内容沉到刘海底边以下
        panelView = PanelView(
            onClickURL: { [weak self] url in self?.openURL(url) },
            notchInset: g.height
        )
        let container = HoverView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        // 容器透明,完全由 PanelView 负责形状和颜色(避免容器白底露出边框线)
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        container.onEnter = { [weak self] in self?.cancelClose() }     // 进面板 → 保持
        container.onExit  = { [weak self] in self?.requestClose() }    // 离面板 → 查活跃区后决定
        panelView.frame = container.bounds
        panelView.autoresizingMask = [.width, .height]
        container.addSubview(panelView)
        panelWindow.contentView = container
        panelWindow.alphaValue = 1
        debugLog("SETUP screen.frame=\(screen.frame) visibleFrame=\(screen.visibleFrame) notch=\(g.left),\(g.right) h=\(g.height) panelW=\(panelWidth)")
    }

    // ── 展开:面板顶部顶到屏幕顶(包裹刘海),从顶外下滑 ──
    private func openPanel() {
        cancelClose()
        guard !isOpen, let screen = NSScreen.main else { return }
        isOpen = true
        animationGeneration += 1
        let gen = animationGeneration
        let sf = screen.frame
        let g = notchGeom(screen)

        renderPanel()
        // 展开面板时按需强制刷新(层1的"按需"部分):Claude 会跳过缓存取实时
        refresh(force: true)
        // 刘海模式:顶部留出刘海融合区并水平居中包裹刘海
        // 右上角模式:无融合区,面板贴屏幕右缘并多出 1pt,把右缘边线推出可视区
        // (与角落热区连成一片,光标贴边下移不脱开)
        let cornerMode = QuotaDisplayPreferences.triggerMode == .topRightCorner
        openedInCornerMode = cornerMode
        panelView.notchInset = cornerMode ? 0 : g.height
        let targetX = cornerMode ? sf.maxX - panelWidth + 1 : g.center - panelWidth / 2
        // fittingSize 已含 notchInset → 总高度 = 刘海融合区 + 内容
        let totalH = panelView.fittingSize.height
        // 目标:顶部超出屏幕顶 2pt,刚好盖住那条 1px 边线,不浪费可视空间
        let target = NSRect(x: targetX,
                            y: sf.maxY - totalH + 2,
                            width: panelWidth, height: totalH)
        currentTargetFrame = target
        debugLog("OPEN totalH=\(totalH) target=\(target.origin.x),\(target.origin.y) \(target.width)x\(target.height) | topY=\(target.origin.y+target.height) sfMaxY=\(sf.maxY) actualBefore=\(panelWindow.frame)")

        if cornerMode {
            // 窗口直接就位,内容层从右上角辐射放大(见 playRadiateFromCorner)
            panelWindow.setFrame(target, display: false)
            playRadiateFromCorner()
        } else {
            // 起始:完全藏在屏幕顶外
            let start = NSRect(x: target.origin.x, y: sf.maxY + hideInset,
                               width: panelWidth, height: totalH)
            panelWindow.setFrame(start, display: false)
            resetRadiateState()   // 清掉可能未完成的角落动画残留
            panelWindow.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panelWindow.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                guard let self = self, self.isOpen, gen == self.animationGeneration else { return }
                self.debugLog("OPENED actualFrame=\(self.panelWindow.frame) topY=\(self.panelWindow.frame.maxY)")
                self.startPolling()   // 展开完成后启动兜底轮询
            })
        }
    }

    // ── 收起:滑回屏幕顶外(藏到刘海后) / 缩回右上角 ──
    private func closePanel() {
        guard isOpen else { return }
        isOpen = false
        animationGeneration += 1
        let gen = animationGeneration
        currentTargetFrame = nil
        stopPolling()   // 收起后停止轮询
        guard let screen = NSScreen.main else {
            panelWindow.orderOut(nil)
            return
        }
        let sf = screen.frame
        let cur = panelWindow.frame
        let hidden = NSRect(x: cur.origin.x, y: sf.maxY + hideInset,
                            width: cur.width, height: cur.height)
        if openedInCornerMode {
            // 缩回右上角 + 淡出(显式动画:AppKit 的 layer-backed 视图不支持隐式动画)
            guard let layer = panelWindow.contentView?.layer else {
                panelWindow.orderOut(nil)
                panelWindow.setFrame(hidden, display: false)
                return
            }
            setRadiateAnchor(atCorner: true)
            // 从当前展示状态开始缩(展开动画中途收起也能平滑接管)
            let fromT = layer.presentation()?.transform ?? layer.transform
            let fromO = layer.presentation()?.opacity ?? layer.opacity
            let small = CATransform3DMakeScale(0.1, 0.1, 1)

            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: fromT)
            shrink.toValue = NSValue(caTransform3D: small)
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = fromO
            fadeOut.toValue = 0
            fadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let group = CAAnimationGroup()
            group.animations = [shrink, fadeOut]
            group.duration = 0.28

            layer.removeAllAnimations()   // 打断可能未完的展开动画
            // 模型值设为终态,动画播完移除后不跳变
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = small
            layer.opacity = 0
            CATransaction.commit()
            layer.add(group, forKey: "radiateOut")

            // 动画结束后真正隐藏,避免 macOS 27 把屏幕外窗口纳入空间缩略图。
            // 代次不符说明面板已重新展开,不能再隐藏;内容层到下次展开时才复位。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self = self, !self.isOpen, gen == self.animationGeneration else { return }
                self.panelWindow.orderOut(nil)
                self.panelWindow.setFrame(hidden, display: false)
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panelWindow.animator().setFrame(hidden, display: true)
            }, completionHandler: { [weak self] in
                guard let self = self, !self.isOpen, gen == self.animationGeneration else { return }
                self.panelWindow.orderOut(nil)
            })
        }
    }

    // ── 右上角辐射动画 ──
    // 窗口直接放在目标位,只对内容层做 transform(窗口 frame 不动,活跃区判断不受影响)
    private func playRadiateFromCorner() {
        guard let contentView = panelWindow.contentView, let layer = contentView.layer else {
            panelWindow.orderFrontRegardless()
            startPolling()
            return
        }
        setRadiateAnchor(atCorner: true)
        // 若是在收起动画中途重新展开,从当前展示状态接着放大,避免跳变
        let interrupted = layer.animation(forKey: "radiateOut") != nil
        let startT = interrupted
            ? (layer.presentation()?.transform ?? CATransform3DMakeScale(0.12, 0.12, 1))
            : CATransform3DMakeScale(0.12, 0.12, 1)
        let startO: Float = interrupted ? (layer.presentation()?.opacity ?? 0) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()

        // 缩放:角落一点 → 轻微过冲 → 归位(Dynamic Island 式弹性)
        let expand = CAKeyframeAnimation(keyPath: "transform")
        expand.values = [
            NSValue(caTransform3D: startT),
            NSValue(caTransform3D: CATransform3DMakeScale(1.05, 1.05, 1)),
            NSValue(caTransform3D: CATransform3DIdentity),
        ]
        expand.keyTimes = [0, 0.7, 1]
        expand.duration = 0.44
        expand.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startO
        fade.toValue = 1
        fade.duration = 0.24
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup()
        group.animations = [expand, fade]
        group.duration = 0.44
        layer.add(group, forKey: "radiateIn")
        panelWindow.orderFrontRegardless()   // 首帧动画准备好后再显示,避免整块面板闪现

        // 动画结束后还原锚点/启动兜底轮询;代次不符说明已被更新的展开/收起接管
        let gen = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            guard let self = self, self.isOpen, gen == self.animationGeneration else { return }
            self.resetRadiateState()
            self.startPolling()
        }
    }

    // 内容层锚点钉到右上角(辐射源)或还原到中心;不触发隐式动画
    private func setRadiateAnchor(atCorner: Bool) {
        guard let contentView = panelWindow.contentView, let layer = contentView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if atCorner {
            layer.anchorPoint = CGPoint(x: 1, y: 1)
            layer.position = CGPoint(x: contentView.frame.maxX, y: contentView.frame.maxY)
        } else {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: contentView.frame.midX, y: contentView.frame.midY)
        }
        CATransaction.commit()
    }

    // 动画结束/被打断后,把内容层恢复为无变换、不透明、锚点居中的常态
    private func resetRadiateState() {
        guard let contentView = panelWindow.contentView, let layer = contentView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: contentView.frame.midX, y: contentView.frame.midY)
        CATransaction.commit()
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

    private func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        QuotaFetcher.fetch(force: force) { [weak self] svcs in
            guard let self = self else { return }
            self.isRefreshing = false
            self.services = svcs
            self.lastUpdate = Date()
            if self.isOpen { self.renderPanel(updateFrame: true) }
        }
    }

    @objc private func cardVisibilityChanged() {
        guard isOpen else { return }
        renderPanel(updateFrame: true)
    }

    // ── 触发方式切换:收起面板,把热区搬到新位置 ──
    @objc private func triggerModeChanged() {
        if isOpen { closePanel() }
        guard let screen = NSScreen.main else { return }
        let rect = hotZoneRect(for: screen)
        notchHotRect = rect
        hotZone.setFrame(rect, display: true)
    }

    private func renderPanel(updateFrame: Bool = false) {
        let visible = QuotaDisplayPreferences.visibleServices(from: services)
        let emptyMessage = services.isEmpty
            ? "无法读取数据（probe 脚本未返回）"
            : "没有可显示的卡片"
        panelView.render(visible, updated: lastUpdate, emptyMessage: emptyMessage)

        guard updateFrame, isOpen, let target = currentTargetFrame else { return }
        let newHeight = panelView.fittingSize.height
        let newFrame = NSRect(x: target.origin.x,
                              y: target.maxY - newHeight,
                              width: target.width,
                              height: newHeight)
        currentTargetFrame = newFrame
        panelWindow.setFrame(newFrame, display: true, animate: true)
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
