# Deploying to AWS

EKS, NAT gateways and load balancers cost money even when idle. Build and test
on kind first (`make local-up`), then bring up **dev only** for demos and
destroy it afterwards. See `docs/cost.md`.

## Prerequisites

- AWS account with admin access for the initial bootstrap
- `aws` CLI v2, Terraform >= 1.10, `kubectl`, `helm`
- This repository pushed to your GitHub account

## 1. Personalise the template

```bash
./scripts/configure-repo.sh <your-github-user> <aws-account-id>
# then set public_endpoint_cidrs in infra/terraform/live/*/terraform.tfvars to your IP
```

## 2. State bucket (once per account)

```bash
terraform -chdir=infra/terraform/bootstrap init
terraform -chdir=infra/terraform/bootstrap apply
```

## 3. Registries and CI roles

```bash
terraform -chdir=infra/terraform/live/global init
terraform -chdir=infra/terraform/live/global apply
terraform -chdir=infra/terraform/live/global output github_actions_role_arns
```

In GitHub, under **Settings > Secrets and variables > Actions > Variables**, add:

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `AWS_ECR_PUSH_ROLE_ARN` | `ecr_push` output |
| `AWS_TF_PLAN_ROLE_ARN` | `terraform_plan` output |
| `AWS_TF_APPLY_ROLE_ARN` | `terraform_apply` output |

Then create GitHub **Environments** named `dev`, `stage` and `prod`, with
required reviewers on `prod`. Optionally add an `INFRACOST_API_KEY` secret for
cost diffs on pull requests.

## 4. Dev cluster

```bash
terraform -chdir=infra/terraform/live/dev init
terraform -chdir=infra/terraform/live/dev apply      # about 15-20 minutes
terraform -chdir=infra/terraform/live/dev output     # queue URLs, bucket names
```

Check that `QUEUE_URL` in `deploy/overlays/dev/*/kustomization.yaml` and the
Velero bucket in `platform/clusters/dev/kustomization.yaml` match the outputs.

Create the runtime secrets. Their values never touch Git or Terraform state:

```bash
aws secretsmanager put-secret-value --secret-id orders/dev/api --secret-string '{"EXAMPLE_API_KEY":"change-me"}'
aws secretsmanager create-secret --name orders/dev/dora-github-token --secret-string "<read-only fine-grained PAT>"
```

## 5. Hand the cluster to GitOps

```bash
make bootstrap-dev
kubectl -n argocd get applications -w
```

## 6. Ship something

Merge any change under `apps/api`. CI builds, scans, signs and pushes the
image, then commits the new tag to the dev overlay. ArgoCD syncs it, and Argo
Rollouts runs the canary. To promote, run **Actions > promote**
(`dev` to `stage`), merge the PR, and repeat for `stage` to `prod`.

## Tear down

```bash
kubectl -n argocd delete application root --wait   # lets ArgoCD remove what it created (load balancers, volumes)
terraform -chdir=infra/terraform/live/dev destroy
```
