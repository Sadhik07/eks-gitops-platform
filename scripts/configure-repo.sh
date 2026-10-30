#!/usr/bin/env bash
# Replaces the placeholders in this template with your own values.
#   ./scripts/configure-repo.sh <github-user-or-org> <aws-account-id> [repo-name]
set -euo pipefail

GH_OWNER="${1:?usage: $0 <github-owner> <aws-account-id> [repo-name]}"
ACCOUNT="${2:?usage: $0 <github-owner> <aws-account-id> [repo-name]}"
REPO="${3:-eks-gitops-platform}"

[[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo "AWS account id must be 12 digits" >&2; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
files=$(grep -rlE 'YOUR_GITHUB_USER|123456789012|eks-gitops-platform' \
  --exclude-dir=.git --exclude-dir=.terraform --exclude=configure-repo.sh . || true)

for f in $files; do
  # Most specific pattern first: owner/repo, then the bare owner and account
  sed -i.bak \
    -e "s|YOUR_GITHUB_USER/eks-gitops-platform|$GH_OWNER/$REPO|g" \
    -e "s|github_repo  = \"eks-gitops-platform\"|github_repo  = \"$REPO\"|g" \
    -e "s|YOUR_GITHUB_USER|$GH_OWNER|g" \
    -e "s|123456789012|$ACCOUNT|g" \
    "$f" && rm -f "$f.bak"
done

echo "Updated $(echo "$files" | wc -w | tr -d ' ') files."
echo "Still to do by hand:"
echo "  - infra/terraform/live/*/terraform.tfvars: public_endpoint_cidrs (your IP: curl -s https://checkip.amazonaws.com)"
echo "  - region, if not us-east-1 (grep -rn us-east-1)"
