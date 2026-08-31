"""Build dataset Parquet from the published sitegen MCAPs.

Writes plain Parquet; `datasets_publish.mjs` turns it into Iceberg tables whose
metadata records the public URLs they will be served from.

Migration steps 1 and 3 of docs/DATASETS.md, over the artefacts that are
already public rather than over a fresh pipeline run:

  site_seed1_60s.mcap  /ground_truth/actors  -> ground_truth_tracks
                       /ground_truth/points  -> num_lidar_points per instance
  labels_rounds.mcap   /pred/*               -> labels (one dataset per round)

Entity ids in /ground_truth/actors are `{instance_id}/{class}[.{part}]`, which
is where class and part come from. The labels MCAP is a visualisation artefact
and carries no class at all, so labels.class is null -- see the note in main().
"""

import math
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import pyarrow as pa
from mcap.reader import make_reader
from mcap_protobuf.decoder import DecoderFactory

NS = 1_000_000_000


def quat_to_yaw(q):
    """Yaw about +Z from a quaternion, in radians."""
    siny = 2.0 * (q.w * q.z + q.x * q.y)
    cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(siny, cosy)


def split_entity_id(eid):
    """`truck_a/haul_truck.bed` -> ('truck_a', 'haul_truck', 'bed')."""
    instance, _, rest = eid.partition("/")
    cls, dot, part = rest.partition(".")
    return instance, cls, (part if dot else None)


def read_actors(path, scene_name):
    """/ground_truth/actors -> rows keyed by (instance, class, part, t)."""
    rows = []
    with open(path, "rb") as f:
        reader = make_reader(f, decoder_factories=[DecoderFactory()])
        t0 = None
        for _, _, msg, proto in reader.iter_decoded_messages(
            topics=["/ground_truth/actors"]
        ):
            if t0 is None:
                t0 = msg.log_time
            t = (msg.log_time - t0) / NS
            for e in proto.entities:
                if not e.cubes:
                    continue
                c = e.cubes[0]
                instance, cls, part = split_entity_id(e.id)
                rows.append(
                    {
                        "dataset_name": scene_name,
                        "instance_id": instance,
                        "class": cls,
                        "part": part,
                        "t": t,
                        "x": c.pose.position.x,
                        "y": c.pose.position.y,
                        "z": c.pose.position.z,
                        # size.x is along heading -> l; size.y -> w
                        "l": c.size.x,
                        "w": c.size.y,
                        "h": c.size.z,
                        "theta": quat_to_yaw(c.pose.orientation),
                    }
                )
    return rows


def read_tf(path):
    """/tf -> {t: (3x3 rotation, translation)} for map <- lidar."""
    out = {}
    with open(path, "rb") as f:
        reader = make_reader(f, decoder_factories=[DecoderFactory()])
        t0 = None
        for _, _, msg, proto in reader.iter_decoded_messages(topics=["/tf"]):
            if t0 is None:
                t0 = msg.log_time
            t = round((msg.log_time - t0) / NS, 3)
            q = proto.rotation
            x, y, z, w = q.x, q.y, q.z, q.w
            R = np.array(
                [
                    [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                    [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                    [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
                ]
            )
            tr = np.array(
                [proto.translation.x, proto.translation.y, proto.translation.z]
            )
            out[t] = (R, tr)
    return out


def read_instance_points(path, tf):
    """/ground_truth/points -> {t: {numeric_instance: (count, centroid, pts)}}.

    The cloud is published in the `lidar` frame while the ground-truth boxes
    are in `map`, so every sweep is transformed with that frame's /tf before
    anything is compared against a box.
    """
    per_t = {}
    with open(path, "rb") as f:
        reader = make_reader(f, decoder_factories=[DecoderFactory()])
        t0 = None
        for _, _, msg, proto in reader.iter_decoded_messages(
            topics=["/ground_truth/points"]
        ):
            if t0 is None:
                t0 = msg.log_time
            t = (msg.log_time - t0) / NS
            n = len(proto.data) // proto.point_stride
            raw = np.frombuffer(proto.data, dtype=np.uint8).reshape(n, proto.point_stride)
            xyz = raw[:, 0:12].copy().view(np.float32).reshape(n, 3).astype(np.float64)
            inst = raw[:, 12:16].copy().view(np.uint32).reshape(n)
            key = round(t, 3)
            if key in tf:
                R, tr = tf[key]
                xyz = xyz @ R.T + tr
            else:
                continue  # no pose for this sweep: cannot place it in map
            out = {}
            for i in np.unique(inst):
                if i == 0:  # background / terrain
                    continue
                sel = xyz[inst == i].astype(np.float64)
                out[int(i)] = (int(sel.shape[0]), sel.mean(axis=0), sel)
            per_t[round(t, 3)] = out
    return per_t


def points_in_box(pts, box):
    """Boolean mask of pts (N,3) inside an oriented box, with a small margin."""
    d = pts - np.array([box["x"], box["y"], box["z"]])
    c, s = math.cos(-box["theta"]), math.sin(-box["theta"])
    local = np.empty_like(d)
    local[:, 0] = c * d[:, 0] - s * d[:, 1]
    local[:, 1] = s * d[:, 0] + c * d[:, 1]
    local[:, 2] = d[:, 2]
    m = 0.15  # returns land on the surface; allow a little slack
    return (
        (np.abs(local[:, 0]) <= box["l"] / 2 + m)
        & (np.abs(local[:, 1]) <= box["w"] / 2 + m)
        & (np.abs(local[:, 2]) <= box["h"] / 2 + m)
    )


def assign_points(actor_rows, per_t):
    """Per-frame containment: {t: {(instance, class, part): n_points}}.

    Two traps here, both of which produce plausible-looking wrong numbers.

    Centroid matching does not work: LiDAR only sees the face pointing at the
    sensor, so an 8 m truck's return centroid sits metres off its box centre
    and lands inside a neighbour. Containment against the oriented box is
    exact, so that is what decides.

    And the assignment must be made *per frame*, never once globally: sitegen
    reuses numeric instance ids between actors that do not overlap in time.
    Ids 6 and 7 are truck_a until t=39.9 and truck_b from t=40.0. A global
    majority vote hands both to truck_a -- whereupon every truck_b row reads
    zero returns and nothing about the output looks wrong.
    """
    by_t = defaultdict(list)
    for r in actor_rows:
        by_t[round(r["t"], 3)].append(r)

    counts = defaultdict(dict)
    trace = defaultdict(set)
    for t, insts in sorted(per_t.items()):
        actors = by_t.get(t)
        if not actors:
            continue
        for num, (_, _, pts) in insts.items():
            best, best_n = None, 0
            for a in actors:
                n = int(points_in_box(pts, a).sum())
                if n > best_n:
                    best, best_n = (a["instance_id"], a["class"], a["part"]), n
            if best is not None and best_n >= max(3, 0.5 * pts.shape[0]):
                counts[t][best] = counts[t].get(best, 0) + best_n
                trace[num].add(f"{best[0]}/{best[1]}" + (f".{best[2]}" if best[2] else ""))
    return counts, trace


def add_point_counts(actor_rows, counts, sweep_ts):
    """Attach num_lidar_points, distinguishing "unseen" from "unknown".

    A labelled sweep exists only every 0.5 s while actors are published at
    10 Hz. Where a sweep exists the count is authoritative and an object with
    no returns gets 0 -- that is the whole point of the column, since "recall
    on objects with >= 5 returns" needs to know an object was there and
    invisible. Where no sweep exists the value is null, meaning unknown.
    """
    seen = known = 0
    for r in actor_rows:
        t = round(r["t"], 3)
        if t in sweep_ts:
            key = (r["instance_id"], r["class"], r["part"])
            n = counts.get(t, {}).get(key, 0)
            r["num_lidar_points"] = n
            known += 1
            if n > 0:
                seen += 1
        else:
            r["num_lidar_points"] = None
    return seen, known


def add_velocities(rows):
    """Finite-difference vx, vy per (instance, class, part) track."""
    tracks = defaultdict(list)
    for r in rows:
        tracks[(r["instance_id"], r["class"], r["part"])].append(r)
    for track in tracks.values():
        track.sort(key=lambda r: r["t"])
        for i, r in enumerate(track):
            if i == 0:
                r["vx"] = r["vy"] = 0.0
                continue
            p = track[i - 1]
            dt = r["t"] - p["t"]
            r["vx"] = (r["x"] - p["x"]) / dt if dt else 0.0
            r["vy"] = (r["y"] - p["y"]) / dt if dt else 0.0


def read_labels(path):
    """/pred/* -> label rows, one dataset_name per round topic."""
    rows = []
    with open(path, "rb") as f:
        reader = make_reader(f, decoder_factories=[DecoderFactory()])
        t0 = None
        for _, ch, msg, proto in reader.iter_decoded_messages():
            if not ch.topic.startswith("/pred/"):
                continue
            if t0 is None:
                t0 = msg.log_time
            t = (msg.log_time - t0) / NS
            round_name = ch.topic.split("/")[-1]
            for e in proto.entities:
                if not e.cubes:
                    continue
                c = e.cubes[0]
                _, _, track_id = e.id.partition("/")
                rows.append(
                    {
                        "dataset_name": f"site_seed1.{round_name}",
                        "instance_id": track_id,
                        "class": None,
                        "t": t,
                        "x": c.pose.position.x,
                        "y": c.pose.position.y,
                        "z": c.pose.position.z,
                        "l": c.size.x,
                        "w": c.size.y,
                        "h": c.size.z,
                        "theta": quat_to_yaw(c.pose.orientation),
                        "cls_conf": None,
                        "cls_source": None,
                        "producer": round_name,
                    }
                )
    return rows


# The canonical shapes live in the registry module -- imported rather than
# restated so the published tables cannot drift from what `register()` writes.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from workflows.datasets import LABELS_SCHEMA, TRACKS_SCHEMA  # noqa: E402


def to_table(rows, schema):
    cols = {f.name: [r.get(f.name) for r in rows] for f in schema}
    return pa.table(cols, schema=schema)


def main():
    scene, labels_mcap, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    # `site_seed1_60s.mcap` -> `site_seed1`, the dataset_name these rows carry.
    scene_name = sys.argv[4] if len(sys.argv) > 4 else Path(scene).stem.rsplit("_", 1)[0]

    print("reading /ground_truth/actors …")
    actors = read_actors(scene, scene_name)
    print(f"  {len(actors)} rows")

    print("reading /tf …")
    tf = read_tf(scene)
    print(f"  {len(tf)} poses")

    print("reading /ground_truth/points …")
    per_t = read_instance_points(scene, tf)
    counts, trace = assign_points(actors, per_t)
    print(f"  {len(per_t)} labelled sweeps; numeric id -> entity over time:")
    for num, names in sorted(trace.items()):
        flag = "   <- id reused" if len(names) > 1 else ""
        print(f"    {num:3d} -> {', '.join(sorted(names))}{flag}")
    seen, known = add_point_counts(actors, counts, set(per_t))
    print(
        f"  num_lidar_points known on {known}/{len(actors)} rows "
        f"(sweeps are 2 Hz, actors 10 Hz); {seen} of those had >= 1 return"
    )

    add_velocities(actors)

    print("reading /pred/* …")
    labels = read_labels(labels_mcap)
    print(f"  {len(labels)} rows")

    out.mkdir(parents=True, exist_ok=True)
    import pyarrow.parquet as pq

    for name, rows, schema in (
        ("ground_truth_tracks", actors, TRACKS_SCHEMA),
        ("labels", labels, LABELS_SCHEMA),
    ):
        tbl = to_table(rows, schema)
        path = out / f"{name}.parquet"
        pq.write_table(tbl, path, compression="snappy")
        print(f"{name}: {tbl.num_rows} rows -> {path}")


if __name__ == "__main__":
    main()
