# Keeping the lab cheap

Rough monthly cost drivers for an always-on **dev** environment. Check current
prices on the AWS pricing pages; they vary by region and change over time.

| Item | Why it costs | How to minimise |
|---|---|---|
| EKS control plane | Hourly fee per cluster | Run only dev; destroy when idle |
| NAT gateway | Hourly fee plus per-GB processing | `single_nat_gateway = true` in dev (the default) |
| System node group | 2 x t3.medium | Fine for dev; the Karpenter `NodePool` prefers Spot for apps |
| EBS volumes | Prometheus and Loki persistence | Reduce PVC sizes in dev |
| CloudWatch logs | Control-plane and VPC flow logs | 30-day retention is already set |

## Habits that matter more than tuning

- **Develop on kind.** `make local-up` exercises CI artifacts, canaries,
  policies and dashboards for $0.
- **Destroy after demos**: `terraform destroy` on `live/dev`. The state bucket
  and ECR (in `global`) cost close to nothing to keep.
- **Watch the cost diff.** With `INFRACOST_API_KEY` set, every Terraform PR
  shows its monthly cost delta.
- Karpenter's `limits` in `platform/config/karpenter/nodepool.yaml` are a hard
  ceiling on how much compute the cluster can buy.

## Azure (`azure-dev`)

| Item | Why it costs | How to minimise |
|---|---|---|
| AKS control plane | Free on the Free tier | Keep `sku_tier = "Free"` outside production |
| System node pool | 2 x Standard_D2s_v5 | Destroy when idle; NAP adds app nodes only when pods need them |
| Load balancer and public IP | Hourly | Created with the cluster; gone after `destroy` |
| Service Bus Standard, Key Vault, storage | Small monthly base plus usage | Cents per day at lab volumes |
| ACR Standard (in `global`) | Daily fee | Destroy `live/global` when finished with Azure |
