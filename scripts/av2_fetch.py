"""Fetch one Argoverse 2 log and lay it out as a Refinery work directory.

    python scripts/av2_fetch.py <log_id> <work_dir> [--prefix sensor/val] [--cache DIR]

Reads the public `argoverse` bucket over plain HTTPS (no credentials), keeps the
raw files under `--cache` so a rerun downloads nothing, and writes what
`run_geometry` reads:

    work_dir/tf.csv              t,x,y,z,qx,qy,qz,qw   one row per sweep
    work_dir/sweeps/index.csv    frame,t,n_points,file
    work_dir/sweeps/NNNNNN.bin   float32 x,y,z,intensity in the ego frame
    work_dir/annotations.csv     the log's cuboids in the same map frame (if any)
    work_dir/meta.json           counts and the map origin; written last

Two conversions matter:

* **A local map frame.** AV2 poses are in a city frame thousands of metres from
  its origin. Every translation here is relative to the first sweep's pose, so
  coordinates stay small; the rotation is the city's. `meta.json` records the
  offset.
* **The ego's own returns are dropped here**, with a box around the vehicle in
  its own frame, because the excavator's forward-kinematics mask in
  `run_geometry` has nothing to say about a car (`proprioception=False`).

AV2 sweeps are Arrow IPC files with LZ4-compressed batches, which arrow-mlake's
reader doesn't take yet, so this step is Python; everything after it is Mojo.
Licence: AV2 is CC BY-NC-SA 4.0.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pyarrow.ipc as ipc

BUCKET = "https://argoverse.s3.amazonaws.com"

# The ego vehicle in its own frame (origin at the rear axle, x forward): a
# generous box, so roof-rack and mirror returns go too.
EGO_X = (-1.5, 4.5)
EGO_Y = (-1.3, 1.3)
EGO_Z = (-0.5, 2.6)


def list_keys(prefix: str) -> list[tuple[str, int]]:
    out: list[tuple[str, int]] = []
    token = None
    while True:
        q = {"list-type": "2", "prefix": prefix}
        if token:
            q["continuation-token"] = token
        url = BUCKET + "/?" + urllib.parse.urlencode(q)
        with urllib.request.urlopen(url, timeout=60) as r:
            text = r.read().decode()
        for key, size in re.findall(
            r"<Key>([^<]+)</Key>.*?<Size>(\d+)</Size>", text, flags=re.S
        ):
            out.append((key, int(size)))
        m = re.search(r"<NextContinuationToken>([^<]+)<", text)
        if "<IsTruncated>true" not in text or not m:
            return out
        token = m.group(1)


def fetch(key: str, dest: Path, size: int | None = None) -> Path:
    if dest.exists() and (size is None or dest.stat().st_size == size):
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(BUCKET + "/" + urllib.parse.quote(key), timeout=120) as r:
        tmp.write_bytes(r.read())
    os.replace(tmp, dest)
    return dest


def quat_matrix(qw: float, qx: float, qy: float, qz: float) -> np.ndarray:
    return np.array(
        [
            [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
            [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
            [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
        ]
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log_id")
    ap.add_argument("work_dir")
    ap.add_argument("--prefix", default="sensor/val", help="split under datasets/av2/")
    ap.add_argument("--cache", default=os.environ.get("AV2_CACHE", "av2-cache"))
    ap.add_argument("--max-sweeps", type=int, default=0, help="0 for all")
    args = ap.parse_args()

    work = Path(args.work_dir)
    if (work / "meta.json").exists():
        print("already converted:", work)
        return 0

    base = f"datasets/av2/{args.prefix}/{args.log_id}/"
    raw = Path(args.cache) / args.prefix / args.log_id
    lidar = sorted(
        (k, s) for k, s in list_keys(base + "sensors/lidar/") if k.endswith(".feather")
    )
    if not lidar:
        print(f"no sweeps under s3://argoverse/{base}", file=sys.stderr)
        return 1
    if args.max_sweeps > 0:
        lidar = lidar[: args.max_sweeps]
    top = {k.rsplit("/", 1)[1]: s for k, s in list_keys(base) if k.count("/") == base.count("/")}

    poses_path = fetch(base + "city_SE3_egovehicle.feather", raw / "city_SE3_egovehicle.feather")
    poses = ipc.open_file(poses_path).read_all().to_pydict()
    by_ts = {t: i for i, t in enumerate(poses["timestamp_ns"])}
    pose_ts = np.array(poses["timestamp_ns"], dtype=np.int64)

    def pose_at(ts: int) -> int:
        i = by_ts.get(ts)
        if i is None:  # not expected for lidar stamps; nearest otherwise
            i = int(np.argmin(np.abs(pose_ts - ts)))
        return i

    # One request at a time runs at about 1 MB/s; sixteen at once fill the link.
    with ThreadPoolExecutor(max_workers=16) as pool:
        list(
            pool.map(
                lambda ks: fetch(ks[0], raw / "sensors" / "lidar" / ks[0].rsplit("/", 1)[1], ks[1]),
                lidar,
            )
        )

    stamps = [int(k.rsplit("/", 1)[1].split(".")[0]) for k, _ in lidar]
    i0 = pose_at(stamps[0])
    origin = np.array([poses["tx_m"][i0], poses["ty_m"][i0], poses["tz_m"][i0]])

    sweeps = work / "sweeps"
    sweeps.mkdir(parents=True, exist_ok=True)
    total = kept = 0
    with open(work / "tf.csv", "w") as tf, open(sweeps / "index.csv", "w") as index:
        tf.write("t,x,y,z,qx,qy,qz,qw\n")
        index.write("frame,t,n_points,file\n")
        for f, ((key, size), ts) in enumerate(zip(lidar, stamps)):
            path = fetch(key, raw / "sensors" / "lidar" / key.rsplit("/", 1)[1], size)
            t = ipc.open_file(path).read_all()
            x = t.column("x").to_numpy().astype(np.float32)
            y = t.column("y").to_numpy().astype(np.float32)
            z = t.column("z").to_numpy().astype(np.float32)
            inten = t.column("intensity").to_numpy().astype(np.float32)
            ego = (
                (x > EGO_X[0]) & (x < EGO_X[1])
                & (y > EGO_Y[0]) & (y < EGO_Y[1])
                & (z > EGO_Z[0]) & (z < EGO_Z[1])
            )
            keep = ~ego
            pts = np.stack([x[keep], y[keep], z[keep], inten[keep]], axis=1)
            name = f"{f:06d}.bin"
            pts.astype("<f4").tofile(sweeps / name)
            total += len(x)
            kept += int(keep.sum())
            rel = (ts - stamps[0]) / 1e9
            index.write(f"{f},{rel:.4f},{len(pts)},{name}\n")
            i = pose_at(ts)
            p = np.array([poses["tx_m"][i], poses["ty_m"][i], poses["tz_m"][i]]) - origin
            tf.write(
                f"{rel:.4f},{p[0]:.6f},{p[1]:.6f},{p[2]:.6f},"
                f"{poses['qx'][i]:.9f},{poses['qy'][i]:.9f},{poses['qz'][i]:.9f},{poses['qw'][i]:.9f}\n"
            )

    n_ann = 0
    if "annotations.feather" in top:
        ann_path = fetch(base + "annotations.feather", raw / "annotations.feather", top["annotations.feather"])
        a = ipc.open_file(ann_path).read_all().to_pydict()
        first, last = stamps[0], stamps[-1]
        with open(work / "annotations.csv", "w") as out:
            out.write("t,track_uuid,category,x,y,z,l,w,h,yaw,num_points,range_m\n")
            for j in range(len(a["timestamp_ns"])):
                ts = a["timestamp_ns"][j]
                if ts < first or ts > last:
                    continue
                i = pose_at(ts)
                r = quat_matrix(poses["qw"][i], poses["qx"][i], poses["qy"][i], poses["qz"][i])
                tr = np.array([poses["tx_m"][i], poses["ty_m"][i], poses["tz_m"][i]]) - origin
                c_ego = np.array([a["tx_m"][j], a["ty_m"][j], a["tz_m"][j]])
                c = r @ c_ego + tr
                ra = quat_matrix(a["qw"][j], a["qx"][j], a["qy"][j], a["qz"][j])
                heading = r @ ra @ np.array([1.0, 0.0, 0.0])
                yaw = math.atan2(heading[1], heading[0])
                rng = math.hypot(c_ego[0], c_ego[1])
                out.write(
                    f"{(ts - first) / 1e9:.4f},{a['track_uuid'][j]},{a['category'][j]},"
                    f"{c[0]:.4f},{c[1]:.4f},{c[2]:.4f},{a['length_m'][j]:.4f},"
                    f"{a['width_m'][j]:.4f},{a['height_m'][j]:.4f},{yaw:.5f},"
                    f"{a['num_interior_pts'][j]},{rng:.3f}\n"
                )
                n_ann += 1

    meta = {
        "log_id": args.log_id,
        "prefix": args.prefix,
        "frames": len(lidar),
        "points": total,
        "ego_points_dropped": total - kept,
        "annotations": n_ann,
        "origin_city_m": origin.tolist(),
        "bytes_downloaded": sum(s for _, s in lidar),
    }
    tmp = work / "meta.json.part"
    tmp.write_text(json.dumps(meta, indent=1) + "\n")
    os.replace(tmp, work / "meta.json")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    sys.exit(main())
