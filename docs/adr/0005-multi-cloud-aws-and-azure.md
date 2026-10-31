# ADR 0005: Run the same platform on AWS (EKS) and Azure (AKS)

- Status: accepted
- Date: 2026-10

## Context

Teams increasingly run on more than one cloud, through acquisitions, customer
requirements or regulators asking for an exit plan. The question for a
platform team is how much of the platform has to be rebuilt per cloud.

## Decision

Keep one platform and swap only the cloud layer.

| Layer | Shared across clouds | Per cloud |
|---|---|---|
| Infrastructure | Module structure, CI pipeline, policy scans | `infra/terraform` (AWS), `infra/terraform-azure` (Azure) |
| Cluster add-ons | `platform/addons` (ArgoCD apps), dashboards, policies | Patches in `platform/clusters/<env>` |
| Workloads | `deploy/base` | `deploy/overlays/<env>` (registry, queue, identity) |
| Application code | Everything | One queue adapter (`QUEUE_BACKEND=sqs|servicebus`) |
| Supply chain | Build, scan, SBOM, cosign signature, Kyverno verification | Registry login (ECR or ACR) |

Service mapping:

| AWS | Azure | Notes |
|---|---|---|
| EKS + Karpenter | AKS + Node Auto-Provisioning | NAP is Karpenter, managed by AKS |
| EKS Pod Identity | Entra Workload ID | Federated credential per service account |
| IAM role for GitHub OIDC | Managed identity + federated credential | No client secrets |
| SQS + DLQ | Service Bus queue | Dead-letter sub-queue after 5 deliveries |
| Secrets Manager | Key Vault (RBAC mode) | Same External Secrets operator |
| S3 state + lockfile | Blob storage + lease | Entra auth, no storage keys |
| ECR (immutable tags) | ACR | Kyverno verifies cosign signatures on both |

## Consequences

- About 70% of the repository is cloud-agnostic. A new add-on or policy lands
  on both clouds through the same pull request.
- AKS has local accounts disabled, so `kubectl` needs Entra ID (`kubelogin`).
  This is stricter than the EKS setup and is the recommended AKS baseline.
- Identity values (client ids) exist only after `terraform apply`.
  `scripts/azure-sync-outputs.sh` writes them into the manifests, using
  `# sync:` markers so it can be re-run safely.
- Only `azure-dev` is defined. Stage and prod on Azure would follow the AWS
  pattern: one more `live/<env>` root, overlay folder and cluster folder each.
