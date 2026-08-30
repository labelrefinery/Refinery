"""Reading what sitegen exports.

Sweeps are raw float32 `x, y, z, intensity` per frame, so this is a byte
reinterpret rather than a parse. Everything else is small enough to be CSV.
"""

from std.math import sqrt, atan2


comptime POINT_STRIDE = 4
"""float32 values per point: x, y, z, intensity."""


struct Pose(ImplicitlyCopyable, Movable):
    """A sensor pose in the map frame: rotation matrix plus translation.

    Stored as loose scalars rather than an `Array`, which is not implicitly
    copyable -- and a pose is copied into every point transform, so paying an
    explicit copy there would be silly.
    """

    var r0: Float64
    var r1: Float64
    var r2: Float64
    var r3: Float64
    var r4: Float64
    var r5: Float64
    var r6: Float64
    var r7: Float64
    var r8: Float64
    var tx: Float64
    var ty: Float64
    var tz: Float64

    def __init__(out self):
        self.r0 = 1.0
        self.r1 = 0.0
        self.r2 = 0.0
        self.r3 = 0.0
        self.r4 = 1.0
        self.r5 = 0.0
        self.r6 = 0.0
        self.r7 = 0.0
        self.r8 = 1.0
        self.tx = 0.0
        self.ty = 0.0
        self.tz = 0.0

    def apply_x(self, x: Float64, y: Float64, z: Float64) -> Float64:
        return self.r0 * x + self.r1 * y + self.r2 * z + self.tx

    def apply_y(self, x: Float64, y: Float64, z: Float64) -> Float64:
        return self.r3 * x + self.r4 * y + self.r5 * z + self.ty

    def apply_z(self, x: Float64, y: Float64, z: Float64) -> Float64:
        return self.r6 * x + self.r7 * y + self.r8 * z + self.tz

    def yaw(self) -> Float64:
        return atan2(self.r3, self.r0)


def pose_from_quaternion(
    x: Float64,
    y: Float64,
    z: Float64,
    qx: Float64,
    qy: Float64,
    qz: Float64,
    qw: Float64,
) -> Pose:
    var p = Pose()
    p.tx = x
    p.ty = y
    p.tz = z
    p.r0 = 1.0 - 2.0 * (qy * qy + qz * qz)
    p.r1 = 2.0 * (qx * qy - qz * qw)
    p.r2 = 2.0 * (qx * qz + qy * qw)
    p.r3 = 2.0 * (qx * qy + qz * qw)
    p.r4 = 1.0 - 2.0 * (qx * qx + qz * qz)
    p.r5 = 2.0 * (qy * qz - qx * qw)
    p.r6 = 2.0 * (qx * qz - qy * qw)
    p.r7 = 2.0 * (qy * qz + qx * qw)
    p.r8 = 1.0 - 2.0 * (qx * qx + qy * qy)
    return p^


struct Sweep(Movable, Sized):
    """One rotation's points, already lifted into the map frame."""

    var t: Float64
    var x: List[Float64]
    var y: List[Float64]
    var z: List[Float64]

    def __init__(out self, t: Float64):
        self.t = t
        self.x = List[Float64]()
        self.y = List[Float64]()
        self.z = List[Float64]()

    def __len__(self) -> Int:
        return len(self.x)


def split_line(line: String, sep: String) -> List[String]:
    var out = List[String]()
    for part in line.split(sep):
        out.append(String(part))
    return out^


def read_csv_rows(path: String) raises -> List[List[String]]:
    """Every non-empty line after the header, split on commas."""
    var handle = open(path, "r")
    var text = handle.read()
    handle.close()

    var rows = List[List[String]]()
    var first = True
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            continue
        if first:
            first = False
            continue
        rows.append(split_line(line, ","))
    return rows^


def read_poses(path: String) raises -> List[Pose]:
    """tf.csv: t,x,y,z,qx,qy,qz,qw."""
    var rows = read_csv_rows(path)
    var out = List[Pose]()
    for i in range(len(rows)):
        ref r = rows[i]
        out.append(
            pose_from_quaternion(
                Float64(r[1]),
                Float64(r[2]),
                Float64(r[3]),
                Float64(r[4]),
                Float64(r[5]),
                Float64(r[6]),
                Float64(r[7]),
            )
        )
    return out^


struct Joints(ImplicitlyCopyable, Movable):
    var t: Float64
    var swing: Float64
    var boom: Float64
    var stick: Float64
    var bucket: Float64

    def __init__(
        out self,
        t: Float64,
        swing: Float64,
        boom: Float64,
        stick: Float64,
        bucket: Float64,
    ):
        self.t = t
        self.swing = swing
        self.boom = boom
        self.stick = stick
        self.bucket = bucket


def read_joints(path: String) raises -> List[Joints]:
    """joints.csv: t,swing,boom,stick,bucket -- the free supervision."""
    var rows = read_csv_rows(path)
    var out = List[Joints]()
    for i in range(len(rows)):
        ref r = rows[i]
        out.append(
            Joints(
                Float64(r[0]),
                Float64(r[1]),
                Float64(r[2]),
                Float64(r[3]),
                Float64(r[4]),
            )
        )
    return out^


def read_sweep(
    directory: String, filename: String, t: Float64, pose: Pose
) raises -> Sweep:
    """Load one frame and lift it into the map frame in the same pass."""
    var handle = open(directory + "/" + filename, "r")
    var raw = handle.read_bytes()
    handle.close()

    var count = len(raw) // (4 * POINT_STRIDE)
    var floats = raw.unsafe_ptr().unsafe_bitcast[Float32]()
    var sweep = Sweep(t)
    for i in range(count):
        var base = i * POINT_STRIDE
        var lx = Float64(floats.unsafe_load(base))
        var ly = Float64(floats.unsafe_load(base + 1))
        var lz = Float64(floats.unsafe_load(base + 2))
        sweep.x.append(pose.apply_x(lx, ly, lz))
        sweep.y.append(pose.apply_y(lx, ly, lz))
        sweep.z.append(pose.apply_z(lx, ly, lz))
    return sweep^
