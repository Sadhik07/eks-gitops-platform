# Secure GitOps Delivery Platform on AWS EKS

A production-style delivery platform that takes a commit to production on
Amazon EKS **without anyone holding cluster or cloud credentials**. Every image
is scanned, signed and admitted only if it was built by this repository's CI.
Every release goes out as a metrics-gated canary that **rolls itself back** when
error rate or latency degrades.

It runs end to end on a laptop (kind, $0) and on AWS (Terraform, three
environments).

```
commit -> test -> build -> Trivy scan -> SBOM -> push (OIDC) -> cosign sign
       -> Git commit of new tag -> ArgoCD sync -> Kyverno verifies signature
       -> Argo Rollouts canary <-> Prometheus analysis -> promote or auto-rollback
```

See [docs/architecture.md](docs/architecture.md) for diagrams and the full
control matrix.

## What's inside

| Area | Implementation |
|---|---|
| **Infrastructure as code** | Terraform modules for VPC, EKS, ECR, GitHub OIDC and workload IAM; one reusable `stacks/environment` called by `live/dev`, `stage` and `prod`; S3 state with native locking |
| **CI** | GitHub Actions with a reusable per-service workflow; builds only changed services; every action pinned to a commit SHA |
| **Supply chain** | Trivy gate, Syft SBOM, cosign keyless signing plus SBOM attestation; Kyverno verifies signatures and pins digests at admission |
| **CD / GitOps** | ArgoCD app-of-apps plus ApplicationSet (one app per service per environment); promotion by PR with signature re-check; prod gated by CODEOWNERS |
| **Progressive delivery** | Argo Rollouts canary with Prometheus `AnalysisTemplate` (5xx ratio and p95) scoped to the canary's pods; slower canary in prod |
| **Policy** | Kyverno: signed images, non-root, no privilege escalation, resource requests and limits, probes, trusted registry, no `:latest`, all with unit tests |
| **Observability** | kube-prometheus-stack, Loki, OpenTelemetry Collector; SLO recording rules and multi-window burn-rate alerts; Grafana SLO and DORA dashboards |
| **DORA metrics** | Stdlib-only exporter computing deploy frequency, lead time, change failure rate and time to restore from GitHub deployments and incident issues |
| **Scaling and cost** | Karpenter (Spot-first, consolidation, spend ceiling), HPA, PDBs, zone spread; Infracost on Terraform PRs |
| **Security** | EKS Pod Identity roles per workload, External Secrets plus Secrets Manager, NetworkPolicies, PSA `restricted`, IMDSv2, Checkov and tflint on every PR |
| **Resilience** | Velero daily backups with a restore runbook, SQS dead-letter queue, game-day playbook |

## Repository layout

```
apps/                 api (FastAPI), worker (SQS consumer), web (nginx)
infra/terraform/      bootstrap/  modules/  stacks/environment/  live/{global,dev,stage,prod}
deploy/               base/<service>  components/aws-secrets  overlays/{local,dev,stage,prod}/<service>
platform/             addons/ (ArgoCD apps)  clusters/<env>/  config/  policies/ (+tests)  bootstrap/
.github/workflows/    ci, _build-service, promote, record-deployment, terraform, manifests, tests, dora-report
docs/                 architecture, ADRs, runbooks, game days, postmortem template, AWS setup, cost
scripts/              local-up, demo-canary-rollback, bootstrap-cluster, configure-repo
```

## Quick start: local, free

Requirements: Docker, kind, kubectl, helm.

```bash
make local-up         # kind cluster + Argo Rollouts + Prometheus/Grafana + the app
make demo-rollback    # ships a release that fails 50% of requests; watch it roll back
make local-down
```

`demo-rollback` prints how long the canary took to detect the bad release and
roll back. Record your own measurement in [docs/game-days.md](docs/game-days.md).

## Deploy to AWS

Step by step in [docs/setup-aws.md](docs/setup-aws.md): bootstrap the state
bucket, apply `global` (ECR plus CI roles), apply `dev`, then
`make bootstrap-dev`. ArgoCD installs the rest from Git.

## Quality gates

Everything CI runs can be run locally with `make check`:

| Gate | Tool |
|---|---|
| Unit tests | pytest (services and DORA calculator) |
| Lint | ruff, ShellCheck, hadolint, `terraform fmt`, tflint |
| IaC security | Checkov (with justified, inline skips) |
| Manifests | `kustomize build` of every overlay, then kubeconform against Kubernetes and CRD schemas |
| Policy | `kyverno test` (14 cases) plus `kyverno apply` of the cluster policies to rendered workloads |

## Design decisions

- [0001 GitOps with ArgoCD](docs/adr/0001-gitops-with-argocd.md)
- [0002 Kustomize for apps, Helm for add-ons](docs/adr/0002-kustomize-for-apps-helm-for-addons.md)
- [0003 Keyless image signing enforced at admission](docs/adr/0003-keyless-image-signing.md)
- [0004 Pod Identity and Karpenter](docs/adr/0004-pod-identity-and-karpenter.md)

## Operating it

- [Canary aborted](docs/runbooks/canary-aborted.md)
- [Error budget burn](docs/runbooks/slo-burn-rate.md)
- [Restore from Velero](docs/runbooks/restore-from-velero.md)
- [Game days](docs/game-days.md) and [postmortem template](docs/postmortems/TEMPLATE.md)

## Roadmap

- AWS Load Balancer Controller with an ALB Ingress for `web` (currently `port-forward`)
- Hub-and-spoke ArgoCD managing all clusters
- Tempo for trace storage (the OTel pipeline exports traces to `debug` today)
- KEDA scaling the worker on SQS queue depth

## License

MIT
