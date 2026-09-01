from refinery.steps import Stage
from refinery.router import (
    build_prompt,
    choose_llm,
    choose_random,
    inputs_ready,
    is_legal,
    legal_stages,
    parse_choice,
)
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
    assert_equal(len(s), 16)
    assert_equal(s[0].name, "generate_scene")
    assert_equal(s[5].name, "geometry")
    assert_equal(s[5].executor, "mojo")
    assert_equal(s[7].name, "filter_labels")
    assert_equal(s[7].executor, "inproc")


def test_training_stages_appear_only_with_a_centerpillars_path() raises:
    var without = build_stages("/s.mcap", "/w", "/sitegen", "/repo", 4.0)
    var with_cp = build_stages(
        "/s.mcap", "/w", "/sitegen", "/repo", 4.0, 1, 6.0, "/cp", 20, 0.2, "r1"
    )
    assert_equal(len(with_cp) - len(without), 6)
    var names = List[String]()
    for i in range(len(with_cp)):
        names.append(with_cp[i].name)
    assert_true("train_student" in names)
    assert_true("student_track" in names)
    # offering a stage whose checkpoint path is nonsense means the router will
    # eventually pick it, and it will fail every time
    var bare = List[String]()
    for i in range(len(without)):
        bare.append(without[i].name)
    assert_true("train_student" not in bare)


def test_only_generate_is_legal_without_a_scene() raises:
    var d = _setup()
    var s = build_stages(d + "/absent.mcap", d + "/w1", "/sitegen", "/repo", 4.0)
    var legal = legal_stages(s, _none(len(s)))
    assert_equal(len(legal), 1)
    assert_equal(s[Int(legal[0])].name, "generate_scene")


def test_only_exports_are_legal_with_just_a_scene() raises:
    var d = _setup()
    var work = d + "/w2"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene2.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    var legal = legal_stages(s, _none(len(s)))
    # the four sitegen exports depend only on the scene, plus generate_scene
    # which the empty ledger does not yet know has run
    assert_equal(len(legal), 5)
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


def test_router_reports_done_when_everything_is_satisfied() raises:
    var d = _setup()
    var s = build_stages(d + "/nope.mcap", d + "/w6", "/sitegen", "/repo", 4.0)
    var all_done = List[Bool]()
    for _ in range(len(s)):
        all_done.append(True)
    var decision = choose_random(s, all_done)
    assert_true(decision.is_done())
    assert_equal(decision.candidates_json(), "[]")


def test_generate_scene_is_the_only_first_move() raises:
    var d = _setup()
    # no scene on disk: only the stage that needs no inputs can run
    var s = build_stages(d + "/absent2.mcap", d + "/w8", "/sitegen", "/repo", 4.0)
    var names = _names(s, legal_stages(s, _none(len(s))))
    assert_equal(len(names), 1)
    assert_equal(names[0], "generate_scene")


def test_candidates_json_is_recorded() raises:
    var d = _setup()
    var work = d + "/w7"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/scene7.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    var decision = choose_random(s, _none(len(s)))
    assert_true(decision.candidates_json().startswith('["generate_scene"'))
    assert_equal(decision.model, "random")


def _answers_generate(prompt: String) raises -> String:
    return String("generate_scene")


def _answers_prose(prompt: String) raises -> String:
    return String("I would run generate_scene first because nothing exists.")


def _answers_nonsense(prompt: String) raises -> String:
    return String("obliterate_everything")


def _answers_two(prompt: String) raises -> String:
    return String("either generate_scene or export_tf would work")


def _raises(prompt: String) raises -> String:
    raise Error("connection refused")


def test_the_prompt_lists_only_legal_stages() raises:
    var d = _setup()
    var s = build_stages(d + "/none.mcap", d + "/wl", "/sitegen", "/repo", 4.0)
    var p = build_prompt(s, legal_stages(s, _none(len(s))), d + "/wl")
    assert_true("generate_scene" in p)
    # geometry cannot run without its inputs, so the model is never offered it
    assert_true("- geometry " not in p)


def test_a_clean_answer_is_taken() raises:
    var d = _setup()
    var s = build_stages(d + "/none.mcap", d + "/wl", "/sitegen", "/repo", 4.0)
    var dec = choose_llm(s, _none(len(s)), d + "/wl", _answers_generate)
    assert_equal(dec.model, "llm")
    assert_equal(s[dec.chosen].name, "generate_scene")
    assert_true(dec.prompt.byte_length() > 0)
    assert_equal(dec.response, "generate_scene")


def test_a_name_inside_prose_is_taken() raises:
    var d = _setup()
    var s = build_stages(d + "/none.mcap", d + "/wl", "/sitegen", "/repo", 4.0)
    var dec = choose_llm(s, _none(len(s)), d + "/wl", _answers_prose)
    assert_equal(s[dec.chosen].name, "generate_scene")


def test_an_illegal_answer_falls_back_and_says_so() raises:
    var d = _setup()
    var s = build_stages(d + "/none.mcap", d + "/wl", "/sitegen", "/repo", 4.0)
    var dec = choose_llm(s, _none(len(s)), d + "/wl", _answers_nonsense)
    assert_equal(dec.model, "llm-fallback")
    # still a legal pick, and the bad answer is kept
    assert_true(is_legal(s[dec.chosen], False))
    assert_equal(dec.response, "obliterate_everything")


def test_an_unreachable_model_falls_back() raises:
    var d = _setup()
    var s = build_stages(d + "/none.mcap", d + "/wl", "/sitegen", "/repo", 4.0)
    var dec = choose_llm(s, _none(len(s)), d + "/wl", _raises)
    assert_equal(dec.model, "llm-fallback")
    assert_true("connection refused" in dec.reason)


def test_an_ambiguous_answer_is_refused() raises:
    var d = _setup()
    var work = d + "/wl2"
    if not exists(work):
        makedirs(work, exist_ok=True)
    var scene = d + "/sl.mcap"
    _touch(scene)
    var s = build_stages(scene, work, "/sitegen", "/repo", 4.0)
    var legal = legal_stages(s, _none(len(s)))
    # naming two legal stages is not a choice
    assert_equal(parse_choice("generate_scene or export_tf", s, legal), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
