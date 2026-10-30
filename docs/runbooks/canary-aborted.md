# Runbook: canary aborted

**Signal**: Argo Rollouts marks `rollout/api` as `Degraded` with "RolloutAborted",
or an AnalysisRun shows `Failed`.

**What already happened automatically**: the canary ReplicaSet was scaled to
zero and 100% of traffic is back on the stable version. Users are not
affected beyond the canary window. This is a triage task, not an outage.

## 1. Confirm the stable version is serving

```bash
kubectl argo rollouts get rollout api -n orders
kubectl -n orders get analysisrun --sort-by=.metadata.creationTimestamp | tail -3
```

Check the SLO dashboard: the error ratio for the stable pod hash should be
back to baseline.

## 2. Find out why the analysis failed

```bash
kubectl -n orders describe analysisrun <name>   # which metric failed, and the measured values
```

| Failed metric | Likely cause | Look at |
|---|---|---|
| `error-rate` | Bug in the new version, missing config or secret | Loki: `{namespace="orders", app="api"} \|= "ERROR"`, plus the diff of the image's commit |
| `p95-latency` | Slow dependency, N+1 query, cold caches | Traces in the OTel backend, worker queue age |
| Analysis `Error` (not `Failed`) | Prometheus unreachable or the query returned nothing | `kubectl -n monitoring get pods`, then run the query in the Prometheus UI |

## 3. Fix forward or revert

- **Revert**: `git revert <bump commit>` on `main`. ArgoCD returns the
  overlay to the stable tag.
- **Fix forward**: merge the fix. CI builds a new tag and bumps dev, and the
  new canary starts automatically.

Do not `kubectl argo rollouts promote --full` a version that failed analysis
unless the failure was an analysis error, not a metric failure.

## 4. Afterwards

If the bug reached prod's canary, open an issue labelled `incident` and
`service:api`, so the DORA change-failure rate counts it. If users were
affected, write a postmortem (`docs/postmortems/TEMPLATE.md`).
