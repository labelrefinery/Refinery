"""Give the discovered instances class names.

`geo_kinetic_discovery` establishes *that* something is there. This establishes
*what*, from two sources that fail in opposite directions:

  - **An open-vocabulary detector names machines and cannot see people.** Over
    ten unobstructed views of a sitegen scene, nine produced `haul truck` with
    the correct label; a worker visible in three of them was never detected.
  - **Geometry finds people and cannot name machines.** Box volume separates
    machine-sized from person-sized at 97.5% here, and says nothing whatever
    about excavator against dozer.

So the detector is asked only where it has a chance, and the size prior covers
the rest. Measured on the seed-1 scene, by how the name was arrived at:

    detector        7 correct, 0 wrong            precision 1.000
    size prior      2 correct, 1 wrong, 7 phantom precision 0.667

Every name the detector gave was right. The size prior's failure is structural:
**it cannot abstain.** Shown a cluster of stockpile it will confidently return
`person`. So an instance the detector was shown and did not corroborate is
recorded as `unknown` rather than guessed at -- detector silence is evidence,
and the output carries `cls_source` and `cls_conf` so a training step can
filter on it instead of taking every name at face value.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import steps
from .context import RunContext


def bootstrap_new_classes(
    scene: Path,
    work: Path,
    labels: Path,
    *,
    dino: Path | None = None,
    prompt: str = "excavator . haul truck . worker . person .",
    max_calls: int = 30,
    views_per_instance: int = 3,
    truth: Path | None = None,
    verbose: bool = True,
) -> dict[str, Any]:
    """Requires a scene generated with `--camera-hz`; returns the named labels."""
    ctx = RunContext(work, "bootstrap_new_classes", verbose=verbose)
    ctx.log(f"\n{'=' * 64}\nbootstrap_new_classes  {scene.name}\n{'=' * 64}")

    named = work / "labels_named.csv"
    steps.name_instances(
        ctx, scene, labels, named,
        dino=dino or (Path(__file__).resolve().parents[2] / "GroundingDino.mojo"),
        prompt=prompt, max_calls=max_calls, views_per_instance=views_per_instance,
    )

    out: dict[str, Any] = {"labels": named}
    if truth is not None:
        steps.export_truth(ctx, scene, truth)
        out["score"] = steps.score(ctx, named, truth, work / "score_named.json", "named")

    ctx.log(ctx.summary())
    return out
