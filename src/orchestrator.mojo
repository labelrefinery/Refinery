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
    mut app: App, inv: Invocation, stage: Stage, work: String, min_path_m: Float64
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
        raise Error("no in-process implementation for stage: " + stage.name)

    raise Error("unknown executor: " + stage.executor)


def advance(mut app: App, inv: Invocation, params: Dict[String, String]) raises -> String:
    """Pick one stage, run it unless the ledger says it is unchanged, record it."""
    var scene = require(params, "scene")
    var work = require(params, "work")
    var sitegen = require(params, "sitegen")
    var repo = get(params, "repo", String("."))
    var ops_path = get(params, "ops", work + "/ops.db")
    var invocation_id = get(params, "invocation", String(""))
    var min_path_m = Float64(get(params, "min_path_m", String("4.0")))

    var db = OpsDb(ops_path)
    if invocation_id.byte_length() == 0:
        invocation_id = db.new_invocation(scene, 0, work)

    var stages = build_stages(scene, work, sitegen, repo, min_path_m)

    # Ask the ledger, not the filesystem, whether each stage is already done.
    # A stage whose outputs exist but whose inputs changed is *not* done.
    var satisfied = List[Bool]()
    for i in range(len(stages)):
        ref s = stages[i]
        var k = step_key(s.params_json, s.inputs)
        satisfied.append(should_skip(db, work, s.name, k, s.outputs))

    var decision = choose_random(stages, satisfied)
    var seq = db.next_seq(invocation_id)
    _ = db.record_decision(
        invocation_id,
        seq,
        decision.candidates_json(),
        String("done") if decision.is_done() else stages[decision.chosen].name,
        decision.reason,
        decision.model,
    )

    if decision.is_done():
        db.set_invocation_status(invocation_id, "done")
        return String(
            '{"invocation": "', invocation_id, '", "stage": null, "done": true}'
        )

    ref stage = stages[decision.chosen]
    var key = step_key(stage.params_json, stage.inputs)
    var step_id = db.start_step(
        invocation_id, seq, stage.name, stage.executor, stage.params_json
    )

    var metrics: String
    try:
        metrics = run_stage(app, inv, stage, work, min_path_m)
    except e:
        db.finish_step(step_id, "failed", "{}", "{}", "", json_escape(String(e)))
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
            app.abandon(inv)
            if not is_suspended(e):
                print("loop error:", e)
