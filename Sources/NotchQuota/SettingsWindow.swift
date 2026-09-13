import AppKit
import ServiceManagement

// 设置窗口:开机自启开关 + 卡片显示开关 + 完全退出按钮
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
        let W: CGFloat = 380, H: CGFloat = 752
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

        // ── 通用卡片 ──
        let launchH: CGFloat = 72
        let launchY = subLbl.frame.minY - 30 - launchH
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

        // ── 触发方式卡片 ──
        let triggerH: CGFloat = 72
        let triggerY = launchY - 16 - triggerH
        let triggerCard = makeCard(y: triggerY, h: triggerH)

        let triggerTitle = NSTextField(labelWithString: "触发方式")
        triggerTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        triggerTitle.textColor = NSColor(white: 0.45, alpha: 1)
        triggerTitle.sizeToFit()
        triggerTitle.frame.origin = NSPoint(x: 16, y: triggerH - 26)

        let triggerMainLbl = NSTextField(labelWithString: "弹出位置")
        triggerMainLbl.font = .systemFont(ofSize: 14, weight: .medium)
        triggerMainLbl.textColor = .white
        triggerMainLbl.sizeToFit()
        triggerMainLbl.frame.origin = NSPoint(x: 16, y: 22)

        let triggerHintLbl = NSTextField(labelWithString: "悬停刘海,或划入屏幕右上角")
        triggerHintLbl.font = .systemFont(ofSize: 11)
        triggerHintLbl.textColor = NSColor(white: 0.5, alpha: 1)
        triggerHintLbl.sizeToFit()
        triggerHintLbl.frame.origin = NSPoint(x: 16, y: 6)

        let modeSwitch = TriggerModeSwitch(frame: NSRect(x: 0, y: 0, width: 198, height: 30))
        modeSwitch.setMode(QuotaDisplayPreferences.triggerMode, animated: false)
        modeSwitch.onChange = { QuotaDisplayPreferences.triggerMode = $0 }
        modeSwitch.frame.origin = NSPoint(x: cardW - modeSwitch.frame.width - 14,
                                          y: (triggerH - modeSwitch.frame.height) / 2)

        [triggerTitle, triggerMainLbl, triggerHintLbl, modeSwitch].forEach { triggerCard.addSubview($0) }

        // ── 显示卡片 ──
        // 列表区域加高到 5 行可见(156),并用 ScrollView 包裹:
        // 未来再加服务时直接滚动,不再被裁掉
        let visibleH: CGFloat = 220
        let visibleY = triggerY - 16 - visibleH
        let visibleCard = makeCard(y: visibleY, h: visibleH)

        let visibleTitle = NSTextField(labelWithString: "显示卡片")
        visibleTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        visibleTitle.textColor = NSColor(white: 0.45, alpha: 1)
        visibleTitle.sizeToFit()
        visibleTitle.frame.origin = NSPoint(x: 16, y: visibleH - 26)
        visibleCard.addSubview(visibleTitle)

        let visibleHint = NSTextField(labelWithString: "选择刘海面板里展示的服务")
        visibleHint.font = .systemFont(ofSize: 11)
        visibleHint.textColor = NSColor(white: 0.5, alpha: 1)
        visibleHint.sizeToFit()
        visibleHint.frame.origin = NSPoint(x: 16, y: visibleH - 45)
        visibleCard.addSubview(visibleHint)

        // ScrollView 包住列表,行数超出可视高度时可滚动
        let listAreaH: CGFloat = 156   // (28+3)*5 + 1,5 行刚好全可见
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: cardW - 24, height: listAreaH))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.autohidesScrollers = false   // 常驻滚动条:6 张卡后有内容在下方,提示可滚动
        let cardList = CardOrderListView(frame: NSRect(x: 0, y: 0, width: cardW - 24, height: listAreaH))
        scroll.documentView = cardList
        visibleCard.addSubview(scroll)

        // ── 退出卡片 ──
        let quitH: CGFloat = 96
        let quitY = max(34, visibleY - 16 - quitH)
        let quitCard = makeCard(y: quitY, h: quitH)

        let quitTitle = NSTextField(labelWithString: "操作")
        quitTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        quitTitle.textColor = NSColor(white: 0.45, alpha: 1)
        quitTitle.sizeToFit()
        quitTitle.frame.origin = NSPoint(x: 16, y: quitH - 26)

        let quitBtn = HoverQuitButton(titleText: "完全退出 NotchQuota",
                                      target: self, action: #selector(quitApp))
        quitBtn.setFrameSize(NSSize(width: 176, height: 30))
        quitBtn.frame.origin = NSPoint(x: (cardW - quitBtn.frame.width) / 2, y: 31)

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
        versionLbl.frame.origin = NSPoint(x: (W - versionLbl.frame.width) / 2, y: 10)

        for v in [icon, nameLbl, subLbl, launchCard, triggerCard, visibleCard, quitCard, versionLbl] {
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

final class CardOrderListView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    // 翻转坐标系:行从顶部 y=0 往下排,NSScrollView 才能正确滚动(6 张卡后需要滚动)
    override var isFlipped: Bool { true }

    private let rowHeight: CGFloat = 28
    private let rowGap: CGFloat = 3
    private var cards = QuotaDisplayPreferences.orderedCards
    private var rows: [CardOrderRowView] = []
    private weak var draggingRow: CardOrderRowView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        rebuildRows()
        // 高度撑到能容纳所有行:行数 ≤ 可视高度时保持原高(不引入滚动),
        // 超出时变高,由外层 NSScrollView 滚动
        let needed = CGFloat(cards.count) * (rowHeight + rowGap) - rowGap
        if needed > frame.height {
            setFrameSize(NSSize(width: frame.width, height: needed))
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rebuildRows()
    }

    private func rebuildRows() {
        subviews.forEach { $0.removeFromSuperview() }
        rows = cards.map { option in
            let row = CardOrderRowView(option: option)
            row.onToggleVisibility = { id, isVisible in
                QuotaDisplayPreferences.setCardVisible(id: id, visible: isVisible)
            }
            row.onDragStart = { [weak self] row, event in self?.startDragging(row, event: event) }
            row.onDragMove = { [weak self] row, event in self?.drag(row, event: event) }
            row.onDragEnd = { [weak self] row in self?.endDragging(row) }
            addSubview(row)
            return row
        }
        layoutRows(animated: false)
    }

    private func frameForRow(at index: Int) -> NSRect {
        let y = CGFloat(index) * (rowHeight + rowGap)
        return NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
    }

    private func layoutRows(animated: Bool, excluding excludedRow: CardOrderRowView? = nil) {
        for (index, row) in rows.enumerated() where row !== excludedRow {
            let frame = frameForRow(at: index)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    row.animator().frame = frame
                }
            } else {
                row.frame = frame
            }
        }
    }

    private func startDragging(_ row: CardOrderRowView, event: NSEvent) {
        draggingRow = row
        addSubview(row, positioned: .above, relativeTo: nil)
        row.setDragging(true)
    }

    private func drag(_ row: CardOrderRowView, event: NSEvent) {
        guard draggingRow === row,
              let currentIndex = rows.firstIndex(where: { $0 === row }) else { return }

        let location = convert(event.locationInWindow, from: nil)
        // 翻转坐标系:y=0 在顶部,行随光标移动,限制在列表范围内
        let newY = min(max(location.y - rowHeight / 2, 0), bounds.height - rowHeight)
        row.frame.origin.y = newY

        let proposedIndex = min(max(Int(location.y / (rowHeight + rowGap)), 0), rows.count - 1)
        guard proposedIndex != currentIndex else { return }

        let movedRow = rows.remove(at: currentIndex)
        rows.insert(movedRow, at: proposedIndex)
        let movedCard = cards.remove(at: currentIndex)
        cards.insert(movedCard, at: proposedIndex)
        QuotaDisplayPreferences.setCardOrder(cards)
        layoutRows(animated: true, excluding: row)
    }

    private func endDragging(_ row: CardOrderRowView) {
        guard draggingRow === row else { return }
        draggingRow = nil
        row.setDragging(false)
        layoutRows(animated: true)
    }
}

final class CardOrderRowView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    let option: QuotaCardOption
    var onToggleVisibility: ((String, Bool) -> Void)?
    var onDragStart: ((CardOrderRowView, NSEvent) -> Void)?
    var onDragMove: ((CardOrderRowView, NSEvent) -> Void)?
    var onDragEnd: ((CardOrderRowView) -> Void)?

    private let grip = NSTextField(labelWithString: "☰")
    private let nameLabel: NSTextField
    private let visibilitySwitch = NSSwitch()

    init(option: QuotaCardOption) {
        self.option = option
        self.nameLabel = NSTextField(labelWithString: option.name)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        layer?.cornerRadius = 7

        grip.font = .systemFont(ofSize: 12, weight: .semibold)
        grip.textColor = NSColor(white: 0.46, alpha: 1)
        grip.alignment = .center
        addSubview(grip)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .white
        addSubview(nameLabel)

        visibilitySwitch.target = self
        visibilitySwitch.action = #selector(toggleVisibility)
        visibilitySwitch.state = QuotaDisplayPreferences.isCardVisible(id: option.id) ? .on : .off
        addSubview(visibilitySwitch)
    }

    override func layout() {
        super.layout()
        grip.frame = NSRect(x: 8, y: 5, width: 18, height: bounds.height - 10)
        nameLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: 32, y: (bounds.height - nameLabel.frame.height) / 2)
        visibilitySwitch.sizeToFit()
        visibilitySwitch.frame.origin = NSPoint(x: bounds.width - visibilitySwitch.frame.width - 10,
                                                y: (bounds.height - visibilitySwitch.frame.height) / 2)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        onDragStart?(self, event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragMove?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        onDragEnd?(self)
    }

    func setDragging(_ isDragging: Bool) {
        let scale: CGFloat = isDragging ? 1.03 : 1
        let bg = isDragging
            ? NSColor(white: 1, alpha: 0.11)
            : NSColor(white: 1, alpha: 0.045)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = bg.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDragging ? 0.28 : 0
        layer?.shadowRadius = isDragging ? 8 : 0
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    @objc private func toggleVisibility() {
        onToggleVisibility?(option.id, visibilitySwitch.state == .on)
    }
}

// 触发方式选择开关:HUD 风格滑动开关
// 渐变滑块(薄荷绿→青) + 霓虹辉光呼吸 + 弹簧滑动 + 选中扫光 + 四角瞄准框
final class TriggerModeSwitch: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    var onChange: ((QuotaTriggerMode) -> Void)?
    private(set) var mode: QuotaTriggerMode = .notch

    private let trackLayer = CALayer()
    private let thumb = CAGradientLayer()
    private let shimmer = CAGradientLayer()
    private let brackets = CAShapeLayer()
    private let leftLabel = CATextLayer()
    private let rightLabel = CATextLayer()
    private var ta: NSTrackingArea?

    private let pad: CGFloat = 3
    private let accentA = NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.62, alpha: 1).cgColor  // 薄荷绿
    private let accentB = NSColor(calibratedRed: 0.12, green: 0.74, blue: 0.92, alpha: 1).cgColor  // 青

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        guard let root = layer else { return }

        trackLayer.backgroundColor = NSColor(white: 0, alpha: 0.30).cgColor
        trackLayer.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        trackLayer.borderWidth = 0.5
        root.addSublayer(trackLayer)

        thumb.startPoint = CGPoint(x: 0, y: 0)
        thumb.endPoint = CGPoint(x: 1, y: 1)
        thumb.colors = [accentA, accentB]
        thumb.shadowColor = accentB
        thumb.shadowOpacity = 0.45
        thumb.shadowRadius = 7
        thumb.shadowOffset = .zero
        root.addSublayer(thumb)
        // 辉光呼吸(选中脉冲/扫光期间被临时盖过,结束后自动回到呼吸)
        let breath = CABasicAnimation(keyPath: "shadowOpacity")
        breath.fromValue = 0.35
        breath.toValue = 0.6
        breath.duration = 2.2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        thumb.add(breath, forKey: "glowBreath")

        // 扫光带:斜向高光,平时停在界外不可见,选中时扫过滑块
        shimmer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.5).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        shimmer.locations = [-0.6, -0.4, -0.2]
        shimmer.startPoint = CGPoint(x: 0, y: 0.15)
        shimmer.endPoint = CGPoint(x: 1, y: 0.85)
        root.addSublayer(shimmer)

        brackets.strokeColor = accentB
        brackets.fillColor = nil
        brackets.lineWidth = 1.2
        brackets.opacity = 0.55
        root.addSublayer(brackets)

        for l in [leftLabel, rightLabel] {
            l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            l.fontSize = 12
            l.alignmentMode = .center
            root.addSublayer(l)
        }
        leftLabel.string = QuotaTriggerMode.notch.displayName
        rightLabel.string = QuotaTriggerMode.topRightCorner.displayName
        applyLabelColors(animated: false)
    }

    func setMode(_ m: QuotaTriggerMode, animated: Bool) {
        guard m != mode else { return }
        mode = m
        updateSelection(animated: animated)
        if animated { playSelectFX() }
    }

    // ── 滑块位置 + 标签颜色 ──
    private func updateSelection(animated: Bool) {
        guard bounds.width > 0 else { return }
        let f = thumbFrame(for: mode)
        let pos = CGPoint(x: f.midX, y: f.midY)
        if animated {
            let fromPos = thumb.presentation()?.position ?? thumb.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumb.position = pos
            shimmer.position = pos
            CATransaction.commit()
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: fromPos)
            spring.damping = 14
            spring.stiffness = 180
            spring.mass = 1
            spring.duration = spring.settlingDuration
            thumb.add(spring, forKey: "thumbSpring")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumb.position = pos
            shimmer.position = pos
            CATransaction.commit()
        }
        applyLabelColors(animated: animated)
    }

    // ── 选中特效:辉光脉冲 + 扫光 + 瞄准框脉冲 ──
    private func playSelectFX() {
        let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
        pulse.values = [0.6, 1.0, 0.45]
        pulse.keyTimes = [0, 0.35, 1]
        pulse.duration = 0.6
        thumb.add(pulse, forKey: "glowPulse")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.locations = [-0.6, -0.4, -0.2]
        CATransaction.commit()
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.6, -0.4, -0.2]
        sweep.toValue = [1.2, 1.4, 1.6]
        sweep.duration = 0.55
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(sweep, forKey: "shimmerSweep")
        // 模型值停在右侧界外,动画移除后扫光带留在界外不可见
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.locations = [1.2, 1.4, 1.6]
        CATransaction.commit()

        let bPulse = CAKeyframeAnimation(keyPath: "opacity")
        bPulse.values = [1.0, 0.55]
        bPulse.keyTimes = [0, 1]
        bPulse.duration = 0.7
        brackets.add(bPulse, forKey: "bracketPulse")
    }

    private func applyLabelColors(animated: Bool) {
        let on = NSColor(white: 0.04, alpha: 0.92).cgColor   // 选中:深色字压在渐变滑块上
        let off = NSColor(white: 1, alpha: 0.55).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        leftLabel.foregroundColor = mode == .notch ? on : off
        rightLabel.foregroundColor = mode == .notch ? off : on
        CATransaction.commit()
    }

    private func thumbFrame(for m: QuotaTriggerMode) -> CGRect {
        let w = (bounds.width - pad * 2) / 2
        let h = bounds.height - pad * 2
        let x = m == .notch ? pad : bounds.width - pad - w
        return CGRect(x: x, y: pad, width: w, height: h)
    }

    // 四角瞄准框(HUD 取景框),臂长 arm 的 L 形角标
    private func bracketsPath(rect r: CGRect, arm: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY + arm)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - arm, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + arm))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - arm)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + arm, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - arm, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - arm))
        return p
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        let f = thumbFrame(for: mode)
        thumb.bounds = CGRect(origin: .zero, size: f.size)
        thumb.position = CGPoint(x: f.midX, y: f.midY)
        thumb.cornerRadius = f.height / 2
        shimmer.bounds = thumb.bounds
        shimmer.position = thumb.position
        shimmer.cornerRadius = thumb.cornerRadius
        let halfW = bounds.width / 2
        let labelH: CGFloat = 15
        leftLabel.frame = CGRect(x: 0, y: (bounds.height - labelH) / 2, width: halfW, height: labelH)
        rightLabel.frame = CGRect(x: halfW, y: (bounds.height - labelH) / 2, width: halfW, height: labelH)
        brackets.frame = bounds
        brackets.path = bracketsPath(rect: bounds.insetBy(dx: -4.5, dy: -4.5), arm: 7)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let s = window?.backingScaleFactor ?? 2
        leftLabel.contentsScale = s
        rightLabel.contentsScale = s
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta { removeTrackingArea(ta) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); ta = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ h: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        brackets.opacity = h ? 0.95 : 0.55
        trackLayer.borderColor = NSColor(white: 1, alpha: h ? 0.22 : 0.10).cgColor
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        let m: QuotaTriggerMode = p.x < bounds.midX ? .notch : .topRightCorner
        if m != mode {
            setMode(m, animated: true)
            onChange?(m)
        }
    }
}

// 完全退出按钮:HUD 危险区风格
// 平时低调;悬停红色霓虹描边 + 斜纹警戒带滑动 + 扫光;按下压缩,松开回弹
final class HoverQuitButton: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    private weak var target: AnyObject?
    private var action: Selector?
    private let titleText: String

    private let bgLayer = CALayer()
    private let stripeClip = CALayer()
    private let stripes = CAShapeLayer()
    private let sweep = CAGradientLayer()
    private let iconLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()
    private var ta: NSTrackingArea?
    private var hovering = false
    private var pressed = false

    private let red = NSColor.systemRed
    private let stripeSpacing: CGFloat = 14

    init(titleText: String, target: Any?, action: Selector?) {
        self.titleText = titleText
        self.target = target as AnyObject?
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
    }

    override init(frame frameRect: NSRect) {
        self.titleText = ""
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        guard let root = layer else { return }

        bgLayer.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        bgLayer.borderColor = red.withAlphaComponent(0.4).cgColor
        bgLayer.borderWidth = 1
        bgLayer.shadowColor = red.cgColor
        bgLayer.shadowOpacity = 0
        bgLayer.shadowRadius = 8
        bgLayer.shadowOffset = .zero
        root.addSublayer(bgLayer)

        // 斜纹警戒带:裁到圆角内,悬停时淡入并无缝滑动
        stripeClip.masksToBounds = true
        stripeClip.opacity = 0
        root.addSublayer(stripeClip)
        stripes.strokeColor = red.withAlphaComponent(0.55).cgColor
        stripes.lineWidth = 5
        stripes.fillColor = nil
        stripeClip.addSublayer(stripes)

        // 扫光带:斜向高光,平时停在界外,悬停进入时扫过一次
        sweep.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        sweep.locations = [-0.6, -0.4, -0.2]
        sweep.startPoint = CGPoint(x: 0, y: 0.15)
        sweep.endPoint = CGPoint(x: 1, y: 0.85)
        root.addSublayer(sweep)

        iconLayer.strokeColor = red.cgColor
        iconLayer.fillColor = nil
        iconLayer.lineWidth = 1.5
        iconLayer.lineCap = .round
        root.addSublayer(iconLayer)

        labelLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelLayer.fontSize = 13
        labelLayer.alignmentMode = .center
        labelLayer.string = titleText
        labelLayer.foregroundColor = NSColor(white: 1, alpha: 0.78).cgColor
        root.addSublayer(labelLayer)
    }

    // 电源符号:上方开口的圆弧 + 顶部竖线(绘制在 12x12 本地坐标内)
    private func powerIconPath() -> CGPath {
        let p = CGMutablePath()
        let c = CGPoint(x: 6, y: 5.2)
        p.addArc(center: c, radius: 4.2,
                 startAngle: .pi / 3, endAngle: 2 * .pi / 3, clockwise: true)
        p.move(to: CGPoint(x: 6, y: 12))
        p.addLine(to: CGPoint(x: 6, y: 6))
        return p
    }

    // 45° 平行斜纹,横向周期 = stripeSpacing(平移一个周期即无缝循环)
    private func stripesPath(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let h = r.height
        var x: CGFloat = -h
        while x < r.width + h {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x + h, y: h))
            x += stripeSpacing
        }
        return p
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = bounds
        bgLayer.cornerRadius = 8
        stripeClip.frame = bounds
        stripeClip.cornerRadius = 8
        stripes.frame = bounds.insetBy(dx: -20, dy: 0)   // 加宽,滑动时不露出断口
        stripes.path = stripesPath(in: stripes.bounds)
        sweep.frame = bounds
        sweep.cornerRadius = 8

        // 图标 + 文字成组水平居中
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textSize = (titleText as NSString).size(withAttributes: [.font: font])
        let iconW: CGFloat = 12, gap: CGFloat = 7
        let total = iconW + gap + textSize.width
        let iconX = (bounds.width - total) / 2
        iconLayer.frame = CGRect(x: iconX, y: (bounds.height - 12) / 2, width: 12, height: 12)
        iconLayer.path = powerIconPath()
        labelLayer.frame = CGRect(x: iconX + iconW + gap,
                                  y: (bounds.height - 15) / 2,
                                  width: textSize.width + 2, height: 15)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        labelLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // ── 悬停:霓虹描边亮起 + 警戒带淡入滑动 + 扫光 ──
    private func setHover(_ h: Bool) {
        hovering = h
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        bgLayer.backgroundColor = h ? red.withAlphaComponent(0.18).cgColor
                                    : NSColor(white: 1, alpha: 0.045).cgColor
        bgLayer.borderColor = (h ? red.withAlphaComponent(0.95)
                                 : red.withAlphaComponent(0.4)).cgColor
        bgLayer.shadowOpacity = h ? 0.5 : 0
        stripeClip.opacity = h ? 0.16 : 0
        iconLayer.strokeColor = (h ? NSColor(calibratedRed: 1, green: 0.42, blue: 0.38, alpha: 1)
                                   : red).cgColor
        labelLayer.foregroundColor = NSColor(white: 1, alpha: h ? 1 : 0.78).cgColor
        CATransaction.commit()
        if h { startStripes(); playSweep() } else { stopStripes() }
    }

    private func startStripes() {
        guard stripes.animation(forKey: "stripeSlide") == nil else { return }
        let a = CABasicAnimation(keyPath: "position.x")
        a.byValue = -stripeSpacing
        a.duration = 0.55
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        stripes.add(a, forKey: "stripeSlide")
    }

    private func stopStripes() {
        stripes.removeAnimation(forKey: "stripeSlide")
    }

    private func playSweep() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.locations = [-0.6, -0.4, -0.2]
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-0.6, -0.4, -0.2]
        a.toValue = [1.2, 1.4, 1.6]
        a.duration = 0.5
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(a, forKey: "sweepGo")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.locations = [1.2, 1.4, 1.6]
        CATransaction.commit()
    }

    // ── 按下压缩 / 松开回弹并触发 ──
    override func mouseDown(with event: NSEvent) {
        pressed = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        bgLayer.backgroundColor = red.withAlphaComponent(0.30).cgColor
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        layer?.transform = CATransform3DIdentity
        bgLayer.backgroundColor = hovering ? red.withAlphaComponent(0.18).cgColor
                                           : NSColor(white: 1, alpha: 0.045).cgColor
        CATransaction.commit()
        let p = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(p), let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta { removeTrackingArea(ta) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); ta = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
}
