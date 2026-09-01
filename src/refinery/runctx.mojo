"""Content-hash idempotency: skip a stage whose inputs and parameters are unchanged.

This is deliberately *not* what Restate gives you. `run_enter`/`run_exit`
journals a side effect within one invocation, so a crash mid-run resumes
without redoing finished steps. This skips work across *separate* invocations:
re-run the loop tomorrow on the same scene and the export, terrain and tracking
stages do not run again. Different guarantees; the loop needs both.

Ported from `RunContext.step()` in the Python workflows, with two changes.

The ledger lives in SQLite rather than `manifest.<workflow>.json`, because the
manifest was rewritten whole after every step and was last-writer-wins between
concurrent runs.

The digest is XXH64 rather than SHA-256. This is change detection, not a
security boundary — nobody is constructing a malicious LiDAR sweep to force a
cache hit — and it avoids pulling objectstore.mojo, its C shim and libcurl into
Refinery for the sake of one hash.
"""

from hashes import Xxh64, xxh64
from std.os import listdir
from std.os.path import exists, isdir

from refinery.opsdb import OpsDb


comptime MISSING = "missing"
"""Digest of a path that does not exist. Distinct from any real digest, so a
vanished input invalidates the key rather than silently matching."""


def _hex64(v: UInt64) -> String:
    comptime DIGITS = "0123456789abcdef"
    var out = String("")
    for i in range(15, -1, -1):
        var nibble = Int((v >> UInt64(i * 4)) & 0xF)
        out += String(DIGITS[byte=nibble])
    return out^


def file_digest(path: String) raises -> String:
    """XXH64 of a file's bytes, streamed so a 90 MB sweep set is not held whole."""
    var handle = open(path, "r")
    var hasher = Xxh64()
    while True:
        var chunk = handle.read_bytes(1 << 20)
        if len(chunk) == 0:
            break
        hasher.update(chunk)
    handle.close()
    return _hex64(hasher.finish())


def tree_digest(path: String) raises -> String:
    """Digest over a directory's relative names and contents, order-independent.

    Names are folded in as well as contents: renaming a file without changing
    any bytes is still a change, and hashing contents alone would miss it.
    """
    var names = listdir(path)
    sort(names)
    var hasher = Xxh64()
    for name in names:
        var child = path + "/" + String(name)
        hasher.update(String(name).as_bytes())
        var sub: String
        if isdir(child):
            sub = tree_digest(child)
        else:
            sub = file_digest(child)
        hasher.update(sub.as_bytes())
    return _hex64(hasher.finish())


def digest(path: String) raises -> String:
    if not exists(path):
        return String(MISSING)
    if isdir(path):
        return tree_digest(path)
    return file_digest(path)


def step_key(params_json: String, inputs: List[String]) raises -> String:
    """The cache key: parameters plus every input's digest, order-independent.

    Inputs are sorted before folding so the key does not depend on the order a
    caller happened to declare them in.
    """
    var sorted_inputs = inputs.copy()
    sort(sorted_inputs)
    var hasher = Xxh64()
    hasher.update(params_json.as_bytes())
    for path in sorted_inputs:
        hasher.update(String(path).as_bytes())
        hasher.update(digest(String(path)).as_bytes())
    return _hex64(hasher.finish())


def outputs_json(outputs: List[String]) raises -> String:
    """`{"path": "digest", ...}` for the ledger, so a later run can verify."""
    var out = String("{")
    for i in range(len(outputs)):
        if i > 0:
            out += ", "
        out += '"' + outputs[i] + '": "' + digest(outputs[i]) + '"'
    out += "}"
    return out^


def should_skip(
    mut db: OpsDb,
    work_dir: String,
    step_name: String,
    key: String,
    outputs: List[String],
) raises -> Bool:
    """True when this exact step already ran and its outputs are still there.

    Existence is checked, not content: matching the Python original, which
    verified `Path(p).exists()` rather than re-digesting. Re-digesting every
    output on every skip would cost more than the skip saves.
    """
    if db.ledger_key(work_dir, step_name) != key:
        return False
    for path in outputs:
        if not exists(String(path)):
            return False
    return True
