from refinery.trainconfig import write_train_config
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/cfgtest"
comptime REPO_TEMPLATE = "/Volumes/ExtNVMe/dev/labelrefinery/Refinery/configs/sitegen.yaml"


def _setup() raises -> String:
    if not exists(TMP):
        makedirs(TMP, exist_ok=True)
    return String(TMP)


def _read(path: String) raises -> String:
    var h = open(path, "r")
    var s = h.read()
    h.close()
    return s^


def test_substitutes_the_three_per_run_lines() raises:
    var d = _setup()
    var m = write_train_config(
        REPO_TEMPLATE, d + "/r1.yaml", "/data/root", "refinery_r1", 7
    )
    assert_equal(m.substituted, 3)
    var body = _read(d + "/r1.yaml")
    assert_true("  root: /data/root" in body)
    assert_true("run_name: refinery_r1" in body)
    assert_true("  epochs: 7" in body)


def test_leaves_the_rest_of_the_template_alone() raises:
    var d = _setup()
    _ = write_train_config(
        REPO_TEMPLATE, d + "/r2.yaml", "/x", "refinery_r2", 20
    )
    var body = _read(d + "/r2.yaml")
    # things that must survive untouched
    assert_true("pillar_size" in body)
    assert_true("classes" in body)
    assert_true("nms_radius" in body)
    # and the stale checked-in root must be gone
    assert_true("cp-data" not in body)


def test_a_template_missing_a_key_is_an_error() raises:
    var d = _setup()
    var h = open(d + "/bad.yaml", "w")
    h.write("run_name: x\ntrain:\n  epochs: 1\n")
    h.close()
    with assert_raises():
        _ = write_train_config(d + "/bad.yaml", d + "/bad_out.yaml", "/r", "n", 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
