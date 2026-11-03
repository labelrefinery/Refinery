"""The view bundle (`refinery.av2_view`) and the viewer's path checks; in the
orca environment, which has objectstore."""

from std.memory import bitcast
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, TestSuite

from refinery.av2_view import publish_view, quantize_sweep
from av2_viewer import valid_bundle_file, valid_log_id


def _f32s(values: List[Float32]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        var u = bitcast[DType.uint32](v)
        for i in range(4):
            out.append(UInt8((u >> UInt32(8 * i)) & 0xFF))
    return out^


def _i16(data: List[UInt8], at: Int) -> Int:
    var u = Int(data[at]) | (Int(data[at + 1]) << 8)
    return u - 65536 if u >= 32768 else u


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def test_a_sweep_quantized_to_centimetres() raises:
    # Three points: one near, one 100 m out (past the range), one negative.
    var sweep = _f32s(
        [1.234, -2.0, 0.5, 17.0, 100.0, 0.0, 0.0, 3.0, -3.456, 0.004, 1.0, 255.0]
    )
    var q = quantize_sweep(sweep, stride=1)
    assert_equal(len(q), 16)  # two points of 8 bytes
    assert_equal(_i16(q, 0), 123)
    assert_equal(_i16(q, 2), -200)
    assert_equal(_i16(q, 4), 50)
    assert_equal(_i16(q, 6), 17)
    assert_equal(_i16(q, 8), -346)
    assert_equal(_i16(q, 10), 0)
    assert_equal(_i16(q, 14), 255)
    # Every second point: the first and the third.
    assert_equal(len(quantize_sweep(sweep, stride=2)), 16)


def test_a_view_bundle() raises:
    var dir = String("build/test-av2-view-log")
    if not exists(dir + "/sweeps"):
        makedirs(dir + "/sweeps")
    _write(dir + "/tf.csv", "t,x,y,z,qx,qy,qz,qw\n0.0000,0,0,0,0,0,0,1\n")
    _write(dir + "/tracks.csv", "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n")
    _write(dir + "/sweeps/index.csv", "frame,t,n_points,file\n0,0.0,1,000000.bin\n")
    with open(dir + "/sweeps/000000.bin", "w") as f:
        f.write_bytes(Span(_f32s([1.0, 2.0, 3.0, 4.0])))
    var root = String("build/test-av2-views")
    _ = publish_view(dir, "log-without-annotations", root)
    for name in ["view.json", "tf.csv", "sweeps.csv", "tracks.csv", "points/000000.bin"]:
        assert_equal(exists(root + "/log-without-annotations/" + name), True)
    # No annotations in, none out.
    assert_equal(exists(root + "/log0/annotations.csv"), False)


def test_the_viewer_serves_bundle_files_only() raises:
    assert_equal(valid_log_id("02678d04-cc9f-3148-9f95-1ba66347dff9"), True)
    assert_equal(valid_log_id("02678d04-cc9f-3148-9f95-1ba66347dff"), False)
    assert_equal(valid_log_id("../../../../etc/passwd-aaaaaaaaaaaaaaaa"), False)
    assert_equal(valid_bundle_file("tracks.csv"), True)
    assert_equal(valid_bundle_file("points/000157.bin"), True)
    assert_equal(valid_bundle_file("points/../tf.csv"), False)
    assert_equal(valid_bundle_file("points/00015a.bin"), False)
    assert_equal(valid_bundle_file("meta.json"), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
