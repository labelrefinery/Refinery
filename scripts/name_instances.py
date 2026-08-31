"""Give geometric instances class names, from cameras and an open-vocabulary detector.

`geo_kinetic_discovery` finds *that* something is there. This gives it a name,
using two sources that are complementary in a way worth stating plainly:

  - **Grounding DINO names machines and cannot see people.** Measured over ten
    unobstructed views of a sitegen scene: 9 of 10 produced `haul truck` with
    the correct label, and a worker visible in three of them was never detected
    once.
  - **Geometry finds people and cannot name machines.** Box volume separates
    machine-sized from person-sized at 97.5% on this scene -- two and a half
    orders of magnitude apart -- but says nothing about excavator vs dozer.

So the detector is asked only about the instances it has a chance with, and the
size prior covers the rest. Every name carries the confidence it was assigned
with, and *how* it was assigned, so a downstream training step can filter on
either.

Detection is expensive (~13 s a frame), so the detector is not run over the
whole log. For each instance the frames where it projects largest are chosen,
capped globally -- which is also what a real system would do.
"""

from __future__ import annotations

import argparse
import csv
import io
import subprocess
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
from foxglove_schemas_protobuf.CameraCalibration_pb2 import CameraCalibration
from foxglove_schemas_protobuf.CompressedImage_pb2 import CompressedImage
from foxglove_schemas_protobuf.FrameTransform_pb2 import FrameTransform
from mcap.reader import make_reader
from PIL import Image

#: Volume above which an instance is machine-sized. Measured: haul trucks land
#: at a median 69.3 m3 and workers at 0.13, and a 5 m3 split separates them
#: 97.5% of the time.
MACHINE_VOLUME_M3 = 5.0

#: Confidence attached to a size-prior name. Deliberately below anything the
#: detector produces, so a filter that trusts names can exclude these first.
SIZE_PRIOR_CONF = 0.30

#: Confidence for an instance the detector was shown and did not corroborate.
#: Lower than the size prior on purpose: this is weaker evidence than never
#: having looked, because looking produced nothing.
UNCORROBORATED_CONF = 0.10

DEFAULT_PROMPT = "excavator . haul truck . worker . person ."

TRACKER_HEADER = [
    "track_id", "cls", "t", "x", "y", "z",
    "w", "l", "h", "vx", "vy", "theta", "conf",
]


@dataclass
class CameraFrame:
    name: str
    t: float
    image: bytes
    rotation: np.ndarray  # map_from_camera
    translation: np.ndarray
    K: np.ndarray


@dataclass
class Vote:
    label: str
    score: float
    source: str


@dataclass
class Instance:
    track_id: str
    votes: list[Vote] = field(default_factory=list)
    volume: float = 0.0


def _quat_to_matrix(q: Any) -> np.ndarray:
    x, y, z, w = q.x, q.y, q.z, q.w
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def _topic_names(scene: Path) -> list[str]:
    with open(scene, "rb") as f:
        summary = make_reader(f).get_summary()
        return [c.topic for c in (summary.channels.values() if summary else [])]


def read_camera_frames(scene: Path) -> list[CameraFrame]:
    """Images, calibration and pose per camera per timestamp, from the log."""
    images: dict[tuple[str, int], bytes] = {}
    calib: dict[str, np.ndarray] = {}
    poses: dict[tuple[str, int], tuple[np.ndarray, np.ndarray]] = {}
    base_ns: int | None = None

    # Only the camera and transform topics. Iterating everything drags 600
    # LiDAR sweeps through the reader for nothing, and that dominates the run.
    wanted = [t for t in _topic_names(scene) if t.startswith("/camera/") or t == "/tf"]
    with open(scene, "rb") as f:
        for _, channel, message in make_reader(f).iter_messages(topics=wanted):
            topic = channel.topic
            if base_ns is None:
                base_ns = message.log_time
            if topic.startswith("/camera/") and topic.endswith("/image"):
                images[(topic.split("/")[2], message.log_time)] = message.data
            elif topic.startswith("/camera/") and topic.endswith("/calibration"):
                c = CameraCalibration()
                c.ParseFromString(message.data)
                calib[topic.split("/")[2]] = np.array(c.K, dtype=float).reshape(3, 3)
            elif topic == "/tf":
                tf = FrameTransform()
                tf.ParseFromString(message.data)
                if tf.child_frame_id.startswith("camera_"):
                    poses[(tf.child_frame_id[len("camera_"):], message.log_time)] = (
                        _quat_to_matrix(tf.rotation),
                        np.array([tf.translation.x, tf.translation.y, tf.translation.z]),
                    )

    frames = []
    for (name, ns), blob in sorted(images.items()):
        pose = poses.get((name, ns))
        if pose is None or name not in calib:
            continue
        raw = CompressedImage()
        raw.ParseFromString(blob)
        frames.append(
            CameraFrame(name, (ns - (base_ns or 0)) / 1e9, raw.data,
                        pose[0], pose[1], calib[name])
        )
    return frames


def project(frame: CameraFrame, points: np.ndarray) -> np.ndarray | None:
    """World points -> pixels, or None if anything is behind the camera."""
    local = (points - frame.translation) @ frame.rotation
    if np.any(local[:, 2] <= 0.1):
        return None
    uv = local @ frame.K.T
    return uv[:, :2] / uv[:, 2:3]


def box_corners(row: dict[str, str]) -> np.ndarray:
    c = np.array([float(row["x"]), float(row["y"]), float(row["z"])])
    length, width, height = float(row["l"]), float(row["w"]), float(row["h"])
    yaw = float(row["theta"])
    r = np.array(
        [[np.cos(yaw), -np.sin(yaw), 0.0], [np.sin(yaw), np.cos(yaw), 0.0], [0.0, 0.0, 1.0]]
    )
    local = np.array(
        [[sx * length / 2, sy * width / 2, sz * height / 2]
         for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    )
    return local @ r.T + c


def run_dino(dino_repo: Path, image: bytes, prompt: str) -> list[tuple[str, float, np.ndarray]]:
    with tempfile.TemporaryDirectory() as tmp:
        ppm = Path(tmp) / "frame.ppm"
        out = Path(tmp) / "det.csv"
        Image.open(io.BytesIO(image)).convert("RGB").save(ppm)
        proc = subprocess.run(
            [
                str(Path.home() / ".pixi/bin/pixi"), "run", "mojo", "run", "-O3",
                "-I", "src", "src/main.mojo",
                "data/weights.lft", "data/vocab.txt",
                "--image", str(ppm), "--prompt", prompt, "--csv", str(out),
            ],
            cwd=dino_repo, capture_output=True, text=True, check=False,
        )
        if proc.returncode != 0 or not out.exists():
            return []
        detections = []
        with open(out, newline="") as f:
            for row in csv.DictReader(f):
                detections.append(
                    (
                        row["label"].strip(),
                        float(row["score"]),
                        np.array([float(row[k]) for k in ("x1", "y1", "x2", "y2")]),
                    )
                )
        return detections


def iou(a: np.ndarray, b: np.ndarray) -> float:
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    area_a = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    area_b = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scene", type=Path, required=True)
    ap.add_argument("--labels", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--dino", type=Path, required=True, help="GroundingDino.mojo checkout")
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--max-calls", type=int, default=30, help="detector budget")
    ap.add_argument("--views-per-instance", type=int, default=3)
    ap.add_argument("--min-iou", type=float, default=0.25)
    ap.add_argument(
        "--min-visible",
        type=float,
        default=0.6,
        help="fraction of the projected box that must land on the sensor",
    )
    args = ap.parse_args()

    frames = read_camera_frames(args.scene)
    if not frames:
        raise SystemExit(f"{args.scene} carries no camera topics; generate with --camera-hz")
    by_time: dict[float, list[CameraFrame]] = defaultdict(list)
    for fr in frames:
        by_time[round(fr.t, 4)].append(fr)
    print(f"{len(frames)} camera frames over {len(by_time)} timestamps")

    with open(args.labels, newline="") as f:
        rows = list(csv.DictReader(f))
    per_time: dict[float, list[dict[str, str]]] = defaultdict(list)
    for r in rows:
        per_time[round(float(r["t"]), 4)].append(r)

    instances: dict[str, Instance] = {}
    for r in rows:
        inst = instances.setdefault(r["track_id"], Instance(r["track_id"]))
        inst.volume = max(inst.volume, float(r["w"]) * float(r["l"]) * float(r["h"]))

    # -- choose views: where each instance is largest *and actually in frame*
    #
    # Ranking on the raw projected area picks exactly the wrong frames: a box
    # straddling the edge projects to something like [-535, 276, 343, 548],
    # which scores enormous while only a sliver is visible. Clip to the sensor
    # first, then rank, and require most of the box to have landed on it.
    candidates: list[tuple[float, str, float, dict[str, str], np.ndarray]] = []
    for t, cams in by_time.items():
        for r in per_time.get(t, []):
            corners = box_corners(r)
            for fr in cams:
                uv = project(fr, corners)
                if uv is None:
                    continue
                box = np.array([uv[:, 0].min(), uv[:, 1].min(), uv[:, 0].max(), uv[:, 1].max()])
                width, height = fr.K[0, 2] * 2, fr.K[1, 2] * 2
                clipped = np.array([
                    max(box[0], 0.0), max(box[1], 0.0),
                    min(box[2], width), min(box[3], height),
                ])
                vis_w, vis_h = clipped[2] - clipped[0], clipped[3] - clipped[1]
                if vis_w <= 8 or vis_h <= 8:
                    continue
                full = max((box[2] - box[0]) * (box[3] - box[1]), 1e-6)
                visible_fraction = (vis_w * vis_h) / full
                if visible_fraction < args.min_visible:
                    continue
                candidates.append((vis_w * vis_h, fr.name, t, r, clipped))

    chosen: dict[tuple[str, float], list[tuple[dict[str, str], np.ndarray]]] = defaultdict(list)
    seen_per_instance: dict[str, int] = defaultdict(int)
    offered: set[str] = set()
    for area, cam, t, r, box in sorted(candidates, key=lambda c: -c[0]):
        tid = r["track_id"]
        if seen_per_instance[tid] >= args.views_per_instance:
            continue
        if len(chosen) >= args.max_calls and (cam, t) not in chosen:
            continue
        chosen[(cam, t)].append((r, box))
        seen_per_instance[tid] += 1
        offered.add(tid)

    print(f"detector budget: {len(chosen)} calls covering {len(seen_per_instance)} instances")

    frame_lookup = {(fr.name, round(fr.t, 4)): fr for fr in frames}
    for i, ((cam, t), projected) in enumerate(sorted(chosen.items()), 1):
        fr = frame_lookup.get((cam, round(t, 4)))
        if fr is None:
            continue
        detections = run_dino(args.dino, fr.image, args.prompt)
        matched = 0
        for label, score, dbox in detections:
            best, best_iou = None, args.min_iou
            for r, pbox in projected:
                overlap = iou(dbox, pbox)
                if overlap > best_iou:
                    best, best_iou = r, overlap
            if best is not None:
                instances[best["track_id"]].votes.append(Vote(label, score, "detector"))
                matched += 1
        print(f"  [{i}/{len(chosen)}] {cam} t={t:5.1f}  "
              f"{len(detections)} detections, {matched} associated")

    # -- resolve ----------------------------------------------------------
    #
    # Three outcomes, not two. The size prior cannot abstain -- offered a
    # cluster of stockpile it will confidently call it a person -- so it is not
    # allowed the last word on an instance the detector was *shown and did not
    # corroborate*. Measured on this scene: every one of the detector's names
    # was correct, while the size prior naming everything scored 4 right, 1
    # wrong and 7 phantoms. Detector silence is evidence, so it is recorded
    # rather than papered over.
    counts_by_source: dict[str, int] = defaultdict(int)
    resolved: dict[str, tuple[str, float, str]] = {}
    for tid, inst in instances.items():
        if inst.votes:
            by_label: dict[str, list[float]] = defaultdict(list)
            for v in inst.votes:
                by_label[v.label].append(v.score)
            label = max(by_label, key=lambda k: sum(by_label[k]))
            resolved[tid] = (label, float(np.mean(by_label[label])), "detector")
        elif tid in offered:
            # Shown to the detector, which saw nothing there.
            resolved[tid] = ("unknown", UNCORROBORATED_CONF, "uncorroborated")
        else:
            label = "machine" if inst.volume >= MACHINE_VOLUME_M3 else "person"
            resolved[tid] = (label, SIZE_PRIOR_CONF, "size_prior")
        counts_by_source[resolved[tid][2]] += 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=TRACKER_HEADER + ["cls_conf", "cls_source"])
        w.writeheader()
        for r in rows:
            label, conf, source = resolved[r["track_id"]]
            out = {k: r.get(k, "") for k in TRACKER_HEADER}
            out["cls"] = label
            out["cls_conf"] = f"{conf:.4f}"
            out["cls_source"] = source
            w.writerow(out)

    print(
        f"\nnamed_by detector={counts_by_source['detector']} "
        f"uncorroborated={counts_by_source['uncorroborated']} "
        f"size_prior={counts_by_source['size_prior']}"
    )
    counts: dict[tuple[str, str], int] = defaultdict(int)
    for label, _, source in resolved.values():
        counts[(label, source)] += 1
    for (label, source), n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {label:14s} {source:12s} {n:3d} instances")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
