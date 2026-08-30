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

## 9. Where it stands

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

**Stone removed 489 false positives at a cost of exactly zero true positives.**
Identical TP and FN is the result worth having — the terrain stage is removing
only things that were never objects.

It is a real win and not the elimination that was predicted. 87.3% of the
*remaining* false positives are still pile-related, down from 90.8%, and
phantom tracks fell from 48 to 31. The residue is most likely toe cells, where
a pile meets flat grade and one cell contains both surfaces, so the plane fit
is a compromise and the cell fails the roughness test. That is the next lever.

## 10. What the numbers say to build next

**ATE 0.365 m is already good** on objects nothing was ever told about.
Geometry finds *where* things are.

**AOE 0.749 rad is worthless, and provably so.** The scale runs 0 to π/2, and a
uniformly random heading averages 0.785. The PCA heading is statistically
indistinguishable from a coin flip.

**ASE 0.577 means aligned IoU 0.423** — the boxes disagree on most of their
volume even given the right position and heading.

Both have one cause and it is not the code: a cluster is an object's *visible
surface*, not the object. A truck lit from one side has no far side in the
cloud, so the box is short in depth and the principal axis follows the
illuminated face. That information is not in a single sweep. It is in the
trajectory — which is exactly what `LabelFormer` refines and what a trained
detector encodes as a size prior.

Which is the argument for Pipeline B, stated as a measurement rather than an
assertion.
