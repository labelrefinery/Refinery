"""Pipeline A over Argoverse 2 logs, as an orca pipeline keyed by log ID.

    pixi run -e orca av2-logs          # writes av2.logs from configs/av2_sample.txt
    pixi run -e orca av2-pipeline-a
    ./build/av2-pipeline-a run --partitions @all
    ./build/av2-pipeline-a run --partitions 02678d04-cc9f-3148-9f95-1ba66347dff9

The partitions are the `log_id`s of the warehouse dataset `av2.logs`
(`orca.keyed`), many per run. Per log:

1. **fetch** downloads the log from the public bucket, converts it to a
   work directory (`refinery.av2_fetch`) and, when `AV2_WORK` is in object
   storage, uploads it there; a log already converted is kept.
2. **label** runs Pipeline A on it on the run's dista workers
   (`refinery.sweeps.run_geometry_tasks`: one terrain task, a detect task per
   sweep, with no proprioception and a terrain grid fitted to the drive) and
   appends its tracks to `labelrefinery.labels` as the dataset `av2/<log>`.
3. **view** publishes the log's view bundle (`refinery.av2_view`) to
   `AV2_VIEWS`, which the slice viewer reads: the work directory is on an
   instance that's gone once the run ends.
4. **score** matches the tracks to the log's annotations (`refinery.av2`) and
   appends the result to `av2.scores_a`, which the slice viewer lists, and its
   recall, precision floor and centre error to `labelrefinery.evaluations`,
   naming the labels snapshot it scored (`labelrefinery.labels@<snapshot>`).

Then **summary** adds up the run's scores. Each commit carries orca's lineage
properties, so `orca lineage av2.scores_a` says which run, code and labels
snapshot a score came from.

Environment: `ORCA_WAREHOUSE` (the Iceberg warehouse), `AV2_ROOT` (the
download cache; default `runs/av2`), `AV2_WORK` (work directories, a directory
or `s3://...`; default `<AV2_ROOT>/work`; workers on other machines need a URI
they can all read, see `refinery.workdir`, which mirrors it under
`REFINERY_CACHE`),
`AV2_PREFIX` (the split under `datasets/av2/`; default `sensor/val`, whose
logs are annotated) and `AV2_VIEWS` (where view bundles go, a directory or
`s3://...`; default `<AV2_ROOT>/views`).

Runs: `keys_per_run` logs each, at most `max_runs` at once. With orca's `ec2`
runner each run is a head instance, which runs the steps, and the workers it
was registered with (`orca register --workers 0..4 ...`), which run the
geometry's tasks; locally the workers are `ORCA_WORKERS` processes. A dista
worker runs one task at a time, so a worker instance of 2 vCPUs is enough.
"""

from std.os import getenv
from std.os.path import exists
from std.time import perf_counter_ns

from dista import Seq
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.schema import Schema
from iceberg.values import Datum
from orca import Ctx, Gather, Mapped, Name, Pipeline, Step, orca_main
from orca.keyed import Keyed
from orca.tables import append, ensure_table

from refinery.av2 import score_log
from refinery.av2_fetch import fetch_log
from refinery.av2_view import publish_view
from refinery.datasets import EvalRow, version_ref
from refinery.lake import EVALUATIONS, LABELS, publish_labels, write_evaluation
from refinery.sweeps import GeometryTasks, run_geometry_tasks
from refinery.workdir import WorkDir

comptime SCORES = "av2.scores_a"
comptime PRODUCER = "pipeline_a"

comptime SCORES_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"log_id","required":true,"type":"string"},'
    '{"id":2,"name":"frames","required":true,"type":"long"},'
    '{"id":3,"name":"annotated","required":true,"type":"long"},'
    '{"id":4,"name":"annotated_movable","required":true,"type":"long"},'
    '{"id":5,"name":"predicted","required":true,"type":"long"},'
    '{"id":6,"name":"matched","required":true,"type":"long"},'
    '{"id":7,"name":"matched_movable","required":true,"type":"long"},'
    '{"id":8,"name":"center_error_m","required":true,"type":"double"},'
    '{"id":9,"name":"label_seconds","required":true,"type":"double"},'
    '{"id":10,"name":"tracks_snapshot","required":true,"type":"long"}]}'
)
"""`tracks_snapshot` is the `labelrefinery.labels` snapshot the row scored."""


def _env(name: StaticString, fallback: StaticString) -> String:
    var v = getenv(name)
    return v if v else String(fallback)


@fieldwise_init
struct Fetched(Copyable, Movable):
    var log: Name
    var work: String


@fieldwise_init
struct Labeled(Copyable, Movable):
    var log: Name
    var work: String
    var frames: Int
    var detections: Int
    var kept: Int
    var seconds: Float64
    var snapshot: Int64


@fieldwise_init
struct Scored(Copyable, Movable):
    var log: Name
    var frames: Int
    var annotated: Int
    var annotated_movable: Int
    var predicted: Int
    var matched: Int
    var matched_movable: Int
    var center_error_m: Float64
    var seconds: Float64


def _dataset(log: Name) -> String:
    """The log's labels' `dataset_name`."""
    return String("av2/", log.text)


def fetch(mut ctx: Ctx, log: Name) raises -> Fetched:
    """Downloads and converts one log, unless it's already converted, and
    publishes the work directory where every worker reads it."""
    var root = _env("AV2_ROOT", "runs/av2")
    var base = getenv("AV2_WORK")
    if not base:
        base = String(root, "/work")
    var wd = WorkDir(String(base.rstrip("/"), "/", log.text))
    if wd.has("meta.json"):
        ctx.log(String(log, ": already converted in ", wd.uri))
        return Fetched(log.copy(), wd.uri)
    if not exists(wd.local + "/meta.json"):
        var meta = fetch_log(
            log.text,
            wd.local,
            prefix=_env("AV2_PREFIX", "sensor/val"),
            cache=String(root, "/cache"),
        )
        ctx.log(String(log, ": ", meta, " -> ", wd.local))
    if wd.remote():
        var t0 = perf_counter_ns()
        wd.publish()
        ctx.log(
            String(
                log,
                ": published to ",
                wd.uri,
                " in ",
                Float64(perf_counter_ns() - t0) / 1e9,
                " s",
            )
        )
    return Fetched(log.copy(), wd.uri)


def label(mut ctx: Ctx, f: Fetched) raises -> Labeled:
    """Pipeline A on one log, on the run's workers; its tracks go to
    `labelrefinery.labels` and beside the work directory's sweeps."""
    var wd = WorkDir(f.work)
    var out = wd.local + "/tracks.csv"
    var t0 = perf_counter_ns()
    var m = run_geometry_tasks(
        ctx.runtime[GeometryTasks](),
        wd.uri,
        out,
        proprioception=False,
        fit_terrain_to_drive=True,
    )
    var seconds = Float64(perf_counter_ns() - t0) / 1e9
    wd.put(["tracks.csv"])
    var snap = publish_labels(ctx, out, _dataset(f.log), PRODUCER)
    ctx.log(
        String(
            f.log,
            ": ",
            m.frames,
            " sweeps, ",
            m.raw_detections,
            " detections, ",
            m.kept,
            " tracks in ",
            seconds,
            " s",
        )
    )
    return Labeled(
        f.log.copy(),
        f.work.copy(),
        m.frames,
        m.raw_detections,
        m.kept,
        seconds,
        snap,
    )


def view(mut ctx: Ctx, l: Labeled) raises -> Labeled:
    """The log's view bundle, for the slice viewer."""
    var root = _env("AV2_VIEWS", "")
    if not root:
        root = String(_env("AV2_ROOT", "runs/av2"), "/views")
    var t0 = perf_counter_ns()
    var wd = WorkDir(l.work)
    wd.mirror()
    var n = publish_view(wd.local, l.log.text, root)
    ctx.log(
        String(
            l.log,
            ": view bundle, ",
            n // 1_000_000,
            " MB to ",
            root,
            " in ",
            Float64(perf_counter_ns() - t0) / 1e9,
            " s",
        )
    )
    return l.copy()


def score(mut ctx: Ctx, l: Labeled) raises -> Scored:
    """The log's tracks against its annotations: one row of `av2.scores_a`,
    and the metrics in `labelrefinery.evaluations`."""
    var wd = WorkDir(l.work)
    if not wd.has("annotations.csv"):
        raise Error(l.log.text + " has no annotations to score against")
    wd.mirror()
    var s = score_log(wd.local, wd.local + "/tracks.csv")
    var schema = Schema.parse(SCORES_SCHEMA)
    var cols = List[ColumnBuilder]()
    for id in range(1, 11):
        cols.append(ColumnBuilder.of(schema, id))
    cols[0].add(Datum.string_(l.log.text))
    cols[1].add(Datum.long_(Int64(s.frames)))
    cols[2].add(Datum.long_(Int64(s.annotated)))
    cols[3].add(Datum.long_(Int64(s.annotated_movable)))
    cols[4].add(Datum.long_(Int64(s.predicted)))
    cols[5].add(Datum.long_(Int64(s.matched)))
    cols[6].add(Datum.long_(Int64(s.matched_movable)))
    cols[7].add(Datum.double_(s.center_error_m))
    cols[8].add(Datum.double_(l.seconds))
    cols[9].add(Datum.long_(l.snapshot))
    var table = ensure_table(ctx, SCORES, schema)
    _ = append(ctx, table, [batch_of(cols)])
    var rows: List[EvalRow] = [
        EvalRow(String("all"), String("recall"), s.recall()),
        EvalRow(String("movable"), String("recall"), s.movable_recall()),
        EvalRow(String("all"), String("precision_floor"), s.precision()),
        EvalRow(String("all"), String("center_error_m"), s.center_error_m),
    ]
    _ = write_evaluation(
        ctx, _dataset(l.log), rows, version_ref(LABELS, l.snapshot), ""
    )
    ctx.log(String(l.log, ": ", s))
    return Scored(
        l.log.copy(),
        s.frames,
        s.annotated,
        s.annotated_movable,
        s.predicted,
        s.matched,
        s.matched_movable,
        s.center_error_m,
        l.seconds,
    )


def summary(mut ctx: Ctx, scores: Seq[Scored]) raises -> Int:
    """Recall and the precision floor over every object in the run's logs."""
    var frames = 0
    var annotated = 0
    var movable = 0
    var predicted = 0
    var matched = 0
    var matched_movable = 0
    var seconds = 0.0
    for i in range(len(scores)):
        ref s = scores[i]
        frames += s.frames
        annotated += s.annotated
        movable += s.annotated_movable
        predicted += s.predicted
        matched += s.matched
        matched_movable += s.matched_movable
        seconds += s.seconds
    ctx.log(
        String(
            len(scores),
            " logs, ",
            frames,
            " sweeps | recall ",
            Float64(matched) / Float64(max(annotated, 1)),
            " | movable recall ",
            Float64(matched_movable) / Float64(max(movable, 1)),
            " | precision floor ",
            Float64(matched) / Float64(max(predicted, 1)),
            " | labeling ",
            seconds / Float64(max(frames, 1)) * 1000.0,
            " ms per sweep",
        )
    )
    return len(scores)


comptime Fetch = Step["fetch", Name, Fetched, fetch, Mapped, retries=2]
comptime Label = Step[
    "label", Fetched, Labeled, label, Mapped, after=Fetch, writes=[LABELS]
]
comptime View = Step["view", Labeled, Labeled, view, Mapped, after=Label]
comptime Score = Step[
    "score",
    Labeled,
    Scored,
    score,
    Mapped,
    after=View,
    writes=[SCORES, EVALUATIONS],
]
comptime Summary = Step[
    "summary", Seq[Scored], Int, summary, Gather, after=Score
]

comptime Av2PipelineA = Pipeline[
    "av2_pipeline_a",
    Fetch,
    Label,
    View,
    Score,
    Summary,
    partitions=Keyed["av2.logs", "log_id"],
    keys_per_run=5,
    max_runs=8,
    tasks=GeometryTasks,
]


def main() raises:
    orca_main[Av2PipelineA]()
