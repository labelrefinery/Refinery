"""Writing the kind tables from an orca step.

The same rows as `refinery.publish` and `refinery.datasets` write outside orca,
committed through `orca.tables`, so each snapshot carries what orca records
for a commit -- its run, step, partition, code and the snapshots the step read
-- and `orca lineage` can walk from a label set to the scene it came from or
to every evaluation of it. That record is why there is no registry table (see
`refinery.datasets`). A step that calls these has to declare the dataset in
its `writes=`; orca refuses an undeclared one.

The tables are partitioned by `dataset_name`, so reading one dataset out of a
kind's table prunes to its files. Only this module imports orca, so only the
`orca` environment builds it.
"""

from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, Transform
from orca import Ctx
from orca.tables import append, ensure_table

from refinery.datasets import (
    EVALUATION_SCHEMA_JSON,
    LABELS_SCHEMA_JSON,
    EvalRow,
    dataset,
    evaluation_batch,
)
from refinery.publish import labels_batch

comptime LABELS = "labelrefinery.labels"
comptime EVALUATIONS = "labelrefinery.evaluations"
"""The datasets these write, for a step's `writes=`."""


def by_dataset_name() -> PartitionSpec:
    """Identity on `dataset_name`, field 1 of every kind schema."""
    return PartitionSpec(
        0,
        [
            PartitionField.single(
                1, 1000, String("dataset_name"), Transform.identity()
            )
        ],
    )


def produced_by(ctx: Ctx) -> String:
    """`<pipeline>.<step>`: what an evaluation row says made it."""
    return String(ctx.pipeline, ".", ctx.step)


def publish_labels(
    mut ctx: Ctx,
    labels_path: String,
    dataset_name: String,
    producer: String,
) raises -> Int64:
    """Appends a tracker CSV to `labelrefinery.labels` as `dataset_name` and
    returns the snapshot: that dataset's new version. A retried attempt gets
    its earlier attempt's snapshot back rather than appending twice."""
    var built = labels_batch(labels_path, dataset_name, String(ctx.run), producer)
    var rows = built.rows
    var table = ensure_table(
        ctx, dataset("labels"), Schema.parse(LABELS_SCHEMA_JSON), by_dataset_name()
    )
    var snapshot = append(ctx, table, [built^.into_batch()])
    ctx.log(String(dataset_name, ": ", rows, " label rows, snapshot ", snapshot))
    return snapshot


def write_evaluation(
    mut ctx: Ctx,
    dataset_name: String,
    rows: List[EvalRow],
    predictions: String,
    ground_truth: String,
) raises -> Int64:
    """Appends evaluation rows to `labelrefinery.evaluations` and returns the
    snapshot. `predictions` and `ground_truth` name the versions scored
    (`refinery.datasets.version_ref`), or are empty."""
    var table = ensure_table(
        ctx,
        dataset("evaluation"),
        Schema.parse(EVALUATION_SCHEMA_JSON),
        by_dataset_name(),
    )
    var batch = evaluation_batch(
        dataset_name,
        rows,
        predictions,
        ground_truth,
        produced_by(ctx),
        String(ctx.run),
    )
    return append(ctx, table, [batch^])
