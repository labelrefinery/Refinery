"""Named, versioned, immutable datasets with recorded lineage.

The Mojo port of `workflows/datasets.py`, which was written before the pipeline
moved to Mojo and used PyIceberg for what `iceberg.mojo` now does natively --
including the REST catalog's `X-Iceberg-Access-Delegation: vended-credentials`
handshake, which is exactly what R2 Data Catalog needs. It was also never
exercised against a live catalog.

This file is the **single definition of the dataset schemas**. `publish.mojo`
reads them from here, so the shape a pipeline writes cannot drift from the
shape the registry claims was written.

A dataset is `(name, version)`. Resolving it is a registry lookup followed by a
snapshot-pinned read, so a version returns the same rows forever -- after
compaction, after schema evolution, after later appends to the same table. A
timestamp would survive none of those.

**Two deliberate deviations from the Python schema**, both about nested types.
`parents` is a comma-separated string rather than `list<string>`, and `params`
is a JSON string rather than `map<string,string>`. Building nested Arrow by
hand costs more than it buys for a table whose rows are read one at a time by
`lookup`, and there is no existing data to stay compatible with. If the
registry ever needs to be queried *by* parent, `iceberg.batch.NestedBuilder`
is the way back.
"""

from iceberg.batch import ColumnBuilder, Datum, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.schema import Schema
from iceberg.types import P_DOUBLE, P_INT, P_LONG, P_STRING


comptime NAMESPACE = "labelrefinery"
comptime REGISTRY_TABLE = "datasets"


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


comptime REGISTRY_SCHEMA_JSON = """
{"type":"struct","schema-id":0,"fields":[
{"id":1,"name":"name","required":true,"type":"string"},
{"id":2,"name":"version","required":true,"type":"string"},
{"id":3,"name":"kind","required":true,"type":"string"},
{"id":4,"name":"table","required":true,"type":"string"},
{"id":5,"name":"snapshot_id","required":true,"type":"long"},
{"id":6,"name":"parents","required":false,"type":"string"},
{"id":7,"name":"produced_by","required":false,"type":"string"},
{"id":8,"name":"producer_version","required":false,"type":"string"},
{"id":9,"name":"params","required":false,"type":"string"},
{"id":10,"name":"row_count","required":false,"type":"long"},
{"id":11,"name":"created_at","required":true,"type":"string"}
]}
"""

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


@fieldwise_init
struct Dataset(Copyable, Movable):
    """One registered version."""

    var name: String
    var version: String
    var kind: String
    var table: String
    var snapshot_id: Int
    var parents: List[String]
    var produced_by: String
    var producer_version: String
    var params: String
    var row_count: Int

    def ref(self) -> String:
        return self.name + "@" + self.version


def join_parents(parents: List[String]) -> String:
    var out = String("")
    for i in range(len(parents)):
        if i > 0:
            out += ","
        out += parents[i]
    return out^


def split_parents(raw: String) -> List[String]:
    var out = List[String]()
    if raw.byte_length() == 0:
        return out^
    for part in raw.split(","):
        var one = String(String(part).strip())
        if one.byte_length() > 0:
            out.append(one^)
    return out^


def _open_registry(mut catalog: FilesystemCatalog) raises -> Table:
    if catalog.table_exists(NAMESPACE, REGISTRY_TABLE):
        return catalog.load_table(NAMESPACE, REGISTRY_TABLE)
    return catalog.create_table(
        NAMESPACE, REGISTRY_TABLE, Schema.parse(REGISTRY_SCHEMA_JSON)
    )


def register(
    mut catalog: FilesystemCatalog,
    name: String,
    version: String,
    kind: String,
    snapshot_id: Int,
    row_count: Int,
    parents: List[String],
    produced_by: String = "",
    producer_version: String = "",
    params: String = "{}",
    created_at: String = "",
) raises -> Dataset:
    """Record a version. Never updates a row -- versions are immutable."""
    var table = _open_registry(catalog)

    var b_name = ColumnBuilder(String("name"), 1, P_STRING)
    var b_version = ColumnBuilder(String("version"), 2, P_STRING)
    var b_kind = ColumnBuilder(String("kind"), 3, P_STRING)
    var b_table = ColumnBuilder(String("table"), 4, P_STRING)
    var b_snap = ColumnBuilder(String("snapshot_id"), 5, P_LONG)
    var b_parents = ColumnBuilder(String("parents"), 6, P_STRING)
    var b_by = ColumnBuilder(String("produced_by"), 7, P_STRING)
    var b_pver = ColumnBuilder(String("producer_version"), 8, P_STRING)
    var b_params = ColumnBuilder(String("params"), 9, P_STRING)
    var b_rows = ColumnBuilder(String("row_count"), 10, P_LONG)
    var b_at = ColumnBuilder(String("created_at"), 11, P_STRING)

    var target = kind_table(kind)
    b_name.add(Datum.string_(name))
    b_version.add(Datum.string_(version))
    b_kind.add(Datum.string_(kind))
    b_table.add(Datum.string_(target))
    b_snap.add(Datum.long_(Int64(snapshot_id)))
    b_parents.add(Datum.string_(join_parents(parents)))
    b_by.add(Datum.string_(produced_by))
    b_pver.add(Datum.string_(producer_version))
    b_params.add(Datum.string_(params))
    b_rows.add(Datum.long_(Int64(row_count)))
    b_at.add(Datum.string_(created_at))

    var tx = table.new_append()
    tx.add(
        batch_of(
            [
                b_name^, b_version^, b_kind^, b_table^, b_snap^, b_parents^,
                b_by^, b_pver^, b_params^, b_rows^, b_at^,
            ]
        )
    )
    _ = tx.commit()

    print("registered", name + "@" + version, "->", target, "@", snapshot_id)
    return Dataset(
        name,
        version,
        kind,
        target,
        snapshot_id,
        parents.copy(),
        produced_by,
        producer_version,
        params,
        row_count,
    )
