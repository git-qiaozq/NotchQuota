#!/usr/bin/env python3
"""
quota_probe.py — 统一采集 Codex / Antigravity / Hermes 三家套餐用量。
输出一份 JSON 数组到 stdout，供 NotchQuota.app 渲染。

每个采集器都用 try/except 包住：单家失败不影响其它两家，
失败时返回 status="error" + 简短原因，UI 据此降级显示。
"""
import json, os, re, sys, glob, base64, subprocess, time
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
    """从最近的 session .jsonl 里读 rate_limits 快照(5h主窗口 + 周窗口)。"""
    out = {
        "id": "codex", "name": "Codex", "plan": "ChatGPT Plan",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://chatgpt.com/codex/settings/usage",
    }
    try:
        sess_dir = os.path.join(HOME, ".codex", "sessions")
        files = glob.glob(os.path.join(sess_dir, "**", "*.jsonl"), recursive=True)
        if not files:
            out["detail"] = "无 session 记录"
            return out
        files.sort(key=os.path.getmtime, reverse=True)

        # 从最近的文件往回找最后一条带 rate_limits 的记录
        snapshot = None
        snap_mtime = None
        for fp in files[:8]:  # 最近 8 个 session 足够
            last = None
            with open(fp, "r", errors="ignore") as fh:
                for line in fh:
                    if "rate_limits" in line:
                        last = line
            if last:
                try:
                    rec = json.loads(last)
                    rl = rec.get("payload", {}).get("rate_limits")
                    if rl:
                        snapshot = rl
                        snap_mtime = os.path.getmtime(fp)
                        break
                except Exception:
                    continue

        if not snapshot:
            out["detail"] = "无限额快照"
            return out

        metrics = []
        prim = snapshot.get("primary") or {}
        sec = snapshot.get("secondary") or {}
        if prim:
            used = prim.get("used_percent", 0.0)
            metrics.append({
                "label": "5h 窗口", "used_pct": round(used, 1),
                "reset": _human_reset(prim.get("resets_at", 0)),
            })
        if sec:
            used = sec.get("used_percent", 0.0)
            metrics.append({
                "label": "周窗口", "used_pct": round(used, 1),
                "reset": _human_reset(sec.get("resets_at", 0)),
            })
        out["metrics"] = metrics
        out["status"] = "ok"
        # 标注快照新鲜度
        if snap_mtime:
            age_min = int((_now() - snap_mtime) / 60)
            out["detail"] = f"快照 {age_min}m 前" if age_min < 120 else \
                f"快照 {age_min // 60}h 前"
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
    return out


# ───────────────────── Antigravity ─────────────────────
def probe_antigravity() -> dict:
    """读 keychain 里的 OAuth token，调 Google loadCodeAssist 取套餐层级。"""
    out = {
        "id": "antigravity", "name": "Antigravity", "plan": "—",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://one.google.com/settings",
    }
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", "gemini",
             "-a", "antigravity", "-w"],
            capture_output=True, text=True, timeout=8,
        ).stdout.strip()
        if not raw:
            out["detail"] = "未登录"
            return out
        if raw.startswith("go-keyring-base64:"):
            raw = raw[len("go-keyring-base64:"):]
        blob = json.loads(base64.b64decode(raw))
        tok = blob.get("token", {})
        access = tok.get("access_token", "")
        expiry = tok.get("expiry", "")
        if not access:
            out["detail"] = "无 token"
            return out

        # token 是否过期(原型阶段过期就降级,不做 refresh)
        try:
            exp = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
            if exp < datetime.now(timezone.utc):
                out["detail"] = "token 已过期(请在 IDE 内刷新)"
                out["plan"] = "Google One AI Pro"
                return out
        except Exception:
            pass

        import urllib.request
        req = urllib.request.Request(
            "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            data=json.dumps({"metadata": {"pluginType": "GEMINI"}}).encode(),
            headers={"Authorization": f"Bearer {access}",
                     "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read())

        paid = data.get("paidTier", {}).get("name")
        cur = data.get("currentTier", {}).get("name", "")
        out["plan"] = paid or cur or "Gemini Code Assist"
        out["status"] = "ok"
        # loadCodeAssist 不返回配额百分比 → 显示层级,百分比待后续接口
        out["detail"] = "无量化配额(Google 未公开数字)"
        out["metrics"] = []
    except Exception as e:
        out["detail"] = f"{type(e).__name__}"
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
