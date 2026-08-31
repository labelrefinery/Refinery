"""Named, versioned datasets on magmalake — Iceberg tables in R2.

The concept is in `docs/DATASETS.md`; this is the resolver and the registry.

A dataset is `(name, version)`. Resolving it is a registry lookup followed by a
**snapshot-pinned** scan, so a version returns the same rows forever — after
compaction, after schema evolution, after later appends to the same table. A
timestamp would not survive any of those.

Physical layout is one table per kind, partitioned by dataset name, plus a
registry mapping names to snapshots. A table per dataset would mean thousands
of tables and a catalog nobody can list.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pyarrow as pa

NAMESPACE = "labelrefinery"
REGISTRY_TABLE = f"{NAMESPACE}.datasets"

#: One table per kind. The dataset name is a column, not a table.
KIND_TABLES = {
    "scene": f"{NAMESPACE}.scenes",
    "ground_truth.tracks": f"{NAMESPACE}.ground_truth_tracks",
    "ground_truth.views": f"{NAMESPACE}.ground_truth_views",
    "ground_truth.points": f"{NAMESPACE}.ground_truth_points",
    "prompt": f"{NAMESPACE}.prompts",
    "labels": f"{NAMESPACE}.labels",
    "evaluation": f"{NAMESPACE}.evaluations",
}

REGISTRY_SCHEMA = pa.schema(
    [
        pa.field("name", pa.string(), nullable=False),
        pa.field("version", pa.string(), nullable=False),
        pa.field("kind", pa.string(), nullable=False),
        pa.field("table", pa.string(), nullable=False),
        pa.field("snapshot_id", pa.int64(), nullable=False),
        pa.field("parents", pa.list_(pa.string())),
        pa.field("produced_by", pa.string()),
        pa.field("producer_version", pa.string()),
        pa.field("params", pa.map_(pa.string(), pa.string())),
        pa.field("row_count", pa.int64()),
        pa.field("created_at", pa.timestamp("us", tz="UTC"), nullable=False),
    ]
)

TRACKS_SCHEMA = pa.schema(
    [
        pa.field("dataset_name", pa.string(), nullable=False),
        pa.field("instance_id", pa.string(), nullable=False),
        pa.field("class", pa.string()),
        pa.field("part", pa.string()),
        pa.field("t", pa.float64(), nullable=False),
        pa.field("x", pa.float64()), pa.field("y", pa.float64()), pa.field("z", pa.float64()),
        pa.field("w", pa.float64()), pa.field("l", pa.float64()), pa.field("h", pa.float64()),
        pa.field("theta", pa.float64()),
        pa.field("vx", pa.float64()), pa.field("vy", pa.float64()),
        # How observable the object was. In the truth rather than in an eval
        # config, so a scorer can say "recall on objects with >= 5 returns"
        # instead of hard-coding an exclusion: a grade stake is not a special
        # case, it is the tail of a distribution.
        pa.field("num_lidar_points", pa.int32()),
    ]
)

LABELS_SCHEMA = pa.schema(
    list(TRACKS_SCHEMA)
    + [
        pa.field("conf", pa.float64()),
        pa.field("cls_conf", pa.float64()),
        # detector / size_prior / uncorroborated. Measured on seed-1,
        # detector-assigned names were 100% correct and size-prior names 67%;
        # a consumer that cannot tell them apart must treat them alike.
        pa.field("cls_source", pa.string()),
        pa.field("producer", pa.string()),
        pa.field("producer_version", pa.string()),
        pa.field("run_id", pa.string()),
        pa.field("ontology_version", pa.string()),
    ]
)


class CredentialsMissing(RuntimeError):
    pass


def load_env(repo: Path | None = None) -> dict[str, str]:
    """Environment first, then `.env` at the repo root.

    `.env` rather than a shell profile is deliberate: this token can write to
    the lakehouse, and scoping it to the project beats putting it in every
    shell that opens.
    """
    values = {}
    root = repo or Path(__file__).resolve().parent.parent
    env_file = root / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip("'\"")
    for key in ("R2_CATALOG_URI", "R2_WAREHOUSE", "R2_CATALOG_TOKEN"):
        if os.environ.get(key):
            values[key] = os.environ[key]

    missing = [k for k in ("R2_CATALOG_URI", "R2_WAREHOUSE", "R2_CATALOG_TOKEN")
               if not values.get(k)]
    if missing:
        raise CredentialsMissing(
            f"missing {', '.join(missing)}.\n"
            f"Copy {root / '.env.example'} to {env_file} and fill in the token, "
            "or export them. See docs/DATASETS.md."
        )
    return values


def catalog(repo: Path | None = None):
    """The R2 Data Catalog, over its Iceberg REST interface."""
    from pyiceberg.catalog.rest import RestCatalog

    env = load_env(repo)
    return RestCatalog(
        name="magmalake",
        warehouse=env["R2_WAREHOUSE"],
        uri=env["R2_CATALOG_URI"],
        token=env["R2_CATALOG_TOKEN"],
    )


@dataclass
class Dataset:
    name: str
    version: str
    kind: str
    table: str
    snapshot_id: int
    parents: list[str] = field(default_factory=list)
    produced_by: str = ""
    producer_version: str = ""
    params: dict[str, str] = field(default_factory=dict)
    row_count: int = 0

    @property
    def ref(self) -> str:
        return f"{self.name}@{self.version}"


def ensure_namespace(cat: Any) -> None:
    if (NAMESPACE,) not in cat.list_namespaces():
        cat.create_namespace(NAMESPACE)


def ensure_table(cat: Any, identifier: str, schema: pa.Schema, partition_by: str | None = None):
    from pyiceberg.exceptions import NoSuchTableError

    try:
        return cat.load_table(identifier)
    except NoSuchTableError:
        return cat.create_table(identifier, schema=schema)


def register(
    cat: Any,
    name: str,
    version: str,
    kind: str,
    snapshot_id: int,
    row_count: int,
    parents: list[str] | None = None,
    produced_by: str = "",
    producer_version: str = "",
    params: dict[str, str] | None = None,
) -> Dataset:
    """Record a version. Never updates a row -- versions are immutable."""
    table = ensure_table(cat, REGISTRY_TABLE, REGISTRY_SCHEMA)
    entry = Dataset(
        name=name, version=version, kind=kind, table=KIND_TABLES[kind],
        snapshot_id=snapshot_id, parents=parents or [], produced_by=produced_by,
        producer_version=producer_version, params=params or {}, row_count=row_count,
    )
    table.append(
        pa.Table.from_pylist(
            [
                {
                    "name": entry.name, "version": entry.version, "kind": entry.kind,
                    "table": entry.table, "snapshot_id": entry.snapshot_id,
                    "parents": entry.parents, "produced_by": entry.produced_by,
                    "producer_version": entry.producer_version,
                    "params": list(entry.params.items()),
                    "row_count": entry.row_count,
                    "created_at": time.gmtime(),
                }
            ],
            schema=REGISTRY_SCHEMA,
        )
    )
    return entry


def lookup(cat: Any, ref: str) -> Dataset:
    """`name@version`, or `name` for the most recently registered version."""
    name, _, version = ref.partition("@")
    table = cat.load_table(REGISTRY_TABLE)
    rows = table.scan(row_filter=f"name = '{name}'").to_arrow().to_pylist()
    if version:
        rows = [r for r in rows if r["version"] == version]
    if not rows:
        raise KeyError(f"no dataset {ref!r} in the registry")
    row = max(rows, key=lambda r: r["created_at"])
    return Dataset(
        name=row["name"], version=row["version"], kind=row["kind"], table=row["table"],
        snapshot_id=row["snapshot_id"], parents=row["parents"] or [],
        produced_by=row["produced_by"] or "", producer_version=row["producer_version"] or "",
        params=dict(row["params"] or []), row_count=row["row_count"] or 0,
    )


def resolve(cat: Any, ref: str) -> pa.Table:
    """The rows of a dataset version, pinned to the snapshot it was registered at."""
    entry = lookup(cat, ref)
    table = cat.load_table(entry.table)
    return (
        table.scan(
            row_filter=f"dataset_name = '{entry.name}'",
            snapshot_id=entry.snapshot_id,
        )
        .to_arrow()
    )


def lineage(cat: Any, ref: str, depth: int = 10) -> list[tuple[int, Dataset]]:
    """Walk the recorded parent edges. Depth-first, deduplicated."""
    out: list[tuple[int, Dataset]] = []
    seen: set[str] = set()

    def walk(node: str, level: int) -> None:
        if level > depth or node in seen:
            return
        seen.add(node)
        try:
            entry = lookup(cat, node)
        except KeyError:
            return
        out.append((level, entry))
        for parent in entry.parents:
            walk(parent, level + 1)

    walk(ref, 0)
    return out
