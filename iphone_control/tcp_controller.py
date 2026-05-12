"""
iphone_control.tcp_controller
-----------------------------
IPhoneTCPController: 在 PC 侧以 TCP 客户端连接 iPhone（iPhone 监听端口 9999）。
支持发送 GO / STOP 命令并接收单行回复。
"""

import socket
import time
from typing import Optional


class IPhoneTCPController:
    """TCP controller for iPhone GO/STOP recording workflow.

    iPhone 需先在 App 内开启 TCP 监听（端口默认 9999），
    PC 作为客户端主动连接。
    """

    def __init__(self, ip: str, port: int = 9999, timeout_s: float = 3.0):
        self.addr = (ip, port)
        self.timeout_s = timeout_s
        self.sock: Optional[socket.socket] = None

    # ------------------------------------------------------------------
    # 连接 / 关闭
    # ------------------------------------------------------------------

    def open(self):
        """建立 TCP 连接并配置 Keepalive，防止路由器长时间空闲断连。"""
        self.sock = socket.create_connection(self.addr, timeout=self.timeout_s)
        self.sock.settimeout(self.timeout_s)

        # TCP Keepalive
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 10)
        if hasattr(socket, "TCP_KEEPINTVL"):
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)
        if hasattr(socket, "TCP_KEEPCNT"):
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)

        print(f"📱 iPhone TCP 已连接: {self.addr[0]}:{self.addr[1]}")

    def close(self):
        """关闭连接。"""
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    # ------------------------------------------------------------------
    # 内部工具
    # ------------------------------------------------------------------

    def _recv_line(self) -> Optional[str]:
        """读取直到 \\n，返回去除首尾空白的字符串。"""
        if self.sock is None:
            return None
        buf = b""
        while True:
            ch = self.sock.recv(1)
            if not ch:
                return None
            if ch == b"\n":
                return buf.decode("utf-8", errors="ignore").strip()
            buf += ch

    # ------------------------------------------------------------------
    # 发送命令
    # ------------------------------------------------------------------

    def send(self, cmd: str, expect_prefix: Optional[str] = None) -> Optional[str]:
        """发送命令行并可选等待单行回复。

        Parameters
        ----------
        cmd:
            命令字符串（不含\\n），如 ``"GO"`` / ``"STOP"``。
        expect_prefix:
            若不为 None，等待 iPhone 回复并打印；为 None 则不等待。

        Returns
        -------
        str or None:
            收到的回复行；未启用接收、超时或出错时为 None。
        """
        if self.sock is None:
            return None
        try:
            self.sock.sendall((cmd.strip() + "\n").encode("utf-8"))
            print(f"📱 TCP -> {cmd}")
            if expect_prefix is None:
                return None
            reply = self._recv_line()
            if reply:
                print(f"📱 TCP <- {reply}")
            return reply
        except socket.timeout:
            print(f"⚠️ iPhone TCP 超时 ({cmd})")
            return None
        except Exception as e:
            print(f"⚠️ iPhone TCP 发送失败 ({cmd}): {e}")
            return None

    def time_sync(self, n_samples: int = 5) -> tuple:
        """NTP 式时钟同步：计算 iPhone 时钟与 PC 时钟的偏差。

        原理：PC 记录 t1，发 TIMESYNC；iPhone 立即回复自己的 Unix 时间 t2；
        PC 收到后记录 t3。offset = t2 - (t1+t3)/2，重复 n_samples 次取平均。

        Returns
        -------
        (offset_s, rtt_ms) : tuple[float, float]
            offset_s — iPhone 时钟 - PC 时钟（秒），后处理时用 iPhone_t - offset 得到 PC 等效时间
            rtt_ms   — 平均往返时延（毫秒），越小越准
        """
        if self.sock is None:
            return 0.0, 0.0

        offsets = []
        rtts = []
        old_timeout = self.sock.gettimeout()
        self.sock.settimeout(5.0)
        try:
            for _ in range(n_samples):
                t1 = time.time()
                self.sock.sendall(b"TIMESYNC\n")
                reply = self._recv_line()          # "TIMESYNC:<unix_float>"
                t3 = time.time()
                if reply and reply.startswith("TIMESYNC:"):
                    t2 = float(reply[len("TIMESYNC:"):])
                    offsets.append(t2 - (t1 + t3) / 2.0)
                    rtts.append((t3 - t1) * 1000.0)
        except Exception as e:
            print(f"⚠️ 时钟同步失败: {e}")
        finally:
            if self.sock:
                self.sock.settimeout(old_timeout)

        if not offsets:
            return 0.0, 0.0

        avg_offset = sum(offsets) / len(offsets)
        avg_rtt_ms = sum(rtts) / len(rtts)
        print(f"📱 时钟同步完成: offset={avg_offset*1000:.2f}ms, RTT={avg_rtt_ms:.2f}ms ({len(offsets)} 次)")
        return avg_offset, avg_rtt_ms

    def wait_for_done(self, timeout_s: float = 60.0) -> bool:
        """等待 iPhone 在上传完文件后发来 ``DONE`` 信号。

        iPhone 的 ``uploadFileToPC()`` 完成后会在命令 socket（9999）上发
        ``"DONE\\n"``，PC 收到后即可立刻继续，无需死等固定秒数。

        Parameters
        ----------
        timeout_s:
            最长等待秒数，默认 60s（应大于文件传输可能耗时的上限）。

        Returns
        -------
        bool:
            ``True`` 表示收到 DONE；``False`` 表示超时或连接断开。
        """
        if self.sock is None:
            return False
        old_timeout = self.sock.gettimeout()
        self.sock.settimeout(timeout_s)
        try:
            print(f"⏳ 等待 iPhone DONE 信号（最多 {timeout_s:.0f}s）...")
            line = self._recv_line()
            if line and line.upper() == "DONE":
                print("✅ 收到 iPhone DONE，上传完毕。")
                return True
            else:
                print(f"⚠️ 等待 DONE 时收到意外内容: {line!r}")
                return False
        except socket.timeout:
            print("⚠️ 等待 iPhone DONE 超时。")
            return False
        except Exception as e:
            print(f"⚠️ 等待 DONE 时出错: {e}")
            return False
        finally:
            if self.sock:
                self.sock.settimeout(old_timeout)

    # ------------------------------------------------------------------
    # 上下文管理器支持
    # ------------------------------------------------------------------

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *_):
        self.close()
