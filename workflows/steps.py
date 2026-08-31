"""The individual stages, each a thin wrapper over a tool that already exists.

Nothing here implements an algorithm. Every step shells out to `sitegen`,
`Refinery`'s Mojo binary, or `CenterPillars`, which is the point: a workflow is
wiring, and the wiring should be legible enough that swapping a stage is
obvious.
"""

from __future__ import annotations

import csv
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import numpy as np

from .context import RunContext

REPO = Path(__file__).resolve().parent.parent
SITEGEN = REPO.parent / "sitegen"
CENTERPILLARS = REPO.parent / "CenterPillars.py"
PIXI = Path.home() / ".pixi" / "bin" / "pixi"

TRACKER_HEADER = [
    "track_id", "cls", "t", "x", "y", "z",
    "w", "l", "h", "vx", "vy", "theta", "conf",
]


def _sitegen(ctx: RunContext, *args: str) -> str:
    return ctx.run(["uv", "run", "--project", str(SITEGEN), "sitegen", *args])


def _refinery(ctx: RunContext, *args: str) -> str:
    return ctx.run(
        [str(PIXI), "run", "mojo", "run", "-I", "src", "src/main.mojo", *args], cwd=REPO
    )


# ===----------------------------------------------------------------------===
# Data preparation
# ===----------------------------------------------------------------------===


def export_scene(ctx: RunContext, scene: Path, out: Path) -> None:
    """Everything the Mojo pipeline reads: poses, proprioception, sweeps."""

    def action() -> dict[str, Any]:
        out.mkdir(parents=True, exist_ok=True)
        _sitegen(ctx, "tf", str(scene), "--out", str(out / "tf.csv"))
        _sitegen(ctx, "joints", str(scene), "--out", str(out / "joints.csv"))
        _sitegen(ctx, "ego", str(scene), "--out", str(out / "ego.csv"))
        _sitegen(ctx, "sweeps", str(scene), "--out", str(out / "sweeps"))
        return {"frames": sum(1 for _ in open(out / "sweeps" / "index.csv")) - 1}

    ctx.step(
        "export_scene",
        inputs=[scene],
        outputs=[out / "tf.csv", out / "joints.csv", out / "sweeps"],
        params={},
        action=action,
    )


def export_truth(ctx: RunContext, scene: Path, out: Path, level: str = "object") -> None:
    """The oracle. Read only by the scorer -- never by a labeling stage."""

    def action() -> dict[str, Any]:
        _sitegen(ctx, "truth", str(scene), "--out", str(out), "--level", level)
        return {"rows": sum(1 for _ in open(out)) - 1}

    ctx.step(
        "export_truth",
        inputs=[scene],
        outputs=[out],
        params={"level": level},
        action=action,
    )


# ===----------------------------------------------------------------------===
# Cold start
# ===----------------------------------------------------------------------===


def geometric_labels(
    ctx: RunContext, work: Path, out: Path, terrain: bool = True, reverse: bool = False
) -> None:
    """Pipeline A: self-mask, terrain, cluster, associate, smooth."""

    def action() -> dict[str, Any]:
        stdout = _refinery(
            ctx,
            str(work), str(out),
            "--terrain", "on" if terrain else "off",
            "--reverse", "on" if reverse else "off",
        )
        metrics: dict[str, Any] = {}
        for line in stdout.splitlines():
            if line.startswith("raw detections:"):
                metrics["detections"] = int(line.split()[-1])
            if line.startswith("tracks:"):
                parts = line.split()
                metrics["tracks"] = int(parts[1])
                metrics["kept"] = int(parts[3])
        return metrics

    ctx.step(
        f"geometric_labels{'_reverse' if reverse else ''}",
        inputs=[work / "tf.csv", work / "joints.csv"],
        outputs=[out],
        params={"terrain": terrain, "reverse": reverse},
        action=action,
    )


# ===----------------------------------------------------------------------===
# Label filtering -- the stage that decides whether the loop compounds
# ===----------------------------------------------------------------------===


def _read(path: Path) -> list[dict[str, str]]:
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def _write(path: Path, rows: list[dict[str, str]]) -> None:
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=TRACKER_HEADER)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in TRACKER_HEADER})


def filter_labels(
    ctx: RunContext,
    labels: Path,
    out: Path,
    min_path_m: float = 4.0,
    corroborate: Path | None = None,
    corroborate_tol_m: float = 2.0,
) -> None:
    """Drop labels a real object would not have produced.

    `min_path_m` is the one that works. A phantom is an artefact of which
    returns survived ground removal in one sweep, so it neither persists nor
    travels: median path 0.75 m against 8.26 m for a real object. Filtering on
    it took label precision 0.653 -> 0.865.

    `corroborate` keeps only labels a second detector also saw. Measured, it is
    much weaker (0.653 -> 0.673) -- a student trained on these labels
    corroborates their systematic errors rather than exposing them -- so it is
    off by default and kept for the ablation.
    """

    def action() -> dict[str, Any]:
        rows = _read(labels)
        tracks: dict[str, list[dict[str, str]]] = defaultdict(list)
        for r in rows:
            tracks[r["track_id"]].append(r)

        path_len: dict[str, float] = {}
        for tid, seq in tracks.items():
            seq.sort(key=lambda r: float(r["t"]))
            path_len[tid] = float(
                sum(
                    np.hypot(
                        float(seq[i]["x"]) - float(seq[i - 1]["x"]),
                        float(seq[i]["y"]) - float(seq[i - 1]["y"]),
                    )
                    for i in range(1, len(seq))
                )
            )

        second: dict[float, list[dict[str, str]]] = defaultdict(list)
        if corroborate is not None:
            for r in _read(corroborate):
                second[round(float(r["t"]), 4)].append(r)

        kept = []
        for r in rows:
            if path_len[r["track_id"]] < min_path_m:
                continue
            if corroborate is not None:
                t = round(float(r["t"]), 4)
                if not any(
                    np.hypot(float(r["x"]) - float(s["x"]), float(r["y"]) - float(s["y"]))
                    < corroborate_tol_m
                    for s in second.get(t, [])
                ):
                    continue
            kept.append(r)

        _write(out, kept)
        return {"in": len(rows), "out": len(kept), "tracks_dropped":
                sum(1 for v in path_len.values() if v < min_path_m)}

    ctx.step(
        "filter_labels",
        inputs=[labels] + ([corroborate] if corroborate else []),
        outputs=[out],
        params={"min_path_m": min_path_m, "corroborate": bool(corroborate)},
        action=action,
    )


# ===----------------------------------------------------------------------===
# Distillation
# ===----------------------------------------------------------------------===


def build_training_set(ctx: RunContext, work: Path, labels: Path, out: Path) -> None:
    def action() -> dict[str, Any]:
        stdout = ctx.run(
            [
                "uv", "run", "--project", str(SITEGEN), "python",
                str(REPO / "scripts" / "to_centerpillars.py"),
                str(work), str(labels), "--out", str(out),
            ],
            cwd=REPO,
        )
        boxes = next(
            (int(l.split()[2].rstrip(",")) for l in stdout.splitlines() if l.startswith("boxes")),
            0,
        )
        return {"boxes": boxes}

    ctx.step(
        "build_training_set",
        inputs=[labels, work / "sweeps"],
        outputs=[out],
        params={},
        action=action,
    )


def train_student(
    ctx: RunContext, data: Path, config_out: Path, run_name: str, epochs: int = 20
) -> Path:
    checkpoint = CENTERPILLARS / "runs" / run_name / "best.pt"

    def action() -> dict[str, Any]:
        template = (REPO / "configs" / "sitegen.yaml").read_text()
        config_out.write_text(
            "\n".join(
                f"  root: {data}" if line.startswith("  root:")
                else f"run_name: {run_name}" if line.startswith("run_name:")
                else f"  epochs: {epochs}" if line.startswith("  epochs:")
                else line
                for line in template.splitlines()
            )
            + "\n"
        )
        ctx.run(
            ["uv", "run", "python", "-m", "centerpillars.train", "--config", str(config_out)],
            cwd=CENTERPILLARS,
        )
        history = json.loads((CENTERPILLARS / "runs" / run_name / "history.json").read_text())
        return {"epochs": len(history), "best_mAP": round(max(e["mAP"] for e in history), 4)}

    ctx.step(
        "train_student",
        inputs=[data],
        outputs=[checkpoint],
        params={"run_name": run_name, "epochs": epochs},
        action=action,
    )
    return checkpoint


def student_labels(
    ctx: RunContext,
    checkpoint: Path,
    work: Path,
    detections: Path,
    tracked: Path,
    score_thresh: float = 0.2,
) -> None:
    def action() -> dict[str, Any]:
        ctx.run(
            [
                "uv", "run", "--project", str(CENTERPILLARS), "python",
                str(REPO / "scripts" / "predict_sitegen.py"),
                "--checkpoint", str(checkpoint),
                "--work", str(work),
                "--out", str(detections),
                "--score-thresh", str(score_thresh),
            ],
            cwd=REPO,
        )
        _refinery(ctx, str(work), str(tracked), "--detections", str(detections))
        return {"detections": sum(1 for _ in open(detections)) - 1}

    ctx.step(
        "student_labels",
        inputs=[checkpoint],
        outputs=[detections, tracked],
        params={"score_thresh": score_thresh},
        action=action,
    )


def name_instances(
    ctx: RunContext,
    scene: Path,
    labels: Path,
    out: Path,
    dino: Path,
    prompt: str,
    max_calls: int,
    views_per_instance: int,
) -> None:
    """Camera + open-vocabulary detector naming, with a size-prior fallback."""

    def action() -> dict[str, Any]:
        stdout = ctx.run(
            [
                "uv", "run", "--project", str(SITEGEN), "python",
                str(REPO / "scripts" / "name_instances.py"),
                "--scene", str(scene), "--labels", str(labels), "--out", str(out),
                "--dino", str(dino), "--prompt", prompt,
                "--max-calls", str(max_calls),
                "--views-per-instance", str(views_per_instance),
            ],
            cwd=REPO,
        )
        metrics: dict[str, Any] = {}
        for line in stdout.splitlines():
            if line.startswith("named_by "):
                metrics = {
                    k: int(v)
                    for k, _, v in (f.partition("=") for f in line.split()[1:])
                }
        return metrics

    ctx.step(
        "name_instances",
        inputs=[scene, labels],
        outputs=[out],
        params={"prompt": prompt, "max_calls": max_calls,
                "views_per_instance": views_per_instance},
        action=action,
    )


# ===----------------------------------------------------------------------===
# Measurement
# ===----------------------------------------------------------------------===


def score(
    ctx: RunContext,
    predictions: Path,
    truth: Path,
    out: Path,
    label: str,
    exclude: tuple[str, ...] = ("grade_stake",),
) -> dict[str, Any]:
    def action() -> dict[str, Any]:
        args = ["score", str(predictions), "--truth", str(truth), "--json", str(out)]
        if exclude:
            args += ["--exclude", *exclude]
        _sitegen(ctx, *args)
        return json.loads(out.read_text())["OVERALL"]

    result = ctx.step(
        f"score_{label}",
        inputs=[predictions, truth],
        outputs=[out],
        params={"exclude": list(exclude)},
        action=action,
    )
    return result.metrics or json.loads(out.read_text())["OVERALL"]


def overlay(ctx: RunContext, scene: Path, predictions: list[Path], out: Path) -> None:
    def action() -> dict[str, Any]:
        _sitegen(ctx, "overlay", *[str(p) for p in predictions],
                 "--out", str(out), "--scene", str(scene))
        return {"topics": len(predictions)}

    ctx.step(
        "overlay",
        inputs=predictions,
        outputs=[out],
        params={"n": len(predictions)},
        action=action,
    )
