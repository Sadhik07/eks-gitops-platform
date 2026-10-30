# Game days

Planned failure tests that prove the platform's automation works. Run them,
measure, and write down what happened. These numbers are the evidence behind
the claims in the README.

| # | Scenario | How | Expected automatic response |
|---|---|---|---|
| 1 | Bad release (50% errors) | `make demo-rollback` (kind) or merge a release with `FAULT_RATE=0.5` to dev | Canary analysis fails and the rollout aborts to stable |
| 2 | Slow release | Same, with a latency fault, or load the API until p95 exceeds 500ms | `p95-latency` metric fails and the rollout aborts |
| 3 | Pod crash loop | Delete pods or set a bad command | Liveness probe restarts; the PDB keeps at least 50% available |
| 4 | Node loss | Drain or terminate a Karpenter node | Pods reschedule and Karpenter replaces capacity |
| 5 | Unsigned image | `kubectl run` an unsigned image from our ECR into `orders` | Kyverno denies admission |
| 6 | Poison message | Send `{"quantity": 0}` to SQS 6 times | The message lands in the DLQ and `WorkerHighFailureRate` fires |
| 7 | Restore drill | `docs/runbooks/restore-from-velero.md` | Namespace restored |

## Results log

Fill this in each time you run one. Use your own measured numbers, never estimates.

| Date | # | Environment | Detection time | Recovery time | Notes / follow-ups |
|---|---|---|---|---|---|
| | | | | | |
