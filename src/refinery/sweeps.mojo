"""Pipeline A's geometry as dista tasks: a task per sweep where the time is.

Measured on an Argoverse 2 log (157 sweeps, 14.3M points, one core): lifting
every sweep into the terrain grid takes 0.25 s, growing the terrain 0.01 s,
detecting 36.6 s and tracking 0.7 s. So detection is a task per sweep, and the
terrain is one task that lifts every sweep itself: as a task per sweep, lifting
would move a patch of about 1.5 MB per sweep to save a quarter of a second.

    terrain = GrowTerrain(work)                    one task
    per sweep: DetectSweep(job, [terrain])         157 tasks, any worker
    associate, smooth, write tracks.csv            the driver

Both tasks call `refinery.geometry`, as `refinery.stages.run_geometry` does
one sweep after another, and the driver merges detections in frame order, so
`run_geometry_tasks` writes the bytes `run_geometry` writes.

Each task reads its sweeps from the work directory, so the head and workers
need to see it: one machine, or a shared path. Only this module imports dista,
so only the `orca` environment builds it.
"""

from std.time import perf_counter_ns

from dista import ObjectRef, Seq, Task, TaskWith
from dista.codec import Codec, get_scalar, put_scalar
from orca import Tasks
from stone import CellPatch, GridSpec

from refinery.geometry import (
    SweepJob,
    detect_sweep,
    lift,
    merge_terrain,
    sweep_jobs,
)
from refinery.pipeline import Detection
from refinery.stages import (
    StageMetrics,
    report_detections,
    report_lift,
    report_seconds,
    run_tracking,
)
from refinery.terrain import TerrainModel


# -- what the tasks take and return ------------------------------------------


@fieldwise_init
struct TerrainJob(Copyable, Movable):
    """A work directory's terrain: which sweeps, and on which grid."""

    var work: String
    var proprioception: Bool
    var fit_terrain_to_drive: Bool


def _put_int(mut out: List[UInt8], v: Int):
    put_scalar[DType.int64](out, Int64(v))


def _get_int(buf: Span[UInt8, _], mut pos: Int) raises -> Int:
    return Int(get_scalar[DType.int64](buf, pos))


def _put_f64(mut out: List[UInt8], v: Float64):
    put_scalar[DType.float64](out, v)


def _get_f64(buf: Span[UInt8, _], mut pos: Int) raises -> Float64:
    return get_scalar[DType.float64](buf, pos)


struct Terrain(Codec, Copyable, Movable):
    """The grown terrain, and the points lifting saw, as one task result."""

    var model: TerrainModel
    var total_points: Int
    var ego_points: Int

    def __init__(
        out self, var model: TerrainModel, total_points: Int, ego_points: Int
    ):
        self.model = model^
        self.total_points = total_points
        self.ego_points = ego_points

    def encode(self, mut out: List[UInt8]):
        ref m = self.model
        _put_f64(out, m.spec.origin_x)
        _put_f64(out, m.spec.origin_y)
        _put_f64(out, m.spec.cell_size)
        _put_int(out, m.spec.nx)
        _put_int(out, m.spec.ny)
        _put_int(out, m.seed_cells)
        _put_int(out, m.terrain_cells)
        _put_int(out, m.observed_cells)
        _put_int(out, m.blocked_by_step)
        _put_int(out, self.total_points)
        _put_int(out, self.ego_points)
        # Only reached cells' floors matter (`is_terrain`), but the grid is
        # small next to a sweep: send it dense, one byte and one double a cell.
        _put_int(out, len(m.reached))
        for i in range(len(m.reached)):
            out.append(UInt8(1) if m.reached[i] else UInt8(0))
        for i in range(len(m.floor_z)):
            _put_f64(out, m.floor_z[i])

    @staticmethod
    def decode(buf: Span[UInt8, _], mut pos: Int) raises -> Self:
        var ox = _get_f64(buf, pos)
        var oy = _get_f64(buf, pos)
        var cell = _get_f64(buf, pos)
        var nx = _get_int(buf, pos)
        var ny = _get_int(buf, pos)
        var seeds = _get_int(buf, pos)
        var terrain_cells = _get_int(buf, pos)
        var observed = _get_int(buf, pos)
        var blocked = _get_int(buf, pos)
        var total = _get_int(buf, pos)
        var ego = _get_int(buf, pos)
        var n = _get_int(buf, pos)
        if n != nx * ny or n < 0 or pos + n * 9 > len(buf):
            raise Error("terrain: ", n, " cells don't fit the message")
        var reached = List[Bool](capacity=n)
        for i in range(n):
            reached.append(buf[pos + i] != 0)
        pos += n
        var floor_z = List[Float64](capacity=n)
        for _ in range(n):
            floor_z.append(_get_f64(buf, pos))
        return Self(
            TerrainModel(
                GridSpec(ox, oy, cell, nx, ny),
                reached^,
                floor_z^,
                seeds,
                terrain_cells,
                observed,
                blocked,
            ),
            total,
            ego,
        )


struct Detections(Codec, Copyable, Movable):
    """One sweep's detections, as one task result."""

    var items: List[Detection]

    def __init__(out self, var items: List[Detection]):
        self.items = items^

    def encode(self, mut out: List[UInt8]):
        _put_int(out, len(self.items))
        for d in self.items:
            _put_f64(out, d.t)
            _put_f64(out, d.x)
            _put_f64(out, d.y)
            _put_f64(out, d.z)
            _put_f64(out, d.w)
            _put_f64(out, d.l)
            _put_f64(out, d.h)
            _put_f64(out, d.yaw)
            _put_int(out, d.points)

    @staticmethod
    def decode(buf: Span[UInt8, _], mut pos: Int) raises -> Self:
        var n = _get_int(buf, pos)
        if n < 0 or n * 72 > len(buf) - pos:
            raise Error("detections: ", n, " don't fit the message")
        var items = List[Detection](capacity=n)
        for _ in range(n):
            var t = _get_f64(buf, pos)
            var x = _get_f64(buf, pos)
            var y = _get_f64(buf, pos)
            var z = _get_f64(buf, pos)
            var w = _get_f64(buf, pos)
            var l = _get_f64(buf, pos)
            var h = _get_f64(buf, pos)
            var yaw = _get_f64(buf, pos)
            items.append(Detection(t, x, y, z, w, l, h, yaw, _get_int(buf, pos)))
        return Self(items^)

    def into_items(deinit self) -> List[Detection]:
        return self.items^


# -- the tasks ---------------------------------------------------------------


def grow_terrain_task(job: TerrainJob) raises -> Terrain:
    """Lifts every sweep of the work directory and grows the terrain."""
    var geo = sweep_jobs(
        job.work, job.proprioception, job.fit_terrain_to_drive, True
    )
    var patches = List[CellPatch](capacity=len(geo.jobs))
    var total = 0
    var ego = 0
    for f in range(len(geo.jobs)):
        var lifted = lift(geo.jobs[f])
        total += lifted.total_points
        ego += lifted.ego_points
        patches.append(lifted^.into_patch())
    return Terrain(merge_terrain(geo.spec, patches, geo.poses), total, ego)


def detect_sweep_task(job: SweepJob, terrain: Seq[Terrain]) raises -> Detections:
    """Detects in one sweep against the terrain (the one result in `terrain`)."""
    return Detections(detect_sweep(job, terrain[0].model))


comptime GrowTerrain = Task[TerrainJob, Terrain, grow_terrain_task]
comptime DetectSweep = TaskWith[SweepJob, Terrain, Detections, detect_sweep_task]
comptime GeometryTasks = Tasks[GrowTerrain, DetectSweep]
"""A pipeline that calls `run_geometry_tasks` declares `tasks=GeometryTasks`."""


# -- the driver --------------------------------------------------------------


def run_geometry_tasks(
    mut rt: GeometryTasks.RT,
    work: String,
    out_path: String,
    accel_var: Float64 = 1.5,
    measurement_var: Float64 = 0.25,
    use_terrain: Bool = True,
    reverse: Bool = False,
    proprioception: Bool = True,
    fit_terrain_to_drive: Bool = False,
) raises -> StageMetrics:
    """`refinery.stages.run_geometry` on the run's dista workers: the same
    arguments, the same tracker CSV."""
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
        "| dista tasks: 1 terrain,",
        len(geo.jobs),
        "detect",
    )

    var t0 = perf_counter_ns()
    var terrain_ref = rt.remote[GrowTerrain](
        TerrainJob(work, proprioception, fit_terrain_to_drive)
    )
    var refs = List[ObjectRef[Detections]](capacity=len(geo.jobs))
    for f in range(len(geo.jobs)):
        refs.append(rt.remote[DetectSweep](geo.jobs[f], [terrain_ref]))

    var per_frame = List[List[Detection]](capacity=len(geo.jobs))
    for f in range(len(refs)):
        per_frame.append(rt.take(refs[f]).into_items())
    var t3 = perf_counter_ns()
    var terrain = rt.take(terrain_ref)
    metrics.total_points = terrain.total_points
    metrics.ego_points = terrain.ego_points
    report_lift(metrics, terrain.model)
    report_detections(metrics, per_frame)

    run_tracking(
        per_frame^,
        geo.times.copy(),
        out_path,
        accel_var,
        measurement_var,
        reverse,
        metrics,
    )
    # Lift, terrain and detect overlap across the workers: their time is one
    # span, reported as detect.
    report_seconds(t0, t0, t0, t3, perf_counter_ns())
    return metrics^
