from refinery.review import apply_edits, apply_gold, is_safe_value
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


def test_a_comma_would_shift_every_column_and_is_refused() raises:
    var d = _setup()
    _write(d + "/inj.csv", HEAD + "\n1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var edits = List[List[String]]()
    # read_detections reads positionally, so this would silently move t into x
    edits.append(_edit("1", "cls", "truck,999,0.0,0,0"))
    var m = apply_edits(d + "/inj.csv", d + "/inj_out.csv", edits)
    assert_equal(m.rejected, 1)
    assert_equal(m.rows_changed, 0)
    # the file still has one row of thirteen columns
    var lines = _read(d + "/inj_out.csv").split("\n")
    assert_equal(len(String(lines[1]).split(",")), 13)


def test_a_newline_would_split_a_row_and_is_refused() raises:
    var d = _setup()
    _write(d + "/nl.csv", HEAD + "\n1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var edits = List[List[String]]()
    edits.append(_edit("1", "cls", "truck\nextra"))
    var m = apply_edits(d + "/nl.csv", d + "/nl_out.csv", edits)
    assert_equal(m.rejected, 1)


def test_spreadsheet_formulas_are_refused() raises:
    assert_equal(is_safe_value("=1+1"), False)
    assert_equal(is_safe_value("@SUM(A1)"), False)
    assert_equal(is_safe_value("+cmd"), False)


def test_ordinary_class_names_are_fine() raises:
    assert_equal(is_safe_value("haul_truck"), True)
    assert_equal(is_safe_value("grade stake"), True)
    assert_equal(is_safe_value(""), False)


def _dec(track: String, field: String, value: String) -> List[String]:
    var d = List[String]()
    d.append(track)
    d.append(field)
    d.append(value)
    return d^


def test_gold_keeps_only_vouched_tracks() raises:
    var d = _setup()
    _write(
        d + "/g.csv",
        HEAD + "\n"
        + "1,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n"
        + "2,0,0.0,9,9,0,1,1,1,0,0,0,1.0\n",
    )
    var decs = List[List[String]]()
    decs.append(_dec("1", "keep", "1"))
    decs.append(_dec("1", "cls", "excavator"))
    var m = apply_gold(d + "/g.csv", d + "/g_out.csv", decs)
    assert_equal(m.rows_changed, 1)
    var body = _read(d + "/g_out.csv")
    assert_true("1,excavator," in body)
    # track 2 was never vouched for, so it is not truth
    assert_true("\n2," not in body)


def test_gold_default_is_exclusion() raises:
    var d = _setup()
    _write(d + "/g2.csv", HEAD + "\n7,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var m = apply_gold(d + "/g2.csv", d + "/g2_out.csv", List[List[String]]())
    assert_equal(m.rows_changed, 0)


def test_gold_marks_the_source() raises:
    var d = _setup()
    _write(d + "/g3.csv", HEAD + "\n3,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var decs = List[List[String]]()
    decs.append(_dec("3", "keep", "1"))
    var m = apply_gold(d + "/g3.csv", d + "/g3_out.csv", decs)
    assert_equal(m.rows_changed, 1)
    var body = _read(d + "/g3_out.csv")
    assert_true("cls_source" in body)
    assert_true("gold" in body)


def test_gold_refuses_a_shape_changing_name() raises:
    var d = _setup()
    _write(d + "/g4.csv", HEAD + "\n4,0,0.0,0,0,0,1,1,1,0,0,0,1.0\n")
    var decs = List[List[String]]()
    decs.append(_dec("4", "keep", "1"))
    decs.append(_dec("4", "cls", "truck,9,9"))
    var m = apply_gold(d + "/g4.csv", d + "/g4_out.csv", decs)
    assert_equal(m.rejected, 1)
    var lines = _read(d + "/g4_out.csv").split("\n")
    assert_equal(len(String(lines[1]).split(",")), 14)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
