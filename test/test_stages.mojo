from refinery.stages import run_track_detections
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/stagetest"
comptime HEAD = "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf"


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


def test_no_detections_writes_a_header_and_does_not_crash() raises:
    var d = _setup()
    # exactly what an undertrained student produces
    _write(d + "/empty.csv", HEAD + "\n")
    var m = run_track_detections(d + "/empty.csv", d + "/empty_out.csv")
    assert_equal(m.frames, 0)
    assert_equal(m.tracks, 0)
    assert_equal(m.kept, 0)
    assert_equal(_read(d + "/empty_out.csv"), HEAD + "\n")


def test_a_short_track_is_dropped_but_the_file_is_valid() raises:
    var d = _setup()
    # two frames is below MIN_TRACK_FRAMES, so nothing survives
    _write(
        d + "/short.csv",
        HEAD + "\n"
        + "-1,0,0.0,1,1,0,1,1,1,0,0,0,0.9\n"
        + "-1,0,0.1,1,1,0,1,1,1,0,0,0,0.9\n",
    )
    var m = run_track_detections(d + "/short.csv", d + "/short_out.csv")
    assert_equal(m.frames, 2)
    assert_equal(m.kept, 0)
    assert_true(_read(d + "/short_out.csv").startswith(HEAD))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
