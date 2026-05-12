"""
Merge radar event log (from radacc) with iPhone pose CSV by timestamp.

Usage:
  python merge_radar_iphone.py \
      --iphone Position_Dynamic_xxx.csv \
      --radar radacc_log.csv \
      --out merged_radar_iphone.csv
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--iphone", required=True, help="iPhone pose CSV path")
    p.add_argument("--radar", required=True, help="radacc log CSV path")
    p.add_argument("--out", default="merged_radar_iphone.csv", help="output CSV path")
    p.add_argument("--tolerance-ms", type=float, default=100.0, help="nearest match tolerance in ms")
    return p.parse_args()


def ensure_float_col(df: pd.DataFrame, col: str) -> pd.Series:
    if col not in df.columns:
        return pd.Series([np.nan] * len(df), index=df.index, dtype=float)
    return pd.to_numeric(df[col], errors="coerce")


def interp_on_time(src_t: np.ndarray, src_v: np.ndarray, dst_t: np.ndarray) -> np.ndarray:
    valid = np.isfinite(src_t) & np.isfinite(src_v)
    if valid.sum() < 2:
        return np.full_like(dst_t, np.nan, dtype=float)

    t = src_t[valid]
    v = src_v[valid]
    order = np.argsort(t)
    t = t[order]
    v = v[order]

    y = np.interp(dst_t, t, v)
    y[(dst_t < t[0]) | (dst_t > t[-1])] = np.nan
    return y


def main():
    args = parse_args()

    iphone_path = Path(args.iphone)
    radar_path = Path(args.radar)
    out_path = Path(args.out)

    iphone_df = pd.read_csv(iphone_path)
    radar_df = pd.read_csv(radar_path)

    # Keep real pose samples only.
    pose = iphone_df[iphone_df["event"].fillna("") == ""].copy().reset_index(drop=True)

    pose["timestamp_unix_s"] = pd.to_numeric(pose["timestamp_unix_s"], errors="coerce")
    pose = pose[np.isfinite(pose["timestamp_unix_s"])].copy().sort_values("timestamp_unix_s")

    radar_df["trigger_time_pc"] = ensure_float_col(radar_df, "trigger_time_pc")
    radar_df["trigger_time_iphone_est"] = ensure_float_col(radar_df, "trigger_time_iphone_est")
    radar_df["go_offset_s"] = ensure_float_col(radar_df, "go_offset_s")

    # Choose best available radar timestamp mapped to iPhone clock.
    trig_iphone = radar_df["trigger_time_iphone_est"].copy()
    need_fill = ~np.isfinite(trig_iphone)
    trig_iphone.loc[need_fill] = radar_df.loc[need_fill, "trigger_time_pc"] + radar_df.loc[need_fill, "go_offset_s"]

    radar = radar_df.copy()
    radar["t_align_iphone_s"] = trig_iphone
    radar = radar[np.isfinite(radar["t_align_iphone_s"])].copy().sort_values("t_align_iphone_s")

    if len(radar) == 0:
        raise RuntimeError("No valid radar alignment timestamps found in radar log.")

    pose_small = pose[[
        "timestamp_unix_s",
        "t_rel_s",
        "x_m", "y_m", "z_m",
        "qx", "qy", "qz", "qw",
        "roll_deg", "pitch_deg", "yaw_deg",
    ]].copy()

    tol = args.tolerance_ms / 1000.0
    merged = pd.merge_asof(
        radar,
        pose_small,
        left_on="t_align_iphone_s",
        right_on="timestamp_unix_s",
        direction="nearest",
        tolerance=tol,
    )

    # Add interpolation-based values for smoother alignment.
    dst_t = merged["t_align_iphone_s"].to_numpy(dtype=float)
    src_t = pose["timestamp_unix_s"].to_numpy(dtype=float)

    interp_cols = ["x_m", "y_m", "z_m", "roll_deg", "pitch_deg", "yaw_deg"]
    for col in interp_cols:
        src_v = pd.to_numeric(pose[col], errors="coerce").to_numpy(dtype=float)
        merged[f"{col}_interp"] = interp_on_time(src_t, src_v, dst_t)

    merged["x_cm_interp"] = merged["x_m_interp"] * 100.0
    merged["y_cm_interp"] = merged["y_m_interp"] * 100.0
    merged["z_cm_interp"] = merged["z_m_interp"] * 100.0

    # Convenience columns in your preferred axis sign convention.
    if "x_m_interp" in merged.columns:
        x0 = merged["x_m_interp"].dropna()
        if len(x0):
            x0 = float(x0.iloc[0])
            merged["x_right_cm_interp"] = -(merged["x_m_interp"] - x0) * 100.0
    if "y_m_interp" in merged.columns:
        y0 = merged["y_m_interp"].dropna()
        if len(y0):
            y0 = float(y0.iloc[0])
            merged["y_up_cm_interp"] = (merged["y_m_interp"] - y0) * 100.0
    if "z_m_interp" in merged.columns:
        z0 = merged["z_m_interp"].dropna()
        if len(z0):
            z0 = float(z0.iloc[0])
            merged["z_face_cm_interp"] = -(merged["z_m_interp"] - z0) * 100.0

    merged.to_csv(out_path, index=False)

    matched = merged["timestamp_unix_s"].notna().sum()
    print(f"radar rows: {len(radar)}")
    print(f"iphone pose rows: {len(pose)}")
    print(f"nearest-matched rows (tol={args.tolerance_ms:.0f}ms): {matched}/{len(merged)}")
    print(f"saved: {out_path.resolve()}")


if __name__ == "__main__":
    main()
