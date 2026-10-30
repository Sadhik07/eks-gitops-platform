# Architecture

## Delivery path: commit to production

```mermaid
flowchart LR
    dev[Developer] -->|PR| gh[(GitHub)]
    subgraph CI [GitHub Actions]
      t[Lint + unit tests] --> b[Build image]
      b --> s[Trivy scan<br/>fail on fixable HIGH/CRITICAL]
      s --> sb[Syft SBOM]
      sb --> p[Push to ECR<br/>OIDC, no keys]
      p --> sig[cosign keyless sign<br/>+ SBOM attestation]
      sig --> bump[Commit new tag to<br/>deploy/overlays/dev]
    end
    gh --> t
    bump --> gh
    gh -->|watched by| argo[ArgoCD<br/>in each cluster]
    argo -->|sync| k8s[(EKS)]
    k8s --> kyv{Kyverno admission<br/>signature + policy}
    kyv -->|allowed| ro[Argo Rollouts canary]
    ro -->|queries| prom[(Prometheus)]
    prom -->|error rate / p95| ro
    ro -->|healthy| done[100% new version]
    ro -->|unhealthy| rb[Automatic rollback]
```

Promotion from dev to stage to prod uses the `promote` workflow. It verifies
the image signature and opens a pull request that copies the image tag to the
next overlay. Prod pull requests need CODEOWNERS approval. After merge,
`record-deployment` writes a GitHub Deployment, which feeds the DORA metrics.

## Runtime: one EKS cluster per environment

```mermaid
flowchart TB
  subgraph VPC [VPC, 2-3 AZs]
    subgraph pub [Public subnets]
      nat[NAT gateway]
    end
    subgraph priv [Private subnets]
      sys[System node group<br/>tainted: ArgoCD, Karpenter, CoreDNS]
      kar[Karpenter nodes<br/>Spot + On-Demand]
    end
    subgraph intra [Intra subnets]
      cp[EKS control-plane ENIs]
    end
  end
  kar --> api[api Rollout] & worker[worker] & web[web]
  web --> api
  api -->|SendMessage| sqs[(SQS orders)]
  sqs -->|Receive| worker
  sqs -. after 5 failures .-> dlq[(DLQ)]
  api & worker -->|EKS Pod Identity| iam[Per-workload IAM roles]
  eso[External Secrets] -->|Pod Identity| sm[(Secrets Manager)]
  velero[Velero] --> s3[(S3 backups)]
```

### Who owns what

| Layer | Tool | Where |
|---|---|---|
| Network, EKS, IAM, SQS, S3, ECR | Terraform | `infra/terraform` |
| Cluster add-ons | ArgoCD apps (Helm charts) | `platform/addons` |
| Per-cluster values | Kustomize patches | `platform/clusters/<env>` |
| Guardrails | Kyverno policies | `platform/policies` |
| Application manifests | Kustomize base + overlays | `deploy/` |
| Application code | Python / nginx | `apps/` |

### Observability

- **Metrics**: services expose Prometheus metrics, and ServiceMonitors register
  them with kube-prometheus-stack. SLOs are recording rules plus multi-window
  burn-rate alerts (`deploy/base/api/prometheusrule.yaml`).
- **Traces and logs**: services send OTLP to the OpenTelemetry Collector, which
  routes metrics to Prometheus and logs to Loki. It also drops health-check
  spans before export.
- **Delivery**: the DORA exporter turns GitHub deployment and incident records
  into Prometheus metrics, shown on the "DORA Metrics - Production" Grafana
  dashboard.

### Security controls, end to end

| Control | Implementation |
|---|---|
| No long-lived CI credentials | GitHub OIDC to AWS roles scoped by repo, branch and environment |
| Vulnerable images blocked | Trivy fails the build on fixable HIGH/CRITICAL |
| Provenance | cosign keyless signatures plus SBOM attestations in Rekor |
| Only signed images run | Kyverno `verify-image-signatures`, with tags pinned to digests |
| Hardened pods | Kyverno policies plus Pod Security Admission `restricted` on `orders` |
| Least-privilege AWS access | One IAM role per service account (EKS Pod Identity) |
| Secrets stay out of Git and state | External Secrets syncs from Secrets Manager |
| Network segmentation | NetworkPolicies per workload, default deny |
| IaC misconfiguration | Checkov and tflint on every PR, with justified skips inline |
| Supply chain of CI itself | Every GitHub Action pinned to a commit SHA, updated by Dependabot |
