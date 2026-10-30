#!/usr/bin/env bash
# Game day: ship a release that fails 50% of requests and measure how long the
# canary analysis takes to detect it and roll back, with no human involved.
#
# Prints the measured detection/rollback time; record your own result in
# docs/game-days.md (it depends on scrape interval and machine speed).
set -euo pipefail

NS=orders
FAULT_RATE="${FAULT_RATE:-0.5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"

phase() { kubectl -n "$NS" get rollout api -o jsonpath='{.status.phase}'; }
cleanup() {
  kubectl -n "$NS" delete pod loadgen --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting load generator (through the web frontend, ~20 req/s)"
kubectl -n "$NS" delete pod loadgen --ignore-not-found >/dev/null
kubectl -n "$NS" run loadgen --image=curlimages/curl:8.10.1 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},
    "containers":[{"name":"loadgen","image":"curlimages/curl:8.10.1",
      "command":["sh","-c","while true; do curl -s -o /dev/null http://web/api/version; sleep 0.05; done"],
      "resources":{"requests":{"cpu":"20m","memory":"16Mi"},"limits":{"memory":"32Mi"}},
      "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
kubectl -n "$NS" wait pod/loadgen --for=condition=Ready --timeout=120s >/dev/null

echo "==> Letting Prometheus collect a healthy baseline (90s)"
sleep 90

echo "==> Shipping a bad release: FAULT_RATE=$FAULT_RATE"
start=$(date +%s)
kubectl -n "$NS" patch rollout api --type=json -p "[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",
   \"value\":{\"name\":\"FAULT_RATE\",\"value\":\"$FAULT_RATE\"}}]" >/dev/null

echo "==> Watching the canary"
while true; do
  now=$(date +%s); elapsed=$((now - start))
  p=$(phase)
  aborted=$(kubectl -n "$NS" get rollout api -o jsonpath='{.status.abort}')
  printf "\r  t+%3ss  phase=%-12s aborted=%s   " "$elapsed" "$p" "${aborted:-false}"
  if [[ "$aborted" == "true" ]]; then
    echo; echo "==> Canary ABORTED after ${elapsed}s; traffic is back on the stable version."
    break
  fi
  if [[ "$p" == "Healthy" && $elapsed -gt 60 ]]; then
    echo; echo "!! Rollout completed without being aborted: check the AnalysisTemplate and Prometheus."
    exit 1
  fi
  if (( elapsed > TIMEOUT_SECONDS )); then
    echo; echo "!! Timed out waiting for the analysis"; exit 1
  fi
  sleep 5
done

echo "==> Analysis results"
kubectl -n "$NS" get analysisrun -l rollouts-pod-template-hash \
  --sort-by=.metadata.creationTimestamp -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,MESSAGE:.status.message' | tail -3

echo "==> Reverting the bad change (in the cloud this is a 'git revert')"
idx=$(kubectl -n "$NS" get rollout api -o json \
  | python3 -c 'import json,sys; env=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["env"]; print([e["name"] for e in env].index("FAULT_RATE"))')
kubectl -n "$NS" patch rollout api --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/env/$idx\"}]" >/dev/null

echo "Done. Record the detection time above in docs/game-days.md."
