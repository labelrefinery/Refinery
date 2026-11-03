"""The AV2 scorer over a two-sweep log whose answer is known by hand."""

from std.os import makedirs
from std.os.path import exists
from std.testing import assert_almost_equal, assert_equal, TestSuite

from refinery.av2 import is_movable, score_log
from refinery.terrain import build_terrain
from refinery.io import Pose, pose_from_quaternion


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _log(dir: String) raises:
    if not exists(dir):
        makedirs(dir)
    # The ego drives from (0,0) to (60,0).
    _write(
        dir + "/tf.csv",
        "t,x,y,z,qx,qy,qz,qw\n0.0000,0,0,0,0,0,0,1\n0.1000,60,0,0,0,0,0,1\n",
    )
    # Sweep 0: a car 10 m ahead (matched, 0.5 m off), a pedestrian 20 m ahead
    # (missed), a pole too sparse to count (3 points), and a bus 80 m away
    # (out of range).
    # Sweep 1: the car again (matched exactly), a cone (not movable; matched).
    _write(
        dir + "/annotations.csv",
        "t,track_uuid,category,x,y,z,l,w,h,yaw,num_points,range_m\n"
        + "0.0000,a,REGULAR_VEHICLE,10,0,0,4,2,1.5,0,200,10\n"
        + "0.0000,b,PEDESTRIAN,20,0,0,1,1,1.8,0,40,20\n"
        + "0.0000,c,SIGN,5,5,0,1,1,3,0,3,7\n"
        + "0.0000,d,BUS,80,0,0,12,3,3,0,500,80\n"
        + "0.1000,a,REGULAR_VEHICLE,70,0,0,4,2,1.5,0,200,10\n"
        + "0.1000,e,CONSTRUCTION_CONE,62,3,0,0.4,0.4,0.8,0,30,3.6\n",
    )
    # Tracks: sweep 0 has the car (0.5 m off), a wall nothing annotates, and a
    # far object (out of range); sweep 1 has the car and the cone.
    _write(
        dir + "/tracks.csv",
        "track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf\n"
        + "0,0,0.0,10.5,0,0,2,4,1.5,0,0,0,1.0\n"
        + "1,0,0.0,0,-15,0,0.3,10,3,0,0,0,1.0\n"
        + "2,0,0.0,0,90,0,1,1,1,0,0,0,1.0\n"
        + "0,0,0.1,70,0,0,2,4,1.5,0,0,0,1.0\n"
        + "3,0,0.1,62,3.4,0,0.4,0.4,0.8,0,0,0,1.0\n",
    )


def test_a_known_log() raises:
    var dir = String("build/test-av2-log")
    _log(dir)
    var s = score_log(dir, dir + "/tracks.csv")
    assert_equal(s.frames, 2)
    assert_equal(s.annotated, 4)  # car, pedestrian, car, cone
    assert_equal(s.annotated_movable, 3)
    assert_equal(s.predicted, 4)  # car, wall, car, cone
    assert_equal(s.matched, 3)
    assert_equal(s.matched_movable, 2)
    assert_almost_equal(s.recall(), 0.75)
    assert_almost_equal(s.movable_recall(), 2.0 / 3.0)
    assert_almost_equal(s.precision(), 0.75)
    assert_almost_equal(s.center_error_m, 0.3)  # (0.5 + 0 + 0.4) / 3


def test_the_gate_refuses_a_far_match() raises:
    var dir = String("build/test-av2-log")
    _log(dir)
    var s = score_log(dir, dir + "/tracks.csv", gate=0.45)
    # The car in sweep 0 is 0.5 m off: past the gate now, as is nothing else.
    assert_equal(s.matched, 2)


def test_movable() raises:
    assert_equal(is_movable("PEDESTRIAN"), True)
    assert_equal(is_movable("BOLLARD"), False)


def test_a_grid_fitted_to_the_drive_covers_it() raises:
    var poses: List[Pose] = [
        pose_from_quaternion(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0),
        pose_from_quaternion(250.5, -40.0, 0.0, 0.0, 0.0, 0.0, 1.0),
    ]
    var xs = List[List[Float64]]()
    var ys = List[List[Float64]]()
    var zs = List[List[Float64]]()
    for _ in range(2):
        xs.append([1.0, 251.0])
        ys.append([0.5, -40.0])
        zs.append([0.0, 0.0])
    var site = build_terrain(xs, ys, zs, poses)
    assert_equal(site.spec.nx, 140)
    assert_equal(site.spec.index_of(251.0, -40.0), -1)
    var drive = build_terrain(xs, ys, zs, poses, fit_to_drive=True)
    # 70 m either side of x in [0, 250.5] and y in [-40, 0], on a 1 m lattice.
    assert_almost_equal(drive.spec.origin_x, -70.0)
    assert_almost_equal(drive.spec.origin_y, -110.0)
    assert_equal(drive.spec.nx, 391)
    assert_equal(drive.spec.ny, 180)
    assert_equal(drive.spec.index_of(251.0, -40.0) >= 0, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
