"""
agy_usage.py — 驱动 agy CLI 的 /usage 命令抓取真实配额。
agy 自己处理 OAuth token 刷新 + gRPC + Pro license,比直调 REST API 可靠。

原理:用 pty 模拟交互式会话,登录后发 /usage,解析 TUI 文本输出。
为了避免每分钟启动 agy 触发 OAuth 窗口,这里通过本地 daemon 复用同一个 agy 会话。
"""
import os, pty, select, time, re, signal, sys, socket, subprocess, json, threading, fcntl


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
            # 按组名去重:agy TUI 会重复绘制;保留最后一份,避免 daemon 长缓冲返回旧数据
            entry = {
                'group': group_title,
                'models': models,
                **limits,
            }
            for i, g in enumerate(groups):
                if g['group'] == group_title:
                    groups[i] = entry
                    break
            else:
                groups.append(entry)
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


_RUNTIME_DIR = os.path.join(os.path.expanduser("~"), ".cache", "notchquota")
_SOCKET_PATH = os.path.join(_RUNTIME_DIR, "agy_daemon.sock")
_LOCK_PATH = os.path.join(_RUNTIME_DIR, "agy_daemon.lock")
_DAEMON_LOCK_PATH = os.path.join(_RUNTIME_DIR, "agy_daemon.run.lock")
_LOG_PATH = os.path.join(_RUNTIME_DIR, "agy_daemon.log")


def _network_ready() -> bool:
    for host in ("daily-cloudcode-pa.googleapis.com", "www.googleapis.com"):
        try:
            socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
        except OSError:
            return False
    return True


class _AgySession:
    def __init__(self):
        self.master = None
        self.pid = None
        self.buf = b''
        self.started_at = 0.0
        self.sent_once = False
        self.login_selected = False
        self.lock = threading.Lock()
        self._start()

    def _log(self, msg: str) -> None:
        try:
            os.makedirs(_RUNTIME_DIR, exist_ok=True)
            with open(_LOG_PATH, "a") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        except Exception:
            pass

    def _start(self) -> None:
        self.close()
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
        self.master = master
        self.pid = pid
        self.buf = b''
        self.started_at = time.time()
        self.sent_once = False
        self.login_selected = False
        self._log(f"started agy pid={pid}")

    def _is_running(self) -> bool:
        if self.pid is None:
            return False
        try:
            done, _ = os.waitpid(self.pid, os.WNOHANG)
        except OSError:
            return False
        if done == 0:
            return True
        self.pid = None
        return False

    def _read_for(self, duration: float) -> None:
        deadline = time.time() + duration
        while time.time() < deadline and self.master is not None:
            try:
                r, _, _ = select.select([self.master], [], [], 0.15)
            except OSError:
                break
            if r:
                try:
                    data = os.read(self.master, 4096)
                except OSError:
                    break
                if not data:
                    break
                self.buf += data
                if len(self.buf) > 200_000:
                    self.buf = self.buf[-120_000:]

    def _wait_ready(self, timeout: float) -> bool:
        start = time.time()
        while time.time() - start < timeout:
            if not self._is_running():
                self._start()
            self._read_for(0.3)
            txt = self.buf.decode('utf-8', 'replace')
            if not self.login_selected and 'Select login method:' in txt and 'Google OAuth' in txt:
                self.login_selected = True
                self._log("agy is waiting for manual login")
            if ('AI Pro' in txt or 'Pro (High)' in txt) and time.time() - self.started_at > 5:
                return True
        return False

    def _auth_waiting_result(self, text: str):
        if 'Select login method:' in text and 'Google OAuth' in text:
            self._log("waiting for manual Antigravity login")
            return {
                'status': 'error',
                'detail': '等待手动登录 Antigravity',
                'raw': text[-800:] if text else '',
            }
        if 'paste the authorization code' in text or 'accounts.google.com/o/oauth2' in text:
            self._log("waiting for OAuth authorization code")
            return {
                'status': 'error',
                'detail': '等待 Antigravity OAuth 一次性授权',
                'raw': text[-800:] if text else '',
            }
        return None

    def _startup_retry_reason(self, text: str):
        checks = [
            ('no such host', 'dns not ready'),
            ('network is unreachable', 'network not ready'),
            ('temporary failure in name resolution', 'dns not ready'),
            ('keyringAuth: timed out', 'keyring timed out'),
        ]
        lower = text.lower()
        for needle, reason in checks:
            if needle.lower() in lower:
                return reason
        return None

    def fetch_usage(self, timeout_total: int = 28) -> dict:
        with self.lock:
            try:
                if not self._is_running():
                    self._start()
                ready = self._wait_ready(max(8, timeout_total - 10))
                if not ready:
                    text = _clean(self.buf.decode('utf-8', 'replace'))
                    retry_reason = self._startup_retry_reason(text)
                    if retry_reason:
                        self._log(f"restarting agy after startup failure: {retry_reason}")
                        self._start()
                        ready = self._wait_ready(max(8, timeout_total - 10))
                        text = _clean(self.buf.decode('utf-8', 'replace'))
                if not ready:
                    auth_waiting = self._auth_waiting_result(text)
                    if auth_waiting:
                        return auth_waiting
                    return {'status': 'error', 'detail': 'agy 未就绪', 'raw': text[-800:] if text else ''}

                marker = f"__NOTCHQUOTA_USAGE_{int(time.time() * 1000)}__"
                self.buf += f"\n{marker}\n".encode()
                os.write(self.master, b'\x1b')
                time.sleep(0.15)
                os.write(self.master, b'\x15')
                time.sleep(0.05)
                for ch in '/usage':
                    os.write(self.master, ch.encode())
                    time.sleep(0.03)
                os.write(self.master, b'\r')
                self.sent_once = True

                deadline = time.time() + 9
                groups = []
                text = ''
                while time.time() < deadline:
                    self._read_for(0.3)
                    text = _clean(self.buf.decode('utf-8', 'replace'))
                    recent = text.split(marker, 1)[-1]
                    groups = _parse_usage(recent)
                    if groups and time.time() < deadline - 1:
                        # 多等一小会儿让 TUI 刷新完整,然后取最后一次绘制
                        self._read_for(1.0)
                        text = _clean(self.buf.decode('utf-8', 'replace'))
                        recent = text.split(marker, 1)[-1]
                        groups = _parse_usage(recent)
                        break
                if groups:
                    return {'status': 'ok', 'detail': '实时(agy daemon)', 'groups': groups}
                return {'status': 'error', 'detail': '解析失败', 'raw': text[-800:] if text else '(无输出)'}
            except Exception as e:
                self._log(f"fetch error {type(e).__name__}: {e}")
                return {'status': 'error', 'detail': f'{type(e).__name__}: {e}'}

    def close(self) -> None:
        if self.master is not None and self.pid is not None:
            try:
                _shutdown_agy(self.pid, self.master, self.buf)
            except Exception:
                _kill_child_if_running(self.pid)
        elif self.pid is not None:
            _kill_child_if_running(self.pid)
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
        self.master = None
        self.pid = None


def _daemon_log(msg: str) -> None:
    try:
        os.makedirs(_RUNTIME_DIR, exist_ok=True)
        with open(_LOG_PATH, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def _run_daemon() -> None:
    os.makedirs(_RUNTIME_DIR, exist_ok=True)
    run_lock = open(_DAEMON_LOCK_PATH, "w")
    try:
        fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        _daemon_log("daemon already running; exiting")
        return
    try:
        os.unlink(_SOCKET_PATH)
    except FileNotFoundError:
        pass
    except OSError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(_SOCKET_PATH)
    os.chmod(_SOCKET_PATH, 0o600)
    server.listen(4)
    session = _AgySession()
    last_seen = time.time()
    _daemon_log("daemon ready")

    def handle(conn):
        nonlocal last_seen
        with conn:
            last_seen = time.time()
            cmd = conn.recv(64).decode('utf-8', 'replace').strip()
            if cmd == "usage":
                result = session.fetch_usage()
            elif cmd == "ping":
                result = {"status": "ok", "detail": "pong"}
            else:
                result = {"status": "error", "detail": "未知命令"}
            conn.sendall(json.dumps(result, ensure_ascii=False).encode() + b"\n")

    try:
        while True:
            if time.time() - last_seen > 12 * 3600:
                _daemon_log("idle timeout")
                break
            server.settimeout(5)
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
    finally:
        session.close()
        server.close()
        try:
            os.unlink(_SOCKET_PATH)
        except OSError:
            pass


def _daemon_request(cmd: str, timeout: float) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(_SOCKET_PATH)
        s.sendall(cmd.encode() + b"\n")
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
        return json.loads(b''.join(chunks).decode('utf-8'))


def _ensure_daemon(timeout: float = 20) -> dict:
    os.makedirs(_RUNTIME_DIR, exist_ok=True)
    with open(_LOCK_PATH, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            return _daemon_request("ping", 2)
        except Exception:
            try:
                os.unlink(_SOCKET_PATH)
            except OSError:
                pass
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--daemon"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.time() + timeout
        last_err = None
        while time.time() < deadline:
            try:
                return _daemon_request("ping", 2)
            except Exception as e:
                last_err = e
                time.sleep(0.3)
        return {"status": "error", "detail": f"agy daemon 启动失败: {last_err}"}


def fetch_usage(timeout_total: int = 28) -> dict:
    """通过常驻 agy daemon 实时发送 /usage 并返回结构化配额。"""
    if not _network_ready():
        return {'status': 'error', 'detail': '网络未就绪'}
    ready = _ensure_daemon()
    if ready.get("status") != "ok":
        return ready
    try:
        return _daemon_request("usage", timeout_total + 5)
    except Exception as e:
        return {'status': 'error', 'detail': f'daemon 请求失败: {type(e).__name__}: {e}'}


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == "--daemon":
        _run_daemon()
    else:
        print(json.dumps(fetch_usage(), ensure_ascii=False, indent=2))
