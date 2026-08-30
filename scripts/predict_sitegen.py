"""Run the trained student over a sitegen scene and emit tracker-schema CSV.

CenterPillars' own `predict.py` reads raw ArgoVerse logs, so this is the same
job against sitegen sweeps -- using CenterPillars as a library rather than
changing it. Detections come out in the sensor frame and are lifted to the map
frame here, because that is the frame the oracle and every downstream stage
reason in.

Usage:
    uv run --project ../CenterPillars.py python scripts/predict_sitegen.py \\
        --checkpoint ../CenterPillars.py/runs/sitegen_bootstrap/best.pt \\
        --work WORK_DIR --out student.csv
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np
import torch

from centerpillars.config import decode_config
from centerpillars.decode import decode_heatmap
from centerpillars.evaluate import load_checkpoint
from centerpillars.train import pick_device

TRACKER_HEADER = [
    "track_id", "cls", "t", "x", "y", "z",
    "w", "l", "h", "vx", "vy", "theta", "conf",
]


def read_poses(path: Path) -> list[tuple[np.ndarray, np.ndarray, float]]:
    out = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            qx, qy, qz, qw = (float(r[k]) for k in ("qx", "qy", "qz", "qw"))
            rot = np.array(
                [
                    [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
                    [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
                    [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
                ]
            )
            t = np.array([float(r["x"]), float(r["y"]), float(r["z"])])
            out.append((rot, t, float(np.arctan2(rot[1, 0], rot[0, 0]))))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--checkpoint", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--device", default="auto")
    ap.add_argument("--score-thresh", type=float, default=None)
    args = ap.parse_args()

    device = pick_device(args.device)
    model, cfg = load_checkpoint(args.checkpoint, device)
    if args.score_thresh is not None:
        cfg["postprocess"]["score_thresh"] = args.score_thresh
    dcfg = decode_config(cfg)

    poses = read_poses(args.work / "tf.csv")
    index = list(csv.DictReader(open(args.work / "sweeps" / "index.csv", newline="")))

    rows: list[list] = []
    with torch.no_grad():
        for row in index:
            frame = int(row["frame"])
            t = float(row["t"])
            rot, trans, sensor_yaw = poses[frame]

            raw = np.fromfile(args.work / "sweeps" / row["file"], dtype=np.float32)
            points = torch.from_numpy(raw.reshape(1, -1, 4)).to(device)
            mask = torch.ones(points.shape[:2], dtype=torch.bool, device=device)

            out = model(points, mask)
            dets = decode_heatmap(out["hm"], out["reg"], dcfg)[0]

            for d in dets:
                # decode_heatmap rows: x, y, z, l, w, h, yaw, score, class
                x, y, z, length, width, height, yaw, score = (float(v) for v in d[:8])
                world = rot @ np.array([x, y, z]) + trans
                rows.append(
                    [
                        -1, 0, f"{t:.4f}",
                        f"{world[0]:.4f}", f"{world[1]:.4f}", f"{world[2]:.4f}",
                        f"{width:.4f}", f"{length:.4f}", f"{height:.4f}",
                        "0.0", "0.0", f"{yaw + sensor_yaw:.5f}", f"{score:.4f}",
                    ]
                )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(TRACKER_HEADER)
        w.writerows(rows)
    print(f"wrote {args.out}: {len(rows)} detections over {len(index)} frames")


if __name__ == "__main__":
    main()
