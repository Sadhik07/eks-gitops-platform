# ADR 0002: Kustomize for our services, Helm for third-party add-ons

- Status: accepted
- Date: 2026-10

## Context

Our three services differ per environment only in image tag, replica counts,
config values and canary pacing. Third-party add-ons (Prometheus, Kyverno,
Karpenter and others) ship as maintained Helm charts.

## Decision

- **Services**: plain YAML in `deploy/base`, with per-environment overlays.
  The diff a reviewer sees in a promotion PR is one line: the image tag.
- **Add-ons**: upstream Helm charts referenced by ArgoCD Applications, with
  pinned chart versions and values inline. Per-cluster values are applied with
  Kustomize patches in `platform/clusters/<env>`.

## Consequences

- No templating language to learn for app changes; overlays render with
  `kustomize build` and are schema-checked in CI.
- Argo Rollouts is a CRD, so `kustomizeconfig.yaml` tells Kustomize how
  Rollouts reference generated ConfigMaps.
- Chart upgrades are explicit version bumps, proposed weekly by Renovate.
