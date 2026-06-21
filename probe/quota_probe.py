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
# OAuth client 凭证不硬编码 —— 运行时从 Antigravity app bundle 动态提取
# (避免泄露密钥,且 Antigravity 更新后自动跟随)

def _ag_find_client_creds():
    """从 Antigravity.app 的二进制里提取 OAuth client_id + secret。"""
    import re as _re
    paths = [
        "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
        os.path.join(HOME, "Library/Application Support/Antigravity/bin/agy-node"),
    ]
    cid_pat = _re.compile(rb"(\d{10,}-[a-z0-9]+\.apps\.googleusercontent\.com)")
    sec_pat = _re.compile(rb"(GOCSPX-[A-Za-z0-9_-]{20,})")
    found = {}
    for p in paths:
        if not os.path.exists(p):
            continue
        try:
            data = open(p, "rb").read()
            cids = cid_pat.findall(data)
            secs = sec_pat.findall(data)
            if cids and secs:
                # 配对:取第一组
                cid = cids[0].decode()
                sec = secs[0].decode()
                found.setdefault("clients", []).append((cid, sec))
        except Exception:
            continue
    return found.get("clients", [])

def _ag_get_token():
    """从 keychain 读 Antigravity OAuth token + expiry。"""
    raw = subprocess.run(
        ["security", "find-generic-password", "-s", "gemini",
         "-a", "antigravity", "-w"],
        capture_output=True, text=True, timeout=8,
    ).stdout.strip()
    if not raw:
        return None
    if raw.startswith("go-keyring-base64:"):
        raw = raw[len("go-keyring-base64:"):]
    return json.loads(base64.b64decode(raw))

def _ag_refresh_token(refresh_token: str) -> str:
    """用 Antigravity client 凭证刷新 access_token(不持久化,仅本次用)。"""
    import urllib.request, urllib.parse
    clients = _ag_find_client_creds()
    for cid, sec in clients:
        data = urllib.parse.urlencode({
            "client_id": cid, "client_secret": sec,
            "refresh_token": refresh_token, "grant_type": "refresh_token",
        }).encode()
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                "https://oauth2.googleapis.com/token", data=data, method="POST"),
                timeout=15)
            return json.loads(r.read())["access_token"]
        except Exception:
            continue
    return ""

def _iso_to_epoch(s: str) -> float:
    """ISO8601 → epoch。"""
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0

def probe_antigravity() -> dict:
    """调 Google retrieveUserQuota 取实时配额(按模型,取 Pro 最紧的)。
    token 从 keychain 读;过期则尝试刷新,刷新失败降级到 loadCodeAssist 层级。"""
    out = {
        "id": "antigravity", "name": "Antigravity", "plan": "—",
        "status": "error", "detail": "", "metrics": [],
        "url": "https://gemini.google.com/usage",
    }
    import urllib.request, urllib.error
    try:
        blob = _ag_get_token()
        if not blob:
            out["detail"] = "未登录(请在 Antigravity 内登录)"
            return out
        tok = blob.get("token", {})
        access = tok.get("access_token", "")
        refresh = tok.get("refresh_token", "")
        expiry = tok.get("expiry", "")

        # 判断是否过期
        expired = False
        if expiry:
            try:
                exp = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
                expired = exp < datetime.now(timezone.utc)
            except Exception:
                pass

        # 过期 → 尝试刷新
        if expired and refresh:
            new_access = _ag_refresh_token(refresh)
            if new_access:
                access = new_access
                expired = False

        if not access:
            out["detail"] = "无有效 token"
            return out

        headers = {"Authorization": f"Bearer {access}",
                   "Content-Type": "application/json"}

        # 主路径:retrieveUserQuota → 每模型实时配额
        try:
            req = urllib.request.Request(
                "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
                data=json.dumps({}).encode(), headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())

            buckets = data.get("buckets", [])
            # 取 Pro 模型里剩余最少的(最紧约束)
            pros = [b for b in buckets if "pro" in b.get("modelId", "").lower()]
            target = pros or buckets
            target.sort(key=lambda x: x.get("remainingFraction", 1))

            out["plan"] = "Google One AI Pro"
            out["status"] = "ok"
            out["detail"] = "实时"
            for b in target[:2]:
                remain = b.get("remainingFraction", 1)
                used = round((1 - remain) * 100, 1)
                mid = b.get("modelId", "").replace("gemini-", "")
                reset = _human_reset(_iso_to_epoch(b.get("resetTime", "")))
                out["metrics"].append({
                    "label": mid, "used_pct": used, "reset": reset,
                })
            return out
        except urllib.error.HTTPError:
            pass  # token 无 Pro 许可或其它 → 降级到 loadCodeAssist

        # 降级:loadCodeAssist → 只取套餐层级
        req = urllib.request.Request(
            "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            data=json.dumps({"metadata": {"pluginType": "GEMINI"}}).encode(),
            headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read())
        paid = data.get("paidTier", {}).get("name") or data.get("currentTier", {}).get("name", "")
        out["plan"] = paid or "Gemini Code Assist"
        out["status"] = "ok"
        out["detail"] = "仅层级(配额接口无权限)" if expired else "仅层级"
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
