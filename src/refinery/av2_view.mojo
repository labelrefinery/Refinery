"""A log's view bundle: what the slice viewer (`src/av2_viewer.mojo`) shows,
published from the work directory before the instance that made it is gone.

    var n = publish_view(work, "02678d04-...", "s3://bucket/views/av2")

Under `<root>/<log_id>/`:

    tf.csv            the ego's pose per sweep, in the log's local map frame
    sweeps.csv        frame,t,n_points,file (the work directory's index)
    annotations.csv   the log's cuboids (if it has any)
    tracks.csv        Pipeline A's tracks
    points/NNNNNN.bin each sweep's points, int16 little-endian x,y,z in
                      centimetres in the ego frame and intensity, 8 bytes a
                      point; every `stride`-th point within `max_range`
    view.json         counts; written last, so its presence means the
                      bundle is complete

The root is a directory or a location in object storage (`s3://...`),
written through objectstore's `FileIOResolver`. A sweep is about 0.6 MB this
way, against 1.4 MB as the float32 work file, and loads into a browser as an
`Int16Array` with no parsing.
"""

from std.math import sqrt
from std.memory import bitcast
from std.os import makedirs
from std.os.path import exists
from std.ffi import external_call

from objectstore import FileIOResolver

from .io import read_csv_rows

comptime MAX_RANGE_M = 80.0
comptime STRIDE = 2
"""AV2's two stacked lidars give about 90,000 points a sweep; half of them
draw the same scene at half the download."""


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _f32(data: List[UInt8], at: Int) -> Float32:
    var u = (
        UInt32(data[at])
        | (UInt32(data[at + 1]) << 8)
        | (UInt32(data[at + 2]) << 16)
        | (UInt32(data[at + 3]) << 24)
    )
    return bitcast[DType.float32](u)


def _put_i16(mut out: List[UInt8], v: Int):
    var c = max(-32768, min(32767, v))
    var u = UInt16(c & 0xFFFF)
    out.append(UInt8(u & 0xFF))
    out.append(UInt8(u >> 8))


def _cm(v: Float32) -> Int:
    var s = Float64(v) * 100.0
    return Int(s + 0.5) if s >= 0.0 else Int(s - 0.5)


def quantize_sweep(
    data: List[UInt8],
    max_range: Float64 = MAX_RANGE_M,
    stride: Int = STRIDE,
) -> List[UInt8]:
    """A float32 x,y,z,intensity sweep as the bundle's int16 points: every
    `stride`-th point, of those within `max_range` of the ego."""
    var n = len(data) // 16
    var out = List[UInt8](capacity=n * 8 // max(stride, 1))
    for i in range(0, n, max(stride, 1)):
        var x = _f32(data, i * 16)
        var y = _f32(data, i * 16 + 4)
        var z = _f32(data, i * 16 + 8)
        var inten = _f32(data, i * 16 + 12)
        var r = sqrt(Float64(x) * Float64(x) + Float64(y) * Float64(y))
        if r > max_range:
            continue
        _put_i16(out, _cm(x))
        _put_i16(out, _cm(y))
        _put_i16(out, _cm(z))
        _put_i16(out, Int(inten))
    return out^


def _absolute(path: String) raises -> String:
    if path.startswith("/"):
        return path
    var buf = List[UInt8](length=4096, fill=0)
    var r = external_call["getcwd", Int](buf.unsafe_ptr(), Int(4096))
    if r == 0:
        raise Error("av2_view: getcwd failed")
    var n = 0
    while buf[n] != 0:
        n += 1
    var cwd = String(from_utf8_lossy=Span(buf)[:n])
    return String(cwd, "/", path.removeprefix("./"))


def _location(root: String) raises -> String:
    """A root objectstore resolves: a URI as it is, a path as `file://`."""
    if "://" in root:
        return String(root.rstrip("/"))
    if not exists(root):
        makedirs(root)
    return String("file://", _absolute(root).rstrip("/"))


struct _Sink(Movable):
    var io: FileIOResolver
    var base: String
    var local: Bool
    var bytes: Int

    def __init__(out self, root: String, log_id: String) raises:
        self.io = FileIOResolver()
        self.base = String(_location(root), "/", log_id)
        self.local = self.base.startswith("file://")
        self.bytes = 0
        if self.local:
            var dir = String(self.base.removeprefix("file://"), "/points")
            if not exists(dir):
                makedirs(dir)

    def put(mut self, name: String, data: Span[UInt8, _]) raises:
        self.io.new_output(String(self.base, "/", name)).overwrite(data)
        self.bytes += len(data)

    def put_file(mut self, name: String, path: String) raises:
        var data = _read(path)
        self.put(name, Span(data))


def publish_view(
    work: String,
    log_id: String,
    root: String,
    max_range: Float64 = MAX_RANGE_M,
    stride: Int = STRIDE,
) raises -> Int:
    """Writes `log_id`'s bundle from `work` under `root` (see the module);
    returns the bytes written."""
    var sink = _Sink(root, log_id)
    var sweeps = read_csv_rows(work + "/sweeps/index.csv")
    var points = 0
    for r in sweeps:
        # frame,t,n_points,file
        var q = quantize_sweep(
            _read(work + "/sweeps/" + r[3]), max_range, stride
        )
        points += len(q) // 8
        sink.put("points/" + r[3], Span(q))
    sink.put_file("sweeps.csv", work + "/sweeps/index.csv")
    sink.put_file("tf.csv", work + "/tf.csv")
    sink.put_file("tracks.csv", work + "/tracks.csv")
    var annotated = exists(work + "/annotations.csv")
    if annotated:
        sink.put_file("annotations.csv", work + "/annotations.csv")
    var meta = String(
        '{"log_id": "',
        log_id,
        '", "frames": ',
        len(sweeps),
        ", \"points\": ",
        points,
        ', "max_range_m": ',
        max_range,
        ', "stride": ',
        stride,
        ', "annotations": ',
        "true" if annotated else "false",
        ', "point_format": "int16 x,y,z cm (ego frame), intensity"}\n',
    )
    sink.put("view.json", meta.as_bytes())
    return sink.bytes
