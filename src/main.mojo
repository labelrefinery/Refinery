"""Refinery CLI: run Pipeline A over an exported sitegen scene.

    refinery <work_dir> <out.csv>

`work_dir` is what `sitegen tf|joints|sweeps` wrote: `tf.csv`, `joints.csv`
and `sweeps/`. The output is the tracker CSV schema OfflinePoly reads, so the
next stage is a pipe rather than an adapter.

The pipeline itself lives in `refinery.stages`, so the Restate executor can run
the same code in-process rather than re-invoking this binary per call.
"""

from std.sys import argv

from refinery.stages import run_geometry, run_track_detections


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
    var detections_csv = String("")
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
        elif args[i] == "--detections":
            detections_csv = String(args[i + 1])
        i += 2

    if detections_csv != "":
        _ = run_track_detections(
            detections_csv, out_path, accel_var, measurement_var, reverse
        )
        return

    _ = run_geometry(
        work, out_path, accel_var, measurement_var, use_terrain, reverse
    )
