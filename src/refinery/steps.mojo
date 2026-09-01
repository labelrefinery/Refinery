"""The stage table: what each stage needs, produces, and how it runs.

A mechanical port of the argv construction in `workflows/steps.py`, with one
structural change: `export_scene` was a single step issuing four `sitegen`
subprocesses, and is four stages here. Each is separately idempotent, each can
fail and retry on its own, and the router gets real choices at the start of a
run rather than one monolithic first move.

Three ways a stage runs:
  subprocess — an existing Python tool or `sitegen`, spawned via proc.mojo
  mojo       — a handler on the Restate executor service
  inproc     — pure Mojo the orchestrator runs itself, like the label filter
  review     — opens a review task and waits on an awakeable until a human
               answers, which may be days
"""


@fieldwise_init
struct Stage(Copyable, Movable):
    """One runnable stage, with its paths already resolved."""

    var name: String
    var executor: String
    """subprocess | mojo | inproc"""
    var inputs: List[String]
    var outputs: List[String]
    var params_json: String
    var argv: List[String]
    """subprocess only."""
    var cwd: String
    """subprocess only; "" inherits the orchestrator's."""
    var handler: String
    """mojo only: the executor handler to call."""
    var payload: String
    """mojo only: the `key=value&...` body."""


def build_stages(
    scene: String,
    work: String,
    sitegen: String,
    refinery_repo: String,
    min_path_m: Float64 = 4.0,
    seed: Int = 1,
    duration_s: Float64 = 6.0,
) -> List[Stage]:
    """Every stage for one scene, with concrete paths.

    `sitegen` is invoked through `uv run --project`, matching what the Python
    workflows do -- sitegen is the one repo in this tree on uv rather than pixi,
    and it owns its own environment.
    """
    var tf = work + "/tf.csv"
    var joints = work + "/joints.csv"
    var sweeps = work + "/sweeps"
    var truth = work + "/truth.csv"
    var raw = work + "/labels_raw.csv"
    var raw_reverse = work + "/labels_raw_reverse.csv"
    var labels = work + "/labels.csv"
    var score = work + "/score_labels.json"
    var reviewed = work + "/labels_reviewed.csv"
    var score_reviewed = work + "/score_reviewed.json"
    var warehouse = work + "/datasets"
    # `version-hint.text` is the one stable path an Iceberg table always has
    # after its first commit, so it is what the ledger can check for.
    var published = warehouse + "/labelrefinery/labels/metadata/version-hint.text"

    var stages = List[Stage]()

    # Scene generation is a stage rather than something the control site does
    # before starting a run: it is slow, it can fail, and it deserves the same
    # ledger and timeline treatment as everything else. It is also the only
    # stage with no inputs, so it is the sole legal first move.
    stages.append(
        Stage(
            "generate_scene",
            "subprocess",
            [],
            [scene],
            '{"seed": ' + String(seed) + ', "duration_s": ' + String(duration_s) + "}",
            [
                "uv", "run", "--project", sitegen, "sitegen", "generate",
                "--out", scene, "--seed", String(seed),
                "--duration", String(duration_s),
            ],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "export_tf",
            "subprocess",
            [scene],
            [tf],
            "{}",
            ["uv", "run", "--project", sitegen, "sitegen", "tf", scene, "--out", tf],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "export_joints",
            "subprocess",
            [scene],
            [joints],
            "{}",
            [
                "uv", "run", "--project", sitegen, "sitegen", "joints", scene,
                "--out", joints,
            ],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "export_sweeps",
            "subprocess",
            [scene],
            [sweeps],
            "{}",
            [
                "uv", "run", "--project", sitegen, "sitegen", "sweeps", scene,
                "--out", sweeps,
            ],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "export_truth",
            "subprocess",
            [scene],
            [truth],
            '{"level": "object"}',
            [
                "uv", "run", "--project", sitegen, "sitegen", "truth", scene,
                "--out", truth, "--level", "object",
            ],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "geometry",
            "mojo",
            [tf, joints, sweeps],
            [raw],
            '{"terrain": true, "reverse": false}',
            [],
            "",
            "geometry",
            "work=" + work + "&out=" + raw + "&terrain=on&reverse=off",
        )
    )
    stages.append(
        Stage(
            "geometry_reverse",
            "mojo",
            [tf, joints, sweeps],
            [raw_reverse],
            '{"terrain": true, "reverse": true}',
            [],
            "",
            "geometry",
            "work=" + work + "&out=" + raw_reverse + "&terrain=on&reverse=on",
        )
    )
    stages.append(
        Stage(
            "filter_labels",
            "inproc",
            [raw],
            [labels],
            '{"min_path_m": ' + String(min_path_m) + "}",
            [],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "human_review",
            "review",
            [labels],
            [reviewed],
            "{}",
            [],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "score_reviewed",
            "subprocess",
            [reviewed, truth],
            [score_reviewed],
            '{"exclude": ["grade_stake"]}',
            [
                "uv", "run", "--project", sitegen, "sitegen", "score", reviewed,
                "--truth", truth, "--json", score_reviewed,
                "--exclude", "grade_stake",
            ],
            "",
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "publish_labels",
            "inproc",
            [reviewed],
            [published],
            '{"dataset": "labels", "producer": "human_review"}',
            [],
            warehouse,
            "",
            "",
        )
    )
    stages.append(
        Stage(
            "score_labels",
            "subprocess",
            [labels, truth],
            [score],
            '{"exclude": ["grade_stake"]}',
            [
                "uv", "run", "--project", sitegen, "sitegen", "score", labels,
                "--truth", truth, "--json", score, "--exclude", "grade_stake",
            ],
            "",
            "",
            "",
        )
    )

    return stages^
