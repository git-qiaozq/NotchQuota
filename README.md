# NotchQuota

在 MacBook 刘海处实时查看 **Codex / Claude / Z.AI / Antigravity** 四个 AI 平台的套餐用量。

鼠标划过刘海 → 面板像 Dynamic Island 一样从刘海胀开包裹刘海，展示四家用量；鼠标移开即收回。

## 能力

| 平台 | 数据 | 数据源 |
|------|------|--------|
| **Codex** | 5h + 周窗口 已用百分比、重置倒计时 | `chatgpt.com/backend-api/wham/usage` 实时 API |
| **Claude** | 5h + 周窗口 已用百分比、重置倒计时 | 最小请求 + 响应 header 的 `ratelimit-unified` 字段 |
| **Z.AI** | 5h + 周窗口 已用百分比、重置倒计时 | `open.bigmodel.cn/api/monitor/usage/quota/limit` 实时 API |
| **Antigravity** | 两模型组(Gemini / Claude&GPT)×(5h/周) 已用百分比 | `agy` CLI 的 `/usage` (常驻 daemon 复用会话) |

- 四家**全部实时**，每 60 秒自动刷新；展开面板时按需强制刷新
- 点击卡片跳转到对应平台的用量详情页
- 完整生命周期：应用图标、设置窗口、开机自启开关、完全退出（退出时优雅关闭 daemon）

## 它怎么工作

```
quota_probe.py (Python)                    Sources/NotchQuota (Swift/AppKit)
┌──────────────────────────────────┐       ┌─────────────────────────────────┐
│ 四家数据采集器(统一 JSON)          │       │  QuotaFetcher 启动子进程         │
│ · Codex      wham/usage API       │       │    ↓ stdout JSON                │
│ · Claude     haiku 最小请求+header │──────▶│  PanelView 渲染四家卡片          │
│ · Z.AI       quota/limit API      │       │  AppController 刘海热区/动画/    │
│ · Antigravity agy daemon /usage   │       │    轮询兜底/活跃门控/生命周期     │
│   (agy_usage.py pty 常驻会话)     │       │  SettingsWindow 设置窗口         │
└──────────────────────────────────┘       └─────────────────────────────────┘
```

数据采集逻辑独立于 UI，可单独运行：

```bash
python3 probe/quota_probe.py     # 直接打印四家统一 JSON
```

## 依赖

- macOS 13.0+（带刘海的 MacBook）
- Swift 6.x（系统自带，或 Xcode Command Line Tools）
- Python 3
- `agy` CLI（Antigravity 官方，用于读取其用量）
- 已登录配置：
  - Codex：`~/.codex/auth.json`（Codex CLI 登录后自动生成）
  - Claude：keychain `Claude Code-credentials`（Claude Code 登录后写入）
  - Z.AI：`~/.hermes/.env` 里的 `GLM_API_KEY`（或 `ZAI_API_KEY` 等）
  - Antigravity：`agy` 已登录

## 构建

```bash
cd NotchQuota
bash build_app.sh        # 编译 + 打包到 ~/Applications/NotchQuota.app
open ~/Applications/NotchQuota.app
```

图标由 `scripts/make_icon.swift` 程序化绘制（暗色 squircle + 刘海 + 三条绿色用量条）。

## 使用

- **划过刘海** → 弹出用量面板，移开即收（触控板惯性下不抖动）
- **点击 app 图标**（运行中）→ 打开设置窗口
- 设置窗口：开机自启拨片开关 / 完全退出
- **关闭设置窗口**不会退出 app，刘海功能继续可用

## 管理

```bash
# 重启（改完代码后）
pkill -f NotchQuota.app; bash ~/NotchQuota/build_app.sh; open ~/Applications/NotchQuota.app

# 关闭（app 退出时会自动关闭 agy daemon）
pkill -f NotchQuota.app

# 单独看四家数据（不开 app）
python3 ~/NotchQuota/probe/quota_probe.py
```

## 项目结构

```
NotchQuota/
├── Package.swift
├── build_app.sh                 # 一键编译打包脚本(含图标生成)
├── probe/
│   ├── quota_probe.py           # 数据层:四家统一 JSON 采集 + 各家防护逻辑
│   ├── agy_usage.py             # Antigravity: pty 驱动 agy daemon + TUI 解析
│   └── requirements.txt
├── scripts/
│   └── make_icon.swift          # 图标生成器
└── Sources/NotchQuota/
    ├── main.swift               # 入口
    ├── QuotaModel.swift         # 数据模型 + 子进程调用(force 刷新 + 补全 PATH)
    ├── PanelView.swift          # 下拉面板视图(进度条/卡片)
    ├── AppController.swift      # 刘海热区/动画/轮询兜底/活跃门控/生命周期
    └── SettingsWindow.swift     # 深色设置窗口
```

## 实现要点

### 刘海交互
- **刘海贴合**：动态读取 `NSScreen.auxiliaryTopLeftArea/RightArea` 获取真实刘海几何，面板顶部顶到屏幕顶端包裹刘海；顶部超出屏幕顶 2pt 消除白线
- **触控板防抖**：收起判断不依赖单一 tracking area 事件，而是每次 `NSEvent.mouseLocation` 实测光标位置 + 0.15s 轮询兜底，避免惯性划过时反复弹出收回、长时间停留后事件丢失

### 四家差异化的风险防护
各平台的风险性质不同，防护策略各自精准：

| 平台 | 真实风险 | 防护 |
|------|---------|------|
| **Codex** | 节点 IP 信誉差 → Cloudflare soft block（连接建立但不返回数据 → 超时）| **失败退避**：连续失败 2 次后 5 分钟才试一次（不每分钟撞墙），成功立刻恢复；+ 5 分钟轻缓存 |
| **Claude** | 高频 + 跨国漂移 → 触发 Anthropic 风控 → **封号** | **降频**（15 分钟缓存）+ **活跃门控**（睡眠/锁屏暂停）+ **出口漂移检测**（Clash 切节点换国家 → 跳过本轮）|
| **Z.AI** | 无（国内直连）| — |
| **Antigravity** | 每次启动 agy 触发 OAuth 弹窗 | **daemon 常驻复用会话** + 重启后信任页自动确认 |

### Antigravity daemon
- 直调 Google REST API 会因 keychain token 被 IDE 刷新丢失 Pro scope 而 403，故改用 pty 驱动 `agy` 本身（它自管 token/gRPC/license）
- agy 会话常驻（daemon 模式），避免每分钟重启触发 OAuth 登录弹窗
- app 退出时通过 unix socket 发 `shutdown`，优雅关闭 daemon + agy，无孤儿进程
- 12 小时空闲超时兜底

### GUI 子进程 PATH
- macOS GUI app 的子进程 PATH 默认不含 `~/.local/bin`，故 `agy`/`hermes` 需绝对路径 fallback + Swift 端补全 PATH

## License

MIT
