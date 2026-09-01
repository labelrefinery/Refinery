from refinery.steps import Stage
from refinery.router import choose_random, inputs_ready, is_legal, legal_stages
from refinery.steps import build_stages
from std.os import makedirs, remove
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/routertest"


def _none(n: Int) -> List[Bool]:
    """No stage satisfied by the ledger."""
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


def _setup() raises -> String:
    if not exists(TMP):
        makedirs(TMP, exist_ok=True)
    return String(TMP)


def _touch(path: String) raises:
    var h = open(path, "w")
    h.write("x")
    h.close()


def _names(stages: List[Stage], idxs: List[Int]) -> List[String]:
    var out = List[String]()
    for i in idxs:
        out.append(stages[Int(i)].name)
    return out^


def test_stage_table_has_the_expected_stages() raises:
    var s = build_stages("/scene.mcap", "/w", "/sitegen", "/repo", 4.0)
    assert_equal(len(s), 8)
    assert_equal(s[0].name, "export_tf")
    assert_equal(s[4].name, "geometry")
    assert_equal(s[4].executor, "mojo")
    assert_equal(s[6].name, "filter_labels")
    assert_equal(s[6].executor, "inproc")


def test_nothing_is_legal_without_a_scene() raises:
    var d = _setup()
    var s = build_stages(d + "/absent.mcap", d + "/w1", "/sitegen", "/repo", 4.0)
    assert_equal(len(legal_stages(s, _none(len(s)))), 0)


def test_only_exports_are_legal_with_just_a_scene() raises:
    var d = _setup()
    var work = d + "/w2"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene2.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    var legal = legal_stages(s, _none(len(s)))
    # the four sitegen exports depend only on the scene
    assert_equal(len(legal), 4)
    var names = _names(s, legal)
    assert_true("export_tf" in names)
    assert_true("export_truth" in names)
    assert_true("geometry" not in names)


def test_geometry_unlocks_once_its_inputs_exist() raises:
    var d = _setup()
    var work = d + "/w3"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene3.mcap"
    _touch(scene)
    _touch(work + "/tf.csv")
    _touch(work + "/joints.csv")
    if not exists(work + "/sweeps"):
        makedirs(work + "/sweeps", exist_ok=True)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    var names = _names(s, legal_stages(s, _none(len(s))))
    assert_true("geometry" in names)
    assert_true("geometry_reverse" in names)


def test_the_ledger_decides_done_not_the_filesystem() raises:
    var d = _setup()
    var work = d + "/w4"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene4.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    assert_true(is_legal(s[0], False))
    # the ledger, not the filesystem, decides done-ness
    assert_false(is_legal(s[0], True))


def test_router_only_ever_picks_a_legal_stage() raises:
    var d = _setup()
    var work = d + "/w5"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene5.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    for _ in range(40):
        var decision = choose_random(s, _none(len(s)))
        assert_false(decision.is_done())
        assert_true(is_legal(s[decision.chosen], False))


def test_router_reports_done_when_nothing_is_runnable() raises:
    var d = _setup()
    var s = build_stages(d + "/nope.mcap", d + "/w6", "/sitegen", "/repo", 4.0)
    var decision = choose_random(s, _none(len(s)))
    assert_true(decision.is_done())
    assert_equal(decision.candidates_json(), "[]")


def test_candidates_json_is_recorded() raises:
    var d = _setup()
    var work = d + "/w7"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene7.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    var decision = choose_random(s, _none(len(s)))
    assert_true(decision.candidates_json().startswith('["export_'))
    assert_equal(decision.model, "random")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
