"""Terrain classification, built on Stone.mojo.

The problem, measured: 92.6% of Pipeline A's false positives sat within three
metres of a stockpile toe. Ground removal was "per one metre cell, drop
everything within 0.35 m of the lowest point", but a pile rests at its angle of
repose, 34 degrees, so across one cell the surface climbs
`tan(34 deg) x 1.0 = 0.67 m` -- nearly double the tolerance. The bottom of each
cell was called ground and the top third survived as slivers, which the
clusterer correctly turned into vehicle-shaped objects.

Tightening the tolerance does not fix that. It trades those false positives for
false negatives on real objects standing near slopes.

**The right question is connectivity, not height.** A stockpile is continuous
with the grade it sits on: you can walk from a driven cell to the top of the
pile without ever stepping up more than the angle of repose allows. A truck is
not -- getting from grade to its roof is a three metre jump in one cell, and no
natural surface does that.

So the ground surface is grown, not thresholded. Seed with the cells the
machine drove through, then flood outward, accepting a neighbour whenever its
floor is within one cell's worth of repose-limited rise. Whatever the fill
reaches is terrain, at any absolute height. Whatever it cannot reach is
standing on terrain, and is a candidate object.

  - a 3.4 m pile is reached, one 0.67 m step at a time -> terrain
  - a 1.75 m worker is a 1.75 m jump from grade -> object
  - a truck bed at 2.1 m, likewise -> object
  - toe cells, where a pile meets flat grade and one cell holds both
    surfaces, are reached from either side -> terrain

That last case is what an earlier per-cell threshold test kept getting wrong,
and it was the largest remaining source of false positives after the first
pass at this.

**What Stone provides**: the 2.5-D grid, streaming per-cell accumulation across
the whole sequence, and the plane fit behind slope, roughness and step. The
seeding trick is Stone's too -- the driven trajectory is free supervision,
exactly as joint angles are for the boom chain.

**One honest adaptation**: Stone's own output is a *traversability* label, and
it would call a 34-degree pile NON_TRAVERSABLE, correctly, since nothing drives
up it. That is a different question from terrain-versus-object. Slope is
exactly the feature that separates drivable ground from a pile, and exactly the
feature that must not separate terrain from an object, so the fill ignores
slope and reasons about connectivity instead.
"""

from stone import GridSpec, TerrainGrid, Vec3

from .io import Pose

comptime GRID_EXTENT_M = 70.0
comptime GRID_CELL_M = 1.0
comptime GRID_CELLS = 140
"""2 * GRID_EXTENT_M / GRID_CELL_M, as an integer literal."""

comptime REPOSE_TANGENT = 0.6745
"""tan(34 degrees), the angle of repose. Loose material cannot stand steeper,
so a genuine surface rises at most `cell_size * tan(repose)` between adjacent
cells. A physical constant, not a tuning knob."""

comptime CLIMB_MARGIN = 1.35
"""Slack on that limit, for sensor noise and for cells straddling a break in
slope. Total allowed rise per cell is 0.91 m -- comfortably under a standing
person at 1.75 m, so a worker can never be absorbed into the terrain however
the fill propagates."""

comptime MAX_TERRAIN_STEP_M = 1.30
"""Ceiling on a cell's vertical extent for it to be terrain at all.

Connectivity alone is not quite enough. A truck's lowest *visible* return sits
0.6 to 1.0 m above the grade beside it -- inside the repose allowance -- so a
pure floor-based fill climbs onto the vehicle, eats its lower body, and leaves
a floating top that fits a small, badly placed box. Measured: precision rose to
0.664 but ATE went 0.365 -> 0.445 and ASE 0.577 -> 0.705.

Stone's `step` closes it. A pile cell spans `cell_size * tan(repose)` = 0.67 m
vertically; a truck cell spans two to three metres. So the fill may cross a
repose-limited rise, but only into a cell that is itself thin. Below a standing
person at 1.75 m, so a worker still cannot be absorbed.
"""

comptime GROUND_CLEARANCE_M = 0.30
"""How far above a reached cell's floor a point still counts as ground. A
worker standing in a reached cell is still an object: the cell is terrain, the
points a metre and a half above its floor are not."""

comptime DRIVEN_DILATION_CELLS = 3
"""How far around the machine's own path to look for seed cells.

A machine cannot observe the ground it is standing on -- its own body occludes
it, and the self-mask removes whatever leaks through -- so the trajectory cells
themselves come back unobserved and seeding on them yields an empty set. The
cells beside the path are the honest substitute: the machine physically drove
through that patch, so it is ground flat enough to carry twenty tonnes, and
unlike the path itself it was actually seen.
"""


struct TerrainModel(Movable):
    """The grown ground surface, and what it says about any given point."""

    var spec: GridSpec
    var reached: List[Bool]
    """Cells the fill reached from the machine's own path."""
    var floor_z: List[Float64]
    """Lowest return in the cell: the ground surface, where reached."""
    var blocked_by_step: Int
    """Cells the fill declined to enter because they were too thick to be
    surface. These are the object candidates it protected."""
    var seed_cells: Int
    var terrain_cells: Int
    var observed_cells: Int

    def __init__(
        out self,
        var spec: GridSpec,
        var reached: List[Bool],
        var floor_z: List[Float64],
        seed_cells: Int,
        terrain_cells: Int,
        observed_cells: Int,
        blocked_by_step: Int,
    ):
        self.spec = spec^
        self.reached = reached^
        self.floor_z = floor_z^
        self.seed_cells = seed_cells
        self.terrain_cells = terrain_cells
        self.observed_cells = observed_cells
        self.blocked_by_step = blocked_by_step

    def is_terrain(self, x: Float64, y: Float64, z: Float64) -> Bool:
        var idx = self.spec.index_of(x, y)
        if idx < 0 or not self.reached[idx]:
            return False
        return z <= self.floor_z[idx] + GROUND_CLEARANCE_M


def build_terrain(
    sweeps_x: List[List[Float64]],
    sweeps_y: List[List[Float64]],
    sweeps_z: List[List[Float64]],
    poses: List[Pose],
) raises -> TerrainModel:
    """Accumulate every sweep, then grow the ground surface from the drive.

    Aggregating the whole sequence before deciding anything is the offboard
    advantage in its purest form: every pass over the same ground adds a
    viewpoint, so a cell seen edge-on early is seen properly later, and nothing
    has to be decided in real time.
    """
    var spec = GridSpec(
        -GRID_EXTENT_M, -GRID_EXTENT_M, GRID_CELL_M, GRID_CELLS, GRID_CELLS
    )
    var grid = TerrainGrid(spec)
    var count = spec.cell_count()

    var floor_z = List[Float64](length=count, fill=1.0e18)
    var observed = List[Bool](length=count, fill=False)
    var observed_cells = 0

    for f in range(len(sweeps_x)):
        var points = List[Vec3]()
        for i in range(len(sweeps_x[f])):
            var px = sweeps_x[f][i]
            var py = sweeps_y[f][i]
            var pz = sweeps_z[f][i]
            points.append(Vec3(px, py, pz))
            var idx = spec.index_of(px, py)
            if idx < 0:
                continue
            if not observed[idx]:
                observed[idx] = True
                observed_cells += 1
            if pz < floor_z[idx]:
                floor_z[idx] = pz
        grid.ingest(points)
    grid.finalize()

    # -- seed: the observed neighbourhood of the machine's own path ---------
    var reached = List[Bool](length=count, fill=False)
    var frontier = List[Int]()
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
                if reached[idx] or not observed[idx]:
                    continue
                reached[idx] = True
                frontier.append(idx)
    var seeds = len(frontier)

    # -- grow: four-connected, one repose-limited step at a time ------------
    var max_climb = GRID_CELL_M * REPOSE_TANGENT * CLIMB_MARGIN
    var terrain_cells = seeds
    var blocked = 0
    while len(frontier) > 0:
        var current = frontier[len(frontier) - 1]
        _ = frontier.pop()
        var cx = current % spec.nx
        var cy = current // spec.nx
        var here = floor_z[current]

        for k in range(4):
            var ix = cx + (1 if k == 0 else (-1 if k == 1 else 0))
            var iy = cy + (1 if k == 2 else (-1 if k == 3 else 0))
            if ix < 0 or iy < 0 or ix >= spec.nx or iy >= spec.ny:
                continue
            var idx = iy * spec.nx + ix
            if reached[idx] or not observed[idx]:
                continue
            var rise = floor_z[idx] - here
            if rise < 0.0:
                rise = -rise
            if rise > max_climb:
                continue
            # Thin enough to be a surface? A pile cell spans 0.67 m, a truck
            # cell spans two to three.
            if grid.cells[idx].step > MAX_TERRAIN_STEP_M:
                blocked += 1
                continue
            reached[idx] = True
            terrain_cells += 1
            frontier.append(idx)

    return TerrainModel(
        spec^, reached^, floor_z^, seeds, terrain_cells, observed_cells, blocked
    )
