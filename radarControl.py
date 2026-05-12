"""
radarControl.py """
毫米波雷达自动化控制脚本
"""

import time
import clr
import shutil
import winsound
from pathlib import Path
from datetime import datetime
import csv
import os
import sys
import threading
import socket
from typing import Optional

from motion_lib import MotionController

# rail pose engine (RPE) for SAR imaging processing
from rail_pose_engine.rail_pose_engine import RailPoseEngine

# 用于导轨采集开始的控制代码
import serial
import struct
PORT = 'COM9'  # 替换为你的端口号
BAUDRATE = 115200
SERIAL_DATA = b'\xff'

# ===============================
# 协议帧定义
# BF | motorMask | directionMask | speedHz | durationMs
# ===============================

packet_L_20cm = struct.pack("<BBBii",
    0xBF,         # header
    0b00000001,   # motorMask: 只控制 motor 0
    0b00000000,   # directionMask: motor 0 方向为 1
    8000,     # Hz
    40000   # 毫秒
)

packet_R_20cm = struct.pack("<BBBii",
    0xBF,         # header
    0b00000001,   # motorMask: 只控制 motor 0
    0b00000011,   # directionMask: motor 0 方向为 1
    8000,     # Hz
    40000   # 毫秒
)

packet_D_7600um = struct.pack("<BBBii",
    0xBF,         # header
    0b00000010,   # motorMask: 只控制 motor 1
    0b00000000,   # directionMask: motor 0 方向为 1
    8736,     # Hz
    4000   # 毫秒
)

# 以下协议包用于非规则运动的SAR成像测试
# 以左上角为起点，向下向右对应motor0、motor1正方向{远离电机方向}
# 实际使用的画布大小为 320 000 step x 320 000 step (约 50cm x 50cm)
# 这里和上面有参考系区别，横向电机左右反转了
packet_R_80000step = struct.pack("<BBBii",
    0xBF,         # header
    0b00000001,   # motorMask: 只控制 motor 0
    0b00000000,   # directionMask: motor 0 方向为 1
    16000,     # Hz
    5000   # 毫秒
)

packet_L_80000step = struct.pack("<BBBii",
    0xBF,         # header
    0b00000001,   # motorMask: 只控制 motor 0
    0b00000001,   # directionMask: motor 0 方向为 1
    16000,     # Hz
    5000   # 毫秒
)

packet_D_40000step = struct.pack("<BBBii",
    0xBF,         # header
    0b00000010,   # motorMask: 只控制 motor 1
    0b00000000,   # directionMask: motor 0 方向为 1
    8000,     # Hz
    5000   # 毫秒
)

packet_U_40000step = struct.pack("<BBBii",
    0xBF,         # header
    0b00000010,   # motorMask: 只控制 motor 1
    0b00000010,   # directionMask: motor 0 方向为 1
    8000,     # Hz
    5000   # 毫秒
)

# ==============================
# 全局配置
# ==============================
CONFIG = {
    "MMWAVE_STUDIO_DIR": r"C:\ti\mmwave_studio_03_00_00_14\mmWaveStudio",

    "NUM_ITERATIONS": 6,
    "CAPTURE_DURATION": 40,
    "POSTPROC_WAIT": 10,  # PostPro c 等待时间
    "ADC_FILENAME": "adc_data_Raw_0.bin",
    "ADC_SAVE_PREFIX": "adc_data",
    "LOG_FILE": "capture_log.csv",

    # 是否运行 MATLAB 后处理（PostProc.lua）
    "DO_POSTPROC": False,
    "USE_SERIAL": True,
    "SNAKE_SCAN": True,

    # iPhone TCP 控制（GO/STOP）
    "USE_IPHONE_TCP": True,
    "IPHONE_TCP_IP": "192.168.31.83",
    "IPHONE_TCP_PORT": 9999,
    "IPHONE_TCP_TIMEOUT_S": 3.0,
    "IPHONE_SEND_GO_ON_START": True,
    "IPHONE_SEND_STOP_ON_EXIT": True,

    # STOP 后 iPhone 自动上传文件（TCP）
    # 上传位置与雷达数据保存位置相同（POSTPROC_DIR）
    "IPHONE_FILE_RX_ENABLED": True,
    "IPHONE_FILE_RX_HOST": "0.0.0.0",
    "IPHONE_FILE_RX_PORT": 10001,
    "IPHONE_FILE_RX_TIMEOUT_S": 1.0,
}

SCAN_DIRECTIONS = True

# 自动路径推导
MMWAVE_DIR = Path(CONFIG["MMWAVE_STUDIO_DIR"])
DLL_PATH = MMWAVE_DIR / "Clients" / "RtttNetClientController" / "RtttNetClientAPI.dll"
SCRIPTS_DIR = MMWAVE_DIR / "Scripts"
POSTPROC_DIR = MMWAVE_DIR / "PostProc"
LOG_PATH = POSTPROC_DIR / CONFIG["LOG_FILE"]

# 全局连接实例与退出事件
RSTD_CLIENT = None
exit_event = threading.Event()  # ✅ 替代 RUNNING 标志

# ==============================
# Rail-aware serial sender
# ==============================

def send_with_pose(arduino_ser, rail_engine, packet: bytes):
    """
    Send a BF packet through serial AND record it into rail_pose_engine.

    Parameters
    ----------
    arduino_ser :
        Initialized serial port object.
    rail_engine : RailPoseEngine
        Rail pose engine instance.
    packet : bytes
        Raw 0xBF packet bytes.
    """
    if arduino_ser is None:
        raise RuntimeError("Arduino serial is not initialized")
    if rail_engine is None:
        raise RuntimeError("RailPoseEngine is not initialized")

    t_send = time.time()

    # 1) send to serial
    arduino_ser.write(packet)

    # 2) record into rail pose engine
    rail_engine.feed(t_send, packet)

    return t_send


class IPhoneTCPController:
    """TCP controller for iPhone GO/STOP recording workflow."""

    def __init__(self, ip: str, port: int, timeout_s: float = 1.0):
        self.addr = (ip, port)
        self.timeout_s = timeout_s
        self.sock: Optional[socket.socket] = None

    def open(self):
        self.sock = socket.create_connection(self.addr, timeout=self.timeout_s)
        self.sock.settimeout(self.timeout_s)
        # TCP Keepalive：防止路由器在雷达扫描空闲期间断掉连接
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 10)
        if hasattr(socket, "TCP_KEEPINTVL"):
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)
        if hasattr(socket, "TCP_KEEPCNT"):
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
        print(f"📱 iPhone TCP 已连接: {self.addr[0]}:{self.addr[1]}")

    def _recv_line(self) -> Optional[str]:
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

    def send(self, cmd: str, expect_prefix: Optional[str] = None) -> Optional[str]:
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

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None


class IPhoneFileTCPServer:
    """
    PC 端 TCP 文件接收服务。
    iPhone 在收到 STOP 后主动连接此服务，上传文件。

    协议（TCP）:
      1) 发送文件名\n
      2) 发送文件大小（字节数，字符串）\n
      3) 发送文件内容（size 字节）
    """

    def __init__(self, save_dir: Path, host: str = "0.0.0.0", port: int = 10001, timeout_s: float = 1.0):
        self.save_dir = Path(save_dir)
        self.host = host
        self.port = int(port)
        self.timeout_s = float(timeout_s)
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._srv: Optional[socket.socket] = None

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
            print(f"✅ iPhone 文件已保存: {out} ({got/1e6:.2f} MB)")
        else:
            print(f"⚠️ 文件接收不完整: {out} ({got}/{total} 字节)")

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

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True, name="iphone-file-rx")
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._srv is not None:
            try:
                self._srv.close()
            except Exception:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        print("📥 文件接收服务(TCP)已关闭。")


# ==============================
# 蜂鸣提示
# ==============================
def beep(freq, dur):
    try:
        winsound.Beep(freq, dur)
    except RuntimeError:
        print("\a🔔", flush=True)


def beep_start():
    beep(1000, 200)


def beep_iteration():
    beep(1100, 150)


def beep_end():
    for _ in range(3):
        beep(1200, 150)
        time.sleep(0.1)


# ==============================
# RSTD 连接函数
# ==============================
def connect_rstd():
    """只建立一次连接，在循环中复用"""
    global RSTD_CLIENT

    if RSTD_CLIENT is not None:
        return RSTD_CLIENT

    print("🌐 Connecting to mmWaveStudio ...")
    clr.AddReference(str(DLL_PATH))
    from RtttNetClientAPI import RtttNetClient

    err = RtttNetClient.Init()
    if err != 0:
        raise RuntimeError(f"Init failed, code={err}")

    err = RtttNetClient.Connect("127.0.0.1", 2777)
    if err != 0:
        raise RuntimeError(
            f"Connect failed, code={err}\n⚠️ 请确认 mmWaveStudio 已运行，并在 Lua Shell 输入 RSTD.NetStart()"
        )

    lua_cmd = 'WriteToLog("Connected from Python\\n", "green")'
    rstd_send(RtttNetClient, lua_cmd, tag="hello")
    print("✅ Connected to mmWaveStudio.")
    RSTD_CLIENT = RtttNetClient
    return RtttNetClient


def cleanup_rstd():
    """关闭 RSTD 连接"""
    global RSTD_CLIENT
    if RSTD_CLIENT:
        try:
            print("🔌 正在关闭与 mmWaveStudio 的连接...")
            RSTD_CLIENT.Close()
            print("✅ 已断开连接。")
        except Exception as e:
            print(f"⚠️ 关闭连接时出错: {e}")
        RSTD_CLIENT = None

# RSTD 发送函数
def rstd_send(client, lua_cmd: str, tag: str = "", warn_slow_s: float = 2.0):
    """
    最小封装：打印开始/结束、耗时、返回码。
    不改变行为（仍是同步 SendCommand）。
    """
    t0 = time.time()
    prefix = f"[RSTD]{'['+tag+']' if tag else ''}"

    print(f"{prefix} -> SendCommand START")
    # 为避免日志刷屏，打印前 120 字符
    print(f"{prefix}    cmd: {lua_cmd[:120]}{'...' if len(lua_cmd) > 120 else ''}")

    ret = client.SendCommand(lua_cmd)  # 同步阻塞点
    dt = time.time() - t0

    # ===============================
    # ✅ 关键修改：兼容 pythonnet / MATLAB 两种返回
    # ===============================
    if isinstance(ret, tuple):
        code = ret[0]          # pythonnet 常见：(0, None)
    else:
        code = ret             # MATLAB / 其他封装可能直接返回 int

    # TI RSTD：0 或 30000 都表示成功
    ok = (code == 0) or (code == 30000)

    if not ok:
        print(f"{prefix} <- SendCommand FAIL ret={ret}  (dt={dt:.3f}s)")
        raise RuntimeError(f"RSTD SendCommand failed, ret={ret}, tag={tag}")
    else:
        if dt > warn_slow_s:
            print(f"{prefix} <- SendCommand OK ret={ret}  (SLOW {dt:.3f}s)")
        else:
            print(f"{prefix} <- SendCommand OK ret={ret}  (dt={dt:.3f}s)")

    return ret

# ==============================
# 文件等待函数
# ==============================
def wait_for_adc_file(adc_path: Path, timeout=120):
    """等待 adc_data.bin 文件生成并写入完成"""
    print(f"⏳ Waiting for {adc_path.name} ...")
    t0 = time.time()
    last_size = -1

    while not exit_event.is_set() and time.time() - t0 < timeout:
        if adc_path.exists():
            size = adc_path.stat().st_size
            if size == last_size and size > 0:
                print(f"✅ File ready ({size/1e6:.1f} MB).")
                return True
            last_size = size
        time.sleep(1)

    if exit_event.is_set():
        print("🛑 Interrupted during file wait.")
        return False

    print("⚠️ Timeout waiting for adc_data.bin.")
    return False


# ==============================
# 安全退出函数
# ==============================
def safe_exit():
    """标记退出事件并清理连接"""
    print("\n🛑 检测到退出请求，正在安全退出 radar 控制进程...")
    exit_event.set()
    cleanup_rstd()
    print("✅ radarControl 已安全退出。")


# ==============================
# 主流程
# ==============================
def radar_control_process():
    print("🚀 Starting radar control process...")
    
    global SCAN_DIRECTIONS

    # rail pose engine (RPE) for SAR imaging processing, Init
    rail_engine = RailPoseEngine(
    step_x_m=0.5 / 320000.0,
    step_y_m=0.5 / 320000.0,
    z_m=0.0,
)

    # Arduino/Serial init
    arduino_ser = None
    if CONFIG["USE_SERIAL"]:
        try:
            arduino_ser = serial.Serial(PORT, BAUDRATE, timeout=1)
            print(f"🔗 串口 {PORT} 已连接。")
            time.sleep(1)
        except Exception as e:
            print(f"⚠️ 串口初始化失败: {e}")
            arduino_ser = None

    # iPhone TCP init + 文件接收服务
    iphone = None
    iphone_file_rx = None
    if CONFIG.get("USE_IPHONE_TCP", False):
        try:
            iphone = IPhoneTCPController(
                ip=str(CONFIG.get("IPHONE_TCP_IP", "127.0.0.1")),
                port=int(CONFIG.get("IPHONE_TCP_PORT", 9999)),
                timeout_s=float(CONFIG.get("IPHONE_TCP_TIMEOUT_S", 3.0)),
            )
            iphone.open()
            if CONFIG.get("IPHONE_SEND_GO_ON_START", True):
                iphone.send("GO", expect_prefix="RECORDING")
        except Exception as e:
            print(f"⚠️ iPhone TCP 初始化失败: {e}")
            iphone = None

    if CONFIG.get("IPHONE_FILE_RX_ENABLED", False):
        iphone_file_rx = IPhoneFileTCPServer(
            save_dir=POSTPROC_DIR,
            host=str(CONFIG.get("IPHONE_FILE_RX_HOST", "0.0.0.0")),
            port=int(CONFIG.get("IPHONE_FILE_RX_PORT", 10001)),
            timeout_s=float(CONFIG.get("IPHONE_FILE_RX_TIMEOUT_S", 1.0)),
        )
        iphone_file_rx.start()

    beep_start()

    client = connect_rstd()  # ✅ 只连接一次

    try:
        with open(LOG_PATH, "a", newline="", encoding="utf-8") as log_file:
            writer = csv.writer(log_file)
            writer.writerow(["Iteration", "Timestamp", "ADC File", "Status"])

            i = 0
            while i < CONFIG["NUM_ITERATIONS"]:
                if exit_event.is_set():
                    print("🛑 收到退出事件，结束采集循环。")
                    break
                
                print(f"\n=== [Iteration {i}] ===")
                success = False
                adc_file = "N/A"
                trigger_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

                try:
                    # 1️⃣ ARM
                    lua_arm = str(SCRIPTS_DIR / "Cascade_Capture_1.lua").replace("\\", "\\\\")
                    rstd_send(client, f'dofile("{lua_arm}")', tag="DCAarm")
                    time.sleep(1)

                    # 2️⃣ 触发采集
                    beep_iteration()
                    # 开始 TRIGGER 时 Arduino 触发
                    if CONFIG["USE_SERIAL"] and arduino_ser:
                        if CONFIG["SNAKE_SCAN"]:
                            if SCAN_DIRECTIONS:
                                send_with_pose(arduino_ser, rail_engine, packet_L_20cm)
                                SCAN_DIRECTIONS = False
                            else:
                                send_with_pose(arduino_ser, rail_engine, packet_R_20cm)
                                SCAN_DIRECTIONS = True
                        else:
                            send_with_pose(arduino_ser, rail_engine, packet_L_20cm)
                        #if i % 2 == 0:
                        #    send_with_pose(arduino_ser, rail_engine, packet_D_40000step)
                        #else:
                        #    send_with_pose(arduino_ser, rail_engine, packet_U_40000step)
                        #if SCAN_DIRECTIONS is True:
                        #    send_with_pose(arduino_ser, rail_engine, packet_R_80000step)
                        #else:
                        #    send_with_pose(arduino_ser, rail_engine, packet_L_80000step)
                    else:
                        print("⚙️ 串口触发已禁用，跳过发送。")
                    lua_trig = str(SCRIPTS_DIR / "Cascade_Capture_2.lua").replace("\\", "\\\\")
                    rstd_send(client, f'dofile("{lua_trig}")', tag="TriggerFrame")
                    trigger_time = time.time()
                    print(f"⚡ Triggered capture at {trigger_time}")

                    # 等待采集
                    for _ in range(CONFIG["CAPTURE_DURATION"]):
                        if exit_event.is_set():
                            raise KeyboardInterrupt
                        time.sleep(1)
                    # 采集完毕
                    beep_end()

                    lua_force_stop = str(SCRIPTS_DIR / "Cascade_Capture_3.lua").replace("\\", "\\\\")
                    rstd_send(client, f'dofile("{lua_force_stop}")', tag="StopFrame")

                    next_step = 6708

                    packet_D_downStep = struct.pack("<BBBii",
                        0xBF,         # header
                        0b00000010,   # motorMask: 只控制 motor 1
                        0b00000000,   # directionMask: motor 0 方向为 1
                        8000,     # Hz
                        next_step   # 毫秒
                    )

                    # Arduino 一次Trigger完成后的处理
                    if CONFIG["USE_SERIAL"] and arduino_ser:
                        if not CONFIG["SNAKE_SCAN"]:
                            send_with_pose(arduino_ser, rail_engine, packet_R_20cm)
                        if i < CONFIG["NUM_ITERATIONS"] - 1:
                            send_with_pose(arduino_ser, rail_engine, packet_D_downStep)
                        #if i % 4 == 3: # 完成了最后一组扫描 
                        #    send_with_pose(arduino_ser, rail_engine, packet_D_downStep)
                        #    SCAN_DIRECTIONS = not SCAN_DIRECTIONS # 反转扫描方向
                    else:
                        print("⚙️ 串口触发已禁用，跳过发送。")

                    # 3️⃣ 后处理（可选）
                    if CONFIG["DO_POSTPROC"]:
                        lua_post = str(SCRIPTS_DIR / "PostProc.lua").replace("\\", "\\\\")
                        rstd_send(client, f'dofile("{lua_post}")', tag="PostProc")
                        print(f"🧩 Running PostProc.lua ... waiting {CONFIG['POSTPROC_WAIT']}s")
                        for _ in range(CONFIG["POSTPROC_WAIT"]):
                            if exit_event.is_set():
                                raise KeyboardInterrupt
                            time.sleep(1)
                    else:
                        print("🟡 Skipping PostProc.lua")
                    
                    manual_time = 3
                    manual_flag = True
                    
                    while manual_time > 0 and manual_flag:
                        beep_iteration()
                        time.sleep(1)
                        manual_time -= 1

                    # 4️⃣ 检查文件并保存
                    old = POSTPROC_DIR / CONFIG["ADC_FILENAME"]
                    if wait_for_adc_file(old, timeout=3):
                        new = POSTPROC_DIR / f"{CONFIG['ADC_SAVE_PREFIX']}{i}.bin"
                        shutil.copy(old, new)
                        adc_file = new.name
                        success = True
                        print(f"💾 Saved: {adc_file}")
                    else:
                        print("⚠️ adc_data.bin not found or incomplete.")

                except KeyboardInterrupt:
                    exit_event.set()
                    print("🛑 捕获 KeyboardInterrupt，准备安全退出 radar 控制进程...")
                    break
                except Exception as e:
                    print(f"❌ Error during iteration {i}: {e}")
                finally:
                    writer.writerow([i, trigger_time, adc_file, "OK" if success else "FAIL"])
                    log_file.flush()
                    i = i + 1
                    time.sleep(2)

    except KeyboardInterrupt:
        print("\n🛑 捕获到 KeyboardInterrupt，Radar Control 正在退出...")
    finally:
        if CONFIG["USE_SERIAL"] and arduino_ser:
            arduino_ser.close()
            print("🔌 串口已关闭。")

        if iphone is not None:
            try:
                if CONFIG.get("IPHONE_SEND_STOP_ON_EXIT", True):
                    iphone.send("STOP", expect_prefix="STOPPED")
                    # STOP 后等待 iPhone 主动连接上传文件
                    if CONFIG.get("IPHONE_FILE_RX_ENABLED", False) and iphone_file_rx is not None:
                        print("⏳ 等待 iPhone 上传文件（最多 30s）...")
                        time.sleep(30)
            finally:
                iphone.close()
                print("📱 iPhone TCP 已关闭。")

        if iphone_file_rx is not None:
            iphone_file_rx.stop()

        rail_engine.export_pose_csv_workflow(
            POSTPROC_DIR / "quat_rail.csv",
            min_dt=0.002,
            max_dt=0.016,
        )

        rail_engine.export_ffmpeg_debug_fake_log(
            POSTPROC_DIR / "ffmpeg_debug_fake.log"
        )

        safe_exit()
        beep_end()
        print("\n✅ Radar control process finished.")
        print(f"🗒️ Log saved at: {LOG_PATH}")

def fake_radar_control_process():
    """
    fake_radar_control_process
    ------------------------------------------------------------
    模拟雷达控制流程：仅串口触发 + 等待 + 日志记录。
    不连接 mmWaveStudio。
    """
    print("🧪 Starting FAKE radar control process (串口 + 日志模式)")

    # 1️⃣ 串口初始化
    arduino_ser = None
    if CONFIG["USE_SERIAL"]:
        try:
            arduino_ser = serial.Serial(PORT, BAUDRATE, timeout=1)
            time.sleep(2)  # ✅ 给设备一点时间初始化
            print(f"🔗 串口 {PORT} 已连接，波特率 {BAUDRATE}")
        except Exception as e:
            print(f"⚠️ 串口初始化失败: {e}")
            arduino_ser = None

    # iPhone TCP init + 文件接收服务
    iphone = None
    iphone_file_rx = None
    if CONFIG.get("USE_IPHONE_TCP", False):
        try:
            iphone = IPhoneTCPController(
                ip=str(CONFIG.get("IPHONE_TCP_IP", "127.0.0.1")),
                port=int(CONFIG.get("IPHONE_TCP_PORT", 9999)),
                timeout_s=float(CONFIG.get("IPHONE_TCP_TIMEOUT_S", 3.0)),
            )
            iphone.open()
            if CONFIG.get("IPHONE_SEND_GO_ON_START", True):
                iphone.send("GO", expect_prefix="RECORDING")
        except Exception as e:
            print(f"⚠️ iPhone TCP 初始化失败: {e}")
            iphone = None

    if CONFIG.get("IPHONE_FILE_RX_ENABLED", False):
        iphone_file_rx = IPhoneFileTCPServer(
            save_dir=POSTPROC_DIR,
            host=str(CONFIG.get("IPHONE_FILE_RX_HOST", "0.0.0.0")),
            port=int(CONFIG.get("IPHONE_FILE_RX_PORT", 10001)),
            timeout_s=float(CONFIG.get("IPHONE_FILE_RX_TIMEOUT_S", 1.0)),
        )
        iphone_file_rx.start()

    beep_start()

    # 2️⃣ 日志路径检查与自动切换
    real_log_path = LOG_PATH
    try:
        # 测试能否写入 mmWaveStudio 目录
        with open(real_log_path, "a", encoding="utf-8") as _test:
            pass
    except Exception as e:
        print(f"⚠️ 无法写入 {real_log_path} ，自动切换到 ./captures 目录。({e})")
        fallback_dir = Path("./captures")
        fallback_dir.mkdir(parents=True, exist_ok=True)
        real_log_path = fallback_dir / "fake_capture_log.csv"

    print(f"🗒️ 日志文件: {real_log_path}")

    # 3️⃣ 打开日志文件
    with open(real_log_path, "a", newline="", encoding="utf-8") as log_file:
        writer = csv.writer(log_file)
        writer.writerow(["Iteration", "Timestamp", "ADC File", "Status"])

        # 4️⃣ 采集循环
        for i in range(CONFIG["NUM_ITERATIONS"]):
            if exit_event.is_set():
                print("🛑 收到退出事件，结束采集循环。")
                break

            print(f"\n=== [FAKE Iteration {i}] ===")
            success = False
            adc_file = "N/A"
            trigger_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

            try:
                # ✅ 串口触发
                beep_iteration()
                if CONFIG["USE_SERIAL"] and arduino_ser:
                    arduino_ser.reset_output_buffer()
                    sent = arduino_ser.write(SERIAL_DATA)
                    arduino_ser.flush()
                    print(f"⚡ [FAKE] 已发送 {sent} 字节: {SERIAL_DATA.hex(' ')}")
                else:
                    print("⚙️ 串口触发已禁用，跳过发送。")

                trigger_time = time.time()
                print(f"🕐 [FAKE] Triggered at {trigger_time}")

                # ✅ 模拟采集等待
                capture_dur = int(CONFIG.get("CAPTURE_DURATION", 10))
                print(f"⏳ 模拟采集中（持续 {capture_dur}s）...")
                for t in range(capture_dur):
                    if exit_event.is_set():
                        raise KeyboardInterrupt
                    time.sleep(1)
                    if t % 5 == 0:
                        print(f"   -> 已运行 {t}s")

                # ✅ 模拟保存文件
                fake_file = POSTPROC_DIR / f"{CONFIG['ADC_SAVE_PREFIX']}{i}.bin"
                fake_file.write_bytes(b"FAKE_DATA")
                adc_file = fake_file.name
                success = True
                print(f"💾 [FAKE] Saved fake ADC data: {adc_file}")

            except KeyboardInterrupt:
                print("🛑 检测到 Ctrl+C，中断当前循环。")
                exit_event.set()
                break
            except Exception as e:
                print(f"❌ [FAKE] Error during iteration {i}: {e}")
            finally:
                writer.writerow([i, trigger_time, adc_file, "OK" if success else "FAIL"])
                log_file.flush()
                time.sleep(1)

    # 5️⃣ 清理资源
    if CONFIG["USE_SERIAL"] and arduino_ser:
        arduino_ser.close()
        print("🔌 串口已关闭。")

    if iphone is not None:
        try:
            if CONFIG.get("IPHONE_SEND_STOP_ON_EXIT", True):
                iphone.send("STOP", expect_prefix="STOPPED")
                # STOP 后等待 iPhone 主动连接上传文件
                if CONFIG.get("IPHONE_FILE_RX_ENABLED", False) and iphone_file_rx is not None:
                    print("⏳ 等待 iPhone 上传文件（最多 30s）...")
                    time.sleep(30)
        finally:
            iphone.close()
            print("📱 iPhone TCP 已关闭。")

    if iphone_file_rx is not None:
        iphone_file_rx.stop()

    safe_exit()
    beep_end()
    print("\n✅ Fake radar control process finished.")
    print(f"🗒️ Log saved at: {real_log_path}")



# ==============================
# 独立运行入口
# ==============================
if __name__ == "__main__":
    try:
        radar_control_process()
    except KeyboardInterrupt:
        safe_exit()
