#!/usr/bin/env python3
from __future__ import annotations
"""
quota_probe.py — 统一采集 Codex / Claude / Z.AI / Kimi / Antigravity / DeepSeek / OpenCode Go / Cursor 用量与余额。
输出一份 JSON 数组到 stdout，供 NotchQuota.app 渲染。

每个采集器都用 try/except 包住：单家失败不影响其它几家，
失败时返回 status="error" + 简短原因，UI 据此降级显示。
"""
import json, os, re, base64, subprocess, time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")


def _now() -> float:
    return time.time()


def _human_reset(epoch: float) -> str:
    """把重置时间戳转成 '3h12m' 这样的倒计时。"""
    if not epoch:
        return ""
    delta = int(epoch - _now())
    if delta <= 0:
        return "now"
    h, rem = divmod(delta, 3600)
    m = rem // 60
    if h >= 24:
        d = h // 24
        return f"{d}d{h % 24}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


# ───────────────────────── Codex ─────────────────────────
_CODEX_CACHE = os.path.join(HOME, ".cache", "notchquota_codex.json")
_CODEX_TTL = 300          # 层1: 轻缓存 5 分钟(用量变化不快,减少撞墙频率)
_CODEX_FAIL_FILE = os.path.join(HOME, ".cache", "notchquota_codex_fails")
_CODEX_FAIL_THRESHOLD = 2 # 连续失败 2 次后进入退避
_CODEX_BACKOFF_TTL = 300  # 退避期间最多 5 分钟试一次(不每分钟撞墙)
_CODEX_LOG = os.path.join(HOME, ".cache", "notchquota_codex.log")


def _codex_fail_count() -> int:
    try:
        return int(open(_CODEX_FAIL_FILE).read().strip() or "0")
    except Exception:
        return 0


def _codex_record_fail():
    try:
        os.makedirs(os.path.dirname(_CODEX_FAIL_FILE), exist_ok=True)
        n = _codex_fail_count() + 1
        open(_CODEX_FAIL_FILE, "w").write(str(n))
    except Exception:
        pass


def _codex_reset_fails():
    try:
        os.remove(_CODEX_FAIL_FILE)
    except FileNotFoundError:
        pass
    except Exception:
        pass


def _codex_log(msg: str) -> None:
    try:
        os.makedirs(os.path.dirname(_CODEX_LOG), exist_ok=True)
        with open(_CODEX_LOG, "a") as f:
            f.write(f"{datetime.now().isoformat(timespec='seconds')} {msg}\n")
    except Exception:
        pass


def _codex_cached_result(detail: str) -> dict | None:
    try:
        if os.path.exists(_CODEX_CACHE):
            d = json.load(open(_CODEX_CACHE))
            if d.get("status") == "ok":
                d["detail"] = detail
                return d
    except Exception:
        pass
    return None


def _codex_metrics_by_label(result: dict) -> dict[str, dict]:
    return {
        metric.get("label", ""): metric
        for metric in result.get("metrics", [])
        if isinstance(metric, dict)
    }


def _codex_all_windows_zero(result: dict) -> bool:
    """只把两个窗口同时为 0 视为可疑，单窗口归零可能是正常重置。"""
    metrics = _codex_metrics_by_label(result)
    windows = [metrics.get("5h 窗口"), metrics.get("周窗口")]
    return all(metric is not None and metric.get("used_pct") == 0 for metric in windows)


def _codex_has_usage(result: dict) -> bool:
    return any(
        isinstance(metric, dict) and (metric.get("used_pct") or 0) > 0
        for metric in result.get("metrics", [])
    )


def _codex_same_reset_cycle(current: dict, cached: dict) -> bool:
    """只有重置时间戳一致时才用旧值兜底，避免掩盖真实的新周期归零。"""
    current_metrics = _codex_metrics_by_label(current)
    cached_metrics = _codex_metrics_by_label(cached)
    for label in ("5h 窗口", "周窗口"):
        current_reset = current_metrics.get(label, {}).get("reset_at")
        cached_reset = cached_metrics.get(label, {}).get("reset_at")
        if not current_reset or current_reset != cached_reset:
            return False
    return True


def _codex_window_label(window: dict, fallback: str) -> str:
    """按窗口时长识别 5h/周额度；primary/secondary 的含义会随套餐变化。"""
    seconds = window.get("limit_window_seconds") or 0
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        seconds = 0
    if 4 * 3600 <= seconds <= 6 * 3600:
        return "5h 窗口"
    if 6 * 24 * 3600 <= seconds <= 8 * 24 * 3600:
        return "周窗口"
    return fallback


def _codex_metrics_from_rate_limit(rate_limit: dict) -> list[dict]:
    """把 wham 的窗口转换为 UI 指标，并保持 5h 在前、周窗口在后。"""
    metrics_by_label = {}
    for key, fallback in (
        ("primary_window", "5h 窗口"),
        ("secondary_window", "周窗口"),
    ):
        window = rate_limit.get(key) or {}
        if not window:
            continue
        label = _codex_window_label(window, fallback)
        metrics_by_label[label] = {
            "label": label,
            "used_pct": round(window.get("used_percent", 0), 1),
            "reset": _human_reset(window.get("reset_at", 0)),
            # 仅供本地缓存判断是否仍是同一统计周期；AppKit 解码会忽略此字段。
            "reset_at": window.get("reset_at", 0),
        }
    return [
        metrics_by_label[label]
        for label in ("5h 窗口", "周窗口")
        if label in metrics_by_label
    ]


def _probe_codex_fresh() -> dict:
    """实际调 wham/usage API 取 Codex 实时用量(无门控)。"""
    out = {
        "id": "codex", "name": "Codex", "plan": "ChatGPT Plan",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://chatgpt.com/codex/cloud/settings/analytics",
    }
    try:
        auth_path = os.path.join(HOME, ".codex", "auth.json")
        if not os.path.exists(auth_path):
            out["detail"] = "未找到 auth.json(请先登录 Codex)"
            return out
        auth = json.load(open(auth_path))
        tokens = auth.get("tokens", {})
        access = tokens.get("access_token", "")
        acct = tokens.get("account_id", "")
        if not access or not acct:
            out["detail"] = "无有效凭证"
            return out

        import urllib.request, urllib.error
        req = urllib.request.Request(
            "https://chatgpt.com/backend-api/wham/usage",
            headers={
                "Authorization": f"Bearer {access}",
                "ChatGPT-Account-Id": acct,
                "User-Agent": "codex_cli_rs/0.1.0",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 401:
                out["detail"] = "token 过期(请运行 codex 刷新)"
            else:
                out["detail"] = f"HTTP {e.code}"
            return out
        except urllib.error.URLError as e:
            reason = getattr(e, "reason", e)
            out["detail"] = "网络波动"
            out["transient"] = True
            _codex_log(f"URLError: {reason}")
            return out

        rl = data.get("rate_limit", {})
        plan = data.get("plan_type", "")
        out["plan"] = f"ChatGPT {plan.capitalize()}" if plan else "ChatGPT Plan"

        out["metrics"] = _codex_metrics_from_rate_limit(rl)
        out["status"] = "ok"
        out["detail"] = "实时"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


def probe_codex() -> dict:
    """Codex 用量,带 soft-block 防护:
    - 层1 轻缓存: 5 分钟(用量变化不快,减少撞墙频率)
    - 层2 失败退避: 连续失败 2 次后,5 分钟才试一次(不每分钟撞墙);
      成功立刻清零恢复正常。
    强制刷新(展开面板)时跳过缓存,但退避仍生效(避免手动触发也撞墙)。"""
    forced = os.environ.get("NOTCHQUOTA_FORCE") == "1"
    fails = _codex_fail_count()

    # 层2: 退避中 — 优先返回上次成功缓存(保持 UI 不被打断),只有完全没有缓存时才显示橙色提示
    in_backoff = fails >= _CODEX_FAIL_THRESHOLD
    if in_backoff and not forced:
        cached = _codex_cached_result("节点不通,显示上次结果")
        if cached:
            return cached
        # 没有缓存(首次就失败)→ 只能显示橙色提示
        return {
            "id": "codex", "name": "Codex", "plan": "ChatGPT Plan",
            "status": "error", "detail": f"节点不通(已降频)",
            "metrics": [], "url": "https://chatgpt.com/codex/cloud/settings/analytics",
        }

    # 层1: 轻缓存(非强制刷新时)
    if not forced:
        try:
            if os.path.exists(_CODEX_CACHE):
                age = _now() - os.path.getmtime(_CODEX_CACHE)
                if age < _CODEX_TTL:
                    d = json.load(open(_CODEX_CACHE))
                    if d.get("status") == "ok":
                        d["detail"] = f"缓存{int(age/60)}m"
                        return d
        except Exception:
            pass

    # 真正发请求
    result = _probe_codex_fresh()
    if result.get("status") == "ok":
        if _codex_all_windows_zero(result):
            # wham/usage 偶尔会在同一统计周期内暂时返回全 0，先给后端一次短暂同步机会。
            _codex_log("all-zero usage response; retrying once")
            time.sleep(1)
            retried = _probe_codex_fresh()
            if retried.get("status") == "ok":
                result = retried
                if _codex_has_usage(result):
                    _codex_log("all-zero usage response recovered on retry")
            else:
                _codex_log(f"all-zero usage retry failed: {retried.get('detail', 'unknown')}")

            # 两次都是 0 且重置时间未变化，说明不是新周期：保留上一份可信结果，且不污染缓存。
            if _codex_all_windows_zero(result):
                cached = _codex_cached_result("统计同步中,显示上次结果")
                if cached and _codex_has_usage(cached) and _codex_same_reset_cycle(result, cached):
                    _codex_log("all-zero usage response kept cached result from same reset cycle")
                    _codex_reset_fails()
                    return cached

        _codex_reset_fails()    # 成功 → 清零,恢复正常频率
        try:
            os.makedirs(os.path.dirname(_CODEX_CACHE), exist_ok=True)
            json.dump(result, open(_CODEX_CACHE, "w"), ensure_ascii=False)
        except Exception:
            pass
    elif result.get("transient"):
        _codex_record_fail()
        cached = _codex_cached_result("网络波动,显示上次结果")
        if cached:
            return cached
    else:
        _codex_record_fail()     # 失败 → 计数,触发退避
    return result


# ───────────────────── Antigravity ─────────────────────
# 通过驱动 agy CLI 的 /usage 命令获取真实配额(agy 自行处理 token/gRPC/license)
# 比直调 REST API 可靠 —— 后者会因 keychain token 被 IDE 刷新丢失 Pro scope 而 403

def probe_antigravity() -> dict:
    """驱动 agy /usage,解析 TUI 输出,返回两家模型组的周/5h 限额。"""
    out = {
        "id": "antigravity", "name": "Antigravity", "plan": "Google One AI Pro",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://gemini.google.com/usage",
    }
    import sys
    probe_dir = os.path.dirname(os.path.abspath(__file__))
    if probe_dir not in sys.path:
        sys.path.insert(0, probe_dir)
    try:
        from agy_usage import fetch_usage
    except ImportError:
        out["detail"] = "agy_usage.py 缺失"
        return out

    # 展开面板时 Swift 端会设置 NOTCHQUOTA_FORCE=1。将它传给 agy daemon，
    # 使已在终端重新登录后的后台旧会话能够立即重载 Keychain。
    result = fetch_usage(force=os.environ.get("NOTCHQUOTA_FORCE") == "1")
    if result.get("status") != "ok":
        out["detail"] = result.get("detail", "未知错误")
        return out

    groups = result.get("groups", [])
    out["status"] = "ok"
    out["detail"] = result.get("detail", "实时")

    def _fmt_reset_hours(h):
        """小时数 → 'Xd Yh' 格式(不足1天则显示 'Xh Ym')。"""
        if h is None:
            return ""
        if h >= 24:
            d = int(h // 24)
            rh = int(round(h - d * 24))
            if rh >= 24:        # 四舍五入后满一天 → 进位
                d += 1; rh -= 24
            return f"{d}d{rh}h" if rh else f"{d}d"
        hh = int(h)
        mm = int(round((h - hh) * 60))
        if mm >= 60:            # 同理,分钟满一小时 → 进位
            hh += 1; mm -= 60
        return f"{hh}h{mm}m" if mm else f"{hh}h"

    # 每个模型组按固定顺序显示: 5h 窗口在上, 周窗口在下(和 Codex 统一)
    # 只保留 Gemini 组,过滤掉 Claude&GPT 组
    for g in groups:
        if "CLAUDE" in g.get("group", "").upper():
            continue
        five_h = g.get("five_hour_limit", {})
        weekly = g.get("weekly_limit", {})
        if not five_h and not weekly:
            continue
        # 组名简化: GEMINI MODELS → Gemini / CLAUDE AND GPT MODELS → Claude&GPT
        short = g["group"].replace("MODELS", "").strip()
        if "CLAUDE" in short:
            short = "Claude&GPT"
        elif "GEMINI" in short:
            short = "Gemini"
        # 5h 窗口(直接用 agy 的原始 'Xh Ym')
        if five_h:
            out["metrics"].append({
                "label": f"{short} 5h",
                "used_pct": five_h["used_pct"],
                "reset": five_h.get("reset", ""),
            })
        # 周窗口(换算成 'Xd Yh')
        if weekly:
            out["metrics"].append({
                "label": f"{short} 周",
                "used_pct": weekly["used_pct"],
                "reset": _fmt_reset_hours(weekly.get("reset_hours")),
            })
    return out

# ───────────────────────── Claude ─────────────────────────
# Claude Pro 用量:用 keychain 里的 OAuth token 发一条 haiku 最小请求,
# 从响应 header 里提取 ratelimit-unified 字段(5h/7d 窗口 utilization + reset)。

def _claude_get_token() -> dict:
    """从 keychain 读 Claude Code 的 OAuth 凭证。返回 {token, refresh, expires_at} 或 {}。"""
    raw = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, timeout=8,
    ).stdout.strip()
    if not raw:
        return {}
    try:
        cred = json.loads(raw)
        oauth = cred.get("claudeAiOauth", {})
        return {
            "token": oauth.get("accessToken", ""),
            "refresh": oauth.get("refreshToken", ""),
            "expires_at": oauth.get("expiresAt", 0),
            "sub": oauth.get("subscriptionType", ""),
        }
    except Exception:
        return {}


def _claude_refresh_token(refresh_token: str) -> str:
    """用 refresh_token 静默续期,返回新 access_token。
    注意:Claude.ai 的 OAuth token endpoint 有 Cloudflare 防护,对脚本请求不友好,
    且真正的 client_id/endpoint 嵌在 Claude Code 内部。此处为尽力而为的尝试,
    失败时返回空(由调用方降级为"请运行 claude /login 重新登录")。"""
    import urllib.request, urllib.parse
    client_ids = [
        "9d1c250a-e61b-44d9-88ed-5944d1962f5e",  # Claude Code 客户端(从二进制提取)
    ]
    for cid in client_ids:
        data = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": cid,
        }).encode()
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                "https://console.anthropic.com/v1/oauth/token",
                data=data, method="POST",
                headers={"content-type": "application/json"}), timeout=15)
            return json.loads(r.read()).get("access_token", "")
        except Exception:
            continue
    return ""


_CLAUDE_CACHE = os.path.join(HOME, ".cache", "notchquota_claude.json")
_CLAUDE_TTL = 900  # 15 分钟:降频防封号(层1)
_CLAUDE_LAST_COUNTRY_FILE = os.path.join(HOME, ".cache", "notchquota_claude_country")


def _claude_get_country() -> str:
    """查当前出口 IP 所在国家(轻量,~0.3s)。失败返回空。"""
    import urllib.request
    try:
        r = urllib.request.urlopen(
            "http://ip-api.com/json/?fields=countryCode", timeout=4)
        return json.loads(r.read()).get("countryCode", "")
    except Exception:
        return ""


def _claude_last_country() -> str:
    try:
        return open(_CLAUDE_LAST_COUNTRY_FILE).read().strip()
    except Exception:
        return ""


def _claude_save_country(c: str) -> None:
    try:
        os.makedirs(os.path.dirname(_CLAUDE_LAST_COUNTRY_FILE), exist_ok=True)
        open(_CLAUDE_LAST_COUNTRY_FILE, "w").write(c)
    except Exception:
        pass


def _probe_claude_fresh() -> dict:
    """实际发请求取 Claude 用量(无门控)。"""
    out = {
        "id": "claude", "name": "Claude", "plan": "Claude Pro",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://claude.ai/new#settings/usage",
    }
    import urllib.request, urllib.error
    try:
        cred = _claude_get_token()
        token = cred.get("token", "")
        if not token:
            out["detail"] = "未找到 Claude 凭证"
            return out

        # token 过期 → 尝试刷新
        expires_at = cred.get("expires_at", 0) / 1000.0 if cred.get("expires_at") else 0
        refresh_tried = False
        if expires_at and expires_at < _now() and cred.get("refresh"):
            refresh_tried = True
            new_token = _claude_refresh_token(cred["refresh"])
            if new_token:
                token = new_token
                refresh_tried = False  # 刷新成功,不算失败

        # 发最小请求
        body = json.dumps({
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "messages": [{"role": "user", "content": "hi"}],
        }).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages",
            data=body, method="POST", headers={
                "Authorization": f"Bearer {token}",
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
            })
        try:
            r = urllib.request.urlopen(req, timeout=15)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                if refresh_tried:
                    out["detail"] = "登录已过期,请运行 claude /login 重新登录"
                else:
                    out["detail"] = "token 失效(请运行 claude 重新登录)"
            else:
                out["detail"] = f"HTTP {e.code}"
            return out

        # 解析 header 里的 ratelimit-unified 字段
        hdr = r.headers
        def _util(window):
            v = hdr.get(f"anthropic-ratelimit-unified-{window}-utilization")
            return float(v) * 100 if v else None
        def _reset(window):
            v = hdr.get(f"anthropic-ratelimit-unified-{window}-reset")
            return float(v) if v else 0

        metrics = []
        five_u = _util("5h")
        if five_u is not None:
            metrics.append({
                "label": "5h 窗口",
                "used_pct": round(five_u, 1),
                "reset": _human_reset(_reset("5h")),
            })
        week_u = _util("7d")
        if week_u is not None:
            metrics.append({
                "label": "周窗口",
                "used_pct": round(week_u, 1),
                "reset": _human_reset(_reset("7d")),
            })

        out["plan"] = f"Claude {cred.get('sub','Pro').capitalize()}" if cred.get("sub") else "Claude Pro"
        out["metrics"] = metrics
        out["status"] = "ok"
        out["detail"] = "实时" if metrics else "无用量 header"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


def probe_claude() -> dict:
    """Claude Pro 用量,带封号风险防护:
    - 层1: 15分钟缓存(后台定时器即便每分钟跑,Claude 也最多15分钟真发一次)
    - 层3: 出口国家漂移检测(Clash切节点换国家 → 跳过本轮,避免短时间跨国)
    强制刷新(展开面板)时跳过层1缓存,但层3漂移检测仍生效。"""
    forced = os.environ.get("NOTCHQUOTA_FORCE") == "1"

    # 层1: 缓存(非强制刷新时)
    if not forced:
        try:
            if os.path.exists(_CLAUDE_CACHE):
                age = _now() - os.path.getmtime(_CLAUDE_CACHE)
                if age < _CLAUDE_TTL:
                    d = json.load(open(_CLAUDE_CACHE))
                    if d.get("status") == "ok":
                        d["detail"] = f"缓存{int(age/60)}m"
                        return d
        except Exception:
            pass

    # 层3: 出口漂移检测 — 国家变化则跳过,返回上次缓存
    cur_country = _claude_get_country()
    last_country = _claude_last_country()
    if cur_country and last_country and cur_country != last_country:
        # 出口漂移:返回缓存(如果有),否则报状态,绝不发请求
        try:
            if os.path.exists(_CLAUDE_CACHE):
                d = json.load(open(_CLAUDE_CACHE))
                if d.get("status") == "ok":
                    d["detail"] = f"出口变化({last_country}→{cur_country}),已跳过"
                    return d
        except Exception:
            pass
        return {
            "id": "claude", "name": "Claude", "plan": "Claude Pro",
            "status": "error", "detail": f"出口变化,已跳过({last_country}→{cur_country})",
            "metrics": [], "url": "https://claude.ai/new#settings/usage",
        }

    # 真正发请求
    result = _probe_claude_fresh()
    # 记录本次出口国家(仅成功时更新,避免临时网络抖动污染基线)
    if result.get("status") == "ok" and cur_country:
        _claude_save_country(cur_country)
        # 写缓存(供层1 和层3 跳过时返回)
        try:
            os.makedirs(os.path.dirname(_CLAUDE_CACHE), exist_ok=True)
            json.dump(result, open(_CLAUDE_CACHE, "w"), ensure_ascii=False)
        except Exception:
            pass
    return result


# ─────────────────────── Z.AI Coding Plan ───────────────────────
# 用 Z.AI/GLM 的 API key 查 coding plan 真实配额。
# key 查找顺序: Keychain(NotchQuota/zai) → ~/.config/notchquota/keys.env
#   → ~/.hermes/.env(向后兼容,历史来源)。
# bigmodel.cn(中国站)与 api.z.ai(全球站)账号体系不互通,两站接口都试,
# 记住上次成功的站,避免每次都先撞一次 401。

_ZAI_KEYCHAIN_SERVICE = "NotchQuota/zai"
_ZAI_ENDPOINTS = [
    ("https://open.bigmodel.cn/api/monitor/usage/quota/limit", "bigmodel.cn"),
    ("https://api.z.ai/api/monitor/usage/quota/limit", "z.ai"),
]
_ZAI_SITE_FILE = os.path.join(HOME, ".cache", "notchquota_zai_site")
_zai_last_good = ""          # 上次成功站点的 url,优先重试(app 每次轮请新起进程,需落盘)


def _zai_find_key() -> str:
    """Keychain → NotchQuota keys.env → Hermes .env,找到第一个非空 key。"""
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-s", _ZAI_KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            key = r.stdout.strip()
            if key:
                return key
    except Exception:
        pass

    keys = ["ZAI_API_KEY", "GLM_API_KEY", "Z_AI_API_KEY", "ZHIPUAI_API_KEY"]
    pat = re.compile(r'\s*(' + '|'.join(keys) + r')\s*=\s*["\']?([A-Za-z0-9._\-]+)')
    envs = [os.path.join(HOME, ".config", "notchquota", "keys.env"),
            os.path.join(HOME, ".hermes", ".env")]
    for env in envs:
        if not os.path.exists(env):
            continue
        try:
            with open(env) as f:
                for line in f:
                    m = pat.match(line)
                    if m:
                        return m.group(2)
        except Exception:
            pass
    return ""


def _zai_fetch_limits(key: str):
    """调配额接口,返回 (limits, None);全部失败返回 (None, 错误摘要)。

    注意: quota/limit 认证失败时 HTTP 状态码是 200,失败信息在 body 里
    ({"code":1000,"msg":"身份验证失败","success":false}),必须检查 success。"""
    global _zai_last_good
    import urllib.request, urllib.error
    if not _zai_last_good:
        try:
            cached = open(_ZAI_SITE_FILE).read().strip()
            _zai_last_good = cached if cached in [u for u, _ in _ZAI_ENDPOINTS] else ""
        except Exception:
            _zai_last_good = ""
    urls = ([_zai_last_good] if _zai_last_good else []) + \
           [u for u, _ in _ZAI_ENDPOINTS if u != _zai_last_good]
    last_err = ""
    for url in urls:
        site = dict(_ZAI_ENDPOINTS).get(url, url)
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            last_err = f"{site}: HTTP {e.code}" + ("(key 无效)" if e.code == 401 else "")
            continue
        except Exception as e:
            last_err = f"{site}: {type(e).__name__}"
            continue

        if not data.get("success"):
            msg = str(data.get("msg") or f"code {data.get('code')}")
            last_err = f"{site}: {'key 无效' if data.get('code') == 1000 else msg}"
            continue

        limits = (data.get("data") or {}).get("limits") or []
        if not limits:
            last_err = f"{site}: 响应无窗口数据"
            continue
        _zai_last_good = url
        try:
            os.makedirs(os.path.dirname(_ZAI_SITE_FILE), exist_ok=True)
            open(_ZAI_SITE_FILE, "w").write(url)
        except Exception:
            pass
        return limits, None
    return None, last_err


def probe_hermes() -> dict:
    """调 Z.AI coding plan 用量 API,返回 5h/周窗口的真实配额。"""
    out = {
        "id": "hermes", "name": "Z.AI", "plan": "Coding Plan",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://open.bigmodel.cn/coding-plan/personal/usage",
    }
    try:
        key = _zai_find_key()
        if not key:
            out["detail"] = "未配置 Z.AI key"
            return out

        limits, err = _zai_fetch_limits(key)
        if err:
            out["detail"] = err
            return out

        metrics = []
        # TOKENS_LIMIT: unit=3 是 5h 窗口, unit=6 是周窗口
        five_h, weekly = None, None
        for L in limits:
            if L.get("type") != "TOKENS_LIMIT":
                continue
            unit = L.get("unit")
            pct = L.get("percentage", 0)
            reset_epoch = (L.get("nextResetTime") or 0) / 1000
            reset_str = _human_reset(reset_epoch)
            entry = {"used_pct": float(pct), "reset": reset_str}
            if unit == 3:
                five_h = entry
            elif unit == 6:
                weekly = entry

        # 固定顺序: 5h 在上、周在下(和 Codex/Antigravity 统一)
        if five_h:
            metrics.append({"label": "5h 窗口", **five_h})
        if weekly:
            metrics.append({"label": "周窗口", **weekly})

        if not metrics:
            out["detail"] = "响应无窗口数据"
            return out

        out["metrics"] = metrics
        out["status"] = "ok"
        out["detail"] = "实时"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


# ───────────────────────── Kimi ─────────────────────────
# Kimi Code (Coding Plan) 用量: 用 Hermes .env 里的 KIMI_API_KEY 调
# api.kimi.com/coding/v1/usages。响应含 usage(周窗口) + limits[](5h 窗口),
# limit/used 都是字符串形式的"次数"(总额 100)。

def _kimi_find_key() -> str:
    """从 Hermes .env 读 Kimi Code API key。"""
    env = os.path.join(HOME, ".hermes", ".env")
    if not os.path.exists(env):
        return ""
    keys = ["KIMI_API_KEY", "KIMI_CN_API_KEY", "KIMI_CODING_API_KEY"]
    pat = re.compile(r'\s*(' + '|'.join(keys) + r')\s*=\s*["\']?([A-Za-z0-9._\-]+)')
    with open(env) as f:
        for line in f:
            m = pat.match(line)
            if m:
                return m.group(2)
    return ""


def _kimi_parse_reset(reset_time: str) -> float:
    """ISO 时间字符串 → epoch 秒。失败返回 0。"""
    try:
        dt = datetime.fromisoformat(reset_time.replace("Z", "+00:00"))
        return dt.timestamp()
    except Exception:
        return 0


def probe_kimi() -> dict:
    """Kimi Code (Coding Plan) 5h/周窗口用量。"""
    out = {
        "id": "kimi", "name": "Kimi", "plan": "Coding Plan",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://www.kimi.com/code/console",
    }
    try:
        key = _kimi_find_key()
        if not key:
            out["detail"] = "未配置 Kimi key"
            return out

        import urllib.request, urllib.error
        req = urllib.request.Request(
            "https://api.kimi.com/coding/v1/usages",
            headers={
                "Authorization": f"Bearer {key}",
                "User-Agent": "KimiCLI/1.6",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            code = e.code
            if code == 401:
                out["detail"] = "key 无效(需 Kimi Code 的 sk-kimi- 密钥)"
            else:
                out["detail"] = f"HTTP {code}"
            return out
        except urllib.error.URLError:
            out["detail"] = "网络波动"
            return out

        def _pct(d: dict) -> float:
            try:
                limit = float(d.get("limit") or 0)
                used = float(d.get("used") or 0)
                return round(used / limit * 100, 1) if limit > 0 else 0.0
            except (TypeError, ValueError):
                return 0.0

        metrics = []
        # 5h 窗口: limits[0].window.duration=300 分钟
        for L in data.get("limits", []) or []:
            detail = L.get("detail") or {}
            if not detail:
                continue
            metrics.append({
                "label": "5h 窗口",
                "used_pct": _pct(detail),
                "reset": _human_reset(_kimi_parse_reset(detail.get("resetTime", ""))),
            })
            break  # 只取第一个(实测只有一个 5h 窗口)
        # 周窗口: usage
        usage = data.get("usage") or {}
        if usage:
            metrics.append({
                "label": "周窗口",
                "used_pct": _pct(usage),
                "reset": _human_reset(_kimi_parse_reset(usage.get("resetTime", ""))),
            })

        # 会员等级
        level = (data.get("user", {}).get("membership", {}) or {}).get("level", "")
        if level:
            out["plan"] = f"Coding {level.replace('LEVEL_', '').capitalize()}"

        out["metrics"] = metrics
        out["status"] = "ok"
        out["detail"] = "实时"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


# ─────────────────────── DeepSeek ───────────────────────
# DeepSeek 是按量付费,没有套餐用量比例,只有账户余额。
# 国内直连、请求轻量,无需缓存/退避(和 Z.AI/Kimi 同级)。

def _deepseek_find_key() -> str:
    """从 Hermes .env 读 DeepSeek API key。"""
    env = os.path.join(HOME, ".hermes", ".env")
    if not os.path.exists(env):
        return ""
    keys = ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]
    pat = re.compile(r'\s*(' + '|'.join(keys) + r')\s*=\s*["\']?([A-Za-z0-9._\-]+)')
    with open(env) as f:
        for line in f:
            m = pat.match(line)
            if m:
                return m.group(2)
    return ""


def probe_deepseek() -> dict:
    """查 DeepSeek API 账户余额(按量付费,无套餐用量)。
    balance 字段交给 Swift 渲染专属的余额卡片(区别于其它家的百分比指标)。"""
    out = {
        "id": "deepseek", "name": "DeepSeek", "plan": "按量付费",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://platform.deepseek.com/usage",
        "balance": None,
    }
    try:
        key = _deepseek_find_key()
        if not key:
            out["detail"] = "未配置 DeepSeek key"
            return out

        import urllib.request, urllib.error
        req = urllib.request.Request(
            "https://api.deepseek.com/user/balance",
            headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            code = e.code
            out["detail"] = "key 无效" if code == 401 else f"HTTP {code}"
            return out
        except urllib.error.URLError:
            out["detail"] = "网络波动"
            return out

        infos = data.get("balance_infos") or []
        if not infos:
            out["detail"] = "无余额信息"
            return out
        info = infos[0]
        out["balance"] = {
            "currency": info.get("currency", "CNY"),
            "total": info.get("total_balance", "0"),
            "granted": info.get("granted_balance", "0"),
            "topped_up": info.get("topped_up_balance", "0"),
            "is_available": data.get("is_available", True),
        }
        out["status"] = "ok"
        out["detail"] = "实时"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


# ─────────────────── OpenCode Go ───────────────────
# OpenCode Go 是 $10/月的订阅计划,提供 5h 滚动($12)、周($30)、月($60) 三个用量窗口。
# 没有公开 API,通过 workspace ID + auth cookie 抓取网页控制台提取用量。
#
# 配置: ~/.config/notchquota/opencode_go.json
# {
#   "workspaceId": "wrk_xxxxxxxxxxxxxxxxxxxxxxxx",
#   "authCookie": "Fe26.2**..."
# }

_GO_CONFIG = os.path.join(HOME, ".config", "notchquota", "opencode_go.json")


def _go_read_config() -> dict:
    """读取 OpenCode Go 配置(workspaceId + authCookie)。"""
    try:
        if os.path.exists(_GO_CONFIG):
            return json.load(open(_GO_CONFIG))
    except Exception:
        pass
    return {}


def _go_parse_usage(html: str) -> list[dict] | None:
    """从 SolidJS SSR 页面提取 rolling/weekly/monthly 用量。"""
    # 查找 go 充值数据中的用量字段
    # 格式: rollingUsage:$R[N]={status:"ok",resetInSec:18000,usagePercent:0}
    import re as _re

    windows = {}
    for label, key in [("5h 窗口", "rollingUsage"), ("周窗口", "weeklyUsage"),
                       ("月窗口", "monthlyUsage")]:
        m = _re.search(
            rf'{key}:\$R\[\d+\]=\{{status:"([^"]+)",resetInSec:(\d+),usagePercent:([\d.]+)}}',
            html)
        if not m:
            continue
        status, reset_sec, pct = m.group(1), int(m.group(2)), float(m.group(3))
        if status != "ok":
            continue
        windows[label] = {
            "used_pct": round(pct, 1),
            "reset": _human_reset(time.time() + reset_sec) if reset_sec else "",
        }
    if not windows:
        return None

    metrics = []
    for label in ("5h 窗口", "周窗口", "月窗口"):
        if label in windows:
            metrics.append({"label": label, **windows[label]})
    return metrics


def probe_opencode_go() -> dict:
    """抓取 OpenCode Go 用量面板,返回 5h/周/月 三个窗口用量。"""
    out = {
        "id": "opencode-go", "name": "OpenCode Go", "plan": "Go",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://opencode.ai/workspace/wrk_01KEN93SBGJZ26F7NWJRHFX29K/go",
    }
    config = _go_read_config()
    workspace_id = config.get("workspaceId") or os.environ.get("OPENCODE_GO_WORKSPACE_ID", "")
    auth_cookie = config.get("authCookie") or os.environ.get("OPENCODE_GO_AUTH_COOKIE", "")

    if not workspace_id:
        out["detail"] = "未配置 workspace ID(请设置 ~/.config/notchquota/opencode_go.json)"
        return out
    if not auth_cookie:
        out["detail"] = "未配置 auth cookie(请设置 ~/.config/notchquota/opencode_go.json)"
        return out

    import urllib.request, urllib.error
    try:
        url = f"https://opencode.ai/workspace/{workspace_id}/go"
        req = urllib.request.Request(
            url,
            headers={
                "Cookie": f"auth={auth_cookie}",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                "Accept": "text/html,application/xhtml+xml",
            },
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            html = r.read().decode("utf-8", errors="replace")

        metrics = _go_parse_usage(html)
        if metrics:
            out["metrics"] = metrics
            out["status"] = "ok"
            out["detail"] = "实时"
        else:
            out["detail"] = "未找到用量数据(页面结构可能已变化)"
    except urllib.error.HTTPError as e:
        if e.code == 302:
            out["detail"] = "auth cookie 已过期,请重新获取"
        else:
            out["detail"] = f"HTTP {e.code}"
    except urllib.error.URLError:
        out["detail"] = "网络波动"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


# ─────────────────────── Cursor ───────────────────────
# Cursor Pro 用量:从 Cursor 客户端本地存储(state.vscdb)读 accessToken,
# 调 DashboardService/GetCurrentPeriodUsage 取当前账单周期的 Included Usage。
# token 由 Cursor 客户端自动轮换并写回 vscdb,probe 每次运行重读即可,零配置。
# 该接口是 Cursor 客户端自己状态栏/设置页在用的,调用频率风险低,5 分钟轻缓存即可。

_CURSOR_DB = os.path.join(HOME, "Library", "Application Support", "Cursor",
                          "User", "globalStorage", "state.vscdb")
_CURSOR_CACHE = os.path.join(HOME, ".cache", "notchquota_cursor.json")
_CURSOR_TTL = 300          # 层1: 轻缓存 5 分钟(同 Codex)


def _cursor_read_kv(*keys: str) -> dict:
    """只读模式打开 Cursor 的 state.vscdb,一次取多个 cursorAuth/* 键。
    WAL 允许并发读;偶发 database is locked 时重试一次,仍失败则返回 {}。"""
    if not os.path.exists(_CURSOR_DB):
        return {}
    import sqlite3
    uri = "file:" + _CURSOR_DB + "?mode=ro"
    placeholders = ",".join("?" for _ in keys)
    for attempt in range(2):
        try:
            conn = sqlite3.connect(uri, uri=True, timeout=5)
            try:
                rows = conn.execute(
                    f"SELECT key, value FROM ItemTable WHERE key IN ({placeholders})",
                    [f"cursorAuth/{k}" for k in keys],
                ).fetchall()
                return {k.split("/", 1)[1]: (v or "") for k, v in rows}
            finally:
                conn.close()
        except sqlite3.OperationalError:
            if attempt == 0:
                time.sleep(0.5)
                continue
            return {}
        except Exception:
            return {}
    return {}


def _cursor_jwt_exp(token: str) -> float:
    """解码 JWT payload 取 exp(秒)。失败返回 0(交给服务端判定)。"""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return 0
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        return float(data.get("exp") or 0)
    except Exception:
        return 0


def _probe_cursor_fresh() -> dict:
    """实际调 Cursor 后端取实时用量(无门控)。"""
    out = {
        "id": "cursor", "name": "Cursor", "plan": "Cursor",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://cursor.com/settings",
    }
    try:
        kv = _cursor_read_kv("accessToken", "stripeMembershipType",
                             "stripeSubscriptionStatus")
        token = (kv.get("accessToken") or "").strip()
        if not token:
            out["detail"] = "未找到 Cursor 凭证(请先登录 Cursor)"
            return out

        membership = (kv.get("stripeMembershipType") or "").strip()
        if membership:
            out["plan"] = membership.capitalize()
        sub_status = (kv.get("stripeSubscriptionStatus") or "").strip()
        if sub_status and sub_status != "active":
            out["plan"] += f" · {sub_status}"

        # 本地预检 JWT 有效期,过期就不必发请求了(打开一次 Cursor 即会自动轮换)
        exp = _cursor_jwt_exp(token)
        if exp and exp < _now():
            out["detail"] = "token 已过期(请打开一次 Cursor 刷新登录)"
            return out

        import urllib.request, urllib.error
        req = urllib.request.Request(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
            data=b"{}", method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            })
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                out["detail"] = "token 失效(请打开一次 Cursor 刷新登录)"
            else:
                out["detail"] = f"HTTP {e.code}"
            return out
        except urllib.error.URLError:
            out["detail"] = "网络波动"
            return out

        metrics = []
        # 主指标: Included Usage(套餐内额度,单位是美分)
        plan_usage = data.get("planUsage") or {}
        total_spend = float(plan_usage.get("totalSpend") or 0)
        limit = float(plan_usage.get("limit") or 0)
        cycle_end = float(data.get("billingCycleEnd") or 0) / 1000
        if limit > 0:
            metrics.append({
                "label": f"Included ${limit / 100:g}",
                "used_pct": round(total_spend / limit * 100, 1),
                "reset": _human_reset(cycle_end),
            })
        # 副指标: 按需消费(超额部分),开了上限才显示
        slu = data.get("spendLimitUsage") or {}
        ind_limit = float(slu.get("individualLimit") or 0)
        if ind_limit > 0:
            ind_used = ind_limit - float(slu.get("individualRemaining") or 0)
            metrics.append({
                "label": "按需消费",
                "text": f"${ind_used / 100:.2f} / ${ind_limit / 100:.2f}",
            })

        if not metrics:
            out["detail"] = "无可用指标(可能未开启用量统计)"
            return out
        out["metrics"] = metrics
        out["status"] = "ok"
        out["detail"] = "实时"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


def probe_cursor() -> dict:
    """Cursor Pro 用量,带 5 分钟轻缓存(同 Codex 层1)。
    强制刷新(展开面板)时跳过缓存。"""
    forced = os.environ.get("NOTCHQUOTA_FORCE") == "1"
    if not forced:
        try:
            if os.path.exists(_CURSOR_CACHE):
                age = _now() - os.path.getmtime(_CURSOR_CACHE)
                if age < _CURSOR_TTL:
                    d = json.load(open(_CURSOR_CACHE))
                    if d.get("status") == "ok":
                        d["detail"] = f"缓存{int(age/60)}m"
                        return d
        except Exception:
            pass

    result = _probe_cursor_fresh()
    if result.get("status") == "ok":
        try:
            os.makedirs(os.path.dirname(_CURSOR_CACHE), exist_ok=True)
            json.dump(result, open(_CURSOR_CACHE, "w"), ensure_ascii=False)
        except Exception:
            pass
    return result


def main():
    result = [probe_codex(), probe_claude(), probe_hermes(), probe_kimi(),
              probe_antigravity(), probe_deepseek(), probe_opencode_go(),
              probe_cursor()]
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
