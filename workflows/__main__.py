"""Run a named workflow.

    python -m workflows geo_kinetic_discovery --scene site.mcap --work runs/a
    python -m workflows improve_offboard_model --scene site.mcap --work runs/a \
        --labels runs/a/labels.csv --round r1
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import WORKFLOWS


def main() -> None:
    p = argparse.ArgumentParser(prog="workflows", description=__doc__)
    p.add_argument("workflow", choices=sorted(WORKFLOWS))
    p.add_argument("--scene", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--truth", type=Path, help="oracle CSV; enables scoring")
    p.add_argument("--labels", type=Path, help="improve_offboard_model: input labels")
    p.add_argument("--round", dest="round_name", default="r1")
    p.add_argument("--min-path-m", type=float, default=4.0)
    p.add_argument("--epochs", type=int, default=20)
    p.add_argument("--score-thresh", type=float, default=0.2)
    p.add_argument("--corroborate", type=Path)
    args = p.parse_args()

    common = dict(scene=args.scene, work=args.work, truth=args.truth,
                  min_path_m=args.min_path_m)
    if args.workflow == "geo_kinetic_discovery":
        out = WORKFLOWS[args.workflow](**common)
    else:
        if args.labels is None:
            p.error("improve_offboard_model requires --labels")
        out = WORKFLOWS[args.workflow](
            labels=args.labels, round_name=args.round_name, epochs=args.epochs,
            score_thresh=args.score_thresh, corroborate=args.corroborate, **common,
        )

    print("\nartefacts:")
    for k, v in out.items():
        if isinstance(v, dict):
            print(f"  {k}: " + "  ".join(f"{m}={v[m]}" for m in
                  ("precision", "recall", "f1") if m in v))
        else:
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
