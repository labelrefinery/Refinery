"""Pipeline A's geometry stage on dista: `refinery`'s geometry, with a task
per sweep (`refinery.sweeps`).

    geometry-tasks <work_dir> <out.csv> [--workers N] [--reverse on|off]
        [--terrain on|off] [--proprioception on|off] [--fit-terrain on|off]

It forks a dista head and `--workers` workers on this machine (default 4),
or with `DISTA_HEAD` set joins that cluster, whose workers must see
`work_dir`. Its output is byte for byte what `refinery` writes for the same
arguments, which `test/geometry_tasks.sh` checks.
"""

from std.os import getenv
from std.sys import argv

from refinery.sweeps import GeometryTasks, run_geometry_tasks


def _workers() -> Int:
    var args = argv()
    for i in range(len(args) - 1):
        if args[i] == "--workers":
            try:
                return Int(String(args[i + 1]))
            except:
                pass
    return 4


def main() raises:
    # First: in local mode this forks the head and workers, and a worker
    # never returns from here.
    var rt = GeometryTasks.start(_workers())
    var args = argv()
    if len(args) < 3:
        print(
            "usage: geometry-tasks <work_dir> <out.csv> [--workers N]"
            " [--reverse on|off] [--terrain on|off]"
            " [--proprioception on|off] [--fit-terrain on|off]"
        )
        return
    var use_terrain = True
    var reverse = False
    var proprioception = True
    var fit_terrain = False
    var i = 3
    while i + 1 < len(args):
        if args[i] == "--terrain":
            use_terrain = args[i + 1] == "on"
        elif args[i] == "--reverse":
            reverse = args[i + 1] == "on"
        elif args[i] == "--proprioception":
            proprioception = args[i + 1] == "on"
        elif args[i] == "--fit-terrain":
            fit_terrain = args[i + 1] == "on"
        i += 2
    _ = run_geometry_tasks(
        rt,
        String(args[1]),
        String(args[2]),
        use_terrain=use_terrain,
        reverse=reverse,
        proprioception=proprioception,
        fit_terrain_to_drive=fit_terrain,
    )
