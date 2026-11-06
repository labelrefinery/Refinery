"""A work directory in object storage, mirrored on each machine that reads it.

    var wd = WorkDir("s3://bucket/work/av2/02678d04-...")
    var sweep = wd.path("sweeps/000017.bin")     # downloaded once, then local

A pipeline's steps run in its driver, but its dista tasks run on workers that
on orca's `ec2` runner are instances of their own, and a run resumed after its
head went away starts on a new one. So a work directory that more than one
machine reads lives at a URI (`s3://...`, or `file://...` to try it on one
machine), and each machine keeps a mirror of the files it has read under
`REFINERY_CACHE` (default `/tmp/refinery`). A task reads only what it needs: a
detect task one sweep, the terrain task all of them.

A plain path is a work directory that's local already: every method is then a
no-op or a local check, which is how a laptop run and the tests behave.

A download lands under a temporary name and is renamed into place, so worker
processes sharing a mirror never read half a file. Files in a work directory
are written once (`meta.json` last, as `refinery.av2_fetch` writes it), so a
mirrored file is never stale. Only the `orca` environment builds this module,
for objectstore.
"""

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import exists

from objectstore import FileIOResolver

from refinery.io import read_csv_rows

comptime BATCH = 32
"""Objects fetched per `read_all_many` call."""

def _optional() -> List[String]:
    """Files a work directory may have besides its sweeps, poses and
    `meta.json`."""
    return ["joints.csv", "annotations.csv", "tracks.csv"]


def _parent(path: String) -> String:
    var i = path.rfind("/")
    return String(path[byte=0:i]) if i > 0 else String(".")


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _place(path: String, data: Span[UInt8, _]) raises:
    """Writes `path` whole or not at all: a reader sees it complete or not
    there."""
    var dir = _parent(path)
    if not exists(dir):
        makedirs(dir, exist_ok=True)
    var pid = external_call["getpid", Int32]()
    var part = String(path, ".part-", pid)
    with open(part, "w") as f:
        f.write_bytes(data)
    var src = part.copy()
    var dst = path.copy()
    if (
        external_call["rename", Int32](
            src.as_c_string_span().ptr(),
            dst.as_c_string_span().ptr(),
        )
        != 0
    ):
        raise Error("workdir: can't rename ", part, " to ", path)


struct WorkDir(Copyable, Movable):
    """Where a work directory lives (`uri`) and where this machine reads it
    (`local`)."""

    var uri: String
    var local: String

    def __init__(out self, uri: String):
        self.uri = String(uri.rstrip("/"))
        if "://" in self.uri:
            var cache = getenv("REFINERY_CACHE", "/tmp/refinery")
            self.local = String(
                cache.rstrip("/"), "/", self.uri.replace("://", "/")
            )
        else:
            self.local = self.uri.copy()

    def remote(self) -> Bool:
        return "://" in self.uri

    def path(self, rel: String) raises -> String:
        """The local copy of `rel`."""
        self.get([rel])
        return String(self.local, "/", rel)

    def get(self, rels: List[String]) raises:
        """Mirrors every `rels[i]` not mirrored yet."""
        if not self.remote():
            return
        var want = List[String]()
        for r in rels:
            if not exists(String(self.local, "/", r)):
                want.append(r)
        if not want:
            return
        var io = FileIOResolver()
        var start = 0
        while start < len(want):
            var end = min(start + BATCH, len(want))
            var keys = List[String]()
            for i in range(start, end):
                keys.append(String(self.uri, "/", want[i]))
            var got = io.read_all_many(keys)
            for i in range(start, end):
                _place(String(self.local, "/", want[i]), Span(got[i - start]))
            start = end

    def has(self, rel: String) -> Bool:
        """Whether the work directory has `rel`, mirrored or not."""
        if exists(String(self.local, "/", rel)):
            return True
        if not self.remote():
            return False
        return FileIOResolver().exists(String(self.uri, "/", rel))

    def sweeps(self) raises -> List[String]:
        """Every sweep's path under the work directory, from its index."""
        var out = List[String]()
        for row in read_csv_rows(self.path("sweeps/index.csv")):
            # frame,t,n_points,file
            out.append(String("sweeps/", row[3]))
        return out^

    def mirror(self) raises:
        """Mirrors the whole work directory: its poses, sweeps and whichever
        optional files it has."""
        if not self.remote():
            return
        var rels: List[String] = ["tf.csv", "sweeps/index.csv"]
        rels.extend(self.sweeps())
        for name in _optional():
            if self.has(name):
                rels.append(name)
        self.get(rels)

    def put(self, rels: List[String]) raises:
        """Uploads the local `rels`, in order, over what's there."""
        if not self.remote():
            return
        var io = FileIOResolver()
        for r in rels:
            var data = _read(String(self.local, "/", r))
            io.write(String(self.uri, "/", r), Span(data))

    def publish(self) raises:
        """Uploads the whole local work directory, `meta.json` last, so its
        presence at `uri` means the rest is there."""
        if not self.remote():
            return
        var rels: List[String] = ["tf.csv", "sweeps/index.csv"]
        rels.extend(self.sweeps())
        for name in _optional():
            if exists(String(self.local, "/", name)):
                rels.append(name)
        rels.append("meta.json")
        self.put(rels)
