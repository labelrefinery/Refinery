"""Dataset schemas, for the tools that still speak pyarrow.

**`src/refinery/datasets.mojo` is the source of truth.** The registry and
resolver that used to live here -- register / lookup / resolve / lineage over
PyIceberg -- were ported to Mojo, where `iceberg.mojo` writes Iceberg natively
including the REST catalog and R2's vended-credentials handshake. That code was
never exercised against a live catalog and is gone rather than left to rot.

What survives is the two pyarrow schemas, and only because
`scripts/datasets_from_mcap.py` builds Parquet with pyarrow. When that
extractor moves to Mojo this file goes with it. Until then, keep these in step
with the Iceberg JSON in `datasets.mojo`: they are the same columns twice, which
is exactly the drift the Mojo side exists to prevent.
"""

from __future__ import annotations

import pyarrow as pa

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
