"""The durable loop: ask the router what to run next, run it, record it.

A Restate Virtual Object keyed by scene, which serialises runs on one scene for
free — necessary because stages share a work directory and the ledger, and
because `train_student` later writes a checkpoint keyed only by run name.

One invocation advances the run by **one stage**, which is the shape the router
implies: it is asked what to do next, so "next" is the unit. It also keeps
handlers short, so a stage that takes minutes does not hold the driver for the
whole pipeline, and the control site gets a timeline that grows a row at a time.

    pixi run orchestrator
    restate deployments register http://localhost:9081
    curl localhost:8080/RefineryLoop/<scene-id>/step \
      -d '"scene=/s.mcap&work=/w&sitegen=/sitegen&invocation=<id>"'

`step` returns `{"stage": "...", "status": "...", "done": false}`. Drive it
until `done` is true; the control site does that, one row at a time.
"""

from restate import App, Invocation, is_suspended

from refinery.filter import filter_labels
from refinery.publish import publish_labels
from refinery.review import apply_edits, apply_gold
from refinery.trainconfig import write_train_config
from refinery.opsdb import OpsDb
from refinery.proc import run_checked
from refinery.router import choose_random
from refinery.runctx import outputs_json, should_skip, step_key
from refinery.steps import Stage, build_stages


def unquote(s: String) -> String:
    return String(String(s.strip()).removeprefix('"').removesuffix('"'))


def parse_params(body: String) -> Dict[String, String]:
    var out = Dict[String, String]()
    for pair in unquote(body).split("&"):
        var text = String(pair)
        if text.byte_length() == 0:
            continue
        var parts = text.split("=")
        if len(parts) < 2:
            continue
        var key = String(String(parts[0]).strip())
        var value = String("")
        for i in range(1, len(parts)):
            if i > 1:
                value += "="
            value += String(parts[i])
        if key.byte_length() > 0:
            out[key] = String(value.strip())
    return out^


def get(params: Dict[String, String], key: String, fallback: String) -> String:
    try:
        return params[key]
    except:
        return fallback.copy()


def require(params: Dict[String, String], key: String) raises -> String:
    var value = get(params, key, String(""))
    if value.byte_length() == 0:
        raise Error("missing required parameter: " + key)
    return value^


def json_escape(s: String) -> String:
    var out = String("")
    for i in range(s.byte_length()):
        var c = s[byte=i]
        if c == '"':
            out += '\\"'
        elif c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        else:
            out += String(c)
    return out^


def run_stage(
    mut app: App,
    inv: Invocation,
    stage: Stage,
    work: String,
    min_path_m: Float64,
    dataset_name: String = "",
    run_id: String = "",
) raises -> String:
    """Execute one stage and return its metrics JSON.

    Journaled by the caller, so this runs once per invocation even across
    replays.
    """
    if stage.executor == "subprocess":
        var log = work + "/logs/" + stage.name + ".log"
        var result = run_checked(stage.argv, log, stage.cwd)
        return String('{"exit_code": ', result.exit_code, "}")

    if stage.executor == "mojo":
        # A different process serves this, so the single-threaded driver's
        # self-call deadlock does not apply.
        return app.call(inv, "RefineryExecutor", stage.handler, stage.payload)

    if stage.executor == "inproc":
        if stage.name == "filter_labels":
            var metrics = filter_labels(
                stage.inputs[0], stage.outputs[0], min_path_m
            )
            return metrics.as_json()
        if stage.name == "write_train_config":
            # cwd carries the template, handler the run name, payload epochs.
            var cfg = write_train_config(
                stage.cwd,
                stage.outputs[0],
                stage.inputs[0],
                stage.handler,
                Int(Float64(stage.payload)),
            )
            return cfg.as_json()
        if stage.name == "publish_labels":
            # `cwd` carries the warehouse root for this stage -- the field is
            # unused by in-process stages otherwise.
            var pub = publish_labels(
                stage.inputs[0], stage.cwd, dataset_name, run_id
            )
            return pub.as_json()
        raise Error("no in-process implementation for stage: " + stage.name)

    raise Error("unknown executor: " + stage.executor)


def await_review(
    mut app: App,
    inv: Invocation,
    mut db: OpsDb,
    invocation_id: String,
    step_id: String,
    stage: Stage,
) raises -> String:
    """Open a review task and wait for a person, however long that takes.

    `awakeable_await` suspends the invocation: the process is freed and Restate
    re-delivers with journal replay when the site resolves the awakeable. That
    is what makes a wait of days cost nothing.

    Opening the task is keyed on the awakeable id, because a replay re-creates
    the same id and must not open a second task for the same wait.
    """
    var kind = String("gold") if stage.executor == "gold" else String("review")
    var awakeable = app.awakeable_create(inv)
    var task_id = db.open_review(
        invocation_id, step_id, stage.inputs[0], awakeable, kind
    )
    print(kind, "waiting:", task_id, "awakeable:", awakeable)

    _ = app.awakeable_await(inv, awakeable)

    db.resolve_review(task_id)
    var edits = db.review_edits(task_id)
    if kind == "gold":
        var g = apply_gold(stage.inputs[0], stage.outputs[0], edits)
        return g.as_json()
    var metrics = apply_edits(stage.inputs[0], stage.outputs[0], edits)
    return metrics.as_json()


def advance(mut app: App, inv: Invocation, params: Dict[String, String]) raises -> String:
    """Pick one stage, run it unless the ledger says it is unchanged, record it."""
    var scene = require(params, "scene")
    var work = require(params, "work")
    var sitegen = require(params, "sitegen")
    var repo = get(params, "repo", String("."))
    var ops_path = get(params, "ops", work + "/ops.db")
    var invocation_id = get(params, "invocation", String(""))
    var min_path_m = Float64(get(params, "min_path_m", String("4.0")))
    var seed = Int(Float64(get(params, "seed", String("1"))))
    var duration_s = Float64(get(params, "duration_s", String("6.0")))
    var centerpillars = get(params, "centerpillars", String(""))
    var epochs = Int(Float64(get(params, "epochs", String("20"))))
    var score_thresh = Float64(get(params, "score_thresh", String("0.2")))
    var round_name = get(params, "round", String("r1"))
    var camera_hz = Float64(get(params, "camera_hz", String("1.0")))
    var dino = get(params, "dino", String(""))

    var db = OpsDb(ops_path)
    if invocation_id.byte_length() == 0:
        invocation_id = db.new_invocation(scene, seed, work)
    elif not db.invocation_exists(invocation_id):
        # Almost always a caller pointing at a different ops.db than the one
        # the invocation was created in. Every foreign key downstream would
        # fail, identically, on every retry -- so say so and stop.
        raise Error(
            "invocation " + invocation_id + " is not in " + ops_path
            + " -- pass ops= pointing at the database it was created in"
        )

    var stages = build_stages(
        scene,
        work,
        sitegen,
        repo,
        min_path_m,
        seed,
        duration_s,
        centerpillars,
        epochs,
        score_thresh,
        round_name,
        camera_hz,
        dino,
    )

    # Ask the ledger, not the filesystem, whether each stage is already done.
    # A stage whose outputs exist but whose inputs changed is *not* done.
    var satisfied = List[Bool]()
    for i in range(len(stages)):
        ref s = stages[i]
        var k = step_key(s.params_json, s.inputs)
        satisfied.append(should_skip(db, work, s.name, k, s.outputs))

    # Journal the decision and the bookkeeping. The router picks at RANDOM, so
    # without this a replay after a suspension would choose a different stage
    # than the one already recorded -- and `start_step` would insert a second
    # row for the same attempt. `run_enter`/`run_exit` makes the whole block
    # happen once and replay identically.
    var plan: String
    var replayed_plan = app.run_enter(inv)
    if replayed_plan:
        plan = replayed_plan.value()
    else:
        var decision = choose_random(stages, satisfied)
        var seq = db.next_seq(invocation_id)
        var chosen_name = String("done") if decision.is_done() else stages[
            decision.chosen
        ].name
        _ = db.record_decision(
            invocation_id,
            seq,
            decision.candidates_json(),
            chosen_name,
            decision.reason,
            decision.model,
        )
        var new_step_id = String("")
        if not decision.is_done():
            new_step_id = db.start_step(
                invocation_id,
                seq,
                chosen_name,
                stages[decision.chosen].executor,
                stages[decision.chosen].params_json,
            )
        plan = app.run_exit(inv, chosen_name + "|" + new_step_id)

    var plan_parts = plan.split("|")
    var chosen_name = String(plan_parts[0])
    var step_id = String(plan_parts[1]) if len(plan_parts) > 1 else String("")

    if chosen_name == "done":
        db.set_invocation_status(invocation_id, "done")
        return String(
            '{"invocation": "', invocation_id, '", "stage": null, "done": true}'
        )

    var chosen_index = -1
    for i in range(len(stages)):
        if stages[i].name == chosen_name:
            chosen_index = i
    if chosen_index < 0:
        raise Error("journalled stage no longer in the table: " + chosen_name)

    ref stage = stages[chosen_index]
    var key = step_key(stage.params_json, stage.inputs)

    var metrics: String
    try:
        if stage.executor == "review" or stage.executor == "gold":
            metrics = await_review(app, inv, db, invocation_id, step_id, stage)
        else:
            metrics = run_stage(
                app,
                inv,
                stage,
                work,
                min_path_m,
                String("site_seed") + String(seed) + ".reviewed",
                invocation_id,
            )
    except e:
        # A suspension is not a failure. `awakeable_await` raises to unwind the
        # handler so Restate can free the process; the step is *waiting*, and
        # marking it failed would put a review-in-progress on the timeline as
        # an error and set the whole run to failed.
        if is_suspended(e):
            db.finish_step(step_id, "waiting", "{}", "{}", "", "")
            db.set_invocation_status(invocation_id, "waiting")
        else:
            db.finish_step(
                step_id, "failed", "{}", "{}", "", json_escape(String(e))
            )
            db.set_invocation_status(invocation_id, "failed")
        raise e

    db.finish_step(
        step_id, "ok", outputs_json(stage.outputs), metrics, "", ""
    )
    db.record_ledger(
        work, stage.name, key, outputs_json(stage.outputs), metrics
    )
    db.set_invocation_status(invocation_id, "running")

    return String(
        '{"invocation": "',
        invocation_id,
        '", "stage": "',
        stage.name,
        '", "status": "ok", "metrics": ',
        metrics,
        ', "done": false}',
    )


def main() raises:
    var app = App("RefineryLoop", ["step"], object=True, port=9081)
    print(
        "RefineryLoop listening on :9081 — register with"
        " `restate deployments register http://localhost:9081`"
    )
    while True:
        var inv = app.next()
        try:
            var params = parse_params(inv.input_string())
            var result = advance(app, inv, params)
            app.complete(inv, result)
        except e:
            if is_suspended(e):
                app.abandon(inv)
            else:
                # Terminal, not retried. The driver is single-threaded, so an
                # invocation that fails identically on every redelivery does
                # not just fail -- it starves every other request behind it.
                print("loop error:", e)
                try:
                    app.fail(inv, String(e))
                except:
                    app.abandon(inv)
