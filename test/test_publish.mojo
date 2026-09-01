from refinery.publish import publish_labels
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/pubtest"
comptime HEAD = "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf"


def _fresh(name: String) raises -> String:
    var d = String(TMP) + "/" + name
    if not exists(d):
        makedirs(d, exist_ok=True)
    return d


def _write(path: String, body: String) raises:
    var h = open(path, "w")
    h.write(body)
    h.close()


def test_publish_creates_a_snapshot() raises:
    var d = _fresh("one")
    _write(
        d + "/labels.csv",
        HEAD + "\n"
        + "3,haul_truck,0.0,1,2,3,1,1,1,0,0,0,1.0\n"
        + "3,haul_truck,0.1,1,2,3,1,1,1,0,0,0,1.0\n",
    )
    var m = publish_labels(d + "/labels.csv", d + "/wh", "s.reviewed", "run-1")
    assert_equal(m.rows, 2)
    assert_true(m.snapshot_id != 0)
    assert_true(m.snapshot_id != -1)
    assert_true(exists(d + "/wh/labelrefinery/labels/metadata/version-hint.text"))


def test_a_second_publish_appends_a_new_snapshot() raises:
    var d = _fresh("two")
    _write(d + "/a.csv", HEAD + "\n1,worker,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var first = publish_labels(d + "/a.csv", d + "/wh", "s.r1", "run-1")
    var second = publish_labels(d + "/a.csv", d + "/wh", "s.r2", "run-2")
    # a version is never rewritten: the second commit is a different snapshot
    assert_true(first.snapshot_id != second.snapshot_id)


def test_extra_columns_are_carried() raises:
    var d = _fresh("three")
    _write(
        d + "/n.csv",
        HEAD + ",cls_conf,cls_source\n"
        + "9,excavator,0.0,1,2,3,1,1,1,0,0,0,1.0,0.91,human\n",
    )
    var m = publish_labels(d + "/n.csv", d + "/wh", "s.reviewed", "run-3")
    assert_equal(m.rows, 1)


def test_missing_required_column_is_an_error() raises:
    var d = _fresh("four")
    _write(d + "/bad.csv", "a,b\n1,2\n")
    with assert_raises():
        _ = publish_labels(d + "/bad.csv", d + "/wh", "s", "run-4")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
