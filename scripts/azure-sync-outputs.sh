#!/usr/bin/env bash
# Copies values that only exist after `terraform apply` on Azure (managed
# identity client ids, subscription id, Key Vault URL) into the GitOps
# manifests. Every target line carries a "# sync:<key>" marker, so the script
# is idempotent: re-running it just rewrites the same values.
#
# Usage: ./scripts/azure-sync-outputs.sh            (reads infra/terraform-azure/live/dev)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform-azure/live/dev"
command -v jq >/dev/null || { echo "missing dependency: jq" >&2; exit 1; }

out=$(terraform -chdir="$TF_DIR" output -json stack)
sub_id=$(az account show --query id -o tsv)
kv_url=$(jq -r '.key_vault_url' <<<"$out")

files=(
  "$ROOT/deploy/overlays/azure-dev/api/kustomization.yaml"
  "$ROOT/deploy/overlays/azure-dev/worker/kustomization.yaml"
  "$ROOT/platform/clusters/azure-dev/kustomization.yaml"
)

set_marker() { # set_marker <marker> <value>: replace the value before "# sync:<marker>"
  local marker=$1 value=$2
  for f in "${files[@]}"; do
    sed -i.bak -E "s|([:] )[^ #]+( # sync:${marker})$|\1${value}\2|" "$f" && rm -f "$f.bak"
  done
}

for workload in api worker external-secrets velero kyverno; do
  id=$(jq -r --arg w "$workload" '.workload_client_ids[$w]' <<<"$out")
  set_marker "client-id:${workload}" "$id"
  echo "client-id:${workload} = $id"
done
set_marker "subscription-id" "$sub_id"

store="$ROOT/platform/clusters/azure-dev/config/cluster-secret-store-azure.yaml"
sed -i.bak -E "s|(vaultUrl: ).*|\1${kv_url}|" "$store" && rm -f "$store.bak"
echo "key vault url = $kv_url"

echo
echo "Review with 'git diff', then commit and push. ArgoCD picks the changes up."
