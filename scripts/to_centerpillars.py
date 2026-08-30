"""Turn Pipeline A's pseudo-labels into CenterPillars training data.

This is the bridge from stage A to stage B: the cold-start pipeline's output
becomes the *supervision* for a learned detector, and nothing human-labelled is
involved anywhere.

No change is made to CenterPillars.py. Its `SweepDataset` already reads

    <root>/<split>/<log>/<timestamp_ns>.npz
      points            (N, 4) float32  x, y, z, intensity  -- sensor frame
      boxes             (M, 7) float32  x, y, z, l, w, h, yaw
      labels            (M,)   int64
      num_interior_pts  (M,)   int32

so that layout is the interface, and this script writes it. Points come
straight out of sitegen's `.bin` sweeps, which are already float32 x,y,z,i in
the sensor frame; only the boxes have to be moved, since Pipeline A works in
the map frame.

Usage:
    python to_centerpillars.py WORK_DIR PSEUDO_LABELS.csv --out data/processed

Run it with sitegen's environment, which already has numpy:
    uv run --project ../sitegen python scripts/to_centerpillars.py ...
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import numpy as np

#: Every fifth frame is held out. Interleaved rather than a tail split because
#: the scene has distinct phases -- dig, walk, dig -- and a tail split would
#: validate on a regime the model never trained on.
VAL_EVERY = 5

#: Boxes with fewer returns than this are dropped from the supervision. A
#: pseudo-label fitted to four points is noise, and teaching a detector to
#: reproduce it is worse than not teaching it at all.
MIN_INTERIOR_PTS = 5


def read_poses(path: Path) -> list[tuple[np.ndarray, np.ndarray, float]]:
    """tf.csv -> per-frame (rotation, translation, yaw), map_from_sensor."""
    out = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            qx, qy, qz, qw = (float(r[k]) for k in ("qx", "qy", "qz", "qw"))
            rot = np.array(
                [
                    [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
                    [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
                    [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
                ],
                dtype=np.float64,
            )
            t = np.array([float(r["x"]), float(r["y"]), float(r["z"])])
            out.append((rot, t, float(np.arctan2(rot[1, 0], rot[0, 0]))))
    return out


def read_labels(path: Path) -> dict[float, list[dict[str, float]]]:
    by_time: dict[float, list[dict[str, float]]] = defaultdict(list)
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            by_time[round(float(r["t"]), 4)].append(
                {k: float(r[k]) for k in ("x", "y", "z", "w", "l", "h", "theta")}
            )
    return by_time


def interior_counts(points: np.ndarray, boxes: np.ndarray) -> np.ndarray:
    """How many returns fall inside each box, in the box's own frame."""
    counts = np.zeros(len(boxes), dtype=np.int32)
    for i, b in enumerate(boxes):
        cx, cy, cz, length, width, height, yaw = b
        d = points[:, :3] - np.array([cx, cy, cz])
        c, s = np.cos(-yaw), np.sin(-yaw)
        u = c * d[:, 0] - s * d[:, 1]
        v = s * d[:, 0] + c * d[:, 1]
        counts[i] = int(
            np.count_nonzero(
                (np.abs(u) <= length / 2) & (np.abs(v) <= width / 2) & (np.abs(d[:, 2]) <= height / 2)
            )
        )
    return counts


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("work", type=Path, help="sitegen export dir (tf.csv, sweeps/)")
    ap.add_argument("labels", type=Path, help="pseudo-label CSV in tracker schema")
    ap.add_argument("--out", type=Path, default=Path("data/processed"))
    ap.add_argument("--log-name", default="sitegen_seed1")
    args = ap.parse_args()

    poses = read_poses(args.work / "tf.csv")
    labels = read_labels(args.labels)
    index = list(csv.DictReader(open(args.work / "sweeps" / "index.csv", newline="")))

    written = {"train": 0, "val": 0}
    boxes_written = 0
    dropped = 0

    for row in index:
        frame = int(row["frame"])
        t = round(float(row["t"]), 4)
        rot, trans, sensor_yaw = poses[frame]

        raw = np.fromfile(args.work / "sweeps" / row["file"], dtype=np.float32)
        points = raw.reshape(-1, 4)

        rows = labels.get(t, [])
        boxes = np.zeros((len(rows), 7), dtype=np.float32)
        for i, b in enumerate(rows):
            # map -> sensor: the detector reasons in the frame its points live in.
            local = rot.T @ (np.array([b["x"], b["y"], b["z"]]) - trans)
            boxes[i] = (
                local[0], local[1], local[2],
                b["l"], b["w"], b["h"],
                b["theta"] - sensor_yaw,
            )

        keep = np.ones(len(boxes), dtype=bool)
        npts = np.zeros(len(boxes), dtype=np.int32)
        if len(boxes):
            npts = interior_counts(points, boxes)
            keep = npts >= MIN_INTERIOR_PTS
            dropped += int(np.count_nonzero(~keep))
        boxes, npts = boxes[keep], npts[keep]

        split = "val" if frame % VAL_EVERY == 0 else "train"
        out_dir = args.out / split / args.log_name
        out_dir.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(
            out_dir / f"{frame * 100_000_000}.npz",
            points=points,
            boxes=boxes,
            labels=np.zeros(len(boxes), dtype=np.int64),
            num_interior_pts=npts,
        )
        written[split] += 1
        boxes_written += len(boxes)

    for split in ("train", "val"):
        (args.out / split / args.log_name / ".done").touch()

    print(f"train sweeps {written['train']}, val sweeps {written['val']}")
    print(f"boxes written {boxes_written}, dropped for <{MIN_INTERIOR_PTS} pts {dropped}")


if __name__ == "__main__":
    main()
