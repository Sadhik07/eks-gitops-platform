#!/usr/bin/env bash
# One-time hand-off from Terraform to GitOps for an environment:
#   1. point kubectl at the new EKS or AKS cluster
#   2. install ArgoCD with Helm
#   3. apply the root Application; ArgoCD installs everything else from Git
#
# Usage: ./scripts/bootstrap-cluster.sh dev|stage|prod|azure-dev
set -euo pipefail

ENV="${1:?usage: $0 dev|stage|prod|azure-dev}"
[[ "$ENV" =~ ^(dev|stage|prod|azure-dev)$ ]] || { echo "env must be dev, stage, prod or azure-dev" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="orders-$ENV"
ARGOCD_CHART=10.11.6

if [[ "$ENV" == azure-* ]]; then
  # AKS has local accounts disabled: kubectl authenticates with Entra ID via kubelogin
  AZ_ENV="${ENV#azure-}"
  CLUSTER="aks-orders-$AZ_ENV"
  az aks get-credentials --resource-group "rg-orders-$AZ_ENV" --name "$CLUSTER" --overwrite-existing
  kubelogin convert-kubeconfig -l azurecli
else
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER"
fi

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART" \
  -n argocd --create-namespace -f "$ROOT/platform/bootstrap/argocd-values.yaml" --wait

sed "s|platform/clusters/ENV|platform/clusters/$ENV|" "$ROOT/platform/bootstrap/root-app.yaml" \
  | kubectl apply -f -

echo
echo "ArgoCD is syncing $CLUSTER from Git. Watch it with:"
echo "  kubectl -n argocd get applications -w"
echo "  kubectl -n argocd port-forward svc/argocd-server 8443:443   # UI at https://localhost:8443"
echo "  initial admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
