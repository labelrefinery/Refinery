"""Fetching one Argoverse 2 log and laying it out as a Refinery work directory.

    var meta = fetch_log("02678d04-...", "runs/av2/work/02678d04-...")

The public `argoverse` bucket is read anonymously through objectstore's S3
client, sweeps many at a time. The raw files are kept under `cache`, so a
rerun downloads nothing, and the work directory holds what `run_geometry`
reads:

    work/tf.csv              t,x,y,z,qx,qy,qz,qw   one row per sweep
    work/sweeps/index.csv    frame,t,n_points,file
    work/sweeps/NNNNNN.bin   float32 x,y,z,intensity in the ego frame
    work/annotations.csv     the log's cuboids in the same map frame (if any)
    work/meta.json           counts and the map origin; written last, so its
                             presence means the directory is complete

Two conversions matter:

* **A local map frame.** AV2 poses are in a city frame thousands of metres from
  its origin. Every translation here is relative to the first sweep's pose, so
  coordinates stay small; the rotation is the city's.
* **The ego's own returns are dropped here**, with a box around the vehicle in
  its own frame, because the excavator's forward-kinematics mask in
  `run_geometry` has nothing to say about a car (`proprioception=False`).

AV2's files are Feather v2: Arrow IPC files whose batches are LZ4-compressed,
read with arrow-mlake's `read_ipc_file` and lz4-mojo's frame decoder.
AV2 is licensed CC BY-NC-SA 4.0.
"""

from std.math import atan2, sqrt
from std.memory import bitcast
from std.os import makedirs
from std.os.path import exists

from arrow_mlake import IpcCodecs, IpcStream, LZ4_FRAME, read_ipc_file
from lz4 import compress_frame, decompress_frame
from objectstore import FileIOResolver

comptime BUCKET = "s3://argoverse/datasets/av2/"
comptime BATCH = 32
"""Objects fetched per `read_all_many` call."""

# The ego vehicle in its own frame (origin at the rear axle, x forward): a
# generous box, so roof-rack and mirror returns go too.
comptime EGO_X_LO = -1.5
comptime EGO_X_HI = 4.5
comptime EGO_Y_LO = -1.3
comptime EGO_Y_HI = 1.3
comptime EGO_Z_LO = -0.5
comptime EGO_Z_HI = 2.6


struct Lz4Codecs(IpcCodecs):
    """LZ4 frames, the compression AV2's Feather files use."""

    @staticmethod
    def compress(codec: Int, data: Span[UInt8, _]) raises -> List[UInt8]:
        if codec != LZ4_FRAME:
            raise Error("av2: only LZ4 frames, not codec ", codec)
        return compress_frame(data)

    @staticmethod
    def decompress(
        codec: Int, data: Span[UInt8, _], size: Int
    ) raises -> List[UInt8]:
        if codec != LZ4_FRAME:
            raise Error("av2: only LZ4 frames, not codec ", codec)
        return decompress_frame(data)


@fieldwise_init
struct FetchMeta(Copyable, Movable, Writable):
    var frames: Int
    var points: Int
    var ego_points_dropped: Int
    var annotations: Int
    var bytes_downloaded: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            self.frames,
            " sweeps, ",
            self.points,
            " points (",
            self.ego_points_dropped,
            " ego), ",
            self.annotations,
            " annotations, ",
            self.bytes_downloaded,
            " bytes downloaded",
        )


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _write(path: String, data: Span[UInt8, _]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


def _write_text(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _parent(path: String) -> String:
    var i = path.rfind("/")
    return String(path[byte=0:i]) if i > 0 else String(".")


def _name(key: String) -> String:
    return String(key[byte = key.rfind("/") + 1 :])


def _feather(path: String) raises -> IpcStream:
    return read_ipc_file[Lz4Codecs](Span(_read(path)))


def _cached(path: String) -> Bool:
    """A cached file that reads as a whole Feather file: a download cut off
    partway fails the magic check at its end, and is fetched again."""
    if not exists(path):
        return False
    try:
        _ = _feather(path)
        return True
    except:
        return False


def _fetch_all(
    io: FileIOResolver, keys: List[String], paths: List[String]
) raises -> Int:
    """Downloads every `keys[i]` not already cached at `paths[i]`; returns
    the bytes fetched."""
    var want_keys = List[String]()
    var want_paths = List[String]()
    for i in range(len(keys)):
        if not _cached(paths[i]):
            want_keys.append(keys[i])
            want_paths.append(paths[i])
    var fetched = 0
    var start = 0
    while start < len(want_keys):
        var end = min(start + BATCH, len(want_keys))
        var chunk = List[String]()
        for i in range(start, end):
            chunk.append(want_keys[i])
        var got = io.read_all_many(chunk)
        for i in range(start, end):
            var dir = _parent(want_paths[i])
            if not exists(dir):
                makedirs(dir)
            _write(want_paths[i], Span(got[i - start]))
            fetched += len(got[i - start])
        start = end
    return fetched


struct _Rotation(Copyable, Movable):
    """A unit quaternion as a 3×3 matrix, row-major."""

    var m: List[Float64]

    def __init__(out self, qw: Float64, qx: Float64, qy: Float64, qz: Float64):
        self.m = List[Float64](length=9, fill=0.0)
        self.m[0] = 1 - 2 * (qy * qy + qz * qz)
        self.m[1] = 2 * (qx * qy - qz * qw)
        self.m[2] = 2 * (qx * qz + qy * qw)
        self.m[3] = 2 * (qx * qy + qz * qw)
        self.m[4] = 1 - 2 * (qx * qx + qz * qz)
        self.m[5] = 2 * (qy * qz - qx * qw)
        self.m[6] = 2 * (qx * qz - qy * qw)
        self.m[7] = 2 * (qy * qz + qx * qw)
        self.m[8] = 1 - 2 * (qx * qx + qy * qy)

    def apply(
        self, x: Float64, y: Float64, z: Float64
    ) -> Tuple[Float64, Float64, Float64]:
        return (
            self.m[0] * x + self.m[1] * y + self.m[2] * z,
            self.m[3] * x + self.m[4] * y + self.m[5] * z,
            self.m[6] * x + self.m[7] * y + self.m[8] * z,
        )

    def then(self, other: _Rotation) -> _Rotation:
        """`self × other`."""
        var r = _Rotation(1.0, 0.0, 0.0, 0.0)
        for i in range(3):
            for j in range(3):
                var v = 0.0
                for k in range(3):
                    v += self.m[i * 3 + k] * other.m[k * 3 + j]
                r.m[i * 3 + j] = v
        return r^


def _put_f32(mut out: List[UInt8], v: Float32):
    """Appends `v` little-endian, as the sweep files hold it."""
    var u = bitcast[DType.uint32](v)
    for i in range(4):
        out.append(UInt8((u >> UInt32(8 * i)) & 0xFF))


def _fixed(v: Float64, places: Int) -> Float64:
    """`v` rounded to `places` decimals, as the CSVs carry it."""
    var scale = 10.0**places
    var s = v * scale
    return Float64(Int(s + 0.5) if s >= 0.0 else Int(s - 0.5)) / scale


def _f64s(s: IpcStream, name: String) raises -> List[Float64]:
    var out = List[Float64]()
    for b in s.batches:
        for c in range(b.num_columns()):
            if b.name(c) == name:
                out.extend(b.column_f64(c)[0].copy())
    return out^


def _i64s(s: IpcStream, name: String) raises -> List[Int64]:
    var out = List[Int64]()
    for b in s.batches:
        for c in range(b.num_columns()):
            if b.name(c) == name:
                out.extend(b.column_i64(c)[0].copy())
    return out^


def _strs(s: IpcStream, name: String) raises -> List[String]:
    var out = List[String]()
    for b in s.batches:
        for c in range(b.num_columns()):
            if b.name(c) == name:
                out.extend(b.column_str(c)[0].copy())
    return out^


def _pose_index(
    stamps: List[Int64], by_ts: Dict[Int, Int], ts: Int
) raises -> Int:
    """The pose at `ts`: lidar stamps have one exactly; else the nearest."""
    if ts in by_ts:
        return by_ts[ts]
    var best = 0
    var gap = Int64.MAX
    for i in range(len(stamps)):
        var d = abs(stamps[i] - Int64(ts))
        if d < gap:
            gap = d
            best = i
    return best


def fetch_log(
    log_id: String,
    work: String,
    prefix: String = "sensor/val",
    cache: String = "runs/av2/cache",
    max_sweeps: Int = 0,
) raises -> FetchMeta:
    """Downloads `log_id` from `prefix` (the split under `datasets/av2/`) and
    writes `work` (see the module), overwriting what is there."""
    var io = FileIOResolver()
    io.set("s3.region", "us-east-1")
    var base = String(BUCKET, prefix, "/", log_id, "/")
    var raw = String(cache, "/", prefix, "/", log_id)

    var lidar = List[String]()
    for k in io.list(base + "sensors/lidar/"):
        if k.endswith(".feather"):
            lidar.append(String(base, "sensors/lidar/", _name(k)))
    if len(lidar) == 0:
        raise Error("av2: no sweeps under " + base + "sensors/lidar/")
    sort(lidar)
    if max_sweeps > 0 and len(lidar) > max_sweeps:
        lidar.resize(max_sweeps, String())

    var keys = lidar.copy()
    var paths = List[String]()
    for k in lidar:
        paths.append(String(raw, "/sensors/lidar/", _name(k)))
    keys.append(base + "city_SE3_egovehicle.feather")
    paths.append(raw + "/city_SE3_egovehicle.feather")
    var has_annotations = io.new_input(base + "annotations.feather").exists()
    if has_annotations:
        keys.append(base + "annotations.feather")
        paths.append(raw + "/annotations.feather")
    var fetched = _fetch_all(io, keys, paths)

    var poses = _feather(raw + "/city_SE3_egovehicle.feather")
    var p_ts = _i64s(poses, "timestamp_ns")
    var p_qw = _f64s(poses, "qw")
    var p_qx = _f64s(poses, "qx")
    var p_qy = _f64s(poses, "qy")
    var p_qz = _f64s(poses, "qz")
    var p_tx = _f64s(poses, "tx_m")
    var p_ty = _f64s(poses, "ty_m")
    var p_tz = _f64s(poses, "tz_m")
    var by_ts = Dict[Int, Int]()
    for i in range(len(p_ts)):
        by_ts[Int(p_ts[i])] = i

    var stamps = List[Int]()
    for k in lidar:
        var n = _name(k)
        stamps.append(Int(n[byte = 0 : n.find(".")]))
    var i0 = _pose_index(p_ts, by_ts, stamps[0])
    var ox = p_tx[i0]
    var oy = p_ty[i0]
    var oz = p_tz[i0]

    var sweeps = work + "/sweeps"
    if not exists(sweeps):
        makedirs(sweeps)
    var tf = String("t,x,y,z,qx,qy,qz,qw\n")
    var index = String("frame,t,n_points,file\n")
    var total = 0
    var kept = 0
    for f in range(len(lidar)):
        var s = _feather(paths[f])
        var x = _f64s(s, "x")
        var y = _f64s(s, "y")
        var z = _f64s(s, "z")
        var inten = _i64s(s, "intensity")
        var pts = List[UInt8](capacity=len(x) * 16)
        for i in range(len(x)):
            if (
                x[i] > EGO_X_LO
                and x[i] < EGO_X_HI
                and y[i] > EGO_Y_LO
                and y[i] < EGO_Y_HI
                and z[i] > EGO_Z_LO
                and z[i] < EGO_Z_HI
            ):
                continue
            _put_f32(pts, Float32(x[i]))
            _put_f32(pts, Float32(y[i]))
            _put_f32(pts, Float32(z[i]))
            _put_f32(pts, Float32(inten[i]))
        var n = len(pts) // 16
        total += len(x)
        kept += n
        var name = String(f)
        while name.byte_length() < 6:
            name = "0" + name
        name += ".bin"
        _write(sweeps + "/" + name, Span(pts))
        var rel = _fixed(Float64(stamps[f] - stamps[0]) / 1e9, 4)
        index.write(f, ",", rel, ",", n, ",", name, "\n")
        var i = _pose_index(p_ts, by_ts, stamps[f])
        tf.write(
            rel,
            ",",
            _fixed(p_tx[i] - ox, 6),
            ",",
            _fixed(p_ty[i] - oy, 6),
            ",",
            _fixed(p_tz[i] - oz, 6),
            ",",
            _fixed(p_qx[i], 9),
            ",",
            _fixed(p_qy[i], 9),
            ",",
            _fixed(p_qz[i], 9),
            ",",
            _fixed(p_qw[i], 9),
            "\n",
        )
    _write_text(work + "/tf.csv", tf)
    _write_text(sweeps + "/index.csv", index)

    var n_ann = 0
    if has_annotations:
        var a = _feather(raw + "/annotations.feather")
        var a_ts = _i64s(a, "timestamp_ns")
        var a_uuid = _strs(a, "track_uuid")
        var a_cat = _strs(a, "category")
        var a_l = _f64s(a, "length_m")
        var a_w = _f64s(a, "width_m")
        var a_h = _f64s(a, "height_m")
        var a_qw = _f64s(a, "qw")
        var a_qx = _f64s(a, "qx")
        var a_qy = _f64s(a, "qy")
        var a_qz = _f64s(a, "qz")
        var a_tx = _f64s(a, "tx_m")
        var a_ty = _f64s(a, "ty_m")
        var a_tz = _f64s(a, "tz_m")
        var a_pts = _i64s(a, "num_interior_pts")
        var first = stamps[0]
        var last = stamps[len(stamps) - 1]
        var out = String(
            "t,track_uuid,category,x,y,z,l,w,h,yaw,num_points,range_m\n"
        )
        for j in range(len(a_ts)):
            var ts = Int(a_ts[j])
            if ts < first or ts > last:
                continue
            var i = _pose_index(p_ts, by_ts, ts)
            var r = _Rotation(p_qw[i], p_qx[i], p_qy[i], p_qz[i])
            var c = r.apply(a_tx[j], a_ty[j], a_tz[j])
            var ra = _Rotation(a_qw[j], a_qx[j], a_qy[j], a_qz[j])
            var heading = r.then(ra).apply(1.0, 0.0, 0.0)
            out.write(
                _fixed(Float64(ts - first) / 1e9, 4),
                ",",
                a_uuid[j],
                ",",
                a_cat[j],
                ",",
                _fixed(c[0] + p_tx[i] - ox, 4),
                ",",
                _fixed(c[1] + p_ty[i] - oy, 4),
                ",",
                _fixed(c[2] + p_tz[i] - oz, 4),
                ",",
                _fixed(a_l[j], 4),
                ",",
                _fixed(a_w[j], 4),
                ",",
                _fixed(a_h[j], 4),
                ",",
                _fixed(atan2(heading[1], heading[0]), 5),
                ",",
                a_pts[j],
                ",",
                _fixed(sqrt(a_tx[j] * a_tx[j] + a_ty[j] * a_ty[j]), 3),
                "\n",
            )
            n_ann += 1
        _write_text(work + "/annotations.csv", out)

    var meta = FetchMeta(len(lidar), total, total - kept, n_ann, fetched)
    _write_text(
        work + "/meta.json",
        String(
            '{"log_id": "',
            log_id,
            '", "prefix": "',
            prefix,
            '", "frames": ',
            meta.frames,
            ', "points": ',
            meta.points,
            ', "ego_points_dropped": ',
            meta.ego_points_dropped,
            ', "annotations": ',
            meta.annotations,
            ', "origin_city_m": [',
            ox,
            ", ",
            oy,
            ", ",
            oz,
            '], "bytes_downloaded": ',
            meta.bytes_downloaded,
            "}\n",
        ),
    )
    return meta^
