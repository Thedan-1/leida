"""
交互式 X-Y 投影图
输出单个 HTML 文件，浏览器打开可拖拽/缩放/hover/框选
用法: python visualize_xy_interactive.py [csv文件路径]
"""
import sys
from pathlib import Path
import pandas as pd
import numpy as np
import plotly.graph_objects as go

csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else \
           Path("/Users/thedan/Desktop/leida/Position_Dynamic_20260309_190333.csv")

df = pd.read_csv(csv_path)
data = df[df["event"].fillna("") == ""].copy().reset_index(drop=True)

x_raw = data["x_m"].values
y_raw = data["y_m"].values
z_raw = data["z_m"].values
t     = data["t_rel_s"].values
n     = len(data)

x = -(x_raw - x_raw[0]) * 100   # 右为正，cm
y =  (y_raw - y_raw[0]) * 100   # 上为正，下为负，cm
z = -(z_raw - z_raw[0]) * 100   # 面向用户为正，cm

print(f"帧数: {n}  时长: {t[-1]:.1f}s")
print(f"X: {x.min():.2f}~{x.max():.2f} cm")
print(f"Y: {y.min():.2f}~{y.max():.2f} cm")
print(f"Z: {z.min():.2f}~{z.max():.2f} cm")

# ── 颜色：按时间映射 ─────────────────────────────────────────
color_norm = (t - t.min()) / (t.max() - t.min())

from plotly.subplots import make_subplots
import plotly.graph_objects as go

fig = make_subplots(
    rows=1, cols=2,
    column_widths=[0.55, 0.45],
    specs=[[{"type": "scatter"}, {"type": "scatter3d"}]],
    subplot_titles=["X-Y 投影（右×高度）", "3D 轨迹（X-Y-Z）"],
)

# ── 左：X-Y 投影 ─────────────────────────────────────────────
fig.add_trace(go.Scatter(
    x=x, y=y,
    mode="markers",
    marker=dict(
        size=3,
        color=color_norm,
        colorscale="RdYlBu_r",
        colorbar=dict(title="时间", thickness=12, len=0.7, x=0.45),
        opacity=0.7,
    ),
    text=[f"t={ti:.2f}s  X={xi:.2f}  Y={yi:.2f}" for ti, xi, yi in zip(t, x, y)],
    hovertemplate="%{text}<extra></extra>",
    name="X-Y",
), row=1, col=1)

fig.add_trace(go.Scatter(
    x=[x[0], x[-1]], y=[y[0], y[-1]],
    mode="markers+text",
    marker=dict(size=10, color=["green", "red"], symbol=["circle", "x"]),
    text=["起点", "终点"], textposition=["bottom right", "top left"],
    hoverinfo="skip", showlegend=False,
), row=1, col=1)

# ── 右：3D 轨迹 ──────────────────────────────────────────────
fig.add_trace(go.Scatter3d(
    x=x, y=z, z=y,
    mode="markers",
    marker=dict(
        size=2,
        color=color_norm,
        colorscale="RdYlBu_r",
        opacity=0.7,
    ),
    text=[f"t={ti:.2f}s  X={xi:.2f}  Y={yi:.2f}  Z={zi:.2f}"
          for ti, xi, yi, zi in zip(t, x, y, z)],
    hovertemplate="%{text}<extra></extra>",
    name="3D",
), row=1, col=2)

fig.update_layout(
    title=dict(text=f"{csv_path.name}  ({n} frames, {t[-1]:.0f}s)", font_size=14),
    plot_bgcolor="white",
    hovermode="closest",
    dragmode="pan",
    width=1400, height=600,
    scene=dict(
        xaxis=dict(title="X →右 (cm)"),
        yaxis=dict(title="Z →面 (cm)"),
        zaxis=dict(title="Y ↑上 (cm)"),
        aspectmode="data",
    ),
)

fig.update_xaxes(
    title_text="X → 右 (cm)", range=[-2, 57], dtick=5,
    showgrid=True, gridcolor="#e0e0e0", zeroline=True, zerolinecolor="#aaa",
    row=1, col=1,
)
fig.update_yaxes(
    title_text="Y ↑ 上 (cm)", range=[-15, 5], dtick=2,
    showgrid=True, gridcolor="#e0e0e0", zeroline=True, zerolinecolor="#aaa",
    row=1, col=1,
)

out = csv_path.with_suffix(".html")
fig.write_html(str(out), include_plotlyjs="cdn", config={
    "scrollZoom": True,      # 滚轮缩放
    "displayModeBar": True,
    "modeBarButtonsToAdd": ["drawrect", "eraseshape"],
})
print(f"已保存: {out}")
