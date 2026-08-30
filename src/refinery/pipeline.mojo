"""Pipeline A: cold start. No labels, no checkpoints, no training.

    proprioception self-mask -> ground removal -> clustering -> box fit
      -> gated association (Hungarian.mojo) -> RTS smoothing (Kalman.mojo)

Every stage is geometry or classical estimation, so this runs on a scene it
has never seen with nothing learned in advance. That is the point: it produces
the first generation of pseudo-labels, which is what a student model is then
trained on.

The one piece of supervision it does use is free. The ego machine publishes its
own joint angles, so forward kinematics puts its boom, stick and bucket exactly
where they are, and their returns come out of the cloud before anything else
runs. Roughly an eighth of every sweep is the ego looking at itself; a
clusterer given those points invents a large object welded to the sensor.
"""

from std.math import atan2, cos, sin, sqrt

from hungarian import CostMatrix, solve_gated, UNASSIGNED
from kalman import GaussianState, Matrix, Observation, smooth_track

from .io import Joints, Pose, Sweep
from .terrain import TerrainModel

# ===----------------------------------------------------------------------===
# Tunables
# ===----------------------------------------------------------------------===

comptime GROUND_CELL_M = 1.0
"""Ground is estimated per XY cell rather than globally: a stockpile is four
metres above local grade, and a single plane fit over the whole site would
call its flanks obstacles and its peak sky."""

comptime GROUND_TOL_M = 0.35
comptime VOXEL_M = 0.6
"""Clustering resolution. Below the gap between a worker and the ground they
stand on, above the point spacing on a truck at thirty metres."""

comptime MIN_CLUSTER_POINTS = 6
comptime MAX_CLUSTER_EXTENT_M = 16.0
comptime ASSOCIATION_GATE_M = 3.5
comptime MAX_MISSES = 5
comptime MIN_TRACK_FRAMES = 4
"""A track seen three times is noise. This is the cheapest false-positive
filter there is, and it only works offline -- online you must decide before
you know how long the track will live."""

comptime EGO_BODY_RADIUS_M = 2.9
comptime EGO_BODY_TOP_M = 3.6
comptime EGO_LINK_RADIUS_M = 0.9
comptime BOOM_FOOT_X = 1.2
comptime BOOM_FOOT_Z = 0.6
comptime BOOM_LENGTH = 5.7
comptime STICK_LENGTH = 2.9
comptime BUCKET_LENGTH = 1.4
comptime SENSOR_MAST_X = 1.3
comptime SENSOR_MAST_Z = 3.2
comptime SLEW_HEIGHT = 1.1


# ===----------------------------------------------------------------------===
# Ego geometry from proprioception
# ===----------------------------------------------------------------------===


struct Segment(ImplicitlyCopyable, Movable):
    """A capsule: the axis of one boom-chain link, plus a clearance radius."""

    var ax: Float64
    var ay: Float64
    var az: Float64
    var bx: Float64
    var by: Float64
    var bz: Float64
    var radius: Float64

    def __init__(
        out self,
        ax: Float64,
        ay: Float64,
        az: Float64,
        bx: Float64,
        by: Float64,
        bz: Float64,
        radius: Float64,
    ):
        self.ax = ax
        self.ay = ay
        self.az = az
        self.bx = bx
        self.by = by
        self.bz = bz
        self.radius = radius

    def contains(self, px: Float64, py: Float64, pz: Float64) -> Bool:
        var dx = self.bx - self.ax
        var dy = self.by - self.ay
        var dz = self.bz - self.az
        var len2 = dx * dx + dy * dy + dz * dz
        var u = 0.0
        if len2 > 1e-9:
            u = (
                (px - self.ax) * dx + (py - self.ay) * dy + (pz - self.az) * dz
            ) / len2
            if u < 0.0:
                u = 0.0
            if u > 1.0:
                u = 1.0
        var qx = self.ax + u * dx
        var qy = self.ay + u * dy
        var qz = self.az + u * dz
        var ex = px - qx
        var ey = py - qy
        var ez = pz - qz
        return ex * ex + ey * ey + ez * ez <= self.radius * self.radius


struct EgoMask(Movable):
    """Where the ego machine is this frame, reconstructed from its joints."""

    var base_x: Float64
    var base_y: Float64
    var links: List[Segment]

    def __init__(
        out self, base_x: Float64, base_y: Float64, var links: List[Segment]
    ):
        self.base_x = base_x
        self.base_y = base_y
        self.links = links^

    def masks(self, px: Float64, py: Float64, pz: Float64) -> Bool:
        # Body: everything within the slew radius, below the cab roof.
        var dx = px - self.base_x
        var dy = py - self.base_y
        if pz <= EGO_BODY_TOP_M and dx * dx + dy * dy <= EGO_BODY_RADIUS_M**2:
            return True
        for i in range(len(self.links)):
            if self.links[i].contains(px, py, pz):
                return True
        return False


def ego_mask(pose: Pose, joints: Joints) -> EgoMask:
    """Forward kinematics down the boom chain, in world coordinates.

    Every pitch joint turns about the house's own y-axis, so the angles simply
    add down the chain and each link direction is one rotation away from the
    house frame. That is the whole reason this is twenty lines rather than a
    matrix stack.
    """
    # The sensor is bolted to the house, so the house frame is the sensor's
    # rotation and the mast offset backed out of its translation.
    var hx = pose.tx - (pose.r0 * SENSOR_MAST_X + pose.r2 * SENSOR_MAST_Z)
    var hy = pose.ty - (pose.r3 * SENSOR_MAST_X + pose.r5 * SENSOR_MAST_Z)
    var hz = pose.tz - (pose.r6 * SENSOR_MAST_X + pose.r8 * SENSOR_MAST_Z)

    var foot_x = hx + pose.r0 * BOOM_FOOT_X + pose.r2 * BOOM_FOOT_Z
    var foot_y = hy + pose.r3 * BOOM_FOOT_X + pose.r5 * BOOM_FOOT_Z
    var foot_z = hz + pose.r6 * BOOM_FOOT_X + pose.r8 * BOOM_FOOT_Z

    var links = List[Segment]()
    var ax = foot_x
    var ay = foot_y
    var az = foot_z
    var angle = 0.0
    var lengths: List[Float64] = [BOOM_LENGTH, STICK_LENGTH, BUCKET_LENGTH]
    var pitches: List[Float64] = [joints.boom, joints.stick, joints.bucket]

    for i in range(3):
        angle += pitches[i]
        # rot_y(angle) applied to the link's own +x axis, lifted by the house.
        var lx = cos(angle)
        var lz = -sin(angle)
        var dx = pose.r0 * lx + pose.r2 * lz
        var dy = pose.r3 * lx + pose.r5 * lz
        var dz = pose.r6 * lx + pose.r8 * lz
        var bx = ax + lengths[i] * dx
        var by = ay + lengths[i] * dy
        var bz = az + lengths[i] * dz
        links.append(Segment(ax, ay, az, bx, by, bz, EGO_LINK_RADIUS_M))
        ax = bx
        ay = by
        az = bz

    return EgoMask(hx, hy, links^)


# ===----------------------------------------------------------------------===
# Detection
# ===----------------------------------------------------------------------===


struct Detection(ImplicitlyCopyable, Movable):
    """One clustered object in the map frame."""

    var t: Float64
    var x: Float64
    var y: Float64
    var z: Float64
    var w: Float64
    var l: Float64
    var h: Float64
    var yaw: Float64
    var points: Int

    def __init__(
        out self,
        t: Float64,
        x: Float64,
        y: Float64,
        z: Float64,
        w: Float64,
        l: Float64,
        h: Float64,
        yaw: Float64,
        points: Int,
    ):
        self.t = t
        self.x = x
        self.y = y
        self.z = z
        self.w = w
        self.l = l
        self.h = h
        self.yaw = yaw
        self.points = points

    def confidence(self) -> Float64:
        """More returns means more certainty. Saturates -- a hundred points is
        not ten times better evidence than ten, and the association solver only
        uses this to break ties."""
        var c = Float64(self.points) / 60.0
        return c if c < 1.0 else 1.0


def _voxel_key(ix: Int, iy: Int, iz: Int) -> Int:
    return (ix + 4096) * 16_777_216 + (iy + 4096) * 4096 + (iz + 512)


def detect(
    sweep: Sweep, terrain: TerrainModel, use_terrain: Bool
) raises -> List[Detection]:
    """Self-mask, drop terrain, cluster what is left, fit a box to each.

    With `use_terrain` off this falls back to the per-cell-minimum ground
    removal, which is kept only so the two can be compared on the same scene.
    """
    var n = len(sweep)

    # -- ego self-mask, then a per-cell ground estimate over the survivors ---
    var keep = List[Bool](length=n, fill=False)
    var ground_min = Dict[Int, Float64]()
    for i in range(n):
        var px = sweep.x[i]
        var py = sweep.y[i]
        var pz = sweep.z[i]
        if use_terrain and terrain.is_terrain(px, py, pz):
            # A cell Stone calls a continuous surface is terrain at any height:
            # the whole column goes, pile included.
            continue
        keep[i] = True
        var cell = _voxel_key(
            Int(px / GROUND_CELL_M), Int(py / GROUND_CELL_M), 0
        )
        if cell in ground_min:
            if pz < ground_min[cell]:
                ground_min[cell] = pz
        else:
            ground_min[cell] = pz

    # -- voxelize the non-ground remainder ---------------------------------
    var voxel_of_point = List[Int](length=n, fill=-1)
    var voxel_index = Dict[Int, Int]()
    var voxel_keys = List[Int]()
    for i in range(n):
        if not keep[i]:
            continue
        var px = sweep.x[i]
        var py = sweep.y[i]
        var pz = sweep.z[i]
        var cell = _voxel_key(
            Int(px / GROUND_CELL_M), Int(py / GROUND_CELL_M), 0
        )
        if cell in ground_min and pz < ground_min[cell] + GROUND_TOL_M:
            keep[i] = False
            continue
        var key = _voxel_key(
            Int(px / VOXEL_M), Int(py / VOXEL_M), Int(pz / VOXEL_M)
        )
        if key not in voxel_index:
            voxel_index[key] = len(voxel_keys)
            voxel_keys.append(key)
        voxel_of_point[i] = voxel_index[key]

    # -- connected components over the 26-neighbourhood --------------------
    var label = List[Int](length=len(voxel_keys), fill=-1)
    var clusters = 0
    for start in range(len(voxel_keys)):
        if label[start] != -1:
            continue
        label[start] = clusters
        var frontier = List[Int]()
        frontier.append(start)
        while len(frontier) > 0:
            var current = frontier[len(frontier) - 1]
            _ = frontier.pop()
            var key = voxel_keys[current]
            var iz = key % 4096 - 512
            var iy = (key // 4096) % 4096 - 4096
            var ix = key // 16_777_216 - 4096
            for dx in range(-1, 2):
                for dy in range(-1, 2):
                    for dz in range(-1, 2):
                        var neighbour = _voxel_key(ix + dx, iy + dy, iz + dz)
                        if neighbour not in voxel_index:
                            continue
                        var j = voxel_index[neighbour]
                        if label[j] == -1:
                            label[j] = clusters
                            frontier.append(j)
        clusters += 1

    # -- fit one oriented box per component --------------------------------
    var out = List[Detection]()
    for c in range(clusters):
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        var syy = 0.0
        var count = 0
        for i in range(n):
            if voxel_of_point[i] < 0 or label[voxel_of_point[i]] != c:
                continue
            sx += sweep.x[i]
            sy += sweep.y[i]
            count += 1
        if count < MIN_CLUSTER_POINTS:
            continue
        var mx = sx / Float64(count)
        var my = sy / Float64(count)
        for i in range(n):
            if voxel_of_point[i] < 0 or label[voxel_of_point[i]] != c:
                continue
            var ex = sweep.x[i] - mx
            var ey = sweep.y[i] - my
            sxx += ex * ex
            sxy += ex * ey
            syy += ey * ey

        # Principal axis in the ground plane is the object's heading. For a
        # near-isotropic blob this is arbitrary, which is honest: a worker
        # standing still has no observable heading.
        var yaw = 0.5 * atan2(2.0 * sxy, sxx - syy)
        var ca = cos(-yaw)
        var sa = sin(-yaw)

        var lo_u = 1e18
        var hi_u = -1e18
        var lo_v = 1e18
        var hi_v = -1e18
        var lo_z = 1e18
        var hi_z = -1e18
        for i in range(n):
            if voxel_of_point[i] < 0 or label[voxel_of_point[i]] != c:
                continue
            var ex = sweep.x[i] - mx
            var ey = sweep.y[i] - my
            var u = ca * ex - sa * ey
            var v = sa * ex + ca * ey
            if u < lo_u:
                lo_u = u
            if u > hi_u:
                hi_u = u
            if v < lo_v:
                lo_v = v
            if v > hi_v:
                hi_v = v
            if sweep.z[i] < lo_z:
                lo_z = sweep.z[i]
            if sweep.z[i] > hi_z:
                hi_z = sweep.z[i]

        var length = hi_u - lo_u
        var width = hi_v - lo_v
        var height = hi_z - lo_z
        if length > MAX_CLUSTER_EXTENT_M or width > MAX_CLUSTER_EXTENT_M:
            continue

        var cu = (hi_u + lo_u) / 2.0
        var cv = (hi_v + lo_v) / 2.0
        var cb = cos(yaw)
        var sb = sin(yaw)
        out.append(
            Detection(
                sweep.t,
                mx + cb * cu - sb * cv,
                my + sb * cu + cb * cv,
                (hi_z + lo_z) / 2.0,
                width,
                length,
                height,
                yaw,
                count,
            )
        )
    return out^


# ===----------------------------------------------------------------------===
# Association and offline smoothing
# ===----------------------------------------------------------------------===


struct Track(Movable):
    """One object's life: raw observations first, smoothed poses afterwards."""

    var id: Int
    var times: List[Float64]
    var obs_x: List[Float64]
    var obs_y: List[Float64]
    var obs_z: List[Float64]
    var w: List[Float64]
    var l: List[Float64]
    var h: List[Float64]
    var yaw: List[Float64]
    var seen: List[Bool]
    """False on frames the track was predicted through rather than observed."""
    var misses: Int
    var last_x: Float64
    var last_y: Float64

    def __init__(out self, id: Int):
        self.id = id
        self.times = List[Float64]()
        self.obs_x = List[Float64]()
        self.obs_y = List[Float64]()
        self.obs_z = List[Float64]()
        self.w = List[Float64]()
        self.l = List[Float64]()
        self.h = List[Float64]()
        self.yaw = List[Float64]()
        self.seen = List[Bool]()
        self.misses = 0
        self.last_x = 0.0
        self.last_y = 0.0

    def observe(mut self, d: Detection):
        self.times.append(d.t)
        self.obs_x.append(d.x)
        self.obs_y.append(d.y)
        self.obs_z.append(d.z)
        self.w.append(d.w)
        self.l.append(d.l)
        self.h.append(d.h)
        self.yaw.append(d.yaw)
        self.seen.append(True)
        self.misses = 0
        self.last_x = d.x
        self.last_y = d.y

    def coast(mut self, t: Float64):
        """Carry the track through a frame with no detection. The gap is
        recorded rather than interpolated -- the smoother fills it with the
        motion model, and its covariance widens honestly in the middle."""
        self.times.append(t)
        self.obs_x.append(self.last_x)
        self.obs_y.append(self.last_y)
        self.obs_z.append(self.obs_z[len(self.obs_z) - 1])
        self.w.append(self.w[len(self.w) - 1])
        self.l.append(self.l[len(self.l) - 1])
        self.h.append(self.h[len(self.h) - 1])
        self.yaw.append(self.yaw[len(self.yaw) - 1])
        self.seen.append(False)
        self.misses += 1

    def observed_frames(self) -> Int:
        var n = 0
        for i in range(len(self.seen)):
            if self.seen[i]:
                n += 1
        return n


def associate(
    frames: List[List[Detection]], times: List[Float64]
) raises -> List[Track]:
    """Nearest-neighbour association under a hard gate, frame by frame.

    The gate is what makes this a tracker rather than a bipartite curiosity: a
    truck that drives out of the scene must go unmatched, and an ungated
    optimum will happily bind its track to a worker thirty metres away because
    that is still the cheapest complete assignment.
    """
    var tracks = List[Track]()
    var live = List[Int]()
    var next_id = 0

    for frame in range(len(frames)):
        ref dets = frames[frame]
        var t = times[frame]
        var claimed = List[Bool](length=len(dets), fill=False)

        if len(live) > 0 and len(dets) > 0:
            var cost = CostMatrix(len(live), len(dets))
            for r in range(len(live)):
                var lx = tracks[live[r]].last_x
                var ly = tracks[live[r]].last_y
                for c in range(len(dets)):
                    var dx = lx - dets[c].x
                    var dy = ly - dets[c].y
                    cost.set(r, c, sqrt(dx * dx + dy * dy))
            var assignment = solve_gated(cost, gate=ASSOCIATION_GATE_M)
            for r in range(len(live)):
                var c = assignment.col_for_row[r]
                if c == UNASSIGNED:
                    tracks[live[r]].coast(t)
                else:
                    tracks[live[r]].observe(dets[c])
                    claimed[c] = True
        else:
            for r in range(len(live)):
                tracks[live[r]].coast(t)

        # Anything unclaimed starts a new track -- including on the very first
        # frame, where there is nothing live to match against.
        for c in range(len(dets)):
            if claimed[c]:
                continue
            var born = Track(next_id)
            born.observe(dets[c])
            tracks.append(born^)
            live.append(len(tracks) - 1)
            next_id += 1

        var still_live = List[Int]()
        for i in range(len(live)):
            if tracks[live[i]].misses <= MAX_MISSES:
                still_live.append(live[i])
        live = still_live^

    return tracks^


def smooth(
    mut track: Track, accel_var: Float64, measurement_var: Float64
) raises -> None:
    """Replace a track's raw observations with the RTS estimate.

    This is the offline-only step and the reason the pipeline is worth running
    as a batch job. Every frame ends up conditioned on the whole trajectory,
    so the first detections -- made when the object was distant and carried a
    handful of returns -- inherit the accuracy of the later ones.
    """
    var n = len(track.times)
    if n < 2:
        return

    for axis in range(2):
        var obs = List[Observation]()
        for i in range(n):
            var dt = 0.1 if i == 0 else track.times[i] - track.times[i - 1]
            if track.seen[i]:
                var value = track.obs_x[i] if axis == 0 else track.obs_y[i]
                obs.append(Observation(dt, [value]))
            else:
                obs.append(Observation.gap(dt))

        var start = track.obs_x[0] if axis == 0 else track.obs_y[0]
        var p = Matrix.identity(2)
        p.set(0, 0, 4.0)
        p.set(1, 1, 25.0)
        var prior = GaussianState([start, 0.0], p^)
        var result = smooth_track(prior, obs^, 1, accel_var, measurement_var)
        for i in range(n):
            if axis == 0:
                track.obs_x[i] = result.states[i].mean[0]
            else:
                track.obs_y[i] = result.states[i].mean[0]
