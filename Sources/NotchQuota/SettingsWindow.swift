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
        let W: CGFloat = 380, H: CGFloat = 664
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

        // ── 显示卡片 ──
        // 列表区域加高到 5 行可见(156),并用 ScrollView 包裹:
        // 未来再加服务时直接滚动,不再被裁掉
        let visibleH: CGFloat = 220
        let visibleY = launchY - 16 - visibleH
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
        quitBtn.setFrameSize(NSSize(width: 156, height: 28))
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
        versionLbl.frame.origin = NSPoint(x: (W - versionLbl.frame.width) / 2, y: 10)

        for v in [icon, nameLbl, subLbl, launchCard, visibleCard, quitCard, versionLbl] {
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

final class HoverQuitButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private let normalColor = NSColor.systemRed.withAlphaComponent(0.86)
    private let hoverColor = NSColor.systemRed
    private let pressedColor = NSColor(calibratedRed: 0.82, green: 0.12, blue: 0.13, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    init(titleText: String, target: Any?, action: Selector?) {
        super.init(frame: .zero)
        title = titleText
        self.target = target as AnyObject?
        self.action = action
        configure()
    }

    private func configure() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = normalColor.cgColor
        layer?.shadowColor = NSColor.systemRed.cgColor
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 0
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        setButtonType(.momentaryPushIn)
        updateTitle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        animate(backgroundColor: hoverColor,
                scale: 1.045,
                shadowOpacity: 0.32,
                shadowRadius: 10,
                duration: 0.16)
    }

    override func mouseExited(with event: NSEvent) {
        animate(backgroundColor: normalColor,
                scale: 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                duration: 0.18)
    }

    override func mouseDown(with event: NSEvent) {
        animate(backgroundColor: pressedColor,
                scale: 0.985,
                shadowOpacity: 0.16,
                shadowRadius: 5,
                duration: 0.08)
        super.mouseDown(with: event)
        let hoverPoint = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let isHovering = bounds.contains(hoverPoint)
        animate(backgroundColor: isHovering ? hoverColor : normalColor,
                scale: isHovering ? 1.045 : 1,
                shadowOpacity: isHovering ? 0.32 : 0,
                shadowRadius: isHovering ? 10 : 0,
                duration: 0.12)
    }

    private func animate(backgroundColor: NSColor,
                         scale: CGFloat,
                         shadowOpacity: Float,
                         shadowRadius: CGFloat,
                         duration: TimeInterval) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.backgroundColor = backgroundColor.cgColor
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        layer.shadowOpacity = shadowOpacity
        layer.shadowRadius = shadowRadius
        CATransaction.commit()
    }

    private func updateTitle() {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: font ?? NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
    }
}
