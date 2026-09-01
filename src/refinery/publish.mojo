"""Promote a label CSV into a versioned Iceberg dataset.

A CSV on disk gets overwritten; an Iceberg snapshot does not. Once a human has
corrected labels, that correction is a claim about the data and deserves to
survive the next run — which is the whole argument in `docs/DATASETS.md`, and
the reason a reviewed file becomes a dataset rather than staying a file.

The schema is the one `workflows/datasets.py` defines, column for column, so
these rows land in the same shape a pipeline run would produce. The columns a
tracker CSV cannot supply — `part`, `num_lidar_points`, `producer_version`,
`ontology_version` — are written null rather than invented. `producer` and
`run_id` are filled in, because the point of promoting a reviewed file is
knowing who changed it and in which run.
"""

from iceberg.batch import ColumnBuilder, Datum, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.schema import Schema
from iceberg.types import P_DOUBLE, P_INT, P_LONG, P_STRING
from std.os.path import exists


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
struct PublishMetrics(Copyable, ImplicitlyCopyable, Movable):
    var rows: Int
    var snapshot_id: Int
    var table_path: String

    def as_json(self) -> String:
        return String(
            '{"rows": ',
            self.rows,
            ', "snapshot_id": ',
            self.snapshot_id,
            ', "table": "',
            self.table_path,
            '"}',
        )


def _column(header: List[String], name: String) -> Int:
    for i in range(len(header)):
        if header[i] == name:
            return i
    return -1


def _cell(row: List[String], col: Int) -> String:
    if col < 0 or col >= len(row):
        return String("")
    return row[col]


def _num(row: List[String], col: Int) raises -> Datum:
    var raw = _cell(row, col)
    if raw.byte_length() == 0:
        return Datum.none()
    return Datum.double_(Float64(raw))


def publish_labels(
    labels_path: String,
    warehouse: String,
    dataset_name: String,
    run_id: String,
    producer: String = "human_review",
) raises -> PublishMetrics:
    """Append `labels_path` to the `labelrefinery.labels` table as a new snapshot."""
    var handle = open(labels_path, "r")
    var text = handle.read()
    handle.close()

    var header = List[String]()
    var rows = List[List[String]]()
    var first = True
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            continue
        var cells = List[String]()
        for part in line.split(","):
            cells.append(String(part))
        if first:
            header = cells^
            first = False
            continue
        rows.append(cells^)

    var c_track = _column(header, "track_id")
    var c_cls = _column(header, "cls")
    var c_t = _column(header, "t")
    if c_track < 0 or c_t < 0:
        raise Error("labels CSV needs track_id and t: " + labels_path)

    var c_x = _column(header, "x")
    var c_y = _column(header, "y")
    var c_z = _column(header, "z")
    var c_w = _column(header, "w")
    var c_l = _column(header, "l")
    var c_h = _column(header, "h")
    var c_theta = _column(header, "theta")
    var c_vx = _column(header, "vx")
    var c_vy = _column(header, "vy")
    var c_conf = _column(header, "conf")
    var c_cconf = _column(header, "cls_conf")
    var c_csrc = _column(header, "cls_source")

    var b_dataset = ColumnBuilder(String("dataset_name"), 1, P_STRING)
    var b_instance = ColumnBuilder(String("instance_id"), 2, P_STRING)
    var b_class = ColumnBuilder(String("class"), 3, P_STRING)
    var b_part = ColumnBuilder(String("part"), 4, P_STRING)
    var b_t = ColumnBuilder(String("t"), 5, P_DOUBLE)
    var b_x = ColumnBuilder(String("x"), 6, P_DOUBLE)
    var b_y = ColumnBuilder(String("y"), 7, P_DOUBLE)
    var b_z = ColumnBuilder(String("z"), 8, P_DOUBLE)
    var b_w = ColumnBuilder(String("w"), 9, P_DOUBLE)
    var b_l = ColumnBuilder(String("l"), 10, P_DOUBLE)
    var b_h = ColumnBuilder(String("h"), 11, P_DOUBLE)
    var b_theta = ColumnBuilder(String("theta"), 12, P_DOUBLE)
    var b_vx = ColumnBuilder(String("vx"), 13, P_DOUBLE)
    var b_vy = ColumnBuilder(String("vy"), 14, P_DOUBLE)
    var b_npts = ColumnBuilder(String("num_lidar_points"), 15, P_INT)
    var b_conf = ColumnBuilder(String("conf"), 16, P_DOUBLE)
    var b_cconf = ColumnBuilder(String("cls_conf"), 17, P_DOUBLE)
    var b_csrc = ColumnBuilder(String("cls_source"), 18, P_STRING)
    var b_producer = ColumnBuilder(String("producer"), 19, P_STRING)
    var b_pver = ColumnBuilder(String("producer_version"), 20, P_STRING)
    var b_run = ColumnBuilder(String("run_id"), 21, P_STRING)
    var b_onto = ColumnBuilder(String("ontology_version"), 22, P_STRING)

    for i in range(len(rows)):
        ref row = rows[i]
        b_dataset.add(Datum.string_(dataset_name))
        b_instance.add(Datum.string_(_cell(row, c_track)))
        var cls = _cell(row, c_cls)
        b_class.add(
            Datum.none() if cls.byte_length() == 0 else Datum.string_(cls)
        )
        # Nothing a tracker CSV can supply: written null, not invented.
        b_part.add(Datum.none())
        b_npts.add(Datum.none())
        b_pver.add(Datum.none())
        b_onto.add(Datum.none())

        b_t.add(Datum.double_(Float64(_cell(row, c_t))))
        b_x.add(_num(row, c_x))
        b_y.add(_num(row, c_y))
        b_z.add(_num(row, c_z))
        b_w.add(_num(row, c_w))
        b_l.add(_num(row, c_l))
        b_h.add(_num(row, c_h))
        b_theta.add(_num(row, c_theta))
        b_vx.add(_num(row, c_vx))
        b_vy.add(_num(row, c_vy))
        b_conf.add(_num(row, c_conf))
        b_cconf.add(_num(row, c_cconf))

        var src = _cell(row, c_csrc)
        b_csrc.add(
            Datum.none() if src.byte_length() == 0 else Datum.string_(src)
        )
        b_producer.add(Datum.string_(producer))
        b_run.add(Datum.string_(run_id))

    var batch = batch_of(
        [
            b_dataset^, b_instance^, b_class^, b_part^, b_t^, b_x^, b_y^,
            b_z^, b_w^, b_l^, b_h^, b_theta^, b_vx^, b_vy^, b_npts^,
            b_conf^, b_cconf^, b_csrc^, b_producer^, b_pver^, b_run^, b_onto^,
        ]
    )

    var catalog = FilesystemCatalog.local(warehouse)
    var schema = Schema.parse(LABELS_SCHEMA_JSON)

    var table: Table
    if catalog.table_exists("labelrefinery", "labels"):
        table = catalog.load_table("labelrefinery", "labels")
    else:
        table = catalog.create_table("labelrefinery", "labels", schema)

    var tx = table.new_append()
    tx.add(batch)
    _ = tx.commit()

    # Re-load: the commit writes a new metadata file, and the in-memory table
    # still holds the pre-commit one, whose current-snapshot-id is -1.
    var committed = catalog.load_table("labelrefinery", "labels")
    var snapshot = committed.metadata.current_snapshot_id
    print(
        "published",
        len(rows),
        "rows to labelrefinery.labels snapshot",
        snapshot,
    )
    return PublishMetrics(len(rows), Int(snapshot), warehouse)
