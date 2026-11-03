"""Scoring Pipeline A's tracks against an Argoverse 2 log's annotations.

Pipeline A is class-agnostic: it finds things that stand off the ground and
follows them, and names nothing. So the score is too. Per sweep, each annotated
cuboid near enough to see is matched to at most one track position by
bird's-eye-view centre distance, under a gate (Hungarian.mojo's `solve_gated`,
the same solver the tracker associates with), and:

- **recall** is the share of annotated objects matched;
- **movable recall** is the same over the classes that move (vehicles, riders,
  pedestrians, animals), the ones a cold-start labeler is for;
- **precision** is the share of track positions that matched something. AV2
  doesn't annotate walls, trees or poles, which a geometric clusterer does
  find, so this is a floor on precision, not a measure of it.

Both inputs are what `scripts/av2_fetch.py` and `run_geometry` write, in one
local map frame: `annotations.csv`, `tracks.csv` and `tf.csv` (for the ego's
position at each sweep, which bounds a track's range the way `range_m` bounds
an annotation's).
"""

from std.math import sqrt

from hungarian import CostMatrix, solve_gated, UNASSIGNED

from .io import read_csv_rows

comptime MAX_RANGE_M = 50.0
"""Objects further than this from the ego are left out on both sides."""
comptime MIN_POINTS = 5
"""Annotations with fewer interior lidar returns than this are left out: the
clusterer needs six points to call anything a cluster."""
comptime MATCH_GATE_M = 2.0


def is_movable(category: String) -> Bool:
    """The classes that move: vehicles, riders, pedestrians, animals."""
    return (
        category == "REGULAR_VEHICLE"
        or category == "LARGE_VEHICLE"
        or category == "BUS"
        or category == "BOX_TRUCK"
        or category == "TRUCK"
        or category == "TRUCK_CAB"
        or category == "VEHICULAR_TRAILER"
        or category == "SCHOOL_BUS"
        or category == "ARTICULATED_BUS"
        or category == "MOTORCYCLE"
        or category == "MOTORCYCLIST"
        or category == "BICYCLE"
        or category == "BICYCLIST"
        or category == "PEDESTRIAN"
        or category == "WHEELED_RIDER"
        or category == "WHEELED_DEVICE"
        or category == "STROLLER"
        or category == "WHEELCHAIR"
        or category == "DOG"
        or category == "OFFICIAL_SIGNALER"
    )


@fieldwise_init
struct Av2Score(Copyable, Movable, Writable):
    var frames: Int
    var annotated: Int
    """Annotated objects in range with enough points, summed over sweeps."""
    var annotated_movable: Int
    var predicted: Int
    """Track positions in range, summed over sweeps."""
    var matched: Int
    var matched_movable: Int
    var center_error_m: Float64
    """Mean BEV centre distance over matches."""

    def recall(self) -> Float64:
        return Float64(self.matched) / Float64(max(self.annotated, 1))

    def movable_recall(self) -> Float64:
        return Float64(self.matched_movable) / Float64(
            max(self.annotated_movable, 1)
        )

    def precision(self) -> Float64:
        return Float64(self.matched) / Float64(max(self.predicted, 1))

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "frames ",
            self.frames,
            " | recall ",
            self.recall(),
            " (",
            self.matched,
            "/",
            self.annotated,
            ") | movable recall ",
            self.movable_recall(),
            " (",
            self.matched_movable,
            "/",
            self.annotated_movable,
            ") | precision floor ",
            self.precision(),
            " (",
            self.matched,
            "/",
            self.predicted,
            ") | centre error ",
            self.center_error_m,
            " m",
        )


def _frame_key(t: String) raises -> Int:
    """Sweep times are written to 4 decimals; this makes them exact keys."""
    var v = Float64(t) * 10_000.0
    return Int(v + 0.5) if v >= 0.0 else Int(v - 0.5)


def _col(header: List[String], name: String) raises -> Int:
    for i in range(len(header)):
        if header[i] == name:
            return i
    raise Error("no column " + name)


def _header(path: String) raises -> List[String]:
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var line = text.split("\n")[0]
    var out = List[String]()
    for c in line.strip().split(","):
        out.append(String(c))
    return out^


def score_log(
    work: String,
    tracks_csv: String,
    max_range: Float64 = MAX_RANGE_M,
    min_points: Int = MIN_POINTS,
    gate: Float64 = MATCH_GATE_M,
) raises -> Av2Score:
    """Scores `tracks_csv` against `work/annotations.csv` (see the module)."""
    # The ego's position per sweep, for the range of a track position.
    var ego = Dict[Int, Tuple[Float64, Float64]]()
    for r in read_csv_rows(work + "/tf.csv"):
        ego[_frame_key(r[0])] = (Float64(r[1]), Float64(r[2]))

    var ah = _header(work + "/annotations.csv")
    var a_t = _col(ah, "t")
    var a_cat = _col(ah, "category")
    var a_x = _col(ah, "x")
    var a_y = _col(ah, "y")
    var a_pts = _col(ah, "num_points")
    var a_rng = _col(ah, "range_m")
    var gt_x = Dict[Int, List[Float64]]()
    var gt_y = Dict[Int, List[Float64]]()
    var gt_mov = Dict[Int, List[Bool]]()
    for r in read_csv_rows(work + "/annotations.csv"):
        if Int(r[a_pts]) < min_points or Float64(r[a_rng]) > max_range:
            continue
        var k = _frame_key(r[a_t])
        if k not in gt_x:
            gt_x[k] = List[Float64]()
            gt_y[k] = List[Float64]()
            gt_mov[k] = List[Bool]()
        gt_x[k].append(Float64(r[a_x]))
        gt_y[k].append(Float64(r[a_y]))
        gt_mov[k].append(is_movable(r[a_cat]))

    var th = _header(tracks_csv)
    var t_t = _col(th, "t")
    var t_x = _col(th, "x")
    var t_y = _col(th, "y")
    var pr_x = Dict[Int, List[Float64]]()
    var pr_y = Dict[Int, List[Float64]]()
    for r in read_csv_rows(tracks_csv):
        var k = _frame_key(r[t_t])
        if k not in ego:
            continue
        var x = Float64(r[t_x])
        var y = Float64(r[t_y])
        var e = ego[k]
        var dx = x - e[0]
        var dy = y - e[1]
        if sqrt(dx * dx + dy * dy) > max_range:
            continue
        if k not in pr_x:
            pr_x[k] = List[Float64]()
            pr_y[k] = List[Float64]()
        pr_x[k].append(x)
        pr_y[k].append(y)

    var s = Av2Score(len(ego), 0, 0, 0, 0, 0, 0.0)
    var err = 0.0
    for entry in ego.items():
        var k = entry.key
        var n_gt = len(gt_x[k]) if k in gt_x else 0
        var n_pr = len(pr_x[k]) if k in pr_x else 0
        s.predicted += n_pr
        if n_gt == 0:
            continue
        s.annotated += n_gt
        for i in range(n_gt):
            if gt_mov[k][i]:
                s.annotated_movable += 1
        if n_pr == 0:
            continue
        var cost = CostMatrix(n_gt, n_pr)
        for i in range(n_gt):
            for j in range(n_pr):
                var dx = gt_x[k][i] - pr_x[k][j]
                var dy = gt_y[k][i] - pr_y[k][j]
                cost.set(i, j, sqrt(dx * dx + dy * dy))
        var a = solve_gated(cost, gate=gate)
        for i in range(n_gt):
            var j = a.col_for_row[i]
            if j == UNASSIGNED:
                continue
            s.matched += 1
            if gt_mov[k][i]:
                s.matched_movable += 1
            err += cost.get(i, j)
    s.center_error_m = err / Float64(max(s.matched, 1))
    return s^
