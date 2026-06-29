#!/usr/bin/env python3
"""
quota_probe.py — 统一采集 Codex / Antigravity / Hermes 三家套餐用量。
输出一份 JSON 数组到 stdout，供 NotchQuota.app 渲染。

每个采集器都用 try/except 包住：单家失败不影响其它两家，
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

        rl = data.get("rate_limit", {})
        plan = data.get("plan_type", "")
        out["plan"] = f"ChatGPT {plan.capitalize()}" if plan else "ChatGPT Plan"

        metrics = []
        prim = rl.get("primary_window") or {}
        sec = rl.get("secondary_window") or {}
        if prim:
            metrics.append({
                "label": "5h 窗口", "used_pct": round(prim.get("used_percent", 0), 1),
                "reset": _human_reset(prim.get("reset_at", 0)),
            })
        if sec:
            metrics.append({
                "label": "周窗口", "used_pct": round(sec.get("used_percent", 0), 1),
                "reset": _human_reset(sec.get("reset_at", 0)),
            })
        out["metrics"] = metrics
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
        try:
            if os.path.exists(_CODEX_CACHE):
                d = json.load(open(_CODEX_CACHE))
                if d.get("status") == "ok":
                    # 有缓存 → 返回上次结果,只改 detail 提示来源,UI 保持绿色卡片
                    d["detail"] = f"节点不通,显示上次结果"
                    return d
        except Exception:
            pass
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
        _codex_reset_fails()    # 成功 → 清零,恢复正常频率
        try:
            os.makedirs(os.path.dirname(_CODEX_CACHE), exist_ok=True)
            json.dump(result, open(_CODEX_CACHE, "w"), ensure_ascii=False)
        except Exception:
            pass
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

    result = fetch_usage()
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
    for g in groups:
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


# ─────────────────────── Hermes / Z.AI ───────────────────────
# Hermes 当前用 Z.AI/GLM 作为 provider,改用其 API key 查 coding plan 真实配额
# key 从 Hermes .env 读(GLM_API_KEY / ZAI_API_KEY / Z_AI_API_KEY)

def _zai_find_key() -> str:
    """从 Hermes .env 读 Z.AI/GLM API key。"""
    env = os.path.join(HOME, ".hermes", ".env")
    if not os.path.exists(env):
        return ""
    import re as _re
    keys = ["GLM_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY", "ZHIPUAI_API_KEY"]
    pat = _re.compile(r'\s*(' + '|'.join(keys) + r')\s*=\s*["\']?([A-Za-z0-9._\-]+)')
    with open(env) as f:
        for line in f:
            m = pat.match(line)
            if m:
                return m.group(2)
    return ""


def probe_hermes() -> dict:
    """调智谱 coding plan 用量 API,返回 5h/周窗口的真实配额。"""
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

        import urllib.request, urllib.error
        req = urllib.request.Request(
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            code = e.code
            out["detail"] = "key 无效" if code == 401 else f"HTTP {code}"
            return out

        limits = data.get("data", {}).get("limits", [])
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

        out["metrics"] = metrics
        out["status"] = "ok"
        out["detail"] = "实时"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


def main():
    result = [probe_codex(), probe_claude(), probe_hermes(), probe_antigravity()]
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
