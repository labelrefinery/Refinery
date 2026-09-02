"""The Refinery executor: pipeline stages as a Restate service.

Each stage becomes a durable handler. A stage that dies half way is retried
from the journal rather than from the top of the loop, and the orchestrator
addresses stages by name rather than by assembling a `mojo run` command.

Running in-process also removes the JIT compile that `pixi run mojo run
src/main.mojo` paid on every single call.

    pixi run executor
    restate deployments register http://localhost:9080
    curl localhost:8080/RefineryExecutor/geometry -d '"work=/w&out=/w/labels.csv"'

The request body is `key=value` pairs joined by `&`, optionally wrapped in the
quotes a JSON string arrives with. Deliberately not JSON: restate.mojo hands
over raw bytes, both ends of this wire are ours, and a dependency-free format
keeps the executor's only inputs the ones the stage actually needs.

This service never calls another handler, so restate.mojo's single-threaded
driver — which deadlocks if a handler calls one served by the same process —
is not a constraint here.
"""

from restate import App, Ctx, Invocation, Unit

from refinery.stages import run_geometry, run_track_detections


def unquote(s: String) -> String:
    """Drop the surrounding quotes a JSON string body arrives with."""
    return String(String(s.strip()).removeprefix('"').removesuffix('"'))


def parse_params(body: String) -> Dict[String, String]:
    """`a=1&b=2` -> {a: 1, b: 2}. Empty and malformed pairs are skipped."""
    var out = Dict[String, String]()
    for pair in unquote(body).split("&"):
        var text = String(pair)
        if text.byte_length() == 0:
            continue
        var parts = text.split("=")
        if len(parts) < 2:
            continue
        var key = String(String(parts[0]).strip())
        # Rejoin on "=" so a value containing one survives -- paths do not,
        # but a prompt or a filter expression eventually will.
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


def get_float(
    params: Dict[String, String], key: String, fallback: Float64
) raises -> Float64:
    var raw = get(params, key, String(""))
    if raw.byte_length() == 0:
        return fallback
    return Float64(raw)


def require(params: Dict[String, String], key: String) raises -> String:
    var value = get(params, key, String(""))
    if value.byte_length() == 0:
        raise Error("missing required parameter: " + key)
    return value^


def handle_geometry(
    app: App, inv: Invocation, worker: Int, ctx: Ctx[Unit]
) raises -> None:
    var params = parse_params(inv.input_string())

    # Validate before doing anything. A missing parameter fails identically on
    # every retry, so it is terminal -- abandoning it would leave Restate
    # re-delivering and the caller hanging.
    var work: String
    var out: String
    try:
        work = require(params, "work")
        out = require(params, "out")
    except bad:
        app.fail(inv, String(bad))
        return

    var accel = get_float(params, "accel_var", 1.5)
    var meas = get_float(params, "meas_var", 0.25)
    var terrain = get(params, "terrain", "on") == "on"
    var reverse = get(params, "reverse", "off") == "on"

    # Journaled: the stage writes a CSV and is expensive, so a replay after a
    # crash must not run it a second time.
    @parameter
    def compute() raises -> String:
        return run_geometry(work, out, accel, meas, terrain, reverse).as_json()

    app.complete(inv, app.step[compute](inv))


def handle_track_detections(
    app: App, inv: Invocation, worker: Int, ctx: Ctx[Unit]
) raises -> None:
    var params = parse_params(inv.input_string())

    var detections: String
    var out: String
    try:
        detections = require(params, "detections")
        out = require(params, "out")
    except bad:
        app.fail(inv, String(bad))
        return

    var accel = get_float(params, "accel_var", 1.5)
    var meas = get_float(params, "meas_var", 0.25)
    var reverse = get(params, "reverse", "off") == "on"

    @parameter
    def compute() raises -> String:
        return run_track_detections(
            detections, out, accel, meas, reverse
        ).as_json()

    app.complete(inv, app.step[compute](inv))


def main() raises:
    var nothing = Unit()
    print(
        "RefineryExecutor listening on :9080 — register with"
        " `restate deployments register http://localhost:9080`"
    )
    var served = App.run[Unit, __functions_in_module()](
        "RefineryExecutor", nothing, object=False
    )
    print("stopped after", served, "invocations")
