"""The two pipeline modes, callable from the CLI and from the Restate executor.

`main.mojo` used to hold this inline. It moved here so `executor.mojo` can run
the same code in-process instead of re-invoking `mojo run` per call — the
stage is identical either way, which is the point: the executor is a different
way to reach the pipeline, not a different pipeline.

The stdout lines `raw detections: N` and `tracks: n kept: m` are a contract:
`workflows/steps.py` scrapes them for metrics. They stay, and the same numbers
are also returned structurally for callers that would rather not parse.
"""

from refinery.io import (
    Sweep,
    read_csv_rows,
    read_joints,
    read_poses,
    read_sweep,
)
from refinery.pipeline import (
    Detection,
    associate,
    detect,
    ego_mask,
    read_detections,
    smooth,
    MIN_TRACK_FRAMES,
)
from refinery.terrain import TerrainModel, build_terrain


@fieldwise_init
struct StageMetrics(Copyable, ImplicitlyCopyable, Movable):
    """What a stage did, for the ledger and the control site."""

    var frames: Int
    var total_points: Int
    var ego_points: Int
    var raw_detections: Int
    var tracks: Int
    var kept: Int

    @staticmethod
    def empty() -> Self:
        return Self(0, 0, 0, 0, 0, 0)

    def as_json(self) -> String:
        return String(
            '{"frames": ',
            self.frames,
            ', "total_points": ',
            self.total_points,
            ', "ego_points": ',
            self.ego_points,
            ', "raw_detections": ',
            self.raw_detections,
            ', "tracks": ',
            self.tracks,
            ', "kept": ',
            self.kept,
            "}",
        )


def run_tracking(
    var per_frame: List[List[Detection]],
    var frame_times: List[Float64],
    out_path: String,
    accel_var: Float64,
    measurement_var: Float64,
    reverse: Bool,
    mut metrics: StageMetrics,
) raises -> None:
    """Associate, smooth offline, filter short tracks, write the tracker CSV."""
    # An empty input is reachable, not hypothetical: an undertrained student
    # detects nothing, which is the loop's own starting condition. Indexing
    # `frame_times[-1]` below crashes the process rather than raising, so this
    # writes the header and reports zero -- a valid artefact the next stage can
    # read, instead of a segfault.
    if len(frame_times) == 0:
        var empty = open(out_path, "w")
        empty.write("track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n")
        empty.close()
        metrics.tracks = 0
        metrics.kept = 0
        print("tracks: 0 kept: 0 ->", out_path)
        return

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
    metrics.tracks = len(tracks)
    metrics.kept = kept
    print("tracks:", len(tracks), "kept:", kept, "->", out_path)


def run_geometry(
    work: String,
    out_path: String,
    accel_var: Float64 = 1.5,
    measurement_var: Float64 = 0.25,
    use_terrain: Bool = True,
    reverse: Bool = False,
) raises -> StageMetrics:
    """Geometry mode: sweeps and proprioception in, tracker CSV out."""
    var metrics = StageMetrics.empty()
    var per_frame = List[List[Detection]]()
    var frame_times = List[Float64]()

    var poses = read_poses(work + "/tf.csv")
    var joints = read_joints(work + "/joints.csv")
    var index = read_csv_rows(work + "/sweeps/index.csv")
    metrics.frames = len(index)
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
    metrics.total_points = total_points
    metrics.ego_points = ego_points
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

    metrics.raw_detections = total_dets
    print("raw detections:", total_dets)

    run_tracking(
        per_frame^,
        frame_times^,
        out_path,
        accel_var,
        measurement_var,
        reverse,
        metrics,
    )
    return metrics^


def run_track_detections(
    detections_csv: String,
    out_path: String,
    accel_var: Float64 = 1.5,
    measurement_var: Float64 = 0.25,
    reverse: Bool = False,
) raises -> StageMetrics:
    """Detections mode: an existing detections CSV in, tracker CSV out."""
    var metrics = StageMetrics.empty()
    var per_frame = List[List[Detection]]()
    var frame_times = List[Float64]()

    print("detections from", detections_csv, "-- skipping sweeps and terrain")
    read_detections(detections_csv, per_frame, frame_times)
    var n = 0
    for f in range(len(per_frame)):
        n += len(per_frame[f])
    metrics.frames = len(per_frame)
    metrics.raw_detections = n
    print("frames:", len(per_frame), "detections:", n)

    run_tracking(
        per_frame^,
        frame_times^,
        out_path,
        accel_var,
        measurement_var,
        reverse,
        metrics,
    )
    return metrics^
