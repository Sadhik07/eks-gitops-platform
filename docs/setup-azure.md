# Deploying to Azure (AKS)

The Azure environment runs the same platform as AWS: ArgoCD, Argo Rollouts
canaries, Kyverno, Prometheus/Grafana, OpenTelemetry and the three services.
See [ADR 0005](adr/0005-multi-cloud-aws-and-azure.md) for how the clouds map.

You pay for the AKS worker nodes, the load balancer, Service Bus and storage
while the environment exists. The AKS Free tier has no control-plane fee.
Build it for a demo, then destroy it the same day (last section).

## Prerequisites

- An Azure subscription where you are **Owner** (needed once, to create role assignments)
- `az` CLI, `kubelogin`, Terraform >= 1.10, `kubectl`, `helm`, `jq`
- On macOS: `brew install azure-cli Azure/kubelogin/kubelogin terraform kubectl helm jq`

```bash
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

`name_prefix` (default `sadhik07`) makes storage, registry, Key Vault and
Service Bus names globally unique. If a name is taken, change it in every
`terraform.tfvars` under `infra/terraform-azure` and in
`deploy/overlays/azure-dev/*`.

## 1. State storage (once per subscription)

```bash
terraform -chdir=infra/terraform-azure/bootstrap init
terraform -chdir=infra/terraform-azure/bootstrap apply
```

## 2. Registry and CI identities

```bash
terraform -chdir=infra/terraform-azure/live/global init
terraform -chdir=infra/terraform-azure/live/global apply
terraform -chdir=infra/terraform-azure/live/global output
```

In GitHub, under **Settings > Secrets and variables > Actions > Variables**, add:

| Variable | Value |
|---|---|
| `AZURE_TENANT_ID` | `tenant_id` output |
| `AZURE_SUBSCRIPTION_ID` | `subscription_id` output |
| `AZURE_ACR_NAME` | `sadhik07orders` (registry name, without `.azurecr.io`) |
| `AZURE_ACR_PUSH_CLIENT_ID` | `github_actions_client_ids["acr-push"]` |
| `AZURE_TF_PLAN_CLIENT_ID` | `github_actions_client_ids["tf-plan"]` |
| `AZURE_TF_APPLY_CLIENT_ID` | `github_actions_client_ids["tf-apply"]` |

Create a GitHub **Environment** named `azure-dev` (add yourself as a required
reviewer). From the next push, CI pushes every image to ACR as well as building
it, signs it and deploys it to `azure-dev`.

## 3. AKS cluster

Set `api_authorized_ip_ranges` in `infra/terraform-azure/live/dev/terraform.tfvars`
to your IP (`curl -s https://checkip.amazonaws.com`), then:

```bash
terraform -chdir=infra/terraform-azure/live/dev init
terraform -chdir=infra/terraform-azure/live/dev apply      # about 10-15 minutes
```

Write the new identity client ids, subscription id and Key Vault URL into the
manifests, and push them:

```bash
./scripts/azure-sync-outputs.sh
git add -A && git commit -m "azure-dev: sync Terraform outputs" && git push
```

Create the runtime secrets. Their values never touch Git or Terraform state:

```bash
az keyvault secret set --vault-name kv-sadhik07-dev --name orders-api --value '{"EXAMPLE_API_KEY":"change-me"}'
az keyvault secret set --vault-name kv-sadhik07-dev --name dora-github-token --value "<read-only fine-grained PAT>"
```

## 4. Hand the cluster to GitOps

```bash
make bootstrap-azure-dev
kubectl -n argocd get applications -w
```

This runs `az aks get-credentials`, then `kubelogin` (AKS has local accounts
disabled, so `kubectl` signs in with your Entra ID). Then it installs ArgoCD and
applies the root app for `platform/clusters/azure-dev`.

## 5. Ship something

Merge a change under `apps/api`. CI builds and scans it, pushes it to ECR and
ACR, signs both, and bumps `deploy/overlays/dev` and `deploy/overlays/azure-dev`.
Each cluster's ArgoCD rolls it out with a canary.

```bash
kubectl argo rollouts get rollout api -n orders --watch
```

## Tear down

```bash
kubectl -n argocd delete application root --wait     # removes load balancers and disks ArgoCD created
terraform -chdir=infra/terraform-azure/live/dev destroy
```

`live/global` (the registry and identities) and `bootstrap` cost little to keep.
Destroy them too if you are finished:
`terraform -chdir=infra/terraform-azure/live/global destroy`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `kubectl` asks to log in, or returns Forbidden | Run `kubelogin convert-kubeconfig -l azurecli`; Terraform grants the deployer "AKS RBAC Cluster Admin" |
| Pods stuck `Pending` for a few minutes | Node Auto-Provisioning is creating nodes; check `kubectl get nodeclaims` |
| ExternalSecret `SecretSyncedError` | The Key Vault secret is missing, or `azure-sync-outputs.sh` was not run |
| Velero `AuthorizationFailed` | The node resource group name differs; update it in `platform/clusters/azure-dev/kustomization.yaml` |
| Name already taken | Change `name_prefix` (see the top of this page) |
