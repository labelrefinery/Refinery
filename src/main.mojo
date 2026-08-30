"""Refinery CLI: run Pipeline A over an exported sitegen scene.

    refinery <work_dir> <out.csv>

`work_dir` is what `sitegen tf|joints|sweeps` wrote: `tf.csv`, `joints.csv`
and `sweeps/`. The output is the tracker CSV schema OfflinePoly reads, so the
next stage is a pipe rather than an adapter.
"""

from std.sys import argv

from refinery.io import read_csv_rows, read_joints, read_poses, read_sweep
from refinery.pipeline import Detection, associate, detect, ego_mask, smooth
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
    var i = 3
    while i + 1 < len(args):
        if args[i] == "--accel-var":
            accel_var = Float64(String(args[i + 1]))
        elif args[i] == "--meas-var":
            measurement_var = Float64(String(args[i + 1]))
        i += 2

    var poses = read_poses(work + "/tf.csv")
    var joints = read_joints(work + "/joints.csv")
    var index = read_csv_rows(work + "/sweeps/index.csv")
    print("frames:", len(index))

    var per_frame = List[List[Detection]]()
    var frame_times = List[Float64]()
    var total_points = 0
    var total_dets = 0
    for f in range(len(index)):
        ref row = index[f]
        var t = Float64(row[1])
        frame_times.append(t)
        var sweep = read_sweep(work + "/sweeps", String(row[3]), t, poses[f])
        total_points += len(sweep)
        var mask = ego_mask(poses[f], joints[f])
        var dets = detect(sweep, mask)
        total_dets += len(dets)
        per_frame.append(dets^)
        if f % 100 == 0:
            print(
                "  frame",
                f,
                "points",
                len(sweep),
                "detections",
                len(per_frame[f]),
            )

    print("points:", total_points, "raw detections:", total_dets)

    var tracks = associate(per_frame, frame_times)
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
            handle.write(
                String(track.id)
                + ",object,"
                + String(track.times[k])
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
