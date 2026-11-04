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
    Joints,
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
from std.time import perf_counter_ns

from stone import CellPatch

from refinery.geometry import detect_sweep, lift, merge_terrain, sweep_jobs
from refinery.terrain import TerrainModel


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


def report_lift(metrics: StageMetrics, terrain: TerrainModel):
    """The log lines after lifting every sweep and growing the terrain."""
    print(
        "points:",
        metrics.total_points,
        "| ego self-returns removed:",
        metrics.ego_points,
        "(",
        100.0 * Float64(metrics.ego_points) / Float64(max(metrics.total_points, 1)),
        "% )",
    )
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


def report_detections(
    mut metrics: StageMetrics, per_frame: List[List[Detection]]
):
    """Counts the detections into `metrics` and logs them."""
    var total = 0
    for f in range(len(per_frame)):
        total += len(per_frame[f])
        if f % 200 == 0:
            print("  frame", f, "detections", len(per_frame[f]))
    metrics.raw_detections = total
    print("raw detections:", total)


def report_seconds(t0: Int, t1: Int, t2: Int, t3: Int, t4: Int):
    """Where the geometry stage's time went, phase by phase."""
    print(
        "seconds: lift",
        Float64(t1 - t0) / 1e9,
        "| terrain",
        Float64(t2 - t1) / 1e9,
        "| detect",
        Float64(t3 - t2) / 1e9,
        "| track",
        Float64(t4 - t3) / 1e9,
    )


def run_geometry(
    work: String,
    out_path: String,
    accel_var: Float64 = 1.5,
    measurement_var: Float64 = 0.25,
    use_terrain: Bool = True,
    reverse: Bool = False,
    proprioception: Bool = True,
    fit_terrain_to_drive: Bool = False,
) raises -> StageMetrics:
    """Geometry mode: sweeps and proprioception in, tracker CSV out.

    Without `proprioception` there is no `joints.csv` and no forward-kinematics
    self-mask: the work directory's sweeps arrive with the ego's own returns
    already removed, as a car's are (`refinery.av2_fetch`).
    `fit_terrain_to_drive` sizes the terrain grid to the path rather than the
    site (`refinery.terrain.terrain_spec`).
    """
    var metrics = StageMetrics.empty()
    var geo = sweep_jobs(
        work, proprioception, fit_terrain_to_drive, use_terrain
    )
    metrics.frames = len(geo.jobs)
    print(
        "frames:",
        len(geo.jobs),
        "| terrain stage:",
        "on" if use_terrain else "off",
    )

    # Phase one: every sweep's patch of the terrain grid. The whole sequence
    # has to be in hand before terrain can be decided, which is the offboard
    # advantage restated as a data dependency.
    var t0 = perf_counter_ns()
    var patches = List[CellPatch](capacity=len(geo.jobs))
    for f in range(len(geo.jobs)):
        var lifted = lift(geo.jobs[f])
        metrics.total_points += lifted.total_points
        metrics.ego_points += lifted.ego_points
        patches.append(lifted^.into_patch())
    var t1 = perf_counter_ns()
    var terrain = merge_terrain(geo.spec, patches, geo.poses)
    var t2 = perf_counter_ns()
    report_lift(metrics, terrain)

    # Phase two: detect, now that terrain is known.
    var per_frame = List[List[Detection]](capacity=len(geo.jobs))
    for f in range(len(geo.jobs)):
        per_frame.append(detect_sweep(geo.jobs[f], terrain))
    var t3 = perf_counter_ns()
    report_detections(metrics, per_frame)

    var frame_times = geo.times.copy()
    run_tracking(
        per_frame^,
        frame_times^,
        out_path,
        accel_var,
        measurement_var,
        reverse,
        metrics,
    )
    report_seconds(t0, t1, t2, t3, perf_counter_ns())
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
