"""Writes the keys dataset `av2.logs`: the AV2 logs `av2_pipeline_a` runs over.

    av2-logs <warehouse> <list.txt> [<prefix>]

`list.txt` has one log ID per line (`#` starts a comment). Each becomes a row
`(log_id, prefix)`, appended as one snapshot; IDs already in the table are
skipped, so adding logs is running this again with a longer list, and the
snapshot it makes is what orca's keyed sensors watch. The warehouse is a
directory or a location in object storage (`s3://bucket/warehouse`, through
objectstore, from the `AWS_*` environment or the instance role), as
`ORCA_WAREHOUSE` is for orca.
"""

from std.sys import argv

from iceberg.append import prepare_append
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.values import Datum
from iceberg.write import WriteOptions, write_data_files

from orca.cli import seed_random

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"log_id","required":true,"type":"string"},'
    '{"id":2,"name":"prefix","required":true,"type":"string"}]}'
)


def main() raises:
    seed_random()  # iceberg draws snapshot IDs from std.random
    var args = argv()
    if len(args) < 3:
        print("usage: av2-logs <warehouse> <list.txt> [<prefix>]")
        return
    var prefix = String(args[3]) if len(args) > 3 else String("sensor/val")
    var text: String
    with open(String(args[2]), "r") as f:
        text = f.read()

    var root = String(args[1])
    var cat = (
        FilesystemCatalog(String(root.rstrip("/")), FileIO()) if "://" in root
        and not root.startswith("file://") else FilesystemCatalog.local(root)
    )
    var schema = Schema.parse(SCHEMA)
    if not cat.table_exists("av2", "logs"):
        _ = cat.create_table(
            "av2", "logs", schema.copy(), PartitionSpec.unpartitioned()
        )
    var t = cat.load_table("av2", "logs")

    var have = Dict[String, Bool]()
    if t.metadata.has_current_snapshot:
        var res = (
            t.scan()
            .use_snapshot(t.metadata.current_snapshot_id)
            .select([String("log_id")])
            .to_table()
        )
        for row in range(res.num_rows()):
            have[res.value(row, 0).s] = True

    var ids = ColumnBuilder.of(schema, 1)
    var prefixes = ColumnBuilder.of(schema, 2)
    var added = 0
    for line in text.splitlines():
        var id = String(line.split("#")[0].strip())
        if not id or id in have:
            continue
        have[id] = True
        ids.add(Datum.string_(id))
        prefixes.add(Datum.string_(prefix))
        added += 1
    if added == 0:
        print("nothing new;", len(have), "logs already in av2.logs")
        return
    var files = write_data_files(
        t.io,
        t.metadata.location,
        [batch_of([ids^, prefixes^])],
        t.metadata.schema(),
        t.metadata.spec(),
        t.metadata.default_sort_order_id,
        WriteOptions.from_properties(t.metadata.properties),
    )
    var result = prepare_append(
        t.io, t.metadata, files^, Dict[String, String]()
    )
    t.commit(result)
    print("added", added, "logs to av2.logs, snapshot", result.snapshot_id)
