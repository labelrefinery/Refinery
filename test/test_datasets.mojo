from iceberg.catalog.filesystem import FilesystemCatalog
from refinery.datasets import (
    EvalRow,
    dataset,
    kind_table,
    version_ref,
    write_evaluation,
)
from std.os import makedirs
from std.os.path import exists
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

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


def test_dataset_names_the_kind_table() raises:
    assert_equal(dataset("labels"), "labelrefinery.labels")
    assert_equal(dataset("evaluation"), "labelrefinery.evaluations")


def test_version_ref() raises:
    assert_equal(
        version_ref("labelrefinery.labels", 4417), "labelrefinery.labels@4417"
    )


def test_write_evaluation_appends_a_snapshot() raises:
    var d = _fresh("eval1")
    var cat = FilesystemCatalog.local(d)
    var rows = List[EvalRow]()
    rows.append(EvalRow(String("all"), String("recall"), 0.65))
    rows.append(EvalRow(String("all"), String("precision"), 0.42))
    var first = write_evaluation(
        cat, "s", rows, "labelrefinery.labels@1", "", "score", "run-1"
    )
    var second = write_evaluation(
        cat, "s", rows, "labelrefinery.labels@2", "", "score", "run-2"
    )
    assert_true(first > 0)
    assert_true(first != second)
    assert_true(exists(d + "/labelrefinery/evaluations/metadata/version-hint.text"))
    assert_false(exists(d + "/labelrefinery/datasets"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
