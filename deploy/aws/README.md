# labelrefinery on AWS

One CloudFormation stack, [`refinery.yaml`](refinery.yaml), in us-east-2 (the
account's region). It holds one small always-on instance and the things runs
need; the AV2 work runs on instances that orca's `ec2` runner starts per run
and that terminate themselves when the run ends.

| | What | Always on? |
|---|---|---|
| **Control instance** (t4g.large) | Postgres, orca's scheduler and orca ui, the AV2 slice viewer, LabelControl (read-only), Caddy with Let's Encrypt in front | yes, about $55 a month with its disk and address |
| **Run instances**: a head (c7g.large) per run, and 0 to 4 workers (c7g.large, `Workers`) | the head runs `av2-pipeline-a resume <run>`: fetch 5 logs from the public bucket, label, publish view bundles, score; the workers run the labeling's dista tasks (a terrain task and a detect task per sweep), started when tasks wait and drained when idle | only during a run, by the second |
| **Bucket** `refinery-<account>-us-east-2` | `warehouse/` (av2.logs, av2.scores_a, labelrefinery.labels, labelrefinery.evaluations), `work/av2/` (converted logs, which the workers read; 14 days), `logs/` (30 days), `views/av2/` (the viewer's bundles, about 65 MB a log) | storage only |
| **Repository** `refinery` | the image (`deploy/Dockerfile`): orca, the pipeline, the viewer, LabelControl | storage only |

The URLs, from the stack's outputs, use the Elastic IP's
[sslip.io](https://sslip.io) names, which work as soon as the stack is up:

- `https://orca.<a-b-c-d>.sslip.io`: orca ui, with pipelines, runs, logs and lineage. Reading needs no login; starting, rerunning and backfilling do.
- `https://av2.<a-b-c-d>.sslip.io`: the slice viewer. Pick a log, set a slice of sweeps, and play it: the points, the annotated cuboids and Pipeline A's tracks.
- `https://labels.<a-b-c-d>.sslip.io`: LabelControl, read-only.

With `Domain` set to, say, `demo.labelrefinery.org`, they answer at
`orca.`, `av2.` and `labels.` under it as well, once those A records point at
`PublicAddress`.

## Bringing it up

```sh
# 1. The stack (about 5 minutes). The control instance waits for the image.
aws cloudformation deploy --region us-east-2 --stack-name refinery \
  --template-file deploy/aws/refinery.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides DbPassword=$(openssl rand -hex 16) BudgetEmail=you@example.com

# 2. The image (from Refinery's root; it compiles everything, about 20 minutes).
deploy/push.sh dev

# 3. A login for orca ui's actions, on the control instance (Session Manager).
aws ssm start-session --region us-east-2 --target <ControlInstance>
sudo docker exec -i scheduler orca user add demo     # reads the password from stdin

# 4. The logs to label, then the backfill: 150 logs, 5 to a run, 8 runs at once.
sudo docker exec scheduler av2-logs s3://<Bucket>/warehouse /opt/refinery/configs/av2_val.txt
sudo docker exec scheduler orca backfill av2_pipeline_a @all
```

The backfill can also be started from orca ui once logged in. Each run shows
there as it goes; its instance appears in EC2 as `orca-<run>-<start>-head`
and is gone when the run ends, as are its workers, `orca-<run>-<start>-worker`.
Labels land in `labelrefinery.labels` (dataset `av2/<log>`), scores in
`av2.scores_a` and `labelrefinery.evaluations`, and the viewer lists each log
as soon as it's scored.

To show LabelControl's runs, copy an `ops.db` to
`s3://<Bucket>/labelcontrol/ops.db` before the stack starts the control
instance (or copy it into `/var/lib/refinery/labelcontrol/` on the instance
and `docker restart labelcontrol`).

## Cost

About $55 a month for the control instance, its disk and its address, whether
or not anything runs. A full val backfill is 30 runs of a c7g.large
($0.0725/hour) for a few minutes each, well under a dollar; the bundles are
about 10 GB in S3. The Budgets alert emails at 80% of `BudgetDollars` actual
and 100% forecast. `ORCA_VCPU_BUDGET` (`VcpuBudget`, 16) caps how many vCPUs
all runs hold at once, and the control role can start only the
`AllowedRunTypes`, tagged for orca, in the stack's subnet.

## Taking it down

```sh
aws s3 rm --recursive s3://<Bucket>          # a bucket with objects can't be deleted
aws ecr batch-delete-image ...               # nor a repository with images
aws cloudformation delete-stack --region us-east-2 --stack-name refinery
```
