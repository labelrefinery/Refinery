"""Terrain classification, built on Stone.mojo.

The problem this solves, measured: 92.6% of Pipeline A's false positives sat
within three metres of a stockpile toe. The old ground removal was "per one
metre cell, drop everything within 0.35 m of the lowest point". A pile rests at
its angle of repose, 34 degrees, so across a single cell the surface climbs
`tan(34 deg) x 1.0 = 0.67 m` -- nearly double the tolerance. The bottom of each
cell was called ground and the top third survived, producing slivers all over
the flank that the clusterer then did its job on: 33 phantom tracks with a
median footprint of 4.0 x 2.2 x 1.5 m, which looks entirely like a vehicle.

Tightening the tolerance does not fix that. It trades those false positives for
false negatives on real objects standing near slopes.

Stone asks a better question. It bins the cloud into a 2.5-D grid, fits a plane
per cell from the eigenvectors of the scatter matrix, and reports slope,
roughness (RMS residual to that plane) and step (vertical extent within the
cell). The test stops being *how high is this point* and becomes *is this cell
part of a continuous surface, or is it something standing on one*:

  - a stockpile flank is a coherent surface -- steep, but smooth, with a step
    set by the slope and the cell size
  - a truck or a worker is not part of the height field at all: high residual
    to any fitted plane, and a step of metres rather than centimetres

Height stops mattering, continuity starts mattering. A 3.4 m pile is terrain. A
1.75 m worker is not.

**One honest adaptation.** Stone's own output is a *traversability* label, and
it would call a 34-degree pile NON_TRAVERSABLE -- correctly, since nothing
drives up it. But that is a different question from terrain-versus-object, and
using it here would throw the pile back into the clusterer. So this module uses
Stone's geometry (stages 1-2) and its driven-trajectory calibration trick
(stage 3), but gates on **roughness and step only, with slope ignored**. Slope
is exactly the feature that separates traversable ground from a pile, and
exactly the feature that must not separate terrain from an object.

The calibration is still annotation-free. The cells the machine actually drove
over are known ground by construction, so their roughness and step give the
scale of "surface" for this sensor on this site, and the thresholds are that
mean plus a few sigma. Nothing is tuned by hand and nothing is labelled.
"""

from std.math import sqrt

from stone import GridSpec, TerrainGrid, Vec3

from .io import Pose, Sweep

comptime GRID_EXTENT_M = 70.0
comptime GRID_CELL_M = 1.0
comptime GRID_CELLS = 140
"""2 * GRID_EXTENT_M / GRID_CELL_M, as an integer literal."""
comptime SURFACE_SIGMA = 4.0
"""How far past the driven cells' spread a cell may sit and still count as
surface. Generous on purpose: a false 'object' costs precision immediately,
while a missed one is recovered by the next sweep from a new viewpoint."""

comptime DRIVEN_DILATION_CELLS = 3
"""How far around the machine's own path to look for calibration cells.

Stone calibrates from the cells the robot crossed. A machine cannot observe
the ground it is standing on -- its own body occludes it, and the self-mask
removes whatever returns it does get -- so the trajectory cells themselves come
back unobserved and the calibration set is empty. The cells *beside* the path
are the honest substitute: the machine physically drove through that patch, so
it is ground flat enough to carry twenty tonnes, and unlike the path itself it
was actually seen.
"""

comptime MIN_SURFACE_FLOOR_M = 0.12
"""Floor on the learned thresholds, metres. A machine that drives a graded pad
produces driven cells with almost no spread at all, and a threshold fitted from
those would call a gravel patch an object. This is the sensor's own noise, not
a tuning knob."""

comptime REPOSE_TANGENT = 0.6745
"""tan(34 degrees). Loose material cannot stand steeper than its angle of
repose, so a genuine surface spans at most `cell_size * tan(repose)` vertically
within one cell. That is a physical ceiling, not a tuned one, and it is what
stops a contaminated calibration set from opening the gate wide enough to
swallow a truck."""

comptime MAX_SURFACE_STEP_M = 1.3
"""Ceiling on the step threshold, metres. Below a standing person at 1.75 m,
so a worker can never be absorbed into the terrain however the calibration
lands."""

comptime MAX_SURFACE_ROUGHNESS_M = 0.25
"""A plane-fit residual above this in a one metre cell means the returns do not
lie on a plane at all -- which is the definition of not-a-surface."""


def _median(values: List[Float64]) -> Float64:
    """Robust centre. The calibration set is cells beside the machine's path,
    and things walk through it: a worker crossing the swing radius lands a
    1.75 m step in one of them. A mean plus four sigma is then wide enough to
    admit a haul truck. A median does not care."""
    if len(values) == 0:
        return 0.0
    var sorted_values = values.copy()
    for i in range(1, len(sorted_values)):
        var key = sorted_values[i]
        var j = i - 1
        while j >= 0 and sorted_values[j] > key:
            sorted_values[j + 1] = sorted_values[j]
            j -= 1
        sorted_values[j + 1] = key
    return sorted_values[len(sorted_values) // 2]


def _mad(values: List[Float64], centre: Float64) -> Float64:
    """Median absolute deviation, scaled to be a standard-deviation estimate."""
    if len(values) == 0:
        return 0.0
    var deviations = List[Float64]()
    for i in range(len(values)):
        var d = values[i] - centre
        deviations.append(d if d >= 0.0 else -d)
    return 1.4826 * _median(deviations)


struct TerrainModel(Movable):
    """Per-cell surface classification over the whole scene."""

    var spec: GridSpec
    var surface: List[Bool]
    var observed: List[Bool]
    var elevation: List[Float64]
    var driven_cells: Int
    var surface_cells: Int
    var roughness_threshold: Float64
    var step_threshold: Float64

    def __init__(
        out self,
        var spec: GridSpec,
        var surface: List[Bool],
        var observed: List[Bool],
        var elevation: List[Float64],
        driven_cells: Int,
        surface_cells: Int,
        roughness_threshold: Float64,
        step_threshold: Float64,
    ):
        self.spec = spec^
        self.surface = surface^
        self.observed = observed^
        self.elevation = elevation^
        self.driven_cells = driven_cells
        self.surface_cells = surface_cells
        self.roughness_threshold = roughness_threshold
        self.step_threshold = step_threshold

    def is_surface(self, x: Float64, y: Float64) -> Bool:
        var idx = self.spec.index_of(x, y)
        if idx < 0:
            return False
        return self.surface[idx]


def build_terrain(
    sweeps_x: List[List[Float64]],
    sweeps_y: List[List[Float64]],
    sweeps_z: List[List[Float64]],
    poses: List[Pose],
) raises -> TerrainModel:
    """Accumulate every sweep, fit per-cell planes, calibrate from the drive.

    Aggregating the whole sequence before deciding anything is the offboard
    advantage in its purest form: each pass over the same ground adds a
    viewpoint, so a cell seen edge-on early is seen properly later, and nothing
    has to be decided in real time.
    """
    var spec = GridSpec(
        -GRID_EXTENT_M, -GRID_EXTENT_M, GRID_CELL_M, GRID_CELLS, GRID_CELLS
    )
    var grid = TerrainGrid(spec)

    for f in range(len(sweeps_x)):
        var points = List[Vec3]()
        for i in range(len(sweeps_x[f])):
            points.append(Vec3(sweeps_x[f][i], sweeps_y[f][i], sweeps_z[f][i]))
        grid.ingest(points)
    grid.finalize()

    # The machine's own path is known ground, for free -- but dilated, see
    # DRIVEN_DILATION_CELLS.
    var claimed = List[Bool](length=spec.cell_count(), fill=False)
    var driven = List[Int]()
    for i in range(len(poses)):
        var cx = Int((poses[i].tx - spec.origin_x) / spec.cell_size)
        var cy = Int((poses[i].ty - spec.origin_y) / spec.cell_size)
        for dx in range(-DRIVEN_DILATION_CELLS, DRIVEN_DILATION_CELLS + 1):
            for dy in range(-DRIVEN_DILATION_CELLS, DRIVEN_DILATION_CELLS + 1):
                var ix = cx + dx
                var iy = cy + dy
                if ix < 0 or iy < 0 or ix >= spec.nx or iy >= spec.ny:
                    continue
                var idx = iy * spec.nx + ix
                if claimed[idx] or not grid.cells[idx].observed:
                    continue
                claimed[idx] = True
                driven.append(idx)

    # Calibrate from those cells, robustly.
    var roughnesses = List[Float64]()
    var steps = List[Float64]()
    for i in range(len(driven)):
        roughnesses.append(grid.cells[driven[i]].roughness)
        steps.append(grid.cells[driven[i]].step)

    var med_r = _median(roughnesses)
    var med_s = _median(steps)
    var tau_r = med_r + SURFACE_SIGMA * _mad(roughnesses, med_r)
    var tau_s = med_s + SURFACE_SIGMA * _mad(steps, med_s)

    if tau_r < MIN_SURFACE_FLOOR_M:
        tau_r = MIN_SURFACE_FLOOR_M
    if tau_r > MAX_SURFACE_ROUGHNESS_M:
        tau_r = MAX_SURFACE_ROUGHNESS_M
    # Step is bracketed by physics from both sides, so the learned value only
    # moves it within a narrow band -- roughness is what actually discriminates.
    # Floor: a surface at the angle of repose spans cell_size * tan(repose)
    # vertically, and must still count as surface. Ceiling: below the height of
    # the shortest object worth finding, which is a standing person.
    var step_floor = GRID_CELL_M * REPOSE_TANGENT * 1.35
    if tau_s < step_floor:
        tau_s = step_floor
    if tau_s > MAX_SURFACE_STEP_M:
        tau_s = MAX_SURFACE_STEP_M

    var surface = List[Bool](length=spec.cell_count(), fill=False)
    var observed = List[Bool](length=spec.cell_count(), fill=False)
    var elevation = List[Float64](length=spec.cell_count(), fill=0.0)
    var surface_count = 0
    for i in range(spec.cell_count()):
        ref cell = grid.cells[i]
        observed[i] = cell.observed
        elevation[i] = cell.elevation
        if not cell.observed:
            continue
        if cell.roughness <= tau_r and cell.step <= tau_s:
            surface[i] = True
            surface_count += 1

    return TerrainModel(
        spec^,
        surface^,
        observed^,
        elevation^,
        len(driven),
        surface_count,
        tau_r,
        tau_s,
    )
