"""
iphone_control.session
-----------------------
IPhoneSession: 一站式封装，把 TCP 指令控制 + 文件接收两个功能合并成
一个对象，调用方只需要三步：

    session = IPhoneSession(ip="192.168.31.83", save_dir=POSTPROC_DIR)
    session.start()          # 连接 iPhone 并发送 GO，同时开启文件接收服务
    # ... 雷达采集主循环 ...
    session.stop_and_wait()  # 发送 STOP，等待 iPhone 上传文件，清理资源

也支持 from_config() 类方法，直接传原有 CONFIG 字典：

    session = IPhoneSession.from_config(CONFIG, save_dir=POSTPROC_DIR)
"""

import json
import time
from pathlib import Path
from typing import Optional

from .tcp_controller import IPhoneTCPController
from .file_rx_server import IPhoneFileTCPServer


class IPhoneSession:
    """统一管理 iPhone TCP 指令通道 + 文件接收服务的会话对象。

    Parameters
    ----------
    ip:
        iPhone 的 IP 地址。
    control_port:
        iPhone 监听 GO/STOP 指令的端口（默认 9999）。
    file_rx_port:
        PC 端文件接收服务监听端口（默认 10001）。
    save_dir:
        文件保存目录（与雷达数据保存在同一目录）。
    timeout_s:
        TCP 指令连接超时（秒）。
    file_rx_timeout_s:
        文件接收服务 accept 超时（秒），影响停止响应速度。
    file_rx_host:
        文件接收服务绑定地址（默认 "0.0.0.0"）。
    send_go_on_start:
        调用 start() 时是否自动发送 GO 命令（默认 True）。
    send_stop_on_exit:
        调用 stop_and_wait() 时是否发送 STOP 命令（默认 True）。
    enable_file_rx:
        是否启用文件接收服务（默认 True）。
    upload_wait_s:
        发送 STOP 后等待 iPhone 上传文件的最长秒数（默认 30）。
    """

    def __init__(
        self,
        ip: str,
        save_dir: Path,
        control_port: int = 9999,
        file_rx_port: int = 10001,
        timeout_s: float = 3.0,
        file_rx_timeout_s: float = 1.0,
        file_rx_host: str = "0.0.0.0",
        send_go_on_start: bool = True,
        send_stop_on_exit: bool = True,
        enable_file_rx: bool = True,
        upload_wait_s: float = 30.0,
    ):
        self._ip = ip
        self._save_dir = Path(save_dir)
        self._control_port = control_port
        self._file_rx_port = file_rx_port
        self._timeout_s = timeout_s
        self._file_rx_timeout_s = file_rx_timeout_s
        self._file_rx_host = file_rx_host
        self._send_go_on_start = send_go_on_start
        self._send_stop_on_exit = send_stop_on_exit
        self._enable_file_rx = enable_file_rx
        self._upload_wait_s = upload_wait_s

        self._ctrl: Optional[IPhoneTCPController] = None
        self._file_rx: Optional[IPhoneFileTCPServer] = None
        self._active = False

    # ------------------------------------------------------------------
    # 工厂方法：从原有 CONFIG 字典构建
    # ------------------------------------------------------------------

    @classmethod
    def from_config(cls, config: dict, save_dir: Path) -> "IPhoneSession":
        """从 radarControl 风格的 CONFIG 字典创建会话。

        只需在脚本顶部加::

            from iphone_control import IPhoneSession
            iphone_session = IPhoneSession.from_config(CONFIG, save_dir=POSTPROC_DIR)

        CONFIG 中识别的键（均为可选，有默认值）:
          USE_IPHONE_TCP, IPHONE_TCP_IP, IPHONE_TCP_PORT, IPHONE_TCP_TIMEOUT_S,
          IPHONE_SEND_GO_ON_START, IPHONE_SEND_STOP_ON_EXIT,
          IPHONE_FILE_RX_ENABLED, IPHONE_FILE_RX_HOST, IPHONE_FILE_RX_PORT,
          IPHONE_FILE_RX_TIMEOUT_S
        """
        return cls(
            ip=str(config.get("IPHONE_TCP_IP", "127.0.0.1")),
            save_dir=save_dir,
            control_port=int(config.get("IPHONE_TCP_PORT", 9999)),
            file_rx_port=int(config.get("IPHONE_FILE_RX_PORT", 10001)),
            timeout_s=float(config.get("IPHONE_TCP_TIMEOUT_S", 3.0)),
            file_rx_timeout_s=float(config.get("IPHONE_FILE_RX_TIMEOUT_S", 1.0)),
            file_rx_host=str(config.get("IPHONE_FILE_RX_HOST", "0.0.0.0")),
            send_go_on_start=bool(config.get("IPHONE_SEND_GO_ON_START", True)),
            send_stop_on_exit=bool(config.get("IPHONE_SEND_STOP_ON_EXIT", True)),
            enable_file_rx=bool(config.get("IPHONE_FILE_RX_ENABLED", True)),
        )

    # ------------------------------------------------------------------
    # 主要接口
    # ------------------------------------------------------------------

    def start(self):
        """连接 iPhone 并发送 GO，同时启动文件接收服务。

        连接失败时打印警告但不抛异常，后续 send() 调用会静默跳过。
        文件接收服务始终尝试启动（不依赖指令通道成功）。
        """
        # 1. 文件接收服务（先启动，确保 iPhone 上传时已就绪）
        if self._enable_file_rx:
            self._file_rx = IPhoneFileTCPServer(
                save_dir=self._save_dir,
                host=self._file_rx_host,
                port=self._file_rx_port,
                timeout_s=self._file_rx_timeout_s,
            )
            self._file_rx.start()

        # 2. iPhone 指令通道
        try:
            self._ctrl = IPhoneTCPController(
                ip=self._ip,
                port=self._control_port,
                timeout_s=self._timeout_s,
            )
            self._ctrl.open()

            # 发 GO 前先做时钟同步，算出 iPhone-PC 时钟偏差
            offset_s, rtt_ms = self._ctrl.time_sync()

            if self._send_go_on_start:
                t_go = time.time()
                self._ctrl.send("GO", expect_prefix="RECORDING")
            else:
                t_go = time.time()

            # 写 sync_meta.json，供后处理脚本对齐时间戳
            sync_meta = {
                "t_go_unix": t_go,
                "clock_offset_iphone_minus_pc": offset_s,
                "sync_rtt_ms": rtt_ms,
                "note": "iphone_real_time = iphone_csv_timestamp - clock_offset_iphone_minus_pc"
            }
            meta_path = self._save_dir / "sync_meta.json"
            meta_path.write_text(json.dumps(sync_meta, indent=2))
            print(f"📄 sync_meta.json 已写入: {meta_path}")

        except Exception as e:
            print(f"⚠️ iPhone TCP 初始化失败: {e}")
            self._ctrl = None

        self._active = True

    def send(self, cmd: str, expect_prefix: Optional[str] = None) -> Optional[str]:
        """向 iPhone 发送任意命令，返回回复行（若有）。"""
        if self._ctrl is None:
            return None
        return self._ctrl.send(cmd, expect_prefix=expect_prefix)

    def stop_and_wait(self):
        """发送 STOP，等待 iPhone 上传文件完成（DONE 信号），然后关闭所有资源。"""
        if not self._active:
            return

        if self._ctrl is not None:
            try:
                if self._send_stop_on_exit:
                    self._ctrl.send("STOP", expect_prefix="STOPPED")
                    if self._enable_file_rx and self._file_rx is not None:
                        # 等待 iPhone 上传完成后主动发来的 DONE 信号
                        # 比 time.sleep(30) 更精确：传完即继续，不会多等也不会超时太早
                        self._ctrl.wait_for_done(timeout_s=self._upload_wait_s)
            finally:
                self._ctrl.close()
                self._ctrl = None
                print("📱 iPhone TCP 已关闭。")

        if self._file_rx is not None:
            self._file_rx.stop()
            self._file_rx = None

        self._active = False

    def close(self):
        """立即关闭所有资源（不发送 STOP）。"""
        if self._ctrl is not None:
            self._ctrl.close()
            self._ctrl = None
        if self._file_rx is not None:
            self._file_rx.stop()
            self._file_rx = None
        self._active = False

    # ------------------------------------------------------------------
    # 上下文管理器支持
    # ------------------------------------------------------------------

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *_):
        self.stop_and_wait()
