import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from scripts.eval.harbor.bench import executors
from scripts.eval.harbor.bench.account import Account
from scripts.eval.harbor.profiling import TimingRelay


class ManagerSession:
    def __init__(self, state_dir):
        self.account = Account(state_dir)
        if not self.account.session:
            raise ValueError("请先在管理机器上运行 metacodes login")
        self.gateway = self.account.gateway

    def current(self):
        return self.refresh(None)

    def refresh(self, stale):
        try:
            session = self.account.session.access(self.account.request, stale)
        except (ValueError, OSError):
            return None
        if session["gateway_url"] == self.gateway:
            return session["access_token"]
        return None


def peer_key(path):
    if not path:
        raise ValueError("share 需要 --peer-env，指定本节点专用的配对文件")
    path = path.expanduser()
    if not path.exists():
        pending = tempfile.NamedTemporaryFile(dir=path.parent, delete=False)
        try:
            with pending:
                pending.write(f"MODEL_MANAGER_KEY=mcpeer-{secrets.token_hex(32)}\n".encode("ascii"))
                pending.flush()
                os.fsync(pending.fileno())
            try:
                os.link(pending.name, path)
            except FileExistsError:
                pass
        finally:
            Path(pending.name).unlink()
    with path.open("rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or (os.name == "posix" and info.st_mode & 0o077):
            raise ValueError("配对文件必须是私有普通文件（0600）")
        value = re.fullmatch(rb"MODEL_MANAGER_KEY=(mcpeer-[0-9a-f]{64})\r?\n?", stream.read(256))
        if not value or stream.read(1):
            raise ValueError("配对文件需要一行 MODEL_MANAGER_KEY=mcpeer-<64 位随机十六进制数>")
        return value[1].decode("ascii")


def share(cfg, name, key_file, port, state):
    if not name:
        raise ValueError("share 需要 --executor 指定一台 SSH 节点")
    executor = executors.find(cfg, name)
    if not isinstance(executor, executors.SshExecutor):
        raise ValueError("share 需要 SSH 执行机器")
    port = 18767 if port is None else port
    if not 1024 <= port <= 65535:
        raise ValueError("远端回环端口必须在 1024 到 65535 之间")
    session = ManagerSession(state)
    if not session.current():
        raise ValueError("管理机器的 Metask 会话当前不可用")
    key = peer_key(key_file)
    with TimingRelay(session.gateway, session, state, bind="127.0.0.1", token=key,
                     record=False, model_gateway=True) as relay:
        argv = executors.ssh_argv(executor, ["cat"], reverse=(port, relay.server.server_port), paired=True)
        print(f"连接 {name} 的模型接口 http://127.0.0.1:{port}。按 Ctrl-C 停止共享。", file=sys.stderr, flush=True)
        try:
            while True:
                with subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL) as tunnel:
                    try:
                        code = tunnel.wait()
                    finally:
                        tunnel.stdin.close()
                        if tunnel.poll() is None:
                            tunnel.terminate()
                if code != 255:
                    return code
                print("SSH 连接不可用，5 秒后重新连接。", file=sys.stderr, flush=True)
                time.sleep(5)
        except KeyboardInterrupt:
            return 0
