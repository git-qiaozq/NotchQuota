"""
agy_usage.py — 驱动 agy CLI 的 /usage 命令抓取真实配额。
agy 自己处理 OAuth token 刷新 + gRPC + Pro license,比直调 REST API 可靠。

原理:用 pty 模拟交互式会话,登录后发 /usage,解析 TUI 文本输出。
"""
import os, pty, select, time, re, signal


def _clean(text: str) -> str:
    """去掉 ANSI 控制序列和 TUI 装饰字符。"""
    text = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', text)      # CSI 序列
    text = re.sub(r'\x1b[()][AB012]', '', text)             # charset 切换
    text = re.sub(r'[\u2800-\u28ff]', '', text)             # 盲文 spinner
    text = re.sub(r'\r', '\n', text)                        # CR → LF
    text = re.sub(r'\n{3,}', '\n\n', text)                  # 压缩空行
    return text


def _parse_usage(text: str) -> list:
    """解析 /usage 输出,返回 [{group, models, weekly:{pct,reset}, five_hour:{pct,reset}}, ...]"""
    groups = []
    # 匹配 "XXX MODELS" 分组标题
    group_pat = re.compile(
        r'([A-Z][A-Z /&]+MODELS).*?(?=[A-Z][A-Z /&]+MODELS|$)', re.S)
    for gm in group_pat.finditer(text):
        block = gm.group(0)
        # 组名里的 "Models within this group: X, Y"
        name_m = re.search(r'within this group:\s*([^\n]+)', block)
        models = name_m.group(1).strip() if name_m else ""
        group_title = re.match(r'([A-Z][A-Z /&]+MODELS)', block).group(1).strip()
        # 每个限额窗口: 进度条百分比 + remaining + Refreshes in
        limits = {}
        for win in ['Weekly Limit', 'Five Hour Limit']:
            key = win.lower().replace(' ', '_')
            # 格式1(常用): [进度条] X%  Y% remaining · Refreshes in Zh Wm
            wp = re.search(
                rf'{win}\s*\n\s*\[[█░]+\]\s*([\d.]+)%\s*\n\s*(\d+)%\s*remaining'
                rf'(?:.*?Refreshes in\s*([^\n]+?))?\s*\n',
                block, re.S)
            if wp:
                reset_raw = (wp.group(3) or '').strip().rstrip('.')
                hm = re.search(r'(?:(\d+)h)?\s*(?:(\d+)m)?', reset_raw)
                total_h = None
                if hm and (hm.group(1) or hm.group(2)):
                    h = int(hm.group(1) or 0)
                    m = int(hm.group(2) or 0)
                    total_h = round(h + m / 60, 2)
                limits[key] = {
                    'used_pct': round(100 - float(wp.group(2)), 1),
                    'remaining_pct': float(wp.group(2)),
                    'bar_pct': float(wp.group(1)),
                    'reset': reset_raw,
                    'reset_hours': total_h,
                }
                continue
            # 格式2(配额充裕): [进度条] X%  Quota available
            qa = re.search(
                rf'{win}\s*\n\s*\[[█░]+\]\s*([\d.]+)%\s*\n\s*Quota available',
                block, re.S)
            if qa:
                pct = float(qa.group(1))
                limits[key] = {
                    'used_pct': round(100 - pct, 1),
                    'remaining_pct': pct,
                    'bar_pct': pct,
                    'reset': '',
                    'reset_hours': None,
                }
        if limits:
            # 按组名去重:agy TUI 刷新时会在 buffer 里重复绘制,只保留第一份
            if not any(g['group'] == group_title for g in groups):
                groups.append({
                    'group': group_title,
                    'models': models,
                    **limits,
                })
    return groups


def _resolve_agy() -> str:
    """解析 agy 的绝对路径。PATH 找不到时 fallback 到 ~/.local/bin/agy。"""
    import shutil
    p = shutil.which("agy")
    if p:
        return p
    # GUI app 的子进程 PATH 可能不含 ~/.local/bin → fallback
    fallback = os.path.expanduser("~/.local/bin/agy")
    if os.path.exists(fallback):
        return fallback
    return "agy"   # 让 execvp 报原始错误


def _wait_child(pid: int, timeout: float) -> bool:
    """等待子进程退出；退出返回 True，超时返回 False。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return True
        except OSError:
            return True
        if done == pid:
            return True
        time.sleep(0.1)
    return False


def _read_available(master: int, buf: bytes, deadline: float) -> bytes:
    """在等待退出时继续收集 TUI 输出，避免丢掉最后一屏 /usage。"""
    while time.time() < deadline:
        try:
            r, _, _ = select.select([master], [], [], 0.1)
        except OSError:
            break
        if not r:
            continue
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
    return buf


def _shutdown_agy(pid: int, master: int, buf: bytes) -> bytes:
    """优雅退出 agy，给 OAuth/token 刷新留出落盘时间。"""
    try:
        os.write(master, b'\x1b')
        time.sleep(0.1)
        os.write(master, b'/exit\r')
    except OSError:
        pass

    graceful_deadline = time.time() + 8
    while time.time() < graceful_deadline:
        buf = _read_available(master, buf, min(time.time() + 0.3, graceful_deadline))
        if _wait_child(pid, 0.1):
            return buf

    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return buf
    if _wait_child(pid, 3):
        return buf

    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    _wait_child(pid, 2)
    return buf


def _kill_child_if_running(pid: int) -> None:
    """异常路径兜底清理，避免遗留 agy 子进程。"""
    try:
        done, _ = os.waitpid(pid, os.WNOHANG)
    except OSError:
        return
    if done == pid:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return
    if _wait_child(pid, 2):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    _wait_child(pid, 1)


def fetch_usage(timeout_total: int = 28) -> dict:
    """驱动 agy /usage,返回解析后的结构化配额。
    返回 {status, detail, groups:[...]} 或 {status:'error', detail}。"""
    master = None
    pid = None
    try:
        agy_path = _resolve_agy()
        master, slave = pty.openpty()
        pid = os.fork()
        if pid == 0:
            os.setsid()
            os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
            os.close(master)
            import fcntl, termios, struct
            fcntl.ioctl(slave, termios.TIOCSWINSZ,
                        struct.pack('HHHH', 60, 160, 0, 0))
            try:
                os.execvp(agy_path, [agy_path])
            except OSError:
                os._exit(127)
        os.close(slave)

        buf = b''
        start = time.time()
        sent = False
        sent_t = 0
        while time.time() - start < timeout_total:
            r, _, _ = select.select([master], [], [], 0.3)
            if r:
                try:
                    data = os.read(master, 4096)
                except OSError:
                    break
                if not data:
                    break
                buf += data
            txt = buf.decode('utf-8', 'replace')
            # 登录完成标志:看到邮箱 + Pro + 等几秒让 TUI 就绪
            if not sent and ('AI Pro' in txt or 'Pro (High)' in txt) \
                    and time.time() - start > 6:
                time.sleep(0.8)
                # 发 esc 关补全菜单,再逐字符发 /usage
                os.write(master, b'\x1b')
                time.sleep(0.3)
                for ch in '/usage':
                    os.write(master, ch.encode())
                    time.sleep(0.05)
                time.sleep(0.3)
                os.write(master, b'\r')
                sent = True
                sent_t = time.time()
            # /usage 发出后等数据回来
            if sent and time.time() - sent_t > 7:
                break

        # 收尾:不要立刻 SIGKILL，避免打断 agy 写回 OAuth/Keychain 状态。
        buf = _shutdown_agy(pid, master, buf)
        try:
            os.close(master)
        except OSError:
            pass
        master = None

        text = _clean(buf.decode('utf-8', 'replace'))
        groups = _parse_usage(text)
        if groups:
            return {'status': 'ok', 'detail': '实时(agy)', 'groups': groups}
        # 解析失败 → 返回原始文本片段便于调试
        snippet = text[-800:] if text else "(无输出)"
        return {'status': 'error', 'detail': '解析失败', 'raw': snippet}
    except FileNotFoundError:
        return {'status': 'error', 'detail': '未安装 agy'}
    except Exception as e:
        return {'status': 'error', 'detail': f'{type(e).__name__}: {e}'}
    finally:
        if master is not None:
            try:
                os.close(master)
            except OSError:
                pass
        if pid is not None:
            _kill_child_if_running(pid)


if __name__ == '__main__':
    import json
    print(json.dumps(fetch_usage(), ensure_ascii=False, indent=2))
