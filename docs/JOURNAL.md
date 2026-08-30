# Build journal

A running log of what was built, what broke, and what the numbers said. Kept
because the interesting part of an auto-labeling pipeline is rarely the
architecture diagram — it is the sequence of measurements that forced each
decision.

Every number here was measured on the machine, not estimated.

---

## 1. There was no data, so the data came first

The goal was two pipelines over the same scene: one starting with no labels at
all, one bootstrapping a model from the first one's output. That only means
anything if something can score the result, which rules out every public
dataset — they either have no labels (nothing to score against) or have them
(you are not really starting unlabeled).

Nothing synthetic exists for construction. [3D-ConHE](https://www.mdpi.com/2076-3417/14/9/3599)
is loose CAD models; [Rohbau3D](https://www.nature.com/articles/s41597-025-05827-7)
is static real scans. Neither has motion, a sensor, or truth.

So: **[sitegen](https://github.com/labelrefinery/sitegen)**, which writes one
MCAP holding both the observable topics and a held-out oracle, on the rule that
only the scorer reads `/ground_truth/*`. Both live in one file so the truth
cannot drift from the data — the same pass wrote them.

## 2. The obvious sensor mount was wrong

First scene generated cleanly, so the next question was whether the returns
were distributed like a real sweep. They were not:

```
ego/excavator.house   67% of all returns
```

The LiDAR was on the middle of the cab roof, which is where you would naturally
put it, and it was firing two thirds of its downward beams into its own house.
Moving it to a front mast fixed it:

```
terrain                  82.6%
ego/excavator.house       7.9%    ← self-returns, realistic and useful
truck_a/haul_truck.bed    4.1%
ego/excavator.boom        4.0%
worker_0                  0.2%
worker_1                  0.1%
```

That distribution is the point of the whole dataset: **the two workers together
are 0.3% of the cloud.** A worker at 14 m gets about 20 points, which pencils
out exactly from the beam spacing, so the sensor physics is right and the hard
case is genuinely hard.

*Lesson: check the histogram before trusting the renderer.*

## 3. The scorer was validated before being trusted

A referee you have not tested is not a referee. Two checks:

- truth scored against itself → exactly `1.0 / 1.0 / 1.0`, zero error, zero
  switches
- truth plus injected 0.3σ jitter → **ATE 0.3747** against the analytic
  expectation `0.3 · √(π/2) = 0.3760`, and **AOE 0.0798** against an injected
  0.1σ

Matching is nuScenes-style: greedy by descending confidence against centre
*distance*, not IoU. A truck at 45 m carrying eight returns will never reach an
IoU threshold however good the tracker is, and an eval that reports zero there
is measuring the sensor.

## 4. Pipeline A ran, and reported zero tracks

Detection worked immediately — 4 to 6 objects per frame, 3061 across the scene.
Tracking reported `tracks: 0`.

The association loop had a branch for "no live tracks yet" that coasted
existing tracks and returned. On frame zero there are no live tracks *and* no
tracks are ever born, so nothing could ever start. Spawning is now
unconditional on unclaimed detections.

*Lesson: a pipeline that produces zero output is a better bug than one that
produces plausible output.*

## 5. Recall was measuring the LiDAR, not the labeler

First honest score came out at recall **0.27**, which felt wrong given the
detections looked reasonable. Breaking the oracle down by class:

```
3600 grade_stake      ← 60% of all ground-truth rows
1200 worker
 600 haul_truck
 600 excavator
```

A grade stake is 50 mm square and collects a couple of returns per sweep.
Excluding them, the same run scores recall **0.69**. Nothing about the pipeline
changed; the metric had been dominated by objects the sensor cannot resolve.

`sitegen score --exclude grade_stake` makes that a documented choice rather
than a shell `grep`.

## 6. The false positives were measured, not assumed

The write-up initially claimed "most false positives are stockpiles". That was
an inference, so it got checked:

```
false positives                     1779
  within 3 m of a stockpile toe     1647   (92.6%)
  from                                33   distinct phantom tracks
  median footprint            4.0 × 2.2 × 1.5 m
```

Claim survived, with a number attached. The mechanism was then traceable
exactly: ground removal was "per 1 m cell, drop within 0.35 m of the lowest
point", but a pile at its 34° angle of repose climbs `tan(34°) × 1.0 = 0.67 m`
across one cell — nearly double the tolerance. The bottom of each cell was
called ground and the top third survived as slivers, which the clusterer
correctly turned into vehicle-shaped objects.

Tightening the tolerance does not fix that. It trades those false positives for
false negatives on real objects standing near slopes.

## 7. The machine could not stand still

The fix for §6 was Stone, which calibrates terrain from the cells a machine
actually drove over — free supervision, exactly like joint angles are for the
boom chain. Except the ego excavator's base was pinned at the origin for all
60 seconds. No trajectory, no calibration.

A stationary sensor was quietly removing three things worth testing anyway: the
map never grew, occlusion behind the stockpile never resolved, and there was
nothing for a terrain labeler to learn from. So the machine now cuts what it
can reach, **walks 6.5 m back along the trench line** at ~0.8 m/s with the
house squared up and the boom tucked, and digs again. The second hauler
repositions with it.

The scene got harder, which is correct:

| | static (0.1.0) | walking (0.2.0) |
| --- | --- | --- |
| precision | 0.481 | 0.415 |
| recall | 0.686 | 0.648 |
| F1 | 0.565 | 0.506 |
| ID switches | 9 | 16 |

A moving sensor sees more of the stockpile from more angles, and the ego's own
motion makes association work harder.

## 8. Stone took four attempts, and every failure was informative

**Attempt 1 — the calibration ate the machine.** `tau_step` came back at
**2.89 m**, wide enough to swallow a haul truck, and detections collapsed from
3025 to 687. The terrain grid was ingesting the ego's own returns, and the
driven cells are *exactly where the machine is standing*, so "known ground"
contained a three-metre machine.

*The self-mask has to run before the terrain calibration, not just before the
clusterer.* Moving it there removed **863,324 points — 15.0% of the scene**,
which matches the independent estimate from §2.

**Attempt 2 — the machine cannot see the ground it stands on.** With the ego
removed, `driven cells: 0`. Its own body occludes the ground beneath it and the
self-mask removes whatever returns leak through, so the trajectory cells come
back unobserved and the calibration set is empty. It silently fell through to
the hard-coded floors — which produced *plausible* numbers, the most dangerous
kind of failure.

Fix: calibrate from the observed cells *beside* the path (3-cell dilation). The
machine physically drove through that patch, so it is ground flat enough to
carry twenty tonnes, and unlike the path itself it was actually seen.

**Attempt 3 — a worker walked through the calibration set.** Now 60 driven
cells, but `tau_step` = **5.44 m** and detections collapsed to 1. The dilated
neighbourhood catches worker_1, who crosses the swing radius around t=25, and
`mean + 4σ` is not robust to a single 1.75 m contaminant.

Fix: median and MAD instead of mean and σ.

**Attempt 4 — the clamp was inverted.** `tau_step` came back at 0.158 m, which
is *tighter* than the 0.67 m a genuine surface spans at the angle of repose, so
pile cells failed the surface test and nothing changed. The physical bracket
runs the other way: a surface at the steepest natural slope must still count as
surface (floor), and the threshold must stay below a standing person (ceiling).

## 9. Thresholding cells was the wrong shape of answer

The per-cell test above bought +15% precision at zero cost in true positives,
which was real, but 87.3% of the *remaining* false positives were still
pile-related. The residue was toe cells: where a pile meets flat grade, one
cell holds two surfaces, the plane fit is a compromise, and the cell fails a
roughness test it should pass.

No threshold fixes that, because the question was never "is this cell flat".
**It is "is this cell connected to the ground".** A stockpile is continuous
with the grade it sits on -- you can walk from a driven cell to its peak
without ever stepping up more than the angle of repose allows. A truck is not:
grade to roof is a three metre jump, and no natural surface does that.

So the ground surface is now *grown*, not thresholded. Seed with the cells
beside the machine's path, flood outward, accept a neighbour when its floor is
within one cell's repose-limited rise. Toe cells are reached from either side,
so they stop being a special case.

**That overshot, informatively.** Precision went to 0.664, but ATE degraded
0.365 -> 0.445 and ASE 0.577 -> 0.705. A truck's lowest *visible* return sits
0.6 to 1.0 m above the grade beside it -- inside the repose allowance -- so the
fill climbed onto vehicles, ate their lower bodies, and left floating tops that
fit small, badly-placed boxes.

The fix is to combine the two ideas rather than choose between them: the fill
may cross a repose-limited rise, but **only into a cell that is itself thin**.
Stone's `step` supplies that -- a pile cell spans 0.67 m vertically, a truck
cell spans two to three. Connectivity decides where terrain extends; step
decides what is eligible to be terrain at all. 162 cells were refused entry on
those grounds.

## 10. Where it stands

Four configurations, same binary, same scene:

| | none | threshold | grow | grow + step guard |
| --- | --- | --- | --- | --- |
| TP | 1555 | 1555 | 1542 | **1552** |
| FP | 2189 | 1700 | 782 | **824** |
| precision | 0.415 | 0.478 | 0.664 | **0.653** |
| recall | 0.648 | 0.648 | 0.643 | **0.647** |
| F1 | 0.506 | 0.550 | 0.653 | **0.650** |
| ATE | 0.379 | 0.365 | 0.445 | **0.365** |
| ASE | 0.575 | 0.577 | 0.705 | **0.576** |

The last column is the one to ship: **62% fewer false positives than the
baseline, three true positives lost out of 1555, and box quality unchanged.**
Pure region growing scores marginally better on precision and materially worse
on everything about the boxes, which is the wrong trade for a labeler whose
output trains a detector.

Pile-related false positives fell from 1987 (90.8%) to 584 (70.9%), and phantom
tracks from 48 to 32.

## 11. What the numbers say to build next

**ATE 0.365 m is already good** on objects nothing was ever told about.
Geometry finds *where* things are.

**AOE 0.750 rad is worthless, and provably so.** The scale runs 0 to π/2, and a
uniformly random heading averages 0.785. The PCA heading is statistically
indistinguishable from a coin flip.

**ASE 0.576 means aligned IoU 0.424** — the boxes disagree on most of their
volume even given the right position and heading.

Both have one cause and it is not the code: a cluster is an object's *visible
surface*, not the object. A truck lit from one side has no far side in the
cloud, so the box is short in depth and the principal axis follows the
illuminated face. That information is not in a single sweep. It is in the
trajectory — which is exactly what `LabelFormer` refines and what a trained
detector encodes as a size prior.

Which is the argument for Pipeline B, stated as a measurement rather than an
assertion.

---

## 12. Offline-Poly made things worse, and the ablation says why

Stage one of Pipeline B is `OfflinePoly`, which is learning-free and consumes
*final tracklets from arbitrary upstream trackers* — exactly what Pipeline A
emits. It is Tracking-By-Tracking, so it wants more than one source. Pipeline A
can supply a second for free: **run the association backwards through time.**
Births and deaths swap ends, gating resolves differently around occlusions, and
fragments break in different places. The two runs are genuinely different — 70
tracklets forward, 68 backward, and the backward pass has better ATE (0.347 vs
0.365) but slightly worse precision.

First interop snag: the shared CSV schema is not quite shared. `sitegen truth`
writes `cls` as a class *name*; `OfflinePoly` parses it as an integer and dies
with `invalid numeric field: object`. Refinery now emits `0`.

Then the result, which was not the expected one:

| | fwd only | +OfflinePoly (1 src, ego) | +OfflinePoly (2 src, no ego) | +OfflinePoly (2 src, ego) |
| --- | --- | --- | --- | --- |
| TP | **1552** | 1449 | **1572** | 1233 |
| FP | **824** | 942 | 918 | 1257 |
| precision | **0.653** | 0.606 | 0.631 | 0.495 |
| recall | 0.647 | 0.604 | **0.655** | 0.514 |
| F1 | **0.650** | 0.605 | 0.643 | 0.504 |
| ATE | **0.365** | 0.641 | 0.387 | 0.472 |
| ASE | **0.576** | 0.765 | 0.891 | 0.871 |
| AOE | 0.750 | 0.697 | **0.670** | 0.837 |

Three things fall out of that:

**`--ego` corner-aligned correction is actively harmful here** — ATE 0.365 →
0.641 with one source. It aligns *corners*, and corners are a function of yaw
and size, which are the two things Pipeline A gets wrong. Correcting position
using a bad heading moves the box the wrong way. Turn it off.

**Multi-source fusion genuinely works.** Two sources recover 20 true positives
the forward pass missed (1572 vs 1552) and lift recall above either input.
Running the same tracker backwards is a real second opinion, not a copy.

**Heading improves and size degrades.** AOE 0.750 → 0.670, because Offline-Poly
reasons about heading from *motion*, which beats PCA on a partial surface. ASE
0.576 → 0.891, because its fusion adjusts box dimensions and our dimensions
were the unreliable input.

The pattern is consistent: **Offline-Poly improves what it can derive from
trajectory and degrades what it must take on faith from the boxes.** It is not
broken — it is being fed inputs that violate its assumptions. It was designed
downstream of `CenterPillars`, a detector that emits well-formed boxes with
meaningful yaw.

Which is the finding worth having: **you cannot skip stage B by chaining more
learning-free refinement.** The missing information is a size and shape prior,
and only a trained model carries one.

## 13. The student, trained on the pipeline's own output

No changes to `CenterPillars.py`. Its `SweepDataset` already reads

    <root>/<split>/<log>/<timestamp>.npz
      points, boxes, labels, num_interior_pts

so that layout is the interface, and `scripts/to_centerpillars.py` writes it:
sitegen's `.bin` sweeps are already float32 x,y,z,i in the sensor frame, and
only the pseudo-label boxes have to be moved map → sensor.

Two choices in the adapter worth stating:

- **Interleaved val split**, every fifth frame, not a tail split. The scene has
  distinct phases — dig, walk, dig — and a tail split would validate on a
  regime the model never trained on.
- **Boxes with fewer than five interior returns are dropped**: 676 of 2376. A
  pseudo-label fitted to four points is noise, and teaching a detector to
  reproduce it is worse than not teaching it at all.

That leaves 480 train and 120 val sweeps carrying 1700 boxes — none of them
human-labelled, all of them Pipeline A's own output.

## 14. The student learns shape, inherits the teacher's mistakes, and amplifies them

Trained on Pipeline A's own output, nothing human-labelled: 20 epochs, 0.61M
parameters, ~6 minutes on MPS. Against the pseudo-labels it reaches **mAP
0.895**, which only says it reproduced its teacher.

Against the oracle, run through the *same* association, smoothing and
track-length filter the teacher gets — otherwise the comparison is a tracker,
not a detector:

| | TP | FP | precision | recall | F1 | ATE | ASE | AOE |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **A — teacher** | 1552 | 824 | **0.653** | 0.647 | **0.650** | **0.365** | 0.576 | 0.750 |
| B — student @0.1 | 1576 | 2292 | 0.407 | **0.657** | 0.503 | 0.379 | 0.539 | 0.629 |
| B — student @0.2 | 1561 | 1450 | 0.518 | 0.650 | 0.577 | 0.366 | 0.530 | 0.620 |
| B — student @0.3 | 1424 | 953 | 0.599 | 0.593 | 0.596 | 0.387 | 0.498 | 0.579 |
| B — student @0.4 | 1269 | 625 | 0.670 | 0.529 | 0.591 | 0.391 | **0.453** | **0.553** |

**The prediction held.** §11 argued that ASE and AOE were bad structurally,
because a cluster is an object's visible surface and the missing information is
a shape prior only a trained model carries. The student improves both at *every
threshold*, monotonically: ASE 0.576 → 0.453, AOE 0.750 → 0.553. AOE matters
most — 0.750 was statistically indistinguishable from a coin flip against a
random baseline of 0.785; 0.553 is genuinely informative. One round of
distillation over 480 sweeps bought a heading estimator where geometry had
none.

**But F1 never beats the teacher**, at any threshold: 0.596 against 0.650. At
0.2 the student matches recall (0.650 vs 0.647) with better boxes and worse
precision; at 0.4 it beats precision (0.670 vs 0.653) and loses recall.

**Why, measured.** The teacher's 824 false positives are not noise the student
can average away — they are *labelled as positives in its training set*:

```
teacher labels        2376 rows,  701 (29.5%) sit on a stockpile
student output        2377 rows,  888 (37.4%) sit on a stockpile
```

The student did not just inherit the systematic error, it **amplified** it,
29.5% → 37.4%. That is textbook pseudo-label error propagation, and it is the
whole reason this is a *loop* and not a step. Round two needs its training
labels filtered before it starts — by teacher/student agreement, by track
stability, or by driving the terrain stage harder — and none of that is
possible until round one exists to disagree with.

**Net for one round**: better at describing objects, no better at finding them,
and worse at not inventing them. Exactly the shape of result that says what to
do next rather than that the approach works.
