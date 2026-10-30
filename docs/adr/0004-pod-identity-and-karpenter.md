# ADR 0004: EKS Pod Identity for AWS access, Karpenter for capacity

- Status: accepted
- Date: 2026-10

## Pod Identity instead of IRSA

IRSA needs an OIDC provider per cluster and role trust policies that embed the
cluster's OIDC URL, so roles cannot be reused across clusters without editing
them. EKS Pod Identity uses one service principal (`pods.eks.amazonaws.com`) and
an explicit association per service account.

**Decision**: every workload that calls AWS gets its own role and
`aws_eks_pod_identity_association` (`modules/workload-identity`). No service
account annotations, no static keys.

## Karpenter instead of Cluster Autoscaler with managed node groups

Cluster Autoscaler scales fixed node groups, so instance types are chosen in
advance. Karpenter provisions the cheapest instance that fits pending pods,
mixes Spot and On-Demand, and consolidates under-used nodes.

**Decision**: a small tainted managed node group runs cluster-critical add-ons
(ArgoCD, Karpenter, CoreDNS). All application capacity comes from a Karpenter
`NodePool` with hard CPU and memory limits as a spend ceiling, and a 10%
disruption budget.

## Consequences

- Spot interruptions arrive through an SQS queue that Karpenter watches, so
  nodes drain gracefully. PDBs and topology spread keep services available.
- Nodes expire after 30 days, so AMI patches roll out without manual work.
- Karpenter itself must not run on Karpenter nodes, which is why the system
  node group exists.
