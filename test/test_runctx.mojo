from refinery.opsdb import OpsDb
from refinery.runctx import (
    digest,
    file_digest,
    outputs_json,
    should_skip,
    step_key,
    tree_digest,
)
from std.os import makedirs, remove
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/runctx"


def _write(path: String, body: String) raises:
    var h = open(path, "w")
    h.write(body)
    h.close()


def _setup() raises -> String:
    if not exists(TMP):
        makedirs(TMP, exist_ok=True)
    return String(TMP)


def test_file_digest_is_stable_and_content_sensitive() raises:
    var d = _setup()
    _write(d + "/a.txt", "hello")
    var h1 = file_digest(d + "/a.txt")
    var h2 = file_digest(d + "/a.txt")
    assert_equal(h1, h2)
    _write(d + "/a.txt", "hello!")
    assert_true(file_digest(d + "/a.txt") != h1)


def test_digest_of_missing_path_is_missing() raises:
    assert_equal(digest("/no/such/path/anywhere"), "missing")


def test_tree_digest_notices_a_rename() raises:
    var d = _setup()
    var sub = d + "/tree"
    if not exists(sub):
        makedirs(sub, exist_ok=True)
    _write(sub + "/one.txt", "same bytes")
    var before = tree_digest(sub)
    remove(sub + "/one.txt")
    _write(sub + "/two.txt", "same bytes")
    var after = tree_digest(sub)
    assert_true(before != after)
    remove(sub + "/two.txt")


def test_step_key_changes_with_params() raises:
    var d = _setup()
    _write(d + "/in.txt", "x")
    var k1 = step_key('{"min_path_m": 4.0}', [d + "/in.txt"])
    var k2 = step_key('{"min_path_m": 8.0}', [d + "/in.txt"])
    assert_true(k1 != k2)


def test_step_key_changes_with_input_content() raises:
    var d = _setup()
    _write(d + "/in2.txt", "before")
    var k1 = step_key("{}", [d + "/in2.txt"])
    _write(d + "/in2.txt", "after")
    assert_true(step_key("{}", [d + "/in2.txt"]) != k1)


def test_step_key_ignores_input_order() raises:
    var d = _setup()
    _write(d + "/p.txt", "p")
    _write(d + "/q.txt", "q")
    assert_equal(
        step_key("{}", [d + "/p.txt", d + "/q.txt"]),
        step_key("{}", [d + "/q.txt", d + "/p.txt"]),
    )


def test_skip_requires_matching_key_and_present_outputs() raises:
    var d = _setup()
    var db = OpsDb(":memory:")
    _write(d + "/src.txt", "content")
    _write(d + "/out.txt", "result")
    var key = step_key("{}", [d + "/src.txt"])

    # never run -> do not skip
    assert_false(should_skip(db, d, "stage", key, [d + "/out.txt"]))

    db.record_ledger(d, "stage", key, outputs_json([d + "/out.txt"]), "{}")
    assert_true(should_skip(db, d, "stage", key, [d + "/out.txt"]))

    # a changed input changes the key -> do not skip
    _write(d + "/src.txt", "different")
    var key2 = step_key("{}", [d + "/src.txt"])
    assert_false(should_skip(db, d, "stage", key2, [d + "/out.txt"]))

    # matching key but a deleted output -> do not skip
    remove(d + "/out.txt")
    assert_false(should_skip(db, d, "stage", key, [d + "/out.txt"]))


def test_outputs_json_shape() raises:
    var d = _setup()
    _write(d + "/o.txt", "z")
    var j = outputs_json([d + "/o.txt"])
    assert_true(j.startswith("{"))
    assert_true(j.endswith("}"))
    assert_true('"' + d + "/o.txt" + '":' in j)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
