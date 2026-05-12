"""
visualize_position.py
---------------------
ARKit 轨迹可视化：3D + 三个投影面 + 时间曲线
"""

import sys
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
plt.rcParams["font.family"] = ["Hei", "Arial Unicode MS", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
from mpl_toolkits.mplot3d import Axes3D  # noqa: F401

# ── 读取文件 ────────────────────────────────────────────────
csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else \
           Path("/Users/thedan/Desktop/leida/Position_Dynamic_20260309_190333.csv")

df = pd.read_csv(csv_path)
data = df[df["event"].fillna("") == ""].copy().reset_index(drop=True)

x_raw = data["x_m"].values
y_raw = data["y_m"].values
z_raw = data["z_m"].values
x = -(x_raw - x_raw[0]) * 100   # 翻转符号+平移原点 → 右为正，0~53cm
y =  (y_raw - y_raw[0]) * 100   # 上为正，下为负
z = -(z_raw - z_raw[0]) * 100   # 翻转符号 → 面向用户为正
t = data["t_rel_s"].values
n = len(data)
color = np.linspace(0, 1, n)

print(f"帧数: {n}  时长: {t[-1]:.1f}s")
print(f"X (右+): {x.min():.2f}~{x.max():.2f} cm  峰峰={x.max()-x.min():.2f}cm")
print(f"Y (上+): {y.min():.2f}~{y.max():.2f} cm  峰峰={y.max()-y.min():.2f}cm")
print(f"Z (面+): {z.min():.2f}~{z.max():.2f} cm  峰峰={z.max()-z.min():.2f}cm")

# ── 布局：GridSpec 3×3 ─────────────────────────────────────
fig = plt.figure(figsize=(18, 13))
fig.suptitle(f"{csv_path.name}  ({n} frames, {t[-1]:.0f}s)", fontsize=13)

cmap = plt.cm.coolwarm

from matplotlib.gridspec import GridSpec
gs = GridSpec(3, 3, figure=fig, hspace=0.45, wspace=0.35)

# ── 1. 3D 轨迹（左上，占 1×1） ──────────────────────────────
ax3d = fig.add_subplot(gs[0, 0], projection="3d")
for i in range(n - 1):
    ax3d.plot(x[i:i+2], z[i:i+2], y[i:i+2],
              color=cmap(color[i]), lw=0.6, alpha=0.8)
ax3d.set_xlabel("X →右 (cm)", fontsize=7)
ax3d.set_ylabel("Z →面 (cm)", fontsize=7)
ax3d.set_zlabel("Y ↑上 (cm)", fontsize=7)
ax3d.set_title("3D 轨迹")
ax3d.tick_params(labelsize=6)

# ── 2. X-Y 投影（中上+右上，横跨2列，够宽） ────────────────
ax_xy = fig.add_subplot(gs[0, 1:])
sc = ax_xy.scatter(x, y, c=color, cmap="coolwarm", s=3, alpha=0.7)
ax_xy.set_xlabel("X →右 (cm)")
ax_xy.set_ylabel("Y ↑上 (cm)  [下为负]")
ax_xy.set_title("X-Y 投影（右×高度，Y轴±50cm参考）")
ax_xy.set_xlim(-2, 57)
ax_xy.set_ylim(-50, 50)
ax_xy.xaxis.set_major_locator(ticker.MultipleLocator(10))
ax_xy.yaxis.set_major_locator(ticker.MultipleLocator(10))
ax_xy.axhline(0, color="gray", lw=0.8, ls="--")
ax_xy.axvline(0, color="gray", lw=0.5, ls="--")
ax_xy.grid(alpha=0.3)
plt.colorbar(sc, ax=ax_xy, label="时间→", shrink=0.8)

# ── 3. X-Z 投影（左中） ─────────────────────────────────────
ax_xz = fig.add_subplot(gs[1, 0])
ax_xz.scatter(x, z, c=color, cmap="coolwarm", s=1.5, alpha=0.6)
ax_xz.set_xlabel("X →右 (cm)")
ax_xz.set_ylabel("Z →面向用户 (cm)")
ax_xz.set_title("X-Z 投影（俯视）")
ax_xz.axhline(0, color="gray", lw=0.5, ls="--")
ax_xz.axvline(0, color="gray", lw=0.5, ls="--")
ax_xz.grid(alpha=0.3)

# ── 4. X 时间曲线 ───────────────────────────────────────────
ax_x = fig.add_subplot(gs[1, 1])
ax_x.plot(t, x, color="tab:blue", lw=0.8)
ax_x.axhline(0, color="gray", lw=0.5, ls="--")
ax_x.set_xlabel("t (s)"); ax_x.set_ylabel("X →右 (cm)")
ax_x.set_title("X 横向")
ax_x.grid(alpha=0.3)

# ── 5. Y 时间曲线 ───────────────────────────────────────────
ax_y = fig.add_subplot(gs[1, 2])
ax_y.plot(t, y, color="tab:green", lw=0.8)
ax_y.axhline(0, color="gray", lw=0.5, ls="--")
ax_y.set_xlabel("t (s)"); ax_y.set_ylabel("Y ↑上 (cm)")
ax_y.set_title("Y 高度")
ax_y.set_ylim(-50, 50)
ax_y.yaxis.set_major_locator(ticker.MultipleLocator(10))
ax_y.grid(alpha=0.3)

# ── 6. Z 时间曲线 ───────────────────────────────────────────
ax_z = fig.add_subplot(gs[2, :])
ax_z.plot(t, z, color="tab:orange", lw=0.8)
ax_z.axhline(0, color="gray", lw=0.5, ls="--")
ax_z.set_xlabel("t (s)"); ax_z.set_ylabel("Z →面向用户 (cm)")
ax_z.set_title("Z 深度")
ax_z.grid(alpha=0.3)

plt.tight_layout()
out = csv_path.with_suffix(".png")
plt.savefig(out, dpi=150, bbox_inches="tight")
print(f"\n图已保存: {out}")


# ── 读取文件 ────────────────────────────────────────────────
csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else \
           Path("/Users/thedan/Desktop/leida/Position_Dynamic_20260309_190333.csv")

df = pd.read_csv(csv_path)
# 只取正常数据帧（event 为空）
data = df[df["event"].isna() | (df["event"] == "")].copy()
data = data.reset_index(drop=True)

x_raw = data["x_m"].values * 100   # cm
y_raw = data["y_m"].values * 100
z_raw = data["z_m"].values * 100
t = data["t_rel_s"].values
n = len(data)

# ── 坐标系变换（第一个点为原点）──────────────────────────────
# X:  右 = 正（ARKit X 向右移动时数值变小，翻符号）
# Y:  上 = 正，下 = 负（ARKit Y 已是上正，不变）
# Z:  面向用户 = 正（ARKit 摄像头朝向 -Z，翻符号）
x = -(x_raw - x_raw[0])   # 翻转：右为正
y =  (y_raw - y_raw[0])   # 不变：上为正，下为负
z = -(z_raw - z_raw[0])   # 翻转：面向用户为正

color = np.linspace(0, 1, n)

# ── 图形布局 ────────────────────────────────────────────────
fig = plt.figure(figsize=(18, 10))
fig.suptitle(f"{csv_path.name}  ({n} frames)", fontsize=13)

