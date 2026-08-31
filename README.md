# Refinery

Auto-labeling pipelines assembled from the labelrefinery components, run over
[sitegen](https://github.com/labelrefinery/sitegen) scenes and scored against
their held-out oracle.

This repo is **wiring, not algorithms**. Every stage already exists as its own
repo; what lives here is the assembly, and the A-versus-B comparison that
answers whether labels actually improve.

## Pipeline A — cold start

No labels. No checkpoints. No training. Every stage is geometry or classical
estimation, so it runs on a scene it has never seen:

```
sitegen MCAP
  → proprioception self-mask     forward kinematics from /ego/joint_states
  → terrain classification       Stone.mojo      (per-cell plane fit)
  → voxel clustering             26-neighbourhood connected components
  → oriented box fit             PCA heading in the ground plane
  → gated association            Hungarian.mojo  (solve_gated)
  → RTS smoothing                Kalman.mojo     (smooth_track)
  → tracks.csv
```

The output is the schema `OfflinePoly` reads, so the next stage is a pipe.

**The free supervision.** The ego publishes its own joint angles, so forward
kinematics puts its boom, stick and bucket exactly where they are and their
returns come out before anything else runs. About an eighth of every sweep is
the machine looking at itself; a clusterer handed those points invents a large
object welded to the sensor. Every pitch joint turns about the house's own
y-axis, so the angles add down the chain and each link is one rotation from the
house frame — the whole FK is twenty lines.

**Why the gate matters.** `solve_gated` leaves a track unmatched rather than
binding it to the cheapest available detection. Without it, a truck leaving the
scene gets welded to a worker thirty metres away, because that is still the
optimal complete assignment.

**Why offline.** Two stages here are only possible as a batch job. Track birth
filtering — dropping anything seen fewer than four times — requires knowing how
long a track lived, which an online tracker cannot know at birth. And the RTS
backward pass conditions every frame on the whole trajectory, so the first
detections, made when an object was distant and carried a handful of returns,
inherit the accuracy of the later close ones.

## Running it

```sh
# one-time: export the scene into the formats the stages read
sitegen tf     site.mcap --out work/tf.csv
sitegen joints site.mcap --out work/joints.csv
sitegen sweeps site.mcap --out work/sweeps

pixi run mojo run -I src src/main.mojo work work/pipeline_a.csv
sitegen score work/pipeline_a.csv --truth work/truth.csv --exclude grade_stake
```

Dependencies come from the registry, one command:

```sh
pixi shelf add hungarian-mojo kalman-mojo
```

## Where Pipeline A stands

600 frames, 5.8M points, the default seed-1 scene (sitegen 0.2.0), scored
class-agnostically at a 2 m centre-distance threshold with `--exclude
grade_stake`. Runs in about 90 seconds.

| | | |
| --- | --- | --- |
| precision | 0.415 | of what it labeled, how much was real |
| recall | 0.648 | of what was there, how much it found |
| F1 | 0.506 | |
| ATE | 0.379 m | mean centre error over true positives |
| ASE | 0.575 | `1 - IoU` once centred and aligned: pure size error |
| AOE | 0.746 rad | heading error, folded by pi, so the range is [0, pi/2] |
| ID switches | 16 | how often a truth object's assigned track id changed |

Read those numbers as a baseline to beat, and note *which* ones are bad,
because they say exactly what the learned stages are for:

**ATE is already good.** 38 cm on objects the pipeline was never told about.
Geometry finds where things are.

**ASE and AOE are bad, and structurally so.** AOE deserves reading carefully:
the scale runs 0 to pi/2, and a *uniformly random* heading averages 0.785 rad.
At 0.746 the PCA heading is statistically indistinguishable from a coin flip —
it carries no information. ASE 0.575 means an aligned IoU of 0.425, so the
boxes disagree on most of their volume even after being handed the right
position and heading.

Both have one cause, and it is not the code: a cluster is an object's *visible
surface*, not the object. A truck lit from one side has no far side in the
cloud, so the box comes out systematically short in depth and the principal
axis follows the illuminated face rather than the vehicle. No tuning fixes
this, because the information is not in a single sweep. It is in the
*trajectory* — which is precisely what `LabelFormer` refines and what a trained
detector encodes as a size prior. This is the clearest argument in the repo for
why stage B exists.

**Precision was dragged down by the ontology, not by the clustering.** Measured:
92.6% of false positives sat within 3 m of a stockpile toe, from 33 persistent
phantom tracks with a median footprint of 4.0 × 2.2 × 1.5 m. Genuinely above
ground, genuinely clustered, and the oracle calls them terrain. `Stone.mojo`
now runs ahead of clustering — see the ablation below.

**Recall depends entirely on what you count.** With grade stakes included it is
0.26; without them, 0.65. A stake is 50 mm square and collects a couple of
returns per sweep, so leaving it in measures the LiDAR rather than the labeler.
`--exclude grade_stake` is the honest default.

## The terrain stage, ablated

Same binary, same scene, four configurations:

| | none | threshold | grow | **grow + step guard** |
| --- | --- | --- | --- | --- |
| TP | 1555 | 1555 | 1542 | **1552** |
| FP | 2189 | 1700 | 782 | **824** |
| precision | 0.415 | 0.478 | 0.664 | **0.653** |
| recall | 0.648 | 0.648 | 0.643 | **0.647** |
| F1 | 0.506 | 0.550 | 0.653 | **0.650** |
| ATE | 0.379 m | 0.365 m | 0.445 m | **0.365 m** |
| ASE | 0.575 | 0.577 | 0.705 | **0.576** |

The shipped configuration is the last: **62% fewer false positives than the
baseline, three true positives lost out of 1555, and box quality unchanged.**
Pure region growing scores marginally better on precision and materially worse
on everything about the boxes, which is the wrong trade for a labeler whose
output trains a detector.

Pile-related false positives fell from 1987 (90.8% of all FPs) to 584 (70.9%),
and phantom tracks from 48 to 32.

### Why connectivity rather than a threshold

Stone bins the cloud into a 2.5-D grid, fits a plane per cell from the scatter
matrix eigenvectors, and reports slope, roughness and step. The first attempt
used those as per-cell thresholds and bought +15% precision — but 87% of the
remaining false positives were still pile-related, concentrated in *toe cells*
where a pile meets flat grade and one cell holds two surfaces, so the plane fit
is a compromise and the cell fails a test it should pass.

No threshold fixes that, because the question was never "is this cell flat". It
is **"is this cell connected to the ground"**. A stockpile is continuous with
the grade beneath it — you can walk from a driven cell to its peak without ever
stepping up more than the angle of repose allows. A truck is not: grade to roof
is a three metre jump, and no natural surface does that.

So the ground surface is grown, not thresholded: seed with cells beside the
machine's own path, flood outward, accept a neighbour whose floor is within one
cell's repose-limited rise (0.91 m). Toe cells get reached from either side and
stop being a special case. Height stops mattering; continuity starts mattering.

The step guard is the other half. A truck's lowest *visible* return sits 0.6 to
1.0 m above the grade beside it — inside the repose allowance — so pure growing
climbs onto vehicles and eats their lower bodies, leaving floating tops that
fit small, badly-placed boxes (ATE 0.365 → 0.445, ASE 0.577 → 0.705). Stone's
`step` closes it: the fill may cross a repose-limited rise, but only into a cell
that is itself thin. Connectivity decides where terrain extends; step decides
what is eligible to be terrain at all.

One honest adaptation: Stone's own output is a *traversability* label, and it
would call a 34° pile NON_TRAVERSABLE — correctly, nothing drives up it. That is
a different question from terrain-versus-object, so the fill ignores slope
entirely. Slope is exactly the feature that separates drivable ground from a
pile, and exactly the feature that must not separate terrain from an object.

Getting here took six attempts, each failing differently and informatively. The
sequence is in [docs/JOURNAL.md](docs/JOURNAL.md), along with the rest of the
build.

## Pipeline B — the bootstrap loop

```
A's pseudo-labels → filter → to_centerpillars.py → CenterPillars.py (train)
  → predict_sitegen.py (infer) → the same association + RTS smoothing → score
```

No changes to `CenterPillars.py`. Its `SweepDataset` already reads
`<root>/<split>/<log>/<ts>.npz`, so that layout is the interface;
`scripts/to_centerpillars.py` writes it and `scripts/predict_sitegen.py` runs
the checkpoint using CenterPillars as a library. Nothing human-labelled enters
at any point.

| | TP | FP | precision | recall | F1 | ATE | ASE | AOE |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A — teacher (round 0) | 1552 | 824 | 0.653 | 0.647 | 0.650 | **0.365** | 0.576 | 0.750 |
| B — round 1, unfiltered | 1424 | 953 | 0.599 | 0.593 | 0.596 | 0.387 | 0.498 | 0.579 |
| **B — round 2, filtered** | **1574** | **136** | **0.921** | **0.656** | **0.766** | 0.397 | 0.514 | 0.630 |

**Round two beats the teacher on every axis except ATE** — more true positives,
83% fewer false positives, better size and heading. But the curve is not
monotonic, and that is the point:

```
round 0  (geometry only)      F1 0.650
round 1  (unfiltered labels)  F1 0.596   <- regression
round 2  (filtered labels)    F1 0.766
```

**Round one made things worse.** Trained on the teacher's raw output it
*amplified* the systematic error — 29.5% of teacher rows sit on a stockpile,
37.4% of round-one output did. The label filter is not a refinement on the
loop; it is what makes the loop work at all.

### The filter, and a negative result

Three candidates were scored against the oracle *before* training on any of
them, because label quality predicts student quality and costs six minutes less
to measure:

| filter | rows | precision | recall | F1 |
| --- | --- | --- | --- | --- |
| baseline (unfiltered) | 2376 | 0.653 | **0.647** | 0.650 |
| teacher/student agreement | 1879 | 0.673 | 0.527 | 0.591 |
| **track motion** (path ≥ 4 m) | 1518 | **0.865** | 0.547 | **0.670** |
| both | 1122 | **0.942** | 0.440 | 0.600 |

Agreement — the obvious choice — is the **weakest**. The student was trained on
those labels, so it corroborates the teacher's systematic errors instead of
exposing them. Motion works, and physically: a stockpile phantom is an artifact
of which slivers survived ground removal in one sweep, so it neither persists
nor travels — median path **0.75 m** against **8.26 m** for real objects.

### The result worth reading twice

```
training labels   precision 0.865   recall 0.547
student output    precision 0.921   recall 0.656
```

The student is **better than its own supervision on both axes**. It recovered
objects the filter discarded and rejected false positives the filter admitted.
Below some label-precision threshold a self-training loop amplifies its own
errors; above it, the loop compounds. Somewhere between 0.653 and 0.865 is
where this one flips.

More precision is not always better: the `both` filter had cleaner labels
(0.942) and produced a *worse* student (F1 0.737), having thrown away a third
of the training rows to get there.

Still to wire: `OfflinePoly` sits at the right place but degrades size (see the
journal), and `TrackPermanence` / `LabelFormer` / `GroundingDino` need domain
checkpoints. AOE at 0.630 is the clearest target — `LabelFormer` refines a
whole trajectory rather than a frame, which is what heading needs.

## Named workflows

The two pipelines are `workflows/`, parameterised and resumable:

```sh
# instances from geometry and motion; no class names out
python -m workflows geo_kinetic_discovery \
    --scene site.mcap --work runs/a --truth runs/a/truth.csv

# distil a detector from those labels and label again
python -m workflows improve_offboard_model \
    --scene site.mcap --work runs/a --labels runs/a/labels.csv --round r1
```

Every stage declares its inputs, outputs and parameters; the context hashes
them and skips any stage a previous run already produced. Re-running a finished
workflow costs a second and touches nothing:

```
· export_scene               skipped (unchanged)
· geometric_labels           skipped (unchanged)
...
geo_kinetic_discovery: 0 steps ran, 7 skipped, 0s
```

That is not just convenience. Durable-execution engines replay handlers, so
every step must be idempotent or a retry doubles the work — making it true here
in plain Python means adopting Restate or Temporal later is *wrapping* this
rather than rewriting it. `manifest.<workflow>.json` doubles as the provenance
record: what ran, with which parameters, over which input hashes, producing
which artefacts.

Feeding one workflow's `labels` into the next is the loop:

| | training labels | student output |
| --- | --- | --- |
| precision | 0.865 | **0.910** |
| recall | 0.547 | **0.637** |
| F1 | 0.670 | **0.750** |

`min_path_m` is the load-bearing parameter, not a tuning knob — on unfiltered
labels the same code goes *backwards*.

## Looking at the labels

Scoring tells you a stage got worse; it does not tell you *where*. For that,
write the labels into their own MCAP and play them against the recording:

```sh
sitegen overlay round0.csv round1.csv round2.csv \
    --out labels.mcap --scene site.mcap

foxglove site.mcap labels.mcap        # Foxglove merges local files into one timeline
```

Each CSV becomes a `/pred/<name>` topic of cuboids with billboarded track ids,
one categorical colour each, independently toggleable beside
`/ground_truth/actors`. The scene file is never modified — three rounds of
labels come to 471 KB against an 86 MB recording, so one scene serves any
number of runs.

Prebuilt, if you would rather not run anything:

```sh
curl -O https://samples.magmalake.org/sitegen/v0.2.0/site_seed1_60s.mcap
curl -O https://samples.magmalake.org/sitegen/v0.2.0/labels_rounds.mcap
```

Scrub to t≈25 s: round 0 has objects standing on the stockpile, round 2 does
not. That is the 824 → 136 false-positive drop, visible rather than tabulated.

## Layout

- `src/refinery/io.mojo` — sweeps, poses, joints; the sweep reader lifts points
  into the map frame in the same pass that decodes them
- `src/refinery/pipeline.mojo` — self-mask, detection, association, smoothing
- `src/main.mojo` — CLI

## License

Apache 2.0.
