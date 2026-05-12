from __future__ import annotations

import time
from pathlib import Path

import matplotlib
import numpy as np
import pandas as pd

matplotlib.use("Agg")
import matplotlib.pyplot as plt


SOURCE_CSV = Path("/Users/thedan/Desktop/leida/Position_Dynamic_20260312_123326(3).csv")
OUTPUT_CSV = Path("/Users/thedan/Desktop/leida/test_quat.csv")
OUTPUT_PNG = Path("/Users/thedan/Desktop/leida/test_quat_compare.png")
TARGET_HZ = 60.0
TARGET_DT = 1.0 / TARGET_HZ


def normalize_quaternion(quat: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(quat, axis=1, keepdims=True)
    norms[norms == 0.0] = 1.0
    return quat / norms


def main() -> None:
    df = pd.read_csv(SOURCE_CSV)
    data = df[df["event"].fillna("") == ""].copy().reset_index(drop=True)

    source_frame = np.arange(len(data), dtype=np.int64)
    actual_time = data["time_abs"].to_numpy(dtype=np.float64)
    actual_unix = data["timestamp_unix_s"].to_numpy(dtype=np.float64)
    duration_s = float(actual_time[-1])

    frame_count_60hz = int(np.floor(duration_s * TARGET_HZ)) + 1
    ideal_frame = np.arange(frame_count_60hz, dtype=np.int64)
    ideal_time = ideal_frame.astype(np.float64) * TARGET_DT
    generation_start_unix = time.time()
    ideal_unix = generation_start_unix + ideal_time

    aligned_60hz_frame_for_source = source_frame * 2
    valid_alignment_mask = aligned_60hz_frame_for_source < frame_count_60hz
    aligned_source_frame = source_frame[valid_alignment_mask]
    aligned_60hz_frame = aligned_60hz_frame_for_source[valid_alignment_mask]
    aligned_60hz_time = aligned_60hz_frame.astype(np.float64) * TARGET_DT
    aligned_source_time = actual_time[valid_alignment_mask]
    aligned_source_unix = actual_unix[valid_alignment_mask]
    aligned_error_ms = (aligned_source_time - aligned_60hz_time) * 1000.0
    aligned_drift_from_start_ms = aligned_error_ms - aligned_error_ms[0]

    interp_columns = ["x_m", "y_m", "z_m", "roll_deg", "pitch_deg", "yaw_deg"]
    interpolated = {
        column: np.interp(ideal_time, actual_time, data[column].to_numpy(dtype=np.float64))
        for column in interp_columns
    }

    quat_components = []
    for column in ["qx", "qy", "qz", "qw"]:
        quat_components.append(np.interp(ideal_time, actual_time, data[column].to_numpy(dtype=np.float64)))
    quat_60hz = normalize_quaternion(np.column_stack(quat_components))

    actual_dt_ms = np.diff(actual_time) * 1000.0
    ideal_30hz_dt_ms = (2.0 * TARGET_DT) * 1000.0
    actual_dt_error_from_30hz_ms = actual_dt_ms - ideal_30hz_dt_ms

    aligned_source_frame_column = np.full(frame_count_60hz, np.nan, dtype=np.float64)
    aligned_source_time_column = np.full(frame_count_60hz, np.nan, dtype=np.float64)
    aligned_source_unix_column = np.full(frame_count_60hz, np.nan, dtype=np.float64)
    aligned_error_column_ms = np.full(frame_count_60hz, np.nan, dtype=np.float64)
    aligned_drift_column_ms = np.full(frame_count_60hz, np.nan, dtype=np.float64)
    is_aligned_30hz_point = np.zeros(frame_count_60hz, dtype=np.int64)

    aligned_source_frame_column[aligned_60hz_frame] = aligned_source_frame.astype(np.float64)
    aligned_source_time_column[aligned_60hz_frame] = aligned_source_time
    aligned_source_unix_column[aligned_60hz_frame] = aligned_source_unix
    aligned_error_column_ms[aligned_60hz_frame] = aligned_error_ms
    aligned_drift_column_ms[aligned_60hz_frame] = aligned_drift_from_start_ms
    is_aligned_30hz_point[aligned_60hz_frame] = 1

    out_df = pd.DataFrame(
        {
            "frame": ideal_frame,
            "time_abs": ideal_time,
            "timestamp_unix_s": ideal_unix,
            "is_aligned_30hz_point": is_aligned_30hz_point,
            "aligned_source_frame": aligned_source_frame_column,
            "aligned_source_time_abs": aligned_source_time_column,
            "aligned_source_timestamp_unix_s": aligned_source_unix_column,
            "aligned_error_ms": aligned_error_column_ms,
            "aligned_drift_from_start_ms": aligned_drift_column_ms,
            "x_m": interpolated["x_m"],
            "y_m": interpolated["y_m"],
            "z_m": interpolated["z_m"],
            "qx": quat_60hz[:, 0],
            "qy": quat_60hz[:, 1],
            "qz": quat_60hz[:, 2],
            "qw": quat_60hz[:, 3],
            "roll_deg": interpolated["roll_deg"],
            "pitch_deg": interpolated["pitch_deg"],
            "yaw_deg": interpolated["yaw_deg"],
        }
    )
    out_df.to_csv(OUTPUT_CSV, index=False, float_format="%.9f")

    fig, axes = plt.subplots(3, 1, figsize=(15, 11), constrained_layout=True)

    axes[0].plot(aligned_source_frame, aligned_source_time, label="Original 30Hz time_abs", linewidth=1.0)
    axes[0].plot(aligned_source_frame, aligned_60hz_time, label="Aligned 60Hz time_abs (frame * 2)", linewidth=1.0, alpha=0.85)
    axes[0].set_title("30Hz source vs aligned 60Hz timeline")
    axes[0].set_xlabel("Source frame index")
    axes[0].set_ylabel("Seconds")
    axes[0].legend()
    axes[0].grid(alpha=0.3)

    axes[1].plot(aligned_source_frame, aligned_error_ms, label="Alignment error", linewidth=0.8)
    axes[1].axhline(0.0, color="tab:red", linestyle="--")
    axes[1].set_title("error growth after n -> 2n alignment")
    axes[1].set_xlabel("Source frame index")
    axes[1].set_ylabel("Milliseconds")
    axes[1].legend()
    axes[1].grid(alpha=0.3)

    axes[2].plot(actual_dt_error_from_30hz_ms, label="Per-frame dt error vs ideal 30Hz", linewidth=0.8)
    axes[2].axhline(0.0, color="tab:red", linestyle="--")
    axes[2].set_title("per-frame interval error against ideal 30Hz")
    axes[2].set_xlabel("Source frame index")
    axes[2].set_ylabel("Milliseconds")
    axes[2].legend()
    axes[2].grid(alpha=0.3)

    fig.savefig(OUTPUT_PNG, dpi=160)

    print(f"source rows: {len(actual_time)}")
    print(f"duration_s: {duration_s:.6f}")
    print(f"generated 60Hz rows: {len(out_df)}")
    print(f"aligned rows: {len(aligned_source_frame)}")
    print(f"generation_start_unix: {generation_start_unix:.6f}")
    print(f"actual dt mean ms: {actual_dt_ms.mean():.6f}")
    print(f"actual dt median ms: {np.median(actual_dt_ms):.6f}")
    print(f"actual dt min ms: {actual_dt_ms.min():.6f}")
    print(f"actual dt max ms: {actual_dt_ms.max():.6f}")
    print(f"alignment error start ms: {aligned_error_ms[0]:.6f}")
    print(f"alignment error end ms: {aligned_error_ms[-1]:.6f}")
    print(f"alignment error mean ms: {aligned_error_ms.mean():.6f}")
    print(f"alignment error abs max ms: {np.max(np.abs(aligned_error_ms)):.6f}")
    print(f"saved csv: {OUTPUT_CSV}")
    print(f"saved plot: {OUTPUT_PNG}")


if __name__ == "__main__":
    main()