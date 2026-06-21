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
def probe_codex() -> dict:
    """调 ChatGPT wham/usage API 取实时用量(5h主窗口 + 周窗口)。
    凭证从 ~/.codex/auth.json 读取(Codex CLI 自己维护刷新)。"""
    out = {
        "id": "codex", "name": "Codex", "plan": "ChatGPT Plan",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://chatgpt.com/codex",
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

# ─────────────────────── Hermes ───────────────────────
def probe_hermes() -> dict:
    """调 hermes insights 取 token 用量, hermes status 取订阅到期。"""
    out = {
        "id": "hermes", "name": "Hermes", "plan": "Nous Portal",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://portal.nousresearch.com",
    }
    try:
        hermes = os.path.join(HOME, ".local", "bin", "hermes")
        if not os.path.exists(hermes):
            hermes = "hermes"

        ins = subprocess.run([hermes, "insights"], capture_output=True,
                             text=True, timeout=25).stdout
        # 去 ANSI
        ins = re.sub(r"\x1b\[[0-9;]*m", "", ins)
        metrics = []
        m = re.search(r"Total tokens:\s*([\d,]+)", ins)
        if m:
            metrics.append({"label": "30天 token", "text": m.group(1)})
        m = re.search(r"Sessions:\s*(\d+)", ins)
        if m:
            metrics.append({"label": "会话", "text": m.group(1)})

        st = subprocess.run([hermes, "status"], capture_output=True,
                            text=True, timeout=25).stdout
        st = re.sub(r"\x1b\[[0-9;]*m", "", st)
        m = re.search(r"Access exp:\s*([\d\-: ]+\w*)", st)
        if m:
            metrics.append({"label": "密钥到期", "text": m.group(1).strip()})

        if metrics:
            out["metrics"] = metrics
            out["status"] = "ok"
            out["detail"] = "本地用量统计"
        else:
            out["detail"] = "无法解析 insights"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


def main():
    result = [probe_codex(), probe_antigravity(), probe_hermes()]
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
