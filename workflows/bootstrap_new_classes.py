"""Produce the first labels for a scene nothing has ever been trained on.

There is no model, no checkpoint and no class list. Every stage is geometry or
classical estimation, so this runs on a site it has never seen and on object
classes nobody has named yet -- which is the case that matters, because a
detector trained on public AV data has never heard of an excavator boom.

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


def bootstrap_new_classes(
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
    ctx = RunContext(work, "bootstrap_new_classes", verbose=verbose)
    ctx.log(f"\n{'=' * 64}\nbootstrap_new_classes  {scene.name}\n{'=' * 64}")

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
