#!/usr/bin/env python3
"""
iPhone 精度测试 UDP 远程控制脚本 (Windows 上位机端)

协议流程:
  1. PREPARE → iPhone 预热 AR (2秒)
  2. iPhone 回复 READY
  3. GO → iPhone 开始记录 + 同时启动导轨
  4. STOP → iPhone 停止记录并导出 CSV

使用方法:
  python windows_udp_controller.py --ip <iPhone_IP>

确保 iPhone 和 Windows 在同一 WiFi 局域网下。
iPhone 端在"精度测试"页面中打开 UDP 开关。
"""

import socket
import time
import argparse
import sys
import struct
import os

# ── Windows UTF-8 控制台支持 ──────────────────────────────────────────────────
# 将 Windows 终端代码页切换为 UTF-8（chcp 65001），同时重配 Python stdout/stderr，
# 确保中文和 Emoji 字符不会触发 UnicodeEncodeError。
if sys.platform == "win32":
    os.system("chcp 65001 > nul 2>&1")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
# ─────────────────────────────────────────────────────────────────────────────

try:
    import serial  # Optional: only required when --rail-enable is used
except Exception:
    serial = None


def create_socket():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(10)  # 10秒超时
    return sock


def now_wall_ts():
    """Return high-resolution wall-clock timestamp in seconds."""
    return time.time_ns() / 1e9


def parse_payload(text, hex_data):
    """Build bytes payload from text or hex string."""
    if hex_data:
        return bytes.fromhex(hex_data)
    if text is not None:
        return text.encode("utf-8")
    return None


class RailController:
    """Optional serial rail trigger helper for GO/STOP synchronization."""

    def __init__(self, enabled=False, port="COM5", baud=115200,
                 start_payload=None, stop_payload=None):
        self.enabled = enabled
        self.port = port
        self.baud = baud
        self.start_payload = start_payload
        self.stop_payload = stop_payload
        self._ser = None

    def open(self):
        if not self.enabled:
            return True
        if serial is None:
            print("❌ 未安装 pyserial，无法启用导轨串口控制")
            return False
        try:
            self._ser = serial.Serial(self.port, self.baud, timeout=1)
            print(f"✅ 导轨串口已连接: {self.port} @ {self.baud}")
            return True
        except Exception as e:
            print(f"❌ 导轨串口连接失败: {e}")
            self._ser = None
            return False

    def send_start(self):
        if not self.enabled or self._ser is None or self.start_payload is None:
            return None
        self._ser.write(self.start_payload)
        self._ser.flush()
        return now_wall_ts()

    def send_stop(self):
        if not self.enabled or self._ser is None or self.stop_payload is None:
            return None
        self._ser.write(self.stop_payload)
        self._ser.flush()
        return now_wall_ts()

    def close(self):
        if self._ser is not None:
            try:
                self._ser.close()
            except Exception:
                pass
            self._ser = None


def send_and_wait(sock, message, addr, expected_prefix=None, timeout=10):
    """发送 UDP 消息并等待回复"""
    print(f"  → 发送: {message}")
    sock.sendto(message.encode("utf-8"), addr)

    if expected_prefix is None:
        return None

    start = time.time()
    while time.time() - start < timeout:
        try:
            data, _ = sock.recvfrom(1024)
            reply = data.decode("utf-8").strip()
            print(f"  ← 收到: {reply}")
            if reply.startswith(expected_prefix):
                return reply
        except socket.timeout:
            break

    print(f"  ⚠ 超时未收到 {expected_prefix} 回复")
    return None


def wait_for_reply(sock, expected_prefix, timeout=2.0):
    """Wait for a specific reply without sending new UDP packets."""
    end_time = time.time() + timeout
    while time.time() < end_time:
        try:
            data, _ = sock.recvfrom(1024)
            reply = data.decode("utf-8").strip()
            print(f"  ← 收到: {reply}")
            if reply.startswith(expected_prefix):
                return reply
        except socket.timeout:
            break
    return None


def build_bf_packet(motor_mask, direction_mask, speed_hz, duration_ms):
    """Build rail BF frame: BF | motorMask | directionMask | speedHz | durationMs."""
    return struct.pack("<BBBii", 0xBF, motor_mask, direction_mask, int(speed_hz), int(duration_ms))


def run_radar_like_trajectory(
    rail,
    iterations=65,
    snake_scan=True,
    start_left=True,
    horizontal_speed_hz=16000,
    horizontal_duration_ms=20000,
    vertical_speed_hz=4000,
    vertical_duration_ms=1216,
):
    """Execute a radarControl-like snake trajectory through serial BF packets."""
    if not rail.enabled or rail._ser is None:
        return None, None

    packet_left = build_bf_packet(0b00000001, 0b00000000, horizontal_speed_hz, horizontal_duration_ms)
    packet_right = build_bf_packet(0b00000001, 0b00000011, horizontal_speed_hz, horizontal_duration_ms)
    packet_down = build_bf_packet(0b00000010, 0b00000000, vertical_speed_hz, vertical_duration_ms)

    scan_left = bool(start_left)
    t_traj_start = None

    for i in range(iterations):
        if snake_scan:
            horizontal_packet = packet_left if scan_left else packet_right
            horizontal_name = "LEFT" if scan_left else "RIGHT"
            scan_left = not scan_left
        else:
            horizontal_packet = packet_left
            horizontal_name = "LEFT"

        t_horizontal = now_wall_ts()
        rail._ser.write(horizontal_packet)
        rail._ser.flush()
        if t_traj_start is None:
            t_traj_start = t_horizontal
        print(f"  [轨迹] Iter {i + 1}/{iterations}: X={horizontal_name}, t={t_horizontal:.6f}")
        time.sleep(horizontal_duration_ms / 1000.0)

        t_vertical = now_wall_ts()
        rail._ser.write(packet_down)
        rail._ser.flush()
        print(f"  [轨迹] Iter {i + 1}/{iterations}: Y=DOWN, t={t_vertical:.6f}")
        time.sleep(vertical_duration_ms / 1000.0)

    t_traj_end = now_wall_ts()
    return t_traj_start, t_traj_end


def run_test(ip, port, duration,
             rail_enable=False, rail_port="COM5", rail_baud=115200,
             rail_start_text=None, rail_stop_text=None,
             rail_start_hex=None, rail_stop_hex=None,
             rail_use_radar_trajectory=False,
             traj_iterations=65,
             traj_snake_scan=True,
             traj_start_left=True,
             traj_horizontal_speed_hz=16000,
             traj_horizontal_duration_ms=20000,
             traj_vertical_speed_hz=4000,
             traj_vertical_duration_ms=1216):
    """执行一次完整的测试流程"""
    addr = (ip, port)
    sock = create_socket()
    rail = RailController(
        enabled=rail_enable,
        port=rail_port,
        baud=rail_baud,
        start_payload=parse_payload(rail_start_text, rail_start_hex),
        stop_payload=parse_payload(rail_stop_text, rail_stop_hex),
    )

    try:
        if not rail.open():
            return False

        # 1. PING 测试连接
        print("\n[1/4] 测试连接...")
        reply = send_and_wait(sock, "PING", addr, "PONG", timeout=5)
        if reply is None:
            print("❌ 无法连接到 iPhone，请检查:")
            print("   - iPhone 和 PC 是否在同一 WiFi")
            print("   - iPhone 精度测试页 UDP 是否已打开")
            print(f"   - iPhone IP 是否正确: {ip}")
            return False

        print("✅ 连接成功\n")

        # 2. PREPARE
        print("[2/4] 发送 PREPARE（iPhone 预热中）...")
        t_prepare_send_wall = now_wall_ts()
        reply = send_and_wait(sock, "PREPARE", addr, "READY", timeout=10)
        t_ready_recv_wall = now_wall_ts()
        if reply is None:
            print("❌ iPhone 未就绪")
            return False

        print("✅ iPhone 已就绪\n")

        # READY->GO: immediate trigger
        print("⚡ 收到 READY 后立即触发 GO")

        # 3. GO
        print("[3/4] 发送 GO（开始记录）...")
        t_go_fire_wall_before = now_wall_ts()
        sock.sendto("GO".encode("utf-8"), addr)
        t_go_send_wall = now_wall_ts()

        t_rail_start_wall = None
        t_traj_end_wall = None
        if rail_use_radar_trajectory and rail_enable:
            print("  [轨迹] 按 radarControl 规则执行蛇形轨迹...")
            t_rail_start_wall, t_traj_end_wall = run_radar_like_trajectory(
                rail,
                iterations=traj_iterations,
                snake_scan=traj_snake_scan,
                start_left=traj_start_left,
                horizontal_speed_hz=traj_horizontal_speed_hz,
                horizontal_duration_ms=traj_horizontal_duration_ms,
                vertical_speed_hz=traj_vertical_speed_hz,
                vertical_duration_ms=traj_vertical_duration_ms,
            )
            print("  [轨迹] 已执行完成")
        else:
            t_rail_start_wall = rail.send_start()

        reply = wait_for_reply(sock, "RECORDING", timeout=2.0)
        t_go_fire_wall_after = now_wall_ts()

        print("\n[SYNC] 本次关键时序(PC wall-clock):")
        print(f"  PREPARE 发送: {t_prepare_send_wall:.6f}")
        print(f"  READY 接收  : {t_ready_recv_wall:.6f}")
        print(f"  READY->GO间隔: {max(0.0, t_go_fire_wall_before - t_ready_recv_wall):.6f}s")
        print(f"  GO 已发送   : {t_go_send_wall:.6f}")
        print(f"  GO 触发前   : {t_go_fire_wall_before:.6f}")
        if t_rail_start_wall is not None:
            print(f"  导轨START发送: {t_rail_start_wall:.6f}")
        if t_traj_end_wall is not None:
            print(f"  导轨轨迹完成: {t_traj_end_wall:.6f}")
        print(f"  GO 触发后   : {t_go_fire_wall_after:.6f}")

        if reply is None:
            print("⚠ 未收到确认，但可能已开始记录")

        if not (rail_use_radar_trajectory and rail_enable):
            print(f"✅ 正在记录... 等待 {duration} 秒")
            print()

            # 实时倒计时
            for remaining in range(duration, 0, -1):
                sys.stdout.write(f"\r   ⏱ 倒计时: {remaining:3d} 秒 ")
                sys.stdout.flush()
                time.sleep(1)
            print("\r   ⏱ 倒计时:   0 秒 ✓")
            print()
        else:
            print("✅ 导轨轨迹已跑完，准备通知手机 STOP")

        # 4. STOP
        print("[4/4] 发送 STOP（停止记录）...")
        t_stop_fire_wall_before = now_wall_ts()
        t_rail_stop_wall = rail.send_stop()
        reply = send_and_wait(sock, "STOP", addr, "STOPPED", timeout=10)
        t_stop_fire_wall_after = now_wall_ts()

        print("\n[SYNC] 停止时序(PC wall-clock):")
        print(f"  STOP 触发前 : {t_stop_fire_wall_before:.6f}")
        if t_rail_stop_wall is not None:
            print(f"  导轨STOP发送: {t_rail_stop_wall:.6f}")
        print(f"  STOP 触发后 : {t_stop_fire_wall_after:.6f}")

        if reply:
            count = reply.split(":")[-1] if ":" in reply else "?"
            print(f"✅ 记录完成，共 {count} 条数据点")
        else:
            print("⚠ 未收到停止确认")

        print("\n====== 测试完成 ======")
        print("CSV 文件已保存在 iPhone 的文件库中")
        return True

    finally:
        rail.close()
        sock.close()


def interactive_mode(ip, port):
    """交互模式：手动发送指令"""
    addr = (ip, port)
    sock = create_socket()

    print(f"\n交互模式 - 目标: {ip}:{port}")
    print("可用指令: PING, PREPARE, GO, STOP, quit")
    print("-" * 40)

    try:
        while True:
            cmd = input("\n指令> ").strip().upper()
            if cmd in ("QUIT", "EXIT", "Q"):
                break
            if not cmd:
                continue

            sock.sendto(cmd.encode("utf-8"), addr)
            print(f"  → 已发送: {cmd}")

            try:
                data, _ = sock.recvfrom(1024)
                reply = data.decode("utf-8").strip()
                print(f"  ← 回复: {reply}")
            except socket.timeout:
                print("  ⚠ 未收到回复")
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(
        description="iPhone 精度测试 UDP 远程控制",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s --ip 192.168.1.100                  # 自动模式，默认30秒
  %(prog)s --ip 192.168.1.100 --duration 60    # 记录60秒
  %(prog)s --ip 192.168.1.100 --interactive     # 手动控制模式
        """,
    )
    parser.add_argument("--ip", required=True, help="iPhone 的 IP 地址")
    parser.add_argument("--port", type=int, default=9999, help="UDP 端口 (默认: 9999)")
    parser.add_argument("--duration", type=int, default=30, help="记录时长/秒 (默认: 30)")
    parser.add_argument("--interactive", action="store_true", help="交互模式（手动发送指令）")

    # Optional rail control via serial (best-effort synchronized with GO/STOP)
    parser.add_argument("--rail-enable", action="store_true", help="启用导轨串口联动")
    parser.add_argument("--rail-port", default="COM5", help="导轨串口号 (默认: COM5)")
    parser.add_argument("--rail-baud", type=int, default=115200, help="导轨串口波特率")
    parser.add_argument("--rail-start-text", default=None, help="GO时发送给导轨的文本命令")
    parser.add_argument("--rail-stop-text", default=None, help="STOP时发送给导轨的文本命令")
    parser.add_argument("--rail-start-hex", default=None, help="GO时发送给导轨的HEX字节")
    parser.add_argument("--rail-stop-hex", default=None, help="STOP时发送给导轨的HEX字节")
    parser.add_argument("--rail-use-radar-trajectory", action="store_true",
                        help="启用 radarControl 同款蛇形轨迹（跑完后再 STOP 手机）")
    parser.add_argument("--traj-iterations", type=int, default=65, help="轨迹迭代次数")
    parser.add_argument("--traj-no-snake", action="store_true", help="关闭蛇形（固定同方向）")
    parser.add_argument("--traj-start-right", action="store_true", help="首段改为向右")
    parser.add_argument("--traj-horizontal-speed-hz", type=int, default=16000, help="水平速度Hz")
    parser.add_argument("--traj-horizontal-duration-ms", type=int, default=20000, help="水平时长ms")
    parser.add_argument("--traj-vertical-speed-hz", type=int, default=4000, help="垂直速度Hz")
    parser.add_argument("--traj-vertical-duration-ms", type=int, default=1216, help="垂直时长ms")

    args = parser.parse_args()

    print("=" * 40)
    print("  iPhone 精度测试 · UDP 远程控制")
    print("=" * 40)
    print(f"  目标: {args.ip}:{args.port}")

    if args.interactive:
        interactive_mode(args.ip, args.port)
    else:
        print(f"  时长: {args.duration} 秒")
        if args.rail_use_radar_trajectory and not args.rail_enable:
            print("  ⚠ 已选择轨迹模式，但未启用导轨串口（--rail-enable）")
        if args.rail_use_radar_trajectory:
            print("  轨迹模式: radarControl 蛇形轨迹（导轨跑完后 STOP 手机）")
        run_test(
            args.ip,
            args.port,
            args.duration,
            rail_enable=args.rail_enable,
            rail_port=args.rail_port,
            rail_baud=args.rail_baud,
            rail_start_text=args.rail_start_text,
            rail_stop_text=args.rail_stop_text,
            rail_start_hex=args.rail_start_hex,
            rail_stop_hex=args.rail_stop_hex,
            rail_use_radar_trajectory=args.rail_use_radar_trajectory,
            traj_iterations=args.traj_iterations,
            traj_snake_scan=(not args.traj_no_snake),
            traj_start_left=(not args.traj_start_right),
            traj_horizontal_speed_hz=args.traj_horizontal_speed_hz,
            traj_horizontal_duration_ms=args.traj_horizontal_duration_ms,
            traj_vertical_speed_hz=args.traj_vertical_speed_hz,
            traj_vertical_duration_ms=args.traj_vertical_duration_ms,
        )


if __name__ == "__main__":
    main()
