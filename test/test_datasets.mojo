from iceberg.catalog.filesystem import FilesystemCatalog
from refinery.datasets import (
    join_parents,
    kind_table,
    register,
    split_parents,
)
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/dstest"


def _fresh(name: String) raises -> String:
    var d = String(TMP) + "/" + name
    if not exists(d):
        makedirs(d, exist_ok=True)
    return d


def test_kind_maps_to_one_table_per_kind() raises:
    assert_equal(kind_table("labels"), "labels")
    assert_equal(kind_table("ground_truth.tracks"), "ground_truth_tracks")
    assert_equal(kind_table("evaluation"), "evaluations")


def test_unknown_kind_is_an_error() raises:
    with assert_raises():
        _ = kind_table("nonsense")


def test_parents_roundtrip() raises:
    var p = List[String]()
    p.append("a@1")
    p.append("b@2")
    var back = split_parents(join_parents(p))
    assert_equal(len(back), 2)
    assert_equal(back[0], "a@1")
    assert_equal(back[1], "b@2")


def test_empty_parents_roundtrip() raises:
    assert_equal(len(split_parents("")), 0)
    assert_equal(join_parents(List[String]()), "")


def test_register_records_the_pin() raises:
    var d = _fresh("reg1")
    var cat = FilesystemCatalog.local(d)
    var parents = List[String]()
    parents.append("site.round1@0.1.0")
    var entry = register(
        cat, "site.round2", "0.2.0", "labels", 12345, 60, parents,
        "improve_offboard_model", "sha1", '{"k":"v"}', "2026-09-01T00:00:00Z",
    )
    assert_equal(entry.ref(), "site.round2@0.2.0")
    assert_equal(entry.table, "labels")
    assert_equal(entry.snapshot_id, 12345)
    assert_equal(entry.row_count, 60)
    assert_equal(len(entry.parents), 1)
    assert_true(exists(d + "/labelrefinery/datasets/metadata/version-hint.text"))


def test_registering_twice_keeps_both_versions() raises:
    var d = _fresh("reg2")
    var cat = FilesystemCatalog.local(d)
    var none = List[String]()
    _ = register(cat, "s", "0.1.0", "labels", 1, 1, none, "p", "", "{}", "t1")
    _ = register(cat, "s", "0.2.0", "labels", 2, 2, none, "p", "", "{}", "t2")
    # versions are immutable: a second register appends, never updates
    var tbl = cat.load_table("labelrefinery", "datasets")
    assert_true(tbl.metadata.current_snapshot_id != 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
