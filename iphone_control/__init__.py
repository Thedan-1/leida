"""
iphone_control
==============
iPhone TCP 控制模块：封装雷达采集脚本中所需的 iPhone 相关功能。

快速上手（三行接入）
--------------------
::

    from iphone_control import IPhoneSession

    # 方式 1：直接构造
    session = IPhoneSession(ip="192.168.31.83", save_dir=POSTPROC_DIR)

    # 方式 2：从现有 CONFIG 字典构造（兼容旧代码，无需修改 CONFIG）
    session = IPhoneSession.from_config(CONFIG, save_dir=POSTPROC_DIR)

    session.start()           # 连接 iPhone 发 GO + 启动文件接收服务
    # ... 雷达采集主循环 ...
    session.stop_and_wait()   # 发 STOP + 等待上传 + 清理

也可以当上下文管理器用::

    with IPhoneSession(ip="192.168.31.83", save_dir=POSTPROC_DIR) as s:
        # ... 采集 ...

底层类（按需单独使用）
----------------------
- `IPhoneTCPController` — 仅 GO/STOP TCP 指令通道
- `IPhoneFileTCPServer`  — 仅文件接收服务
"""

from .tcp_controller import IPhoneTCPController
from .file_rx_server import IPhoneFileTCPServer
from .session import IPhoneSession

__all__ = ["IPhoneSession", "IPhoneTCPController", "IPhoneFileTCPServer"]
