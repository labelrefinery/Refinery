"""Distil a detector from existing labels, then use it to label better.

    filter -> training set -> train student -> infer -> track -> score

Run it repeatedly and it is a self-training loop. Whether that loop compounds
or degrades is decided entirely by the label filter feeding it: round one of
this on unfiltered labels went *backwards* (F1 0.650 -> 0.596) because the
teacher's false positives were labelled as positives, and the student amplified
them. On motion-filtered labels the same code reaches F1 0.766, and the student
comes out better than its own supervision on both precision and recall.

So `min_path_m` is not a tuning knob, it is the load-bearing parameter.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import steps
from .context import RunContext


def improve_offboard_model(
    scene: Path,
    work: Path,
    labels: Path,
    *,
    round_name: str = "r1",
    min_path_m: float = 4.0,
    corroborate: Path | None = None,
    epochs: int = 20,
    score_thresh: float = 0.2,
    truth: Path | None = None,
    verbose: bool = True,
) -> dict[str, Any]:
    """One round. Feed its `labels` back in as `labels` to run another."""
    ctx = RunContext(work, f"improve_offboard_model.{round_name}", verbose=verbose)
    ctx.log(f"\n{'=' * 64}\nimprove_offboard_model  round={round_name}\n{'=' * 64}")

    steps.export_scene(ctx, scene, work)

    filtered = work / f"{round_name}_train_labels.csv"
    steps.filter_labels(ctx, labels, filtered, min_path_m=min_path_m,
                        corroborate=corroborate)

    data = work / f"{round_name}_data"
    steps.build_training_set(ctx, work, filtered, data)

    checkpoint = steps.train_student(
        ctx, data, work / f"{round_name}.yaml", f"refinery_{round_name}", epochs=epochs
    )

    detections = work / f"{round_name}_dets.csv"
    tracked = work / f"{round_name}_labels.csv"
    steps.student_labels(ctx, checkpoint, work, detections, tracked,
                         score_thresh=score_thresh)

    out: dict[str, Any] = {
        "labels": tracked,
        "detections": detections,
        "checkpoint": checkpoint,
        "train_labels": filtered,
    }

    if truth is not None:
        steps.export_truth(ctx, scene, truth)
        out["score_train_labels"] = steps.score(
            ctx, filtered, truth, work / f"{round_name}_score_train.json",
            f"{round_name}_train",
        )
        out["score"] = steps.score(
            ctx, tracked, truth, work / f"{round_name}_score.json", round_name
        )

    ctx.log(ctx.summary())
    return out
