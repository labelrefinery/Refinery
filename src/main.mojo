"""Refinery CLI: run Pipeline A over an exported sitegen scene.

    refinery <work_dir> <out.csv>

`work_dir` is what `sitegen tf|joints|sweeps` wrote: `tf.csv`, `joints.csv`
and `sweeps/`. The output is the tracker CSV schema OfflinePoly reads, so the
next stage is a pipe rather than an adapter.
"""

from std.sys import argv

from refinery.io import (
    Sweep,
    read_csv_rows,
    read_joints,
    read_poses,
    read_sweep,
)
from refinery.pipeline import Detection, associate, detect, ego_mask, smooth
from refinery.terrain import TerrainModel, build_terrain
from refinery.pipeline import MIN_TRACK_FRAMES


def main() raises:
    var args = argv()
    if len(args) < 3:
        print(
            "usage: refinery <work_dir> <out.csv> [--accel-var V]"
            " [--meas-var V]"
        )
        return

    var work = String(args[1])
    var out_path = String(args[2])
    var accel_var = 1.5
    var measurement_var = 0.25
    var use_terrain = True
    var reverse = False
    var i = 3
    while i + 1 < len(args):
        if args[i] == "--accel-var":
            accel_var = Float64(String(args[i + 1]))
        elif args[i] == "--meas-var":
            measurement_var = Float64(String(args[i + 1]))
        elif args[i] == "--terrain":
            use_terrain = args[i + 1] == "on"
        elif args[i] == "--reverse":
            reverse = args[i + 1] == "on"
        i += 2

    var poses = read_poses(work + "/tf.csv")
    var joints = read_joints(work + "/joints.csv")
    var index = read_csv_rows(work + "/sweeps/index.csv")
    print(
        "frames:",
        len(index),
        "| terrain stage:",
        "on" if use_terrain else "off",
    )

    # Pass one: lift every sweep into the map frame and hold it. The whole
    # sequence has to be in hand before terrain can be decided, which is the
    # offboard advantage restated as a data dependency.
    var xs = List[List[Float64]]()
    var ys = List[List[Float64]]()
    var zs = List[List[Float64]]()
    var frame_times = List[Float64]()
    var total_points = 0
    var ego_points = 0
    for f in range(len(index)):
        ref row = index[f]
        var t = Float64(row[1])
        frame_times.append(t)
        var sweep = read_sweep(work + "/sweeps", String(row[3]), t, poses[f])
        total_points += len(sweep)
        # Self-mask here, before anything downstream sees the cloud. The
        # terrain calibration needs it as much as the clusterer does: the
        # driven cells are exactly where the machine is standing, so leaving
        # its own returns in makes "known ground" contain a 3 m machine.
        var mask = ego_mask(poses[f], joints[f])
        var fx = List[Float64]()
        var fy = List[Float64]()
        var fz = List[Float64]()
        for i in range(len(sweep)):
            if mask.masks(sweep.x[i], sweep.y[i], sweep.z[i]):
                continue
            fx.append(sweep.x[i])
            fy.append(sweep.y[i])
            fz.append(sweep.z[i])
        ego_points += len(sweep) - len(fx)
        xs.append(fx^)
        ys.append(fy^)
        zs.append(fz^)
    print(
        "points:",
        total_points,
        "| ego self-returns removed:",
        ego_points,
        "(",
        100.0 * Float64(ego_points) / Float64(total_points),
        "% )",
    )

    var terrain = build_terrain(xs, ys, zs, poses)
    print(
        "terrain: observed cells",
        terrain.observed_cells,
        "| seeds",
        terrain.seed_cells,
        "-> ground surface",
        terrain.terrain_cells,
        "cells | blocked as too thick",
        terrain.blocked_by_step,
    )

    # Pass two: detect, now that terrain is known.
    var per_frame = List[List[Detection]]()
    var total_dets = 0
    for f in range(len(index)):
        var sweep = Sweep(frame_times[f])
        sweep.x = xs[f].copy()
        sweep.y = ys[f].copy()
        sweep.z = zs[f].copy()
        var dets = detect(sweep, terrain, use_terrain)
        total_dets += len(dets)
        per_frame.append(dets^)
        if f % 200 == 0:
            print("  frame", f, "detections", len(per_frame[f]))

    print("raw detections:", total_dets)

    # A second, genuinely different tracklet set: associate backwards through
    # time. Births and deaths swap ends, gating resolves differently around
    # occlusions, and fragments break in different places -- which is exactly
    # the multi-source input Offline-Poly's tracking-by-tracking stage wants.
    # Times are mirrored so they stay ascending for the smoother, then mirrored
    # back on the way out.
    var ordered = List[List[Detection]]()
    var ordered_times = List[Float64]()
    var span = frame_times[len(frame_times) - 1]
    if reverse:
        for f in range(len(per_frame) - 1, -1, -1):
            var flipped = List[Detection]()
            for d in range(len(per_frame[f])):
                var det = per_frame[f][d]
                det.t = span - det.t
                flipped.append(det)
            ordered.append(flipped^)
            ordered_times.append(span - frame_times[f])
    else:
        for f in range(len(per_frame)):
            ordered.append(per_frame[f].copy())
            ordered_times.append(frame_times[f])

    var tracks = associate(ordered, ordered_times)
    var kept = 0
    var handle = open(out_path, "w")
    handle.write("track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n")

    for ti in range(len(tracks)):
        if tracks[ti].observed_frames() < MIN_TRACK_FRAMES:
            continue
        smooth(tracks[ti], accel_var, measurement_var)
        kept += 1
        ref track = tracks[ti]
        var n = len(track.times)
        for k in range(n):
            var lo = k - 1 if k > 0 else 0
            var hi = k + 1 if k + 1 < n else n - 1
            var dt = track.times[hi] - track.times[lo]
            var vx = 0.0
            var vy = 0.0
            if dt > 0.0:
                vx = (track.obs_x[hi] - track.obs_x[lo]) / dt
                vy = (track.obs_y[hi] - track.obs_y[lo]) / dt
            var stamp = span - track.times[k] if reverse else track.times[k]
            handle.write(
                String(track.id)
                + ",0,"
                + String(stamp)
                + ","
                + String(track.obs_x[k])
                + ","
                + String(track.obs_y[k])
                + ","
                + String(track.obs_z[k])
                + ","
                + String(track.w[k])
                + ","
                + String(track.l[k])
                + ","
                + String(track.h[k])
                + ","
                + String(vx)
                + ","
                + String(vy)
                + ","
                + String(track.yaw[k])
                + ",1.0\n"
            )
    handle.close()
    print("tracks:", len(tracks), "kept:", kept, "->", out_path)
