# ADR 0001: GitOps with ArgoCD (pull-based) instead of `kubectl apply` from CI

- Status: accepted
- Date: 2026-10

## Context

CI could deploy directly with `kubectl apply` or `helm upgrade`. That would
require cluster-admin credentials in GitHub, would make drift invisible, and
would leave no single record of what is running.

## Decision

Clusters pull their desired state from Git with ArgoCD. CI's only write is a
commit that changes an image tag. Each cluster runs its own ArgoCD and syncs
only `platform/clusters/<env>`.

## Why ArgoCD over Flux

Both are CNCF-graduated and either would work. ArgoCD was chosen because:

- **ApplicationSets** generate one Application per service per environment
  from folder names, so adding a service needs no ArgoCD change.
- **Its UI** shows sync status, diffs and resource trees, which helps during
  incidents and with teams new to GitOps.
- **Argo Rollouts** comes from the same project and the UI shows canary state.

Flux would be preferable for a strictly CLI/CRD-driven workflow, or if a UI
were a security concern.

## Consequences

- No cluster credentials in CI. Rollback is `git revert`.
- `selfHeal: true` reverts manual `kubectl edit` changes. Emergency fixes go
  through Git, or ArgoCD auto-sync is paused for that app explicitly.
- The HPA owns `replicas`, so `ignoreDifferences` is set on that field to
  avoid a sync fight.
- A per-cluster ArgoCD means one failure domain per environment. The trade-off
  is no single pane across clusters; a hub ArgoCD is the upgrade path.
