"""Pipeline A's geometry, one sweep at a time.

The geometry stage has three phases, and only the middle one needs the whole
sequence at once:

1. **lift** each sweep: read it, move it into the map frame, take out the
   ego's own returns (`ego_mask`), and bin it into the terrain grid's cells
   (`stone.CellPatch`). Per sweep.
2. **grow** the terrain: merge every sweep's patch, in frame order, and grow
   the ground surface from the drive (`refinery.terrain.grow_terrain`). Once.
3. **detect** in each sweep: ground removal against that terrain, voxel
   clustering, box fit. Per sweep, and it reads the sweep again rather than
   holding it from step 1, so nothing keeps a whole log of points in memory.

Then association and smoothing run over the whole log
(`refinery.stages.run_tracking`).

`run_geometry` runs these one after another; `refinery.sweeps` runs the
per-sweep phases as dista tasks. Both call the functions here, in the same
order where it matters (patches merge in frame order), so they write the same
bytes. The terrain depends only on each cell's count and lowest and highest
return, which merging gives exactly, so this also reproduces the streaming
version it replaced.

Everything a task needs about its sweep is in its `SweepJob`, a plain struct
that dista sends by reflection.
"""

from stone import CellAccumulator, CellPatch, GridSpec, TerrainGrid, Vec3

from refinery.io import (
    Joints,
    Pose,
    Sweep,
    read_csv_rows,
    read_joints,
    read_poses,
    read_sweep,
)
from refinery.pipeline import Detection, detect, ego_mask
from refinery.terrain import TerrainModel, grow_terrain, terrain_spec


@fieldwise_init
struct SweepJob(Copyable, Movable):
    """One sweep of a work directory, with what lifting it needs."""

    var work: String
    var frame: Int
    var file: String
    """Under `<work>/sweeps`."""
    var t: Float64
    var pose: Pose
    var proprioception: Bool
    var joints: Joints
    """Ignored without `proprioception`."""
    var spec: GridSpec
    """The terrain grid every sweep is binned into."""
    var use_terrain: Bool


@fieldwise_init
struct Lifted(Copyable, Movable):
    """One sweep's contribution to the terrain, and its point counts."""

    var frame: Int
    var patch: CellPatch
    var total_points: Int
    var ego_points: Int

    def into_patch(deinit self) -> CellPatch:
        return self.patch^


@fieldwise_init
struct Geometry(Copyable, Movable):
    """A work directory's sweeps, as jobs, and the drive they were taken on."""

    var jobs: List[SweepJob]
    var poses: List[Pose]
    var times: List[Float64]
    var spec: GridSpec
    """The terrain grid, as in every job."""


def sweep_jobs(
    work: String,
    proprioception: Bool,
    fit_terrain_to_drive: Bool,
    use_terrain: Bool,
) raises -> Geometry:
    """A job per sweep of `work`, on one terrain grid: the site's, or with
    `fit_terrain_to_drive` one sized to the path."""
    var poses = read_poses(work + "/tf.csv")
    var joints = List[Joints]()
    if proprioception:
        joints = read_joints(work + "/joints.csv")
    var index = read_csv_rows(work + "/sweeps/index.csv")
    var spec = terrain_spec(poses, fit_terrain_to_drive)
    var jobs = List[SweepJob](capacity=len(index))
    var times = List[Float64](capacity=len(index))
    for f in range(len(index)):
        ref row = index[f]
        var t = Float64(row[1])
        times.append(t)
        jobs.append(
            SweepJob(
                work,
                f,
                String(row[3]),
                t,
                poses[f],
                proprioception,
                joints[f] if proprioception else Joints(0.0, 0.0, 0.0, 0.0, 0.0),
                spec,
                use_terrain,
            )
        )
    return Geometry(jobs^, poses^, times^, spec)


def _read(job: SweepJob) raises -> Sweep:
    """The sweep, moved into the map frame."""
    return read_sweep(job.work + "/sweeps", job.file, job.t, job.pose)


def _without_ego(job: SweepJob, var sweep: Sweep) -> Sweep:
    """The sweep without the ego's own returns.

    Self-mask before anything downstream sees the cloud. The terrain needs it
    as much as the clusterer does: the driven cells are exactly where the
    machine is standing, so leaving its own returns in makes "known ground"
    contain a 3 m machine. A car's sweeps arrive without them
    (`proprioception` off).
    """
    if not job.proprioception:
        return sweep^
    var mask = ego_mask(job.pose, job.joints)
    var kept = Sweep(job.t)
    for i in range(len(sweep)):
        if mask.masks(sweep.x[i], sweep.y[i], sweep.z[i]):
            continue
        kept.x.append(sweep.x[i])
        kept.y.append(sweep.y[i])
        kept.z.append(sweep.z[i])
    return kept^


def lift(job: SweepJob) raises -> Lifted:
    """Phase 1 for one sweep: its patch of the terrain grid."""
    var raw = _read(job)
    var total = len(raw)
    var sweep = _without_ego(job, raw^)
    var points = List[Vec3](capacity=len(sweep))
    for i in range(len(sweep)):
        points.append(Vec3(sweep.x[i], sweep.y[i], sweep.z[i]))
    return Lifted(
        job.frame, CellPatch.of(job.spec, points), total, total - len(sweep)
    )


def merge_terrain(
    spec: GridSpec, patches: List[CellPatch], poses: List[Pose]
) raises -> TerrainModel:
    """Phase 2: every sweep's patch, in frame order, then the grown surface."""
    var grid = TerrainGrid(spec)
    for i in range(len(patches)):
        grid.merge(patches[i])
    grid.finalize()
    return grow_terrain(grid, poses)


def detect_sweep(job: SweepJob, terrain: TerrainModel) raises -> List[Detection]:
    """Phase 3 for one sweep."""
    return detect(_without_ego(job, _read(job)), terrain, job.use_terrain)
