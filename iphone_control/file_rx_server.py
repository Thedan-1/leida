"""
iphone_control.file_rx_server
-------------------------------
IPhoneFileTCPServer: PC 端 TCP 文件接收服务。

iPhone 在收到 STOP 命令后主动连接此服务上传 CSV 文件。

上传协议（iPhone → PC）:
  1) 文件名\n
  2) 文件大小（字节数，十进制字符串）\n
  3) 文件内容（size 字节原始数据）
"""

import socket
import threading
from pathlib import Path
from typing import Optional


class IPhoneFileTCPServer:
    """PC 端 TCP 文件接收服务。

    Parameters
    ----------
    save_dir:
        文件保存目录（等效于雷达数据的 POSTPROC_DIR）。
    host:
        监听地址，默认 ``"0.0.0.0"``（所有网卡）。
    port:
        监听端口，默认 10001。
    timeout_s:
        accept 超时（秒），控制停止轮询粒度；不影响文件接收超时。
    """

    def __init__(
        self,
        save_dir: Path,
        host: str = "0.0.0.0",
        port: int = 10001,
        timeout_s: float = 1.0,
    ):
        self.save_dir = Path(save_dir)
        self.host = host
        self.port = int(port)
        self.timeout_s = float(timeout_s)
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._srv: Optional[socket.socket] = None

    # ------------------------------------------------------------------
    # 内部：接收一行
    # ------------------------------------------------------------------

    @staticmethod
    def _recv_line(conn: socket.socket) -> Optional[str]:
        buf = b""
        while True:
            ch = conn.recv(1)
            if not ch:
                return None
            if ch == b"\n":
                return buf.decode("utf-8", errors="ignore").strip()
            buf += ch

    # ------------------------------------------------------------------
    # 内部：处理单个连接
    # ------------------------------------------------------------------

    def _handle_conn(self, conn: socket.socket, addr):
        print(f"📥 iPhone 上传连接: {addr}")
        name = self._recv_line(conn)
        size_line = self._recv_line(conn)
        if not name or not size_line:
            print("⚠️ 接收文件头失败，断开。")
            return

        total = int(size_line)
        # 只取文件名部分，防止路径遍历
        safe_name = Path(name).name
        out = self.save_dir / safe_name
        self.save_dir.mkdir(parents=True, exist_ok=True)

        got = 0
        with open(out, "wb") as f:
            while got < total:
                chunk = conn.recv(min(65536, total - got))
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)

        if got == total:
            print(f"✅ iPhone 文件已保存: {out} ({got / 1e6:.2f} MB)")
        else:
            print(f"⚠️ 文件接收不完整: {out} ({got}/{total} 字节)")

    # ------------------------------------------------------------------
    # 内部：主循环
    # ------------------------------------------------------------------

    def _run(self):
        self.save_dir.mkdir(parents=True, exist_ok=True)
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind((self.host, self.port))
        self._srv.listen(5)
        self._srv.settimeout(self.timeout_s)
        print(f"📥 文件接收服务(TCP)已启动: {self.host}:{self.port} -> {self.save_dir}")

        while not self._stop.is_set():
            try:
                conn, addr = self._srv.accept()
            except socket.timeout:
                continue
            except Exception:
                break
            with conn:
                try:
                    self._handle_conn(conn, addr)
                except Exception as e:
                    print(f"⚠️ 文件接收异常: {e}")

    # ------------------------------------------------------------------
    # 公开接口
    # ------------------------------------------------------------------

    def start(self):
        """后台启动文件接收服务（daemon 线程）。"""
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, daemon=True, name="iphone-file-rx"
        )
        self._thread.start()

    def stop(self):
        """停止文件接收服务，等待线程退出。"""
        self._stop.set()
        if self._srv is not None:
            try:
                self._srv.close()
            except Exception:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        print("📥 文件接收服务(TCP)已关闭。")
