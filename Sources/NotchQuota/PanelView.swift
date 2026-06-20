import AppKit

// 下拉面板的内容视图：标题 + 三张服务卡片
final class PanelView: NSView {
    private let stack = NSStackView()
    private var onClickURL: ((String) -> Void)?
    private let notchInset: CGFloat   // 顶部留给刘海融合的空白高度

    init(onClickURL: @escaping (String) -> Void, notchInset: CGFloat = 0) {
        self.onClickURL = onClickURL
        self.notchInset = notchInset
        super.init(frame: .zero)
        wantsLayer = true
        // 近纯黑:和刘海融合成一体
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.98).cgColor
        // 大圆角药丸形(四角都圆) → 刘海嵌在顶部中央
        layer?.cornerRadius = 22
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                 .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        stack.orientation = .vertical
        stack.spacing = 10
        // 顶部内边距 = 刘海高度 + 常规间距 → 内容沉到刘海底边以下
        stack.edgeInsets = NSEdgeInsets(top: notchInset + 14,
                                        left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func render(_ services: [QuotaService], updated: Date) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: "套餐用量")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        if services.isEmpty {
            let err = NSTextField(labelWithString: "⚠️ 无法读取数据（probe 脚本未返回）")
            err.font = .systemFont(ofSize: 12)
            err.textColor = .systemOrange
            stack.addArrangedSubview(err)
        } else {
            for svc in services {
                stack.addArrangedSubview(makeCard(svc))
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let foot = NSTextField(labelWithString: "更新于 \(fmt.string(from: updated)) · 点击卡片打开页面")
        foot.font = .systemFont(ofSize: 10)
        foot.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(foot)
    }

    private func makeCard(_ svc: QuotaService) -> NSView {
        let card = ClickableCard(url: svc.url) { [weak self] u in self?.onClickURL?(u) }
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let v = NSStackView()
        v.orientation = .vertical
        v.spacing = 6
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        v.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            v.topAnchor.constraint(equalTo: card.topAnchor),
            v.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // 头部：圆点 + 名称 + 套餐
        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 7
        let dot = NSTextField(labelWithString: svc.isOK ? "🟢" : "🟠")
        dot.font = .systemFont(ofSize: 9)
        let name = NSTextField(labelWithString: svc.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        let plan = NSTextField(labelWithString: svc.plan)
        plan.font = .systemFont(ofSize: 10)
        plan.textColor = .tertiaryLabelColor
        plan.lineBreakMode = .byTruncatingTail
        head.addArrangedSubview(dot)
        head.addArrangedSubview(name)
        head.addArrangedSubview(plan)
        v.addArrangedSubview(head)

        // 指标
        if svc.metrics.isEmpty {
            let d = NSTextField(labelWithString: svc.detail.isEmpty ? "无可用指标" : svc.detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            v.addArrangedSubview(d)
        } else {
            for m in svc.metrics {
                v.addArrangedSubview(makeMetricRow(m))
            }
            if !svc.detail.isEmpty {
                let d = NSTextField(labelWithString: svc.detail)
                d.font = .systemFont(ofSize: 9)
                d.textColor = .tertiaryLabelColor
                v.addArrangedSubview(d)
            }
        }
        return card
    }

    private func makeMetricRow(_ m: QuotaMetric) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.spacing = 3
        row.alignment = .leading

        let top = NSStackView()
        top.orientation = .horizontal
        let label = NSTextField(labelWithString: m.label)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let valueStr: String
        if let pct = m.usedPct {
            let remain = max(0, 100 - pct)
            var s = String(format: "剩 %.0f%%", remain)
            if let r = m.reset, !r.isEmpty { s += "  ⟳ \(r)" }
            valueStr = s
        } else {
            valueStr = m.text ?? ""
        }
        let value = NSTextField(labelWithString: valueStr)
        value.font = .systemFont(ofSize: 11, weight: .medium)
        value.textColor = .labelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(label)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(value)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalToConstant: 276).isActive = true
        row.addArrangedSubview(top)

        // 进度条(仅百分比型)
        if let pct = m.usedPct {
            let bar = ProgressBar(usedPct: pct)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 276).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
            row.addArrangedSubview(bar)
        }
        return row
    }
}

// 进度条：已用部分着色(<70%绿, <90%黄, 否则红)
final class ProgressBar: NSView {
    private let used: Double
    init(usedPct: Double) { self.used = max(0, min(100, usedPct)); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5)
        NSColor(white: 1, alpha: 0.12).setFill(); bg.fill()
        let w = bounds.width * CGFloat(used / 100.0)
        guard w > 0 else { return }
        let fg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                              xRadius: 2.5, yRadius: 2.5)
        let color: NSColor = used < 70 ? .systemGreen : (used < 90 ? .systemYellow : .systemRed)
        color.setFill(); fg.fill()
    }
}

// 可点击卡片
final class ClickableCard: NSView {
    private let url: String
    private let action: (String) -> Void
    init(url: String, action: @escaping (String) -> Void) {
        self.url = url; self.action = action; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) { action(url) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
