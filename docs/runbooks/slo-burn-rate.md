# Runbook: API error budget burn

**Alerts**

| Alert | Meaning | Budget consumed if it continues | Response |
|---|---|---|---|
| `ApiErrorBudgetFastBurn` (page) | Error rate above 7.2% over both 1h and 5m | 2% of the 30-day budget per hour; all of it in about 2 days | Act now |
| `ApiErrorBudgetSlowBurn` (ticket) | Error rate above 3% over both 6h and 30m | 5% of the budget per 6h | Fix within the working day |

The SLO is 99.5% successful requests over 30 days (budget 0.5%). Requiring
both windows means the alert stops quickly once the problem is fixed (the
short window) and does not fire on a brief blip (the long window).

## Triage (first 10 minutes)

1. **Is a deploy in progress?** `kubectl argo rollouts get rollout api -n orders`.
   If a canary is running, abort it: `kubectl argo rollouts abort api -n orders`.
2. **Recent changes?** ArgoCD history for `<env>-api`, plus merged PRs to
   `deploy/overlays/<env>`.
3. **Which requests fail?** On the SLO dashboard, the request rate by status
   shows whether these are 5xx from the app or 502/504 from upstream.
4. **Dependencies**: SQS throttling or IAM errors appear in Loki as
   `{app="api"} |= "botocore"`. Check the worker backlog alert as well.
5. **Capacity**: `kubectl top pods -n orders`, HPA at max, or pending pods
   waiting for Karpenter (`kubectl get nodeclaims`).

## Mitigate

- Bad release: `git revert` the bump commit, or `kubectl argo rollouts undo api -n orders`
  as a break-glass step, followed by the revert commit.
- Load: raise `maxReplicas` in the overlay's HPA patch.
- Dependency: degrade gracefully if possible, and escalate to the dependency owner.

## Close out

Open or update the `incident` issue (labels `incident`, `service:api`) and
close it when the burn rate is back below 1. That issue's open-to-close time is
the "time to restore" in the DORA dashboard.
