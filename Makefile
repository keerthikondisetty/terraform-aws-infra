SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
ENV ?= dev

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_.-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

.PHONY: verify
verify: fmt validate policy ## Everything CI runs, no AWS credentials needed
	@echo ""
	@echo "  All checks passed."

.PHONY: fmt
fmt: ## Check formatting
	@echo ">> tofu fmt"
	@tofu fmt -check -recursive -diff

.PHONY: validate
validate: ## Validate every environment
	@for dir in envs/*/; do \
		echo ">> validate $$dir"; \
		tofu -chdir="$$dir" init -backend=false -input=false -no-color >/dev/null; \
		tofu -chdir="$$dir" validate -no-color; \
	done

.PHONY: policy
policy: ## checkov
	@echo ">> checkov"
	@checkov -d . --framework terraform --compact --quiet

.PHONY: plan
plan: ## Plan against a real account (needs credentials)
	@tofu -chdir=envs/$(ENV) plan

.PHONY: clean
clean:
	@find . -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@rm -f checkov.sarif
	@echo clean
