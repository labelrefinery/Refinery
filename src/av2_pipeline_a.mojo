"""Pipeline A over Argoverse 2 logs, as an orca pipeline keyed by log ID.

    pixi run -e orca av2-logs          # writes av2.logs from configs/av2_sample.txt
    pixi run -e orca av2-pipeline-a
    ./build/av2-pipeline-a run --partitions @all
    ./build/av2-pipeline-a run --partitions 02678d04-cc9f-3148-9f95-1ba66347dff9

The partitions are the `log_id`s of the warehouse dataset `av2.logs`
(`orca.keyed`), many per run. Per log:

1. **fetch** downloads the log from the public bucket and converts it to a
   work directory (`scripts/av2_fetch.py`); a log already converted is kept.
2. **label** runs Pipeline A on it (`run_geometry` with no proprioception and a
   terrain grid fitted to the drive) and appends its tracks to `av2.tracks_a`.
3. **score** matches the tracks to the log's annotations (`refinery.av2`) and
   appends the result to `av2.scores_a`.

Then **summary** adds up the run's scores. Each commit carries orca's lineage
properties, so `orca lineage av2.scores_a` says which run, code and tracks
snapshot a score came from.

Environment: `ORCA_WAREHOUSE` (the Iceberg warehouse), `AV2_ROOT` (work
directories, the download cache and fetch logs; default `runs/av2`),
`AV2_PREFIX` (the split under `datasets/av2/`; default `sensor/val`, whose logs
are annotated) and `AV2_PYTHON` (default `python`).
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
from refinery.io import read_csv_rows
from refinery.proc import run_checked
from refinery.stages import run_geometry

comptime TRACKS = "av2.tracks_a"
comptime SCORES = "av2.scores_a"

comptime TRACKS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"log_id","required":true,"type":"string"},'
    '{"id":2,"name":"track_id","required":true,"type":"long"},'
    '{"id":3,"name":"t","required":true,"type":"double"},'
    '{"id":4,"name":"x","required":true,"type":"double"},'
    '{"id":5,"name":"y","required":true,"type":"double"},'
    '{"id":6,"name":"z","required":true,"type":"double"},'
    '{"id":7,"name":"w","required":true,"type":"double"},'
    '{"id":8,"name":"l","required":true,"type":"double"},'
    '{"id":9,"name":"h","required":true,"type":"double"},'
    '{"id":10,"name":"vx","required":true,"type":"double"},'
    '{"id":11,"name":"vy","required":true,"type":"double"},'
    '{"id":12,"name":"theta","required":true,"type":"double"}]}'
)

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


def fetch(mut ctx: Ctx, log: Name) raises -> Fetched:
    """Downloads and converts one log, unless it's already converted."""
    var root = _env("AV2_ROOT", "runs/av2")
    var work = String(root, "/work/", log.text)
    if not exists(work + "/meta.json"):
        _ = run_checked(
            [
                _env("AV2_PYTHON", "python"),
                String("scripts/av2_fetch.py"),
                log.text,
                work,
                String("--prefix"),
                _env("AV2_PREFIX", "sensor/val"),
                String("--cache"),
                String(root, "/cache"),
            ],
            String(root, "/logs/", log.text, ".fetch.log"),
        )
    ctx.log(String("fetched ", log, " -> ", work))
    return Fetched(log.copy(), work^)


def label(mut ctx: Ctx, f: Fetched) raises -> Labeled:
    """Pipeline A on one log; its tracks go to `av2.tracks_a`."""
    var out = f.work + "/tracks.csv"
    var t0 = perf_counter_ns()
    var m = run_geometry(
        f.work, out, proprioception=False, fit_terrain_to_drive=True
    )
    var seconds = Float64(perf_counter_ns() - t0) / 1e9

    var schema = Schema.parse(TRACKS_SCHEMA)
    var cols = List[ColumnBuilder]()
    for id in range(1, 13):
        cols.append(ColumnBuilder.of(schema, id))
    for r in read_csv_rows(out):
        # track_id,cls,t,x,y,z,w,l,h,vx,vy,theta,conf
        cols[0].add(Datum.string_(f.log.text))
        cols[1].add(Datum.long_(Int64(Int(r[0]))))
        for c in range(2, 12):
            cols[c].add(Datum.double_(Float64(r[c])))
    var table = ensure_table(ctx, TRACKS, schema)
    var snap = append(ctx, table, [batch_of(cols)])
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


def score(mut ctx: Ctx, l: Labeled) raises -> Scored:
    """The log's tracks against its annotations; one row of `av2.scores_a`."""
    if not exists(l.work + "/annotations.csv"):
        raise Error(l.log.text + " has no annotations to score against")
    var s = score_log(l.work, l.work + "/tracks.csv")
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
    "label", Fetched, Labeled, label, Mapped, after=Fetch, writes=[TRACKS]
]
comptime Score = Step[
    "score", Labeled, Scored, score, Mapped, after=Label, writes=[SCORES]
]
comptime Summary = Step[
    "summary", Seq[Scored], Int, summary, Gather, after=Score
]

comptime Av2PipelineA = Pipeline[
    "av2_pipeline_a",
    Fetch,
    Label,
    Score,
    Summary,
    partitions=Keyed["av2.logs", "log_id"],
    keys_per_run=10,
]


def main() raises:
    orca_main[Av2PipelineA]()
