from refinery.filter import filter_labels
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/filtertest"


def _setup() raises -> String:
    if not exists(TMP):
        makedirs(TMP, exist_ok=True)
    return String(TMP)


def _write(path: String, body: String) raises:
    var h = open(path, "w")
    h.write(body)
    h.close()


def _read(path: String) raises -> String:
    var h = open(path, "r")
    var s = h.read()
    h.close()
    return s^


def test_drops_a_stationary_track_and_keeps_a_moving_one() raises:
    var d = _setup()
    # track 1 never moves; track 2 travels 10 m along x
    _write(
        d + "/in.csv",
        "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n"
        + "1,0,0.0,5.0,5.0,0,1,1,1,0,0,0,1.0\n"
        + "1,0,0.1,5.0,5.0,0,1,1,1,0,0,0,1.0\n"
        + "2,0,0.0,0.0,0.0,0,1,1,1,0,0,0,1.0\n"
        + "2,0,0.1,10.0,0.0,0,1,1,1,0,0,0,1.0\n",
    )
    var m = filter_labels(d + "/in.csv", d + "/out.csv", 4.0)
    assert_equal(m.rows_in, 4)
    assert_equal(m.rows_out, 2)
    assert_equal(m.tracks_in, 2)
    assert_equal(m.tracks_dropped, 1)
    var body = _read(d + "/out.csv")
    assert_true("2,0,0.0,0.0" in body)
    assert_true("1,0,0.0,5.0" not in body)


def test_a_track_is_kept_or_dropped_whole() raises:
    var d = _setup()
    # one track that sits still, then moves 10 m: every row survives
    _write(
        d + "/whole.csv",
        "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n"
        + "7,0,0.0,0.0,0.0,0,1,1,1,0,0,0,1.0\n"
        + "7,0,0.1,0.0,0.0,0,1,1,1,0,0,0,1.0\n"
        + "7,0,0.2,10.0,0.0,0,1,1,1,0,0,0,1.0\n",
    )
    var m = filter_labels(d + "/whole.csv", d + "/whole_out.csv", 4.0)
    assert_equal(m.rows_out, 3)
    assert_equal(m.tracks_dropped, 0)


def test_extra_columns_survive() raises:
    var d = _setup()
    # this is the bug the Python version had: cls_conf/cls_source were dropped
    _write(
        d + "/named.csv",
        "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf,cls_conf,cls_source\n"
        + "3,haul_truck,0.0,0.0,0.0,0,1,1,1,0,0,0,1.0,0.91,detector\n"
        + "3,haul_truck,0.1,10.0,0.0,0,1,1,1,0,0,0,1.0,0.91,detector\n",
    )
    _ = filter_labels(d + "/named.csv", d + "/named_out.csv", 4.0)
    var body = _read(d + "/named_out.csv")
    assert_true("cls_conf,cls_source" in body)
    assert_true("0.91,detector" in body)


def test_threshold_is_respected() raises:
    var d = _setup()
    _write(
        d + "/thresh.csv",
        "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n"
        + "1,0,0.0,0.0,0.0,0,1,1,1,0,0,0,1.0\n"
        + "1,0,0.1,3.0,0.0,0,1,1,1,0,0,0,1.0\n",
    )
    var strict = filter_labels(d + "/thresh.csv", d + "/t1.csv", 4.0)
    assert_equal(strict.rows_out, 0)
    var loose = filter_labels(d + "/thresh.csv", d + "/t2.csv", 2.0)
    assert_equal(loose.rows_out, 2)


def test_missing_column_is_an_error() raises:
    var d = _setup()
    _write(d + "/bad.csv", "a,b,c\n1,2,3\n")
    with assert_raises():
        _ = filter_labels(d + "/bad.csv", d + "/bad_out.csv", 4.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
