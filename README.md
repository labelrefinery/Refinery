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

Same binary, same scene, `--terrain on|off`:

| | terrain off | terrain on | |
| --- | --- | --- | --- |
| TP | 1555 | **1555** | unchanged |
| FP | 2189 | **1700** | −489 |
| FN | 845 | **845** | unchanged |
| precision | 0.415 | **0.478** | +15% |
| recall | 0.648 | 0.648 | unchanged |
| F1 | 0.506 | **0.550** | +8.7% |
| ATE | 0.379 m | 0.365 m | |

**Identical TP and FN is the result worth having**: the terrain stage removed
489 false positives and cost exactly zero true positives, so it is only
removing things that were never objects.

Stone bins the cloud into a 2.5-D grid, fits a plane per cell from the scatter
matrix eigenvectors, and reports slope, roughness and step. The test stops being
*how high is this point* and becomes *is this cell part of a continuous surface,
or something standing on one*. A pile flank is steep but smooth and continuous
with its neighbours; a truck is not part of the height field at all. Height
stops mattering, continuity starts mattering — a 3.4 m pile is terrain, a 1.75 m
worker is not.

One honest adaptation: Stone's own output is a *traversability* label, and it
would call a 34° pile NON_TRAVERSABLE, correctly — nothing drives up it. That
is a different question from terrain-versus-object, so this uses Stone's
geometry and its driven-trajectory calibration but gates on roughness and step
with **slope ignored**. Slope is exactly the feature that separates traversable
ground from a pile, and exactly the feature that must not separate terrain from
an object.

It is not the elimination that was predicted. 87.3% of the *remaining* false
positives are still pile-related, down from 90.8%. The residue is most likely
toe cells, where a pile meets flat grade and one cell holds both surfaces. That
is the next lever.

Getting there took four attempts, each failing differently and informatively —
the sequence is in [docs/JOURNAL.md](docs/JOURNAL.md), along with the rest of
the build.

## Pipeline B — bootstrap

Not built yet. The loop:

```
A's pseudo-labels → CenterPillars.py (train) → CenterPillars.mojo (infer)
  → OfflinePoly.mojo (offline MOT) → TrackPermanence.mojo (occlusion recovery)
  → LabelFormer.mojo (trajectory refinement) → rescore → retrain
```

`GroundingDino.mojo` covers open-vocabulary discovery for whatever the detector
has no class for. The number that makes the case is one curve: label quality
against round, with the oracle as the ceiling.

## Layout

- `src/refinery/io.mojo` — sweeps, poses, joints; the sweep reader lifts points
  into the map frame in the same pass that decodes them
- `src/refinery/pipeline.mojo` — self-mask, detection, association, smoothing
- `src/main.mojo` — CLI

## License

Apache 2.0.
