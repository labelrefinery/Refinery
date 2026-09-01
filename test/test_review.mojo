from refinery.review import apply_edits
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/reviewtest"


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


def _edit(track: String, field: String, value: String) -> List[String]:
    var e = List[String]()
    e.append(track)
    e.append(field)
    e.append(value)
    return e^


comptime HEAD = "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf"


def test_an_edit_applies_to_every_row_of_that_track() raises:
    var d = _setup()
    _write(
        d + "/in.csv",
        HEAD + "\n"
        + "1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n"
        + "1,0,0.1,1,0,0,1,1,1,0,0,0,1.0\n"
        + "2,0,0.0,9,9,0,1,1,1,0,0,0,1.0\n",
    )
    var edits = List[List[String]]()
    edits.append(_edit("1", "cls", "haul_truck"))
    var m = apply_edits(d + "/in.csv", d + "/out.csv", edits)
    assert_equal(m.rows, 3)
    assert_equal(m.edits, 1)
    assert_equal(m.rows_changed, 2)
    var body = _read(d + "/out.csv")
    assert_true("1,haul_truck,0.0" in body)
    assert_true("1,haul_truck,0.1" in body)
    # the other track is untouched
    assert_true("2,0,0.0" in body)


def test_row_order_and_header_are_preserved() raises:
    var d = _setup()
    _write(
        d + "/order.csv",
        HEAD + "\n"
        + "1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n"
        + "2,0,0.0,9,9,0,1,1,1,0,0,0,1.0\n"
        + "1,0,0.1,1,0,0,1,1,1,0,0,0,1.0\n",
    )
    var edits = List[List[String]]()
    edits.append(_edit("1", "cls", "worker"))
    _ = apply_edits(d + "/order.csv", d + "/order_out.csv", edits)
    var lines = _read(d + "/order_out.csv").split("\n")
    assert_equal(String(lines[0]), HEAD)
    # interleaved frame order survives, which read_detections depends on
    assert_true(String(lines[1]).startswith("1,worker,0.0"))
    assert_true(String(lines[2]).startswith("2,0,0.0"))
    assert_true(String(lines[3]).startswith("1,worker,0.1"))


def test_an_unknown_column_is_skipped_not_fatal() raises:
    var d = _setup()
    _write(d + "/u.csv", HEAD + "\n1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var edits = List[List[String]]()
    edits.append(_edit("1", "not_a_column", "x"))
    var m = apply_edits(d + "/u.csv", d + "/u_out.csv", edits)
    assert_equal(m.edits, 0)
    assert_equal(m.rows_changed, 0)


def test_extra_columns_are_editable() raises:
    var d = _setup()
    _write(
        d + "/named.csv",
        HEAD + ",cls_conf,cls_source\n"
        + "5,machine,0.0,0,0,0,1,1,1,0,0,0,1.0,0.30,size_prior\n",
    )
    var edits = List[List[String]]()
    edits.append(_edit("5", "cls", "excavator"))
    edits.append(_edit("5", "cls_source", "human"))
    var m = apply_edits(d + "/named.csv", d + "/named_out.csv", edits)
    assert_equal(m.rows_changed, 2)
    var body = _read(d + "/named_out.csv")
    assert_true("5,excavator," in body)
    assert_true("human" in body)


def test_no_edits_is_a_faithful_copy() raises:
    var d = _setup()
    var body = HEAD + "\n1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n"
    _write(d + "/copy.csv", body)
    var m = apply_edits(d + "/copy.csv", d + "/copy_out.csv", List[List[String]]())
    assert_equal(m.rows_changed, 0)
    assert_equal(_read(d + "/copy_out.csv"), body)


def test_missing_track_id_column_is_an_error() raises:
    var d = _setup()
    _write(d + "/bad.csv", "a,b\n1,2\n")
    with assert_raises():
        _ = apply_edits(d + "/bad.csv", d + "/bad_out.csv", List[List[String]]())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
