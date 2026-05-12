import pandas as pd
import numpy as np
import sys

csv = sys.argv[1] if len(sys.argv) > 1 else "Position_Dynamic_20260309_203743.csv"
df = pd.read_csv(csv)
data = df[df["event"].fillna("") == ""].copy().reset_index(drop=True)
t = data["t_rel_s"].values
dt = np.diff(t)
expected_dt = 1/30

print(f"总帧数: {len(t)}")
print(f"总时长: {t[-1]:.3f}s")
print(f"理论帧数 @30Hz: {30 * t[-1]:.1f} 帧")
print(f"实际/理论: {len(t) / (30 * t[-1]) * 100:.2f}%")
print()
print(f"帧间隔 均值: {dt.mean()*1000:.2f}ms  (期望 {expected_dt*1000:.2f}ms)")
print(f"帧间隔 std:  {dt.std()*1000:.2f}ms")
print(f"帧间隔 最大: {dt.max()*1000:.2f}ms")
print(f"帧间隔 最小: {dt.min()*1000:.2f}ms")
print()

threshold = expected_dt * 2
gaps = np.where(dt > threshold)[0]
print(f"疑似丢包 (间隔 > {threshold*1000:.0f}ms): {len(gaps)} 处")
for i in gaps[:20]:
    print(f"  帧{i}→{i+1}  t={t[i]:.3f}s  间隔={dt[i]*1000:.1f}ms  (~{dt[i]/expected_dt:.1f}帧)")
