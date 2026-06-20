# NotchQuota

在 MacBook 刘海处实时查看 **Codex / Antigravity / Hermes** 三个 AI 平台的套餐用量。

鼠标划过刘海 → 面板像 Dynamic Island 一样从刘海胀开包裹刘海，展示三家用量；鼠标移开即收回。

## 截图 / 能力

- **Codex** — 5 小时窗口 + 周窗口的已用百分比、重置倒计时（从本地 session 快照读取）
- **Antigravity** — Google One AI Pro 套餐层级（读取 keychain 里的 OAuth token 调 Cloud Code 内部接口）
- **Hermes** — 近 30 天 token 用量、会话数、密钥到期时间（调 `hermes` CLI）
- 每 60 秒自动刷新；点击任意卡片打开对应官网
- 完整生命周期：应用图标、设置窗口、开机自启开关、完全退出

## 它怎么工作

```
quota_probe.py (Python)          Sources/NotchQuota (Swift/AppKit)
┌──────────────────────┐         ┌─────────────────────────────┐
│ 三家数据采集器        │ stdout  │  QuotaFetcher 调用脚本      │
│ · Codex  session jsonl│ ──JSON──▶  ───────────────────────▶  │
│ · Antigravity OAuth   │         │  PanelView 渲染三家卡片     │
│ · Hermes   CLI        │         │  AppController 刘海热区/动画 │
└──────────────────────┘         └─────────────────────────────┘
```

数据采集逻辑独立于 UI，可单独运行：

```bash
python3 probe/quota_probe.py     # 直接打印统一 JSON
```

## 依赖

- macOS 13.0+（带刘海的 MacBook）
- Swift 6.x（系统自带，或 Xcode Command Line Tools）
- Python 3 + `cryptography`（用于 Antigravity 的 Chrome cookie 解密）

## 构建

```bash
cd NotchQuota
bash build_app.sh        # 编译 + 打包到 ~/Applications/NotchQuota.app
open ~/Applications/NotchQuota.app
```

图标由 `scripts/make_icon.swift` 程序化绘制（暗色 squircle + 刘海 + 三条绿色用量条）。

## 使用

- **划过刘海** → 弹出用量面板，移开即收
- **点击 app 图标**（运行中）→ 打开设置窗口
- 设置窗口里：开机自启开关 / 完全退出
- **关闭设置窗口**不会退出 app，刘海功能继续可用

## 管理

```bash
# 重启
pkill -f NotchQuota.app; bash ~/NotchQuota/build_app.sh; open ~/Applications/NotchQuota.app
# 关闭
pkill -f NotchQuota.app
```

## 项目结构

```
NotchQuota/
├── Package.swift
├── build_app.sh              # 一键编译打包脚本
├── probe/
│   ├── quota_probe.py        # 数据层:三家统一 JSON
│   └── requirements.txt
├── scripts/
│   └── make_icon.swift       # 图标生成器
└── Sources/NotchQuota/
    ├── main.swift
    ├── QuotaModel.swift      # 数据模型 + 采集器调用
    ├── PanelView.swift       # 下拉面板视图
    ├── AppController.swift   # 刘海热区/动画/生命周期
    └── SettingsWindow.swift  # 设置窗口
```

## 已知限制

- **Antigravity** 的 `loadCodeAssist` 接口只返回套餐层级，不返回配额百分比数字。读取 `gemini.google.com/usage` 的实时百分比需要走浏览器 Cookie 解密（代码框架已就绪）。
- Codex 的用量是 session 中的快照（上次运行时），非严格实时。

## License

MIT
