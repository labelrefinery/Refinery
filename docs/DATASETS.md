# Datasets

Every artefact this system produces or consumes is a **dataset**: a named,
versioned, immutable set of rows whose ancestry is recorded. Scenes, ground
truth, prompts, labels and evaluation results are all the same kind of thing,
and treating them that way is what makes "which labels came from which prompt
against which truth" a query rather than an archaeology project.

Storage is [Apache Iceberg](https://iceberg.apache.org) on **magmalake**, with
Parquet underneath. Nothing here needs a bespoke store — the properties we want
are exactly the ones a table format already provides.

---

## The concept

A dataset is `(name, version)`. Resolving it yields a set of rows and the
lineage that produced them.

```
name        labelrefinery.labels.site_seed1.round2
version     0.3.0
kind        labels
rows        2 377
parents     labelrefinery.labels.site_seed1.round1 @ 0.2.0
            labelrefinery.prompts.construction @ 1.1.0
produced_by improve_offboard_model  (git 6f49927, params {...})
snapshot    4612849022315…          ← the Iceberg snapshot this pins
```

Three properties, and each one earns its keep:

**Named.** A dataset is referred to by name, not by path. `--labels
runs/a/r2_labels.csv` is how the current workflows address data, and it is fine
for one machine and hopeless for two — nothing about that string says which
scene, which round, or which filter produced it.

**Versioned and immutable.** A version is never rewritten. A workflow that
re-runs produces a *new* version, and anything that consumed the old one still
resolves to exactly the rows it saw. This is why training runs stay
reproducible when a labeling bug gets fixed upstream: the old labels do not
change under them, they simply stop being the newest.

**Lineage-bearing.** Every version records its parents and the workflow run
that produced it. Ask "which labels are downstream of prompt v1.0.0" and it is
a graph walk over recorded edges — not a guess from timestamps.

---

## Kinds

### `scene` — a recording

Immutable input. One row per recording; the MCAP itself lives in object storage
and the row carries its identity.

| column | type | |
| --- | --- | --- |
| `scene_id` | string | `site_seed1` |
| `uri` | string | `s3://…/site_seed1_60s.mcap` |
| `sha256` | string | content identity, checked on read |
| `generator` | string | `sitegen` |
| `generator_version` | string | `0.2.0` |
| `seed`, `duration_s`, `rate_hz` | int/double | the parameters that reproduce it |
| `topics` | map<string,long> | message counts per topic |

A scene is reproducible from `(generator_version, seed, params)` — verified: the
same seed yields the same sha256. The row is the claim; the checksum is the
proof.

### `ground_truth` — the oracle, in three facets

Derived from a scene's held-out topics. **One dataset, three facets sharing one
identity space**: `instance_id` and `class` mean the same thing in all of them,
because the same pass wrote them.

That sharing is the point. A separate per-view "golden set" for prompt
validation could drift from the tracks, and then two evaluations of the same run
would disagree about what was present.

**`ground_truth.tracks`** — what the tracking and detection scorers read.

| column | type | |
| --- | --- | --- |
| `instance_id` | string | `truck_a` |
| `class` | string | `haul_truck` |
| `part` | string | `bed`, `boom`, … or null at object level |
| `t` | double | seconds from scene start |
| `x, y, z` | double | map frame |
| `w, l, h` | double | `l` along heading |
| `theta` | double | |
| `vx, vy` | double | finite difference |
| `num_lidar_points` | int | **how observable it was** |

`num_lidar_points` belongs in the truth, not in an eval config. It is what lets
a scorer say "recall on objects with ≥ 5 returns" instead of hard-coding
`--exclude grade_stake` — the stake is not a special case, it is the tail of a
distribution.

**`ground_truth.views`** — what prompt validation reads.

| column | type | |
| --- | --- | --- |
| `instance_id` | string | joins to `tracks` |
| `class` | string | |
| `camera` | string | `front_left` |
| `t` | double | |
| `x1, y1, x2, y2` | double | 2D box from the instance mask, not projected |
| `visible_px` | int | |
| `visible_fraction` | double | visible ÷ unoccluded projection |

Derived from `/ground_truth/camera_instances/*`, so the box is *measured
visibility*, not a projection that ignores occlusion. This is exactly the join I
did by hand to measure the prompt, and the reason to materialise it is that
doing it by hand is how two people end up with two different numbers.

**`ground_truth.points`** — per-point instance ids, for segmentation scoring.

### `prompt` — versioned prompt sets

A prompt is an input to a model and therefore versioned like any other.

| column | type | |
| --- | --- | --- |
| `prompt_id` | string | `construction_v1` |
| `text` | string | `"excavator . haul truck . worker . person ."` |
| `phrase` | string | one row per phrase — `haul truck` |
| `maps_to_class` | string | the ontology class it names — `haul_truck` |
| `ontology_version` | string | |
| `target_model` | string | `grounding-dino-tiny` |

One row per phrase, not per prompt string, because `maps_to_class` is the part
that matters and it is per phrase. It is also what turns a detector's raw label
into an ontology class without string-matching at the call site — the mapping is
data, versioned alongside the prompt that needs it.

### `labels` — anything a labeling workflow produced

Same schema as `ground_truth.tracks` plus the provenance every row must carry:

| column | type | |
| --- | --- | --- |
| … | | the tracks columns |
| `cls_conf` | double | confidence in the *name* |
| `cls_source` | string | `detector` / `size_prior` / `uncorroborated` |
| `producer` | string | `bootstrap_new_classes` |
| `producer_version` | string | git sha |
| `run_id` | string | the workflow run |
| `ontology_version` | string | |

`cls_source` is not decoration. Measured on seed-1, detector-assigned names were
100% correct and size-prior names 67%; a training step that cannot see which is
which has to treat them alike, and will be wrong about a third of the second
group.

### `evaluation` — scores are datasets too

A score is a claim about two other datasets and is worthless without knowing
which versions.

| column | type | |
| --- | --- | --- |
| `run_id` | string | |
| `predictions` | string | dataset name@version |
| `ground_truth` | string | dataset name@version |
| `slice` | string | `all`, `class=worker`, `points>=5` |
| `metric`, `value` | string, double | long form: one row per metric |
| `params` | map | threshold, class-agnostic, … |

Long form rather than a column per metric, so adding AOE later is rows, not a
schema migration.

---

## Layout on magmalake

One Iceberg table per kind, partitioned by dataset name; a registry maps
`(name, version)` to a table snapshot.

```
magmalake                              catalog
└── labelrefinery                      namespace
    ├── datasets                       the registry
    ├── scenes
    ├── ground_truth_tracks            partitioned by (dataset_name, day(t))
    ├── ground_truth_views             partitioned by (dataset_name, camera)
    ├── ground_truth_points            partitioned by (dataset_name)
    ├── prompts
    ├── labels                         partitioned by (dataset_name)
    └── evaluations
```

The registry is the only new concept:

| column | type | |
| --- | --- | --- |
| `name`, `version` | string | the identity |
| `kind` | string | scene / ground_truth / prompt / labels / evaluation |
| `table`, `snapshot_id` | string, long | where the rows are, **pinned** |
| `parents` | list<string> | `name@version`, the lineage edges |
| `produced_by` | string | workflow name |
| `producer_version` | string | git sha |
| `params` | map<string,string> | what the workflow was called with |
| `row_count` | long | |
| `created_at` | timestamp | |

Resolving a dataset is one lookup and one snapshot-pinned scan:

```sql
SELECT * FROM labelrefinery.labels
  FOR VERSION AS OF <snapshot_id>
 WHERE dataset_name = 'site_seed1.round2'
```

**Why the snapshot id rather than a timestamp.** Iceberg snapshots are immutable
by construction, so a pinned read returns the same rows forever, even after
compaction, schema evolution or a later append to the same table. A timestamp
does not survive a rewrite.

**Why one table per kind rather than one per dataset.** A table per dataset
means thousands of tables and a catalog nobody can list. Partitioning by
`dataset_name` gives the same pruning with one schema to evolve, and the
registry restores the named-thing addressing on top.

Write lineage into `snapshot_properties` as well as the registry — belt and
braces, and it means a snapshot is self-describing to anything reading the table
directly:

```python
df.write_iceberg(table, snapshot_properties={
    "dataset_name": "site_seed1.round2",
    "dataset_version": "0.3.0",
    "parents": json.dumps([...]),
    "produced_by": "improve_offboard_model",
    "producer_version": GIT_SHA,
})
```

---

## Versioning rules

Borrowed from the ontology note, because the classification is what makes
"a spec change triggers re-annotation" tractable rather than terrifying:

| change | bump | consumers |
| --- | --- | --- |
| **additive** — new rows, new nullable column | minor | old readers still valid |
| **refining** — a class splits, a name gets more specific | minor | old labels valid but coarse |
| **breaking** — a boundary is redefined, a column changes meaning | **major** | old labels invalid; downstream marked stale |

Only the third forces re-annotation. A consumer pins a major version and takes
minor bumps, so a prompt fix does not silently break a training run mid-flight.

---

## The prompt validation workflow

Codifying the measurement done by hand: `prompt` × `ground_truth.views` → an
`evaluation` dataset.

```
validate_prompt(prompt@version, ground_truth@version, model)
  ├─ select views                 visible_fraction ≥ τ, visible_px ≥ n
  ├─ run the detector             one call per selected view
  ├─ associate                    detection ↔ ground_truth.views box, by IoU
  ├─ map phrase → class           via the prompt dataset's maps_to_class
  └─ emit evaluation rows         per class and per view-difficulty slice
```

What it must report, because the hand measurement showed each of these matters:

- **precision and recall per class**, not pooled. Pooling hid the finding that
  the detector was perfect on trucks and blind to workers.
- **sliced by `visible_px`**, because a prompt that only works on objects
  filling the frame is a different prompt from one that works at 40 m.
- **the abstention rate** — views where a truth instance was present and
  nothing was returned. That is the number that decided `cls_source`, and it is
  invisible if you only score what was returned.

Then a prompt change is an A/B between two `prompt` versions over the *same*
`ground_truth` version, and the answer is a query rather than a memory of what
last week's run printed.

---

## Migrating what exists

The current CSVs already carry the right columns; they are missing identity.

1. `sitegen truth` → `ground_truth.tracks`, adding `num_lidar_points` (the
   raycaster already knows it — it is written to `/ground_truth/points`).
2. A new `sitegen views` export → `ground_truth.views`, from the instance masks.
3. `name_instances.py`'s output → `labels`, its `cls_source` / `cls_conf`
   already present.
4. `RunContext`'s manifest → the registry. It already records inputs, outputs,
   params and hashes per step; a dataset version is that record with a name
   attached.

Step 4 is the one to notice: the workflows already produce lineage, into a JSON
file per run. This design does not add provenance tracking, it moves what exists
somewhere queryable.
