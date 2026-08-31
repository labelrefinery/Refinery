"""Discover object instances from geometry and motion alone.

No model, no checkpoint, no class list -- and, importantly, **no class names
out either**. What this produces is *instances*: a discrete something is here,
this is its box, this is its trajectory. The `cls` column is `0` for every row,
and honestly so.

What geometry and motion can actually settle:

  - **terrain vs not-terrain** -- Stone's connectivity fill, free and reliable
  - **instances** -- connected clusters standing on that terrain
  - **motion attributes** -- static vs moving, path length, velocity. The
    strongest signal here by some distance: it is the label filter that decides
    whether the downstream self-training loop compounds or degrades.
  - **a size bucket** -- measured on this scene, machine-sized and
    person-sized boxes differ by two and a half orders of magnitude (median
    69.3 m3 against 0.13 m3), and a 5 m3 split separates them 97.5% of the time
  - **the ego's own parts, exactly** -- forward kinematics knows which rigid
    body is the boom and which is the bucket. The one place geometry hands you
    true named classes, and it hands them over free.

What it can never settle: excavator against dozer against loader; worker
against any person-shaped object; stockpile against spoil pile, where the
discriminator is *intent* and simply is not present in a point cloud. Naming
needs pixels and a model that has seen the world -- see `bootstrap_new_classes`.

    export -> terrain (Stone) -> cluster -> associate (Hungarian)
           -> smooth (Kalman RTS) -> filter -> labels

The forward and backward association passes are both produced: they are
genuinely different tracklet sets, and the second is what a downstream
tracking-by-tracking stage needs.

The only supervision used anywhere is free: the machine's own joint angles,
which mask the 15% of every sweep that is the ego looking at itself.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import steps
from .context import RunContext


def geo_kinetic_discovery(
    scene: Path,
    work: Path,
    *,
    terrain: bool = True,
    min_path_m: float = 4.0,
    backward_pass: bool = True,
    truth: Path | None = None,
    verbose: bool = True,
) -> dict[str, Any]:
    """Returns the produced artefacts and, when an oracle is given, the score."""
    ctx = RunContext(work, "geo_kinetic_discovery", verbose=verbose)
    ctx.log(f"\n{'=' * 64}\ngeo_kinetic_discovery  {scene.name}\n{'=' * 64}")

    steps.export_scene(ctx, scene, work)

    raw = work / "labels_raw.csv"
    steps.geometric_labels(ctx, work, raw, terrain=terrain)
    if backward_pass:
        steps.geometric_labels(ctx, work, work / "labels_raw_reverse.csv",
                               terrain=terrain, reverse=True)

    filtered = work / "labels.csv"
    steps.filter_labels(ctx, raw, filtered, min_path_m=min_path_m)

    out: dict[str, Any] = {"labels": filtered, "labels_raw": raw}
    if backward_pass:
        out["labels_raw_reverse"] = work / "labels_raw_reverse.csv"

    if truth is not None:
        steps.export_truth(ctx, scene, truth)
        out["score_raw"] = steps.score(ctx, raw, truth, work / "score_raw.json", "raw")
        out["score"] = steps.score(ctx, filtered, truth, work / "score_labels.json", "labels")

    ctx.log(ctx.summary())
    return out
