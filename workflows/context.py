"""Run context: a work directory, a manifest, and step-level idempotency.

Every stage declares its inputs and outputs. The context hashes the inputs plus
the stage's own parameters, and skips the stage when a previous run already
produced that exact result. Two consequences worth the small amount of
machinery:

  - **A workflow is resumable.** Training dies at epoch 12, you fix it and
    re-run; the export, terrain and tracking stages do not run again.
  - **A workflow is safe to hand to an orchestrator.** Durable-execution
    engines replay handlers, so every step has to be idempotent or a retry
    doubles the work. Making that true here, in plain Python, means adopting
    Restate or Temporal later is *wrapping* this rather than rewriting it.

The manifest is also the provenance record: what ran, with which parameters,
over which inputs, producing which artefacts, with hashes throughout.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_digest(path: Path) -> str:
    """Directory digest over relative names and content, order-independent."""
    h = hashlib.sha256()
    for p in sorted(path.rglob("*")):
        if p.is_file():
            h.update(str(p.relative_to(path)).encode())
            h.update(file_digest(p).encode())
    return h.hexdigest()


def digest(path: Path) -> str:
    if path.is_dir():
        return tree_digest(path)
    if path.exists():
        return file_digest(path)
    return "missing"


@dataclass
class StepResult:
    name: str
    skipped: bool
    seconds: float
    outputs: dict[str, str]
    metrics: dict[str, Any] = field(default_factory=dict)


class RunContext:
    """Everything one workflow run needs, plus the record of what it did."""

    def __init__(self, work: Path, name: str, verbose: bool = True):
        self.work = work
        self.name = name
        self.verbose = verbose
        self.work.mkdir(parents=True, exist_ok=True)
        self.manifest_path = self.work / f"manifest.{name}.json"
        self.manifest: dict[str, Any] = (
            json.loads(self.manifest_path.read_text())
            if self.manifest_path.exists()
            else {"workflow": name, "steps": {}}
        )
        self.results: list[StepResult] = []

    # -- plumbing ---------------------------------------------------------

    def log(self, message: str) -> None:
        if self.verbose:
            print(message, flush=True)

    def run(self, argv: list[str], cwd: Path | None = None) -> str:
        proc = subprocess.run(
            argv, cwd=cwd, capture_output=True, text=True, check=False
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"command failed ({proc.returncode}): {' '.join(argv)}\n"
                f"{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}"
            )
        return proc.stdout

    def _save(self) -> None:
        self.manifest_path.write_text(json.dumps(self.manifest, indent=2) + "\n")

    # -- the one thing that matters ---------------------------------------

    def step(
        self,
        name: str,
        inputs: list[Path],
        outputs: list[Path],
        params: dict[str, Any],
        action: Callable[[], dict[str, Any] | None],
        force: bool = False,
    ) -> StepResult:
        """Run `action` unless an identical run already produced `outputs`."""
        key = hashlib.sha256(
            json.dumps(
                {
                    "params": params,
                    "inputs": {str(p): digest(p) for p in inputs},
                },
                sort_keys=True,
            ).encode()
        ).hexdigest()[:16]

        previous = self.manifest["steps"].get(name)
        fresh = (
            previous is not None
            and previous.get("key") == key
            and all(Path(p).exists() for p in previous.get("outputs", {}))
        )
        if fresh and not force:
            self.log(f"  · {name:26s} skipped (unchanged)")
            result = StepResult(name, True, 0.0, previous["outputs"], previous.get("metrics", {}))
            self.results.append(result)
            return result

        self.log(f"  ▸ {name:26s} running")
        started = time.time()
        metrics = action() or {}
        elapsed = time.time() - started

        produced = {str(p): digest(p) for p in outputs}
        self.manifest["steps"][name] = {
            "key": key,
            "params": params,
            "inputs": {str(p): digest(p) for p in inputs},
            "outputs": produced,
            "metrics": metrics,
            "seconds": round(elapsed, 1),
            "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        self._save()
        self.log(f"    {name:26s} done in {elapsed:.0f}s")
        result = StepResult(name, False, elapsed, produced, metrics)
        self.results.append(result)
        return result

    def summary(self) -> str:
        ran = [r for r in self.results if not r.skipped]
        total = sum(r.seconds for r in ran)
        return (
            f"{self.name}: {len(ran)} steps ran, "
            f"{len(self.results) - len(ran)} skipped, {total:.0f}s"
        )
