"""The AV2 slice viewer: Pipeline A's tracks over a log's lidar, beside the
log's scores, for any slice of sweeps of any scored log.

    pixi run -e orca av2-viewer                # http://127.0.0.1:8280

Pages and data:

- `/` is the page (`viewer/index.html`): the scored logs as a table, and for
  the one selected, a 3D view of a slice of its sweeps (points, annotated
  cuboids, track boxes) with a slider and play.
- `/api/logs` is `av2.scores_a` as JSON, one object per log (its latest
  score, by tracks snapshot), with the run totals. It's read at the table's
  current snapshot and kept until the table gets another.
- `/data/<log_id>/<file>` is a file of the log's view bundle
  (`refinery.av2_view`), read from `AV2_VIEWS` (a directory or `s3://...`):
  `view.json`, `tf.csv`, `sweeps.csv`, `annotations.csv`, `tracks.csv` or
  `points/NNNNNN.bin`, nothing else.

Environment: `ORCA_WAREHOUSE`, `AV2_VIEWS` (default `runs/av2/views`),
`AV2_VIEWER_ADDR` (default `127.0.0.1:8280`), `AV2_VIEWER_ASSETS` (the
directory holding `index.html`, default `viewer`). Everything is read-only:
it answers `GET` and `HEAD` and nothing else, so it can be public.
"""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.os.path import exists

from flare.http import Handler, HttpServer, Request, Response, ServerConfig
from flare.net import SocketAddr
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.io import FileIO
from objectstore import FileIOResolver

comptime DEFAULT_ADDR = "127.0.0.1:8280"


def _env(name: StaticString, fallback: StaticString) -> String:
    var v = getenv(name)
    return v if v else String(fallback)


def valid_log_id(id: String) -> Bool:
    """An AV2 log ID: 36 characters of lowercase hex and dashes."""
    if id.byte_length() != 36:
        return False
    for byte in id.as_bytes():
        var b = Int(byte)
        var hex = (b >= ord("0") and b <= ord("9")) or (
            b >= ord("a") and b <= ord("f")
        )
        if not hex and b != ord("-"):
            return False
    return True


def valid_bundle_file(name: String) -> Bool:
    """One of the bundle's named files, or `points/` and six digits `.bin`."""
    if (
        name == "view.json"
        or name == "tf.csv"
        or name == "sweeps.csv"
        or name == "annotations.csv"
        or name == "tracks.csv"
    ):
        return True
    if not name.startswith("points/") or not name.endswith(".bin"):
        return False
    if name.byte_length() != 17:
        return False
    for byte in name.as_bytes()[7:13]:
        var b = Int(byte)
        if b < ord("0") or b > ord("9"):
            return False
    return True


def _json_string(s: String) -> String:
    var out = String('"')
    for byte in s.as_bytes():
        var b = Int(byte)
        if b == ord('"'):
            out += '\\"'
        elif b == ord("\\"):
            out += "\\\\"
        elif b < 0x20:
            out += " "
        else:
            out += chr(b)
    out += '"'
    return out^


def _catalog(root: String) raises -> FilesystemCatalog:
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(String(root.rstrip("/")), FileIO())
    return FilesystemCatalog.local(root)


@fieldwise_init
struct _Row(Copyable, Movable):
    var log_id: String
    var frames: Int64
    var annotated: Int64
    var annotated_movable: Int64
    var predicted: Int64
    var matched: Int64
    var matched_movable: Int64
    var center_error_m: Float64
    var label_seconds: Float64
    var tracks_snapshot: Int64


def scores_json(warehouse: String) raises -> Tuple[Int64, String]:
    """`av2.scores_a` at its current snapshot, as `/api/logs` answers it,
    with the snapshot's ID (-1 when there's no table or no snapshot)."""
    var cat = _catalog(warehouse)
    if not cat.table_exists("av2", "scores_a"):
        return (Int64(-1), String('{"snapshot": null, "logs": []}'))
    var t = cat.load_table("av2", "scores_a")
    if not t.metadata.has_current_snapshot:
        return (Int64(-1), String('{"snapshot": null, "logs": []}'))
    var snap = t.metadata.current_snapshot_id
    var res = t.scan().use_snapshot(snap).to_table()
    var latest = Dict[String, _Row]()
    for r in range(res.num_rows()):
        var row = _Row(
            res.value(r, 0).s,
            res.value(r, 1).i,
            res.value(r, 2).i,
            res.value(r, 3).i,
            res.value(r, 4).i,
            res.value(r, 5).i,
            res.value(r, 6).i,
            res.value(r, 7).f,
            res.value(r, 8).f,
            res.value(r, 9).i,
        )
        if (
            row.log_id not in latest
            or latest[row.log_id].tracks_snapshot < row.tracks_snapshot
        ):
            latest[row.log_id] = row^
    var ids = List[String]()
    for k in latest.keys():
        ids.append(k)
    sort(ids)
    var out = String('{"snapshot": ', snap, ', "logs": [')
    var first = True
    for id in ids:
        ref r = latest[id]
        if not first:
            out += ", "
        first = False
        out.write(
            '{"log_id": ',
            _json_string(r.log_id),
            ', "frames": ',
            r.frames,
            ', "annotated": ',
            r.annotated,
            ', "annotated_movable": ',
            r.annotated_movable,
            ', "predicted": ',
            r.predicted,
            ', "matched": ',
            r.matched,
            ', "matched_movable": ',
            r.matched_movable,
            ', "center_error_m": ',
            r.center_error_m,
            ', "label_seconds": ',
            r.label_seconds,
            ', "tracks_snapshot": ',
            r.tracks_snapshot,
            "}",
        )
    out += "]}"
    return (snap, out^)


struct _Cache(Movable):
    var snapshot: Int64
    var json: String

    def __init__(out self):
        self.snapshot = -2
        self.json = String()


def _location(root: String) raises -> String:
    if "://" in root:
        return String(root.rstrip("/"))
    if root.startswith("/"):
        return String("file://", root.rstrip("/"))
    var buf = List[UInt8](length=4096, fill=0)
    _ = external_call["getcwd", Int](buf.unsafe_ptr(), Int(4096))
    var n = 0
    while buf[n] != 0:
        n += 1
    var cwd = String(from_utf8_lossy=Span(buf)[:n])
    return String("file://", cwd, "/", root.removeprefix("./").rstrip("/"))


def _content_type(name: String) -> String:
    if name.endswith(".json"):
        return "application/json"
    if name.endswith(".csv"):
        return "text/csv; charset=utf-8"
    if name.endswith(".html"):
        return "text/html; charset=utf-8"
    return "application/octet-stream"


def _response(
    status: Int, var body: List[UInt8], content_type: String, cache: String
) -> Response:
    var reason = String("OK")
    if status == 404:
        reason = "Not Found"
    elif status == 405:
        reason = "Method Not Allowed"
    elif status == 500:
        reason = "Internal Server Error"
    var resp = Response(status=status, reason=reason, body=body^)
    try:
        resp.headers.set("Content-Type", content_type)
        resp.headers.set("Cache-Control", cache)
        resp.headers.set("X-Content-Type-Options", "nosniff")
    except:
        pass
    return resp^


def _text(status: Int, msg: String) -> Response:
    return _response(
        status, List[UInt8](msg.as_bytes()), "text/plain; charset=utf-8", "no-store"
    )


struct Viewer(Copyable, Handler):
    """The viewer's pages, over the warehouse and the bundles' root."""

    var warehouse: String
    var views: String
    var page: String
    var cache: Pointer[_Cache, MutUntrackedOrigin]
    """This copy's scores, by snapshot: each worker thread has its own copy
    of the handler, so its own cache, and nothing is shared between them."""

    def __init__(out self, warehouse: String, views: String, page: String) raises:
        self.warehouse = warehouse
        self.views = _location(views)
        self.page = page
        self.cache = unsafe_alloc[_Cache](1)
        self.cache.unsafe_write(_Cache())

    def __init__(out self, *, copy: Self):
        self.warehouse = copy.warehouse
        self.views = copy.views
        self.page = copy.page
        self.cache = unsafe_alloc[_Cache](1)
        self.cache.unsafe_write(_Cache())

    def serve(self, req: Request) raises -> Response:
        if req.method != "GET" and req.method != "HEAD":
            return _text(405, "read-only")
        var q = req.url.find("?")
        var path = String(req.url[byte=:q]) if q >= 0 else req.url
        try:
            if path == "/" or path == "/index.html":
                return _response(
                    200,
                    List[UInt8](self.page.as_bytes()),
                    "text/html; charset=utf-8",
                    "no-cache",
                )
            if path == "/api/logs":
                return self._logs()
            if path.startswith("/data/"):
                return self._data(String(path[byte=6:]))
            if path == "/healthz":
                return _text(200, "ok")
            return _text(404, String("nothing at ", path))
        except e:
            print("av2-viewer:", path, e)
            return _text(500, String(e))

    def _logs(self) raises -> Response:
        var cat = _catalog(self.warehouse)
        var snap = Int64(-1)
        if cat.table_exists("av2", "scores_a"):
            var t = cat.load_table("av2", "scores_a")
            if t.metadata.has_current_snapshot:
                snap = t.metadata.current_snapshot_id
        if snap != self.cache[].snapshot:
            var got = scores_json(self.warehouse)
            self.cache[].snapshot = got[0]
            self.cache[].json = got[1]
        return _response(
            200,
            List[UInt8](self.cache[].json.as_bytes()),
            "application/json",
            "no-cache",
        )

    def _data(self, rest: String) raises -> Response:
        var slash = rest.find("/")
        if slash < 0:
            return _text(404, "no such file")
        var id = String(rest[byte=:slash])
        var name = String(rest[byte = slash + 1 :])
        if not valid_log_id(id) or not valid_bundle_file(name):
            return _text(404, "no such file")
        var io = FileIOResolver()
        var input = io.new_input(String(self.views, "/", id, "/", name))
        if not input.exists():
            return _text(404, String("no ", name, " for ", id))
        # A bundle is written once, its view.json last; only view.json can
        # change, when a log is labelled again.
        var cache = String(
            "no-cache" if name == "view.json" else "public, max-age=3600"
        )
        return _response(200, input.read_all(), _content_type(name), cache)


def main() raises:
    var warehouse = _env("ORCA_WAREHOUSE", "runs/av2/warehouse")
    var views = _env("AV2_VIEWS", "runs/av2/views")
    var addr = _env("AV2_VIEWER_ADDR", DEFAULT_ADDR)
    var assets = _env("AV2_VIEWER_ASSETS", "viewer")
    var page: String
    with open(assets + "/index.html", "r") as f:
        page = f.read()
    var cfg = ServerConfig()
    cfg.idle_timeout_ms = 30_000
    cfg.write_timeout_ms = 60_000
    var server = HttpServer.bind(SocketAddr.parse(addr), cfg^)
    print("av2-viewer on http://", addr, " | views ", views, sep="")
    var workers = Int(_env("AV2_VIEWER_WORKERS", "2"))
    server.serve(Viewer(warehouse, views, page), num_workers=workers, pin_cores=False)
