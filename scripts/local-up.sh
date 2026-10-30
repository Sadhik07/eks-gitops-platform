#!/usr/bin/env bash
# Spins up the whole delivery path on a local kind cluster: Argo Rollouts,
# Prometheus/Grafana, the three services and an SQS emulator. Costs nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=orders
ROLLOUTS_CHART=2.43.8
KPS_CHART=92.16.1

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config "$ROOT/local/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> Building and loading images"
for svc in api worker web; do
  docker build -q -t "orders/$svc:local" --build-arg APP_VERSION=local "$ROOT/apps/$svc" >/dev/null
  kind load docker-image "orders/$svc:local" --name "$CLUSTER" >/dev/null
done

echo "==> Installing Argo Rollouts and kube-prometheus-stack"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

helm upgrade --install argo-rollouts argo/argo-rollouts --version "$ROLLOUTS_CHART" \
  -n argo-rollouts --create-namespace --set dashboard.enabled=true --wait

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART" -n monitoring --create-namespace --wait --timeout 10m \
  --set fullnameOverride=kube-prometheus-stack \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelector.matchLabels.release=kube-prometheus-stack \
  --set prometheus.prometheusSpec.ruleSelector.matchLabels.release=kube-prometheus-stack \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.label=grafana_dashboard \
  --set grafana.sidecar.dashboards.searchNamespace=ALL

echo "==> Loading Grafana dashboards"
kubectl -n monitoring create configmap grafana-dashboards \
  --from-file="$ROOT/platform/config/common/dashboards" \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

echo "==> Deploying the orders services"
kubectl create namespace orders --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace orders pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
kubectl apply -k "$ROOT/deploy/overlays/local"
kubectl -n orders rollout status deployment/elasticmq --timeout=180s
kubectl -n orders rollout status deployment/web --timeout=180s
kubectl -n orders rollout status deployment/worker --timeout=180s
kubectl -n orders wait rollout/api --for=condition=Available --timeout=180s 2>/dev/null \
  || kubectl -n orders get rollout api

cat <<EOF

Local platform is up.
  App:        kubectl -n orders port-forward svc/web 8080:80        -> http://localhost:8080
  Grafana:    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
              (user admin, password: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
  Rollouts:   kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100

Next: ./scripts/demo-canary-rollback.sh   (ships a bad release and watches it roll back)
EOF
