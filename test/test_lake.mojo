"""The orca writers, in an in-memory run (no Postgres): partitioned kind
tables, orca's summary on each snapshot, and the declared-writes check.
Run in the `orca` environment: `pixi run -e orca test-lake`."""

from std.os import makedirs, setenv
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from orca import Ctx
from orca.tables import load_dataset

from refinery.datasets import EvalRow, version_ref
from refinery.lake import (
    EVALUATIONS,
    LABELS,
    publish_labels,
    write_evaluation,
)

comptime HEAD = "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf"


def _warehouse(name: String) raises -> String:
    var d = String("build/test-lake/", name)
    makedirs(d, exist_ok=True)
    _ = setenv("ORCA_WAREHOUSE", d)
    return d


def _ctx(step: String, var writes: List[String]) -> Ctx:
    return Ctx(
        "av2_pipeline_a",
        0,
        step,
        "log-1",
        code="c0de",
        declared_writes=writes^,
    )


def _csv(path: String) raises:
    with open(path, "w") as f:
        f.write(
            HEAD,
            "\n3,vehicle,0.0,1,2,3,1,1,1,0,0,0,1.0",
            "\n3,vehicle,0.1,1,2,3,1,1,1,0,0,0,1.0\n",
        )


def test_labels_land_partitioned_with_orca_summary() raises:
    var d = _warehouse("labels")
    _csv(d + "/tracks.csv")
    var ctx = _ctx("label", [String(LABELS)])
    var snap = publish_labels(ctx, d + "/tracks.csv", "av2/log-1", "pipeline_a")
    assert_true(snap > 0)
    var table = load_dataset(LABELS)
    assert_equal(len(table.metadata.spec().fields), 1)
    assert_equal(table.metadata.spec().fields[0].name, "dataset_name")
    var found = False
    for s in table.metadata.snapshots:
        if s.snapshot_id == snap:
            found = True
            assert_equal(s.summary.get("orca.step", ""), "label")
            assert_equal(s.summary.get("orca.code", ""), "c0de")
            assert_equal(s.summary.get("orca.partition", ""), "log-1")
    assert_true(found)
    assert_true(not exists(d + "/labelrefinery/datasets"))


def test_evaluation_names_what_it_scored() raises:
    _ = _warehouse("eval")
    var ctx = _ctx("score", [String(EVALUATIONS)])
    var rows = List[EvalRow]()
    rows.append(EvalRow(String("all"), String("recall"), 0.65))
    var snap = write_evaluation(
        ctx, "av2/log-1", rows, version_ref(LABELS, 42), ""
    )
    assert_true(snap > 0)


def test_undeclared_write_is_refused() raises:
    var d = _warehouse("undeclared")
    _csv(d + "/tracks.csv")
    var ctx = _ctx("label", List[String]())
    with assert_raises():
        _ = publish_labels(ctx, d + "/tracks.csv", "av2/log-1", "pipeline_a")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
