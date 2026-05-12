import psutil
import os
from multiprocessing import Process, Manager
import time
import threading
import sys

import capture as cap
import logExport as le
import videoTranscode as vt
import sendFile as sf
import radarControl as rc

class TeeStdout:
    """
    同时写入 stdout 和文件的 tee
    """
    def __init__(self, file_path, also_stdout=True):
        self.file = open(file_path, "a", buffering=1, encoding="utf-8")
        self.also_stdout = also_stdout
        self.stdout = sys.__stdout__  # 原始 stdout

    def write(self, data):
        self.file.write(data)
        if self.also_stdout:
            self.stdout.write(data)

    def flush(self):
        self.file.flush()
        if self.also_stdout:
            self.stdout.flush()

def redirect_output(log_path, mode="ONLY_FILE"):
    """
    mode:
      - ONLY_FILE   : 只写文件
      - TEE         : 文件 + stdout
      - ONLY_STDOUT : 不重定向
    """
    log_path = os.path.abspath(log_path)
    log_dir = os.path.dirname(log_path)

    # ✅ 关键：自动创建 logs 目录
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    if mode == "ONLY_FILE":
        f = open(log_path, "a", buffering=1, encoding="utf-8")
        sys.stdout = f
        sys.stderr = f

    elif mode == "TEE":
        tee = TeeStdout(log_path, also_stdout=True)
        sys.stdout = tee
        sys.stderr = tee

    elif mode == "ONLY_STDOUT":
        pass

    else:
        raise ValueError(f"Unknown log mode: {mode}")

def set_priority(level="normal"):
    p = psutil.Process(os.getpid())
    priorities = {
        "idle": psutil.IDLE_PRIORITY_CLASS,
        "below_normal": psutil.BELOW_NORMAL_PRIORITY_CLASS,
        "normal": psutil.NORMAL_PRIORITY_CLASS,
        "above_normal": psutil.ABOVE_NORMAL_PRIORITY_CLASS,
        "high": psutil.HIGH_PRIORITY_CLASS,
        "realtime": psutil.REALTIME_PRIORITY_CLASS,
    }
    p.nice(priorities[level])
    print(f"[PID {p.pid}] priority set to {level}")

# Video capture process
#def capture_process():
#    set_priority("realtime")
#    camera_name = "HBVCAM 4K HD USB3.0 Camera"
#    width, height, fps = 1280, 720, 60
#    output_dir = "./captures"
#    segment_duration = 5
#    cap.capture_video(camera_name, width, height, fps, segment_duration, output_dir)

def capture_process(sync_time=None, shared_dict=None):
    redirect_output("./logs/capture_log.txt", mode="TEE")
    set_priority("high")
    camera_name = "HBVCAM 4K HD USB3.0 Camera"
    width, height, fps = 1280, 720, 60
    output_dir = "./captures"
    segment_duration = 10

    # 等待同步时间（如果提供）
    if sync_time:
        print(f"[SYNC] Waiting for capture start at {sync_time:.3f}")
        while time.time() < sync_time:
            time.sleep(0.001)

    actual_start = time.time()
    print(f"[START] Capture actual start time: {actual_start:.3f}")

    # ✅ 保存到共享字典
    if shared_dict is not None:
        shared_dict["video_start"] = actual_start

    cap.capture_video(camera_name, width, height, fps, segment_duration, output_dir)
    print("[DONE] Capture process finished.")


# Log extraction process
    # using logExport.py pre-defined function
    # BUGS need to fix later, this version will record false absolute timestamps and absolute frame counts
    # These information can be restored with original capture log file if needed
    # FIXED 20251030 1606 by chiahsin : now the absolute timestamp could be applied properly, abs_frame still need to be fix
def log_export_process():
    redirect_output("./logs/export_log.txt", mode="ONLY_FILE")
    set_priority("above_normal")
    le.log_export_process(base_dir="./captures", log_csv="record_log.csv")

# Video Transcoding process (optional)
def video_transcode_process():
    redirect_output("./logs/transcode_log.txt", mode="ONLY_FILE")
    set_priority("normal")
    vt.video_transcode_process(base_dir="./captures", interval=5)

# Data sending process (optional)
def data_send_process():
    redirect_output("./logs/data_send_log.txt", mode="ONLY_FILE")
    set_priority("below_normal")
    # sf.data_send_process(base_dir="./captures", interval=10, delete_flag=False)
    sf.unified_send_process(interval=10, delete_flag=False)

# Radar Control process
def radar_control_process(sync_time=None, shared_dict=None):
    redirect_output("./logs/radar_control_log.txt", mode="TEE")

    set_priority("high")

    if sync_time:
        print(f"[SYNC] Waiting for radar start at {sync_time:.3f}")
        while time.time() < sync_time:
            time.sleep(0.001)

    actual_start = time.time()
    print(f"[START] Radar actual start time: {actual_start:.3f}")

    # ✅ 保存到共享字典
    if shared_dict is not None:
        shared_dict["radar_start"] = actual_start

    rc.radar_control_process()
    # rc.fake_radar_control_process()
    print("[DONE] Radar control finished.")

# =========================================
#  Sync Log Monitoring Thread
# =========================================
def monitor_and_save_log(shared_dict, sync_time, interval=0.5):
    """周期检测 radar_start / video_start，一旦都存在即写入日志"""
    output_dir = "./captures"
    os.makedirs(output_dir, exist_ok=True)
    log_path = os.path.join(output_dir, "sync_log.txt")

    while True:
        # 检查两个关键时间是否都已存在
        if "radar_start" in shared_dict and "video_start" in shared_dict:
            radar_time = shared_dict["radar_start"]
            video_time = shared_dict["video_start"]
            delta = abs(radar_time - video_time)

            with open(log_path, "a", encoding="utf-8") as f:
                f.write("\n=== Synchronization Record ===\n")
                f.write(time.strftime("Date: %Y-%m-%d %H:%M:%S\n", time.localtime()))
                f.write(f"Planned Start Time (sync_time): {sync_time:.6f}\n")
                f.write(f"Radar Actual Start: {radar_time:.6f}\n")
                f.write(f"Video Actual Start: {video_time:.6f}\n")
                f.write(f"Start Time Difference: {delta * 1000:.2f} ms\n")
                f.write("===============================\n")

            print(f"🧾 Sync log saved early to: {os.path.abspath(log_path)}")
            break  # 写一次即可退出

        time.sleep(interval)  # 等待后重试


# =========================================
# Main entry point
# =========================================
if __name__ == "__main__":
    # 🕐 设置同步时间
    sync_delay = 2.0
    sync_time = time.time() + sync_delay
    print(f"🕐 Scheduled synchronized start at {sync_time:.3f} (in {sync_delay:.1f}s)")

    # Manager 用于跨进程共享变量
    with Manager() as manager:
        shared_dict = manager.dict()

        # 启动进程
        p1 = Process(target=capture_process, args=(sync_time, shared_dict))
        p2 = Process(target=log_export_process)
        p3 = Process(target=video_transcode_process)
        p4 = Process(target=data_send_process)
        p5 = Process(target=radar_control_process, args=(sync_time, shared_dict))

        # 启动后台监控线程（独立，不阻塞）
        threading.Thread(
            target=monitor_and_save_log,
            args=(shared_dict, sync_time),
            daemon=True
        ).start()

        # 启动所有进程
        p1.start()
        p2.start()
        p3.start()
        p4.start()
        p5.start()

        # 等待进程结束
        p1.join()
        p2.join()
        p3.join()
        p4.join()
        p5.join()

        print("✅ All processes finished.")