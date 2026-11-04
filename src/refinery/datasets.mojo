"""The dataset schemas, one Iceberg table per kind, and the evaluation rows.

This file is the **single definition of the dataset schemas**. `publish.mojo`
and the orca pipelines read them from here, so the shape one writer produces
can't drift from another's.

A dataset is a name within a kind's table: the `dataset_name` column, which the
orca writers (`refinery.lake`) partition by. A version of it is the snapshot
that committed it, so reading at that snapshot returns the same rows forever --
after compaction, schema evolution and later appends to the same table, none of
which a timestamp would survive.

**There is no registry table.** Who made a snapshot, from which code and which
input snapshots is what orca records for every commit an orca step makes: the
snapshot summary carries `orca.run`, `orca.step`, `orca.code` and `orca.reads`,
and `orca lineage <table> <snapshot>` walks it both ways. Keeping a second copy
of that here would only let the two disagree. Where a row has to name another
dataset version, as an evaluation names the predictions and ground truth it
scored, it names it as `<table>@<snapshot>` (`version_ref`).
"""

from iceberg.batch import ColumnBuilder, Datum, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.schema import Schema
from iceberg.types import P_DOUBLE, P_INT, P_LONG, P_STRING
from parquet import RecordBatch


comptime NAMESPACE = "labelrefinery"


def dataset(kind: String) raises -> String:
    """The warehouse dataset a kind lives in, as orca names it:
    `labelrefinery.labels` for `labels`."""
    return String(NAMESPACE, ".", kind_table(kind))


def version_ref(dataset: String, snapshot: Int64) -> String:
    """One version of a dataset, as a row names it: `<dataset>@<snapshot>`."""
    return String(dataset, "@", snapshot)


def kind_table(kind: String) raises -> String:
    """One table per kind. The dataset name is a column, not a table.

    A table per dataset would mean thousands of tables and a catalog nobody can
    list; partitioning by name gives the same pruning with one schema to
    evolve.
    """
    if kind == "scene":
        return String("scenes")
    if kind == "ground_truth.tracks":
        return String("ground_truth_tracks")
    if kind == "ground_truth.views":
        return String("ground_truth_views")
    if kind == "ground_truth.points":
        return String("ground_truth_points")
    if kind == "prompt":
        return String("prompts")
    if kind == "labels":
        return String("labels")
    if kind == "evaluation":
        return String("evaluations")
    raise Error("unknown dataset kind: " + kind)


comptime LABELS_SCHEMA_JSON = """
{"type":"struct","schema-id":0,"fields":[
{"id":1,"name":"dataset_name","required":true,"type":"string"},
{"id":2,"name":"instance_id","required":true,"type":"string"},
{"id":3,"name":"class","required":false,"type":"string"},
{"id":4,"name":"part","required":false,"type":"string"},
{"id":5,"name":"t","required":true,"type":"double"},
{"id":6,"name":"x","required":false,"type":"double"},
{"id":7,"name":"y","required":false,"type":"double"},
{"id":8,"name":"z","required":false,"type":"double"},
{"id":9,"name":"w","required":false,"type":"double"},
{"id":10,"name":"l","required":false,"type":"double"},
{"id":11,"name":"h","required":false,"type":"double"},
{"id":12,"name":"theta","required":false,"type":"double"},
{"id":13,"name":"vx","required":false,"type":"double"},
{"id":14,"name":"vy","required":false,"type":"double"},
{"id":15,"name":"num_lidar_points","required":false,"type":"int"},
{"id":16,"name":"conf","required":false,"type":"double"},
{"id":17,"name":"cls_conf","required":false,"type":"double"},
{"id":18,"name":"cls_source","required":false,"type":"string"},
{"id":19,"name":"producer","required":false,"type":"string"},
{"id":20,"name":"producer_version","required":false,"type":"string"},
{"id":21,"name":"run_id","required":false,"type":"string"},
{"id":22,"name":"ontology_version","required":false,"type":"string"}
]}
"""


comptime EVALUATION_SCHEMA_JSON = """
{"type":"struct","schema-id":0,"fields":[
{"id":1,"name":"dataset_name","required":true,"type":"string"},
{"id":2,"name":"run_id","required":false,"type":"string"},
{"id":3,"name":"predictions","required":false,"type":"string"},
{"id":4,"name":"ground_truth","required":false,"type":"string"},
{"id":5,"name":"slice","required":false,"type":"string"},
{"id":6,"name":"metric","required":true,"type":"string"},
{"id":7,"name":"value","required":true,"type":"double"},
{"id":8,"name":"produced_by","required":false,"type":"string"},
{"id":9,"name":"created_at","required":false,"type":"string"}
]}
"""
"""Long form -- one row per metric per slice -- so adding a metric later is
rows rather than a schema migration. A score is a claim about two other
datasets, which is why `predictions` and `ground_truth` name versions."""

comptime PROMPT_SCHEMA_JSON = """
{"type":"struct","schema-id":0,"fields":[
{"id":1,"name":"dataset_name","required":true,"type":"string"},
{"id":2,"name":"prompt_id","required":true,"type":"string"},
{"id":3,"name":"text","required":true,"type":"string"},
{"id":4,"name":"phrase","required":true,"type":"string"},
{"id":5,"name":"maps_to_class","required":false,"type":"string"},
{"id":6,"name":"ontology_version","required":false,"type":"string"},
{"id":7,"name":"target_model","required":false,"type":"string"}
]}
"""
"""One row per phrase, not per prompt string, because `maps_to_class` is per
phrase -- and that mapping is what turns a detector's raw label into an
ontology class without string-matching at the call site."""


@fieldwise_init
struct EvalRow(Copyable, Movable):
    """One metric, one slice."""

    var slice: String
    var metric: String
    var value: Float64


def evaluation_batch(
    dataset_name: String,
    rows: List[EvalRow],
    predictions: String,
    ground_truth: String,
    produced_by: String,
    run_id: String,
    created_at: String = "",
) raises -> RecordBatch:
    """Evaluation rows as one batch of `EVALUATION_SCHEMA_JSON`.
    `predictions` and `ground_truth` name the versions scored
    (`version_ref`), or are empty when there are none."""
    var b_name = ColumnBuilder(String("dataset_name"), 1, P_STRING)
    var b_run = ColumnBuilder(String("run_id"), 2, P_STRING)
    var b_pred = ColumnBuilder(String("predictions"), 3, P_STRING)
    var b_gt = ColumnBuilder(String("ground_truth"), 4, P_STRING)
    var b_slice = ColumnBuilder(String("slice"), 5, P_STRING)
    var b_metric = ColumnBuilder(String("metric"), 6, P_STRING)
    var b_value = ColumnBuilder(String("value"), 7, P_DOUBLE)
    var b_by = ColumnBuilder(String("produced_by"), 8, P_STRING)
    var b_at = ColumnBuilder(String("created_at"), 9, P_STRING)

    for i in range(len(rows)):
        ref r = rows[i]
        b_name.add(Datum.string_(dataset_name))
        b_run.add(Datum.string_(run_id))
        b_pred.add(Datum.string_(predictions))
        b_gt.add(Datum.string_(ground_truth))
        b_slice.add(Datum.string_(r.slice))
        b_metric.add(Datum.string_(r.metric))
        b_value.add(Datum.double_(r.value))
        b_by.add(Datum.string_(produced_by))
        b_at.add(Datum.string_(created_at))

    return batch_of(
        [
            b_name^, b_run^, b_pred^, b_gt^, b_slice^, b_metric^, b_value^,
            b_by^, b_at^,
        ]
    )


def write_evaluation(
    mut catalog: FilesystemCatalog,
    dataset_name: String,
    rows: List[EvalRow],
    predictions: String,
    ground_truth: String,
    produced_by: String,
    run_id: String,
    created_at: String = "",
) raises -> Int:
    """Append evaluation rows outside orca and return the snapshot they landed
    in. The Restate loop's writer, until it moves to orca; an orca step uses
    `refinery.lake.write_evaluation`, which records lineage."""
    var target = kind_table("evaluation")
    var table: Table
    if catalog.table_exists(NAMESPACE, target):
        table = catalog.load_table(NAMESPACE, target)
    else:
        table = catalog.create_table(
            NAMESPACE, target, Schema.parse(EVALUATION_SCHEMA_JSON)
        )

    var tx = table.new_append()
    tx.add(
        evaluation_batch(
            dataset_name,
            rows,
            predictions,
            ground_truth,
            produced_by,
            run_id,
            created_at,
        )
    )
    _ = tx.commit()

    var committed = catalog.load_table(NAMESPACE, target)
    var snapshot = Int(committed.metadata.current_snapshot_id)
    print("evaluation:", len(rows), "rows ->", target, "snapshot", snapshot)
    return snapshot
