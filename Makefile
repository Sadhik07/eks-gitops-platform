SHELL := /bin/bash
.DEFAULT_GOAL := help
SERVICES := api worker

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## ---------- Local (kind) ----------
.PHONY: local-up local-down demo-rollback
local-up: ## Create a kind cluster with Rollouts, Prometheus, Grafana and the app
	./scripts/local-up.sh

local-down: ## Delete the kind cluster
	./scripts/local-down.sh

demo-rollback: ## Ship a faulty release and watch the canary roll back
	./scripts/demo-canary-rollback.sh

## ---------- Quality gates (same as CI) ----------
.PHONY: test lint validate policy-test check
test: ## Unit tests for services and tooling
	@for s in $(SERVICES); do (cd apps/$$s && python -m pytest -q) || exit 1; done
	python -m pytest -q tests

lint: ## Lint Python, shell, Dockerfiles and Terraform
	ruff check apps platform/config/common/dora tests
	ruff format --check apps platform/config/common/dora tests
	shellcheck scripts/*.sh
	@for s in api worker web; do hadolint apps/$$s/Dockerfile || exit 1; done
	terraform fmt -check -recursive infra/terraform infra/terraform-azure
	tflint --recursive --config "$(CURDIR)/.tflint.hcl" --chdir infra/terraform
	tflint --recursive --config "$(CURDIR)/.tflint-azure.hcl" --chdir infra/terraform-azure

validate: ## Render every overlay and validate against Kubernetes + CRD schemas
	@mkdir -p .rendered && rm -f .rendered/*
	@for d in deploy/overlays/*/* deploy/overlays/local platform/clusters/* platform/clusters/*/config; do \
	  [ -f $$d/kustomization.yaml ] || continue; \
	  kustomize build $$d > .rendered/$$(echo $$d | tr / _).yaml || exit 1; done
	kubeconform -strict -summary -ignore-missing-schemas -schema-location default \
	  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
	  .rendered/*.yaml

policy-test: ## Kyverno policy unit tests
	kyverno test platform/policies/tests

check: test lint validate policy-test ## Everything CI runs, locally

## ---------- AWS ----------
.PHONY: bootstrap-dev bootstrap-stage bootstrap-prod
bootstrap-%: ## Install ArgoCD and hand a cluster to GitOps (make bootstrap-dev, make bootstrap-azure-dev)
	./scripts/bootstrap-cluster.sh $*

## ---------- Azure ----------
.PHONY: azure-sync
azure-sync: ## Write Azure Terraform outputs (client ids, Key Vault URL) into the manifests
	./scripts/azure-sync-outputs.sh
