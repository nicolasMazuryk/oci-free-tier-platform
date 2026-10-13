# Core infra entrypoint. Layers: foundation -> cloudflare -> core.
SHELL := /bin/bash
.DEFAULT_GOAL := help

OCI_PROFILE ?= DEFAULT
OCI_CONFIG  ?= $(HOME)/.oci/config
oci_cfg = $(shell awk -F= -v p="[$(OCI_PROFILE)]" '$$0==p{f=1;next} /^\[/{f=0} f&&$$1~/^$(1)$$/{gsub(/ /,"",$$2);print $$2}' $(OCI_CONFIG))

export TF_VAR_tenancy_ocid ?= $(call oci_cfg,tenancy)
export TF_VAR_user_ocid    ?= $(call oci_cfg,user)
export TF_VAR_oci_profile  ?= $(OCI_PROFILE)
export OCI_CLI_PROFILE     ?= $(OCI_PROFILE)

LAYERS := foundation cloudflare core
TF = terraform -chdir=terraform/$(1)

.PHONY: help
help: ## List targets
	@grep -hE '^[a-zA-Z0-9_%-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-22s %s\n", $$1, $$2}'

## ---- per-layer terraform -------------------------------------------------
.PHONY: init-% plan-% apply-% output-% fmt validate
init-%: ## terraform init for a layer (init-foundation|init-cloudflare|init-core)
	$(call TF,$*) init -input=false

plan-%: ## terraform plan for a layer
	$(call TF,$*) plan -input=false $(ARGS)

apply-%: ## terraform apply for a layer
	$(call TF,$*) apply -input=false $(ARGS)

output-%: ## terraform output for a layer
	@$(call TF,$*) output $(ARGS)

fmt: ## terraform fmt all layers
	terraform fmt -recursive terraform

validate: ## terraform validate all layers
	@for l in $(LAYERS); do echo "== $$l"; $(call TF,$$l) validate || exit 1; done

.PHONY: plan-all
plan-all: ## plan every layer (expect "No changes" after a full apply)
	@for l in $(LAYERS); do echo "== $$l"; $(call TF,$$l) plan -input=false -detailed-exitcode -compact-warnings >/dev/null && echo "no changes" || echo "CHANGES PENDING ($$?)"; done

## ---- lifecycle ----------------------------------------------------------
.PHONY: bootstrap
bootstrap: ## First-ever deploy of foundation with local state, then migrate into the bucket
	scripts/bootstrap-foundation.sh

.PHONY: wipe restore
wipe: ## Manual backup of /data volume, then destroy the core layer (foundation+cloudflare kept)
	scripts/wipe.sh

restore: ## Recreate core layer; BACKUP=<volume-backup-ocid> restores /data from that backup
	scripts/restore.sh $(BACKUP)

.PHONY: backup
backup: ## Manual backup of core-bv-app-data (NAME=optional-suffix)
	scripts/backup-now.sh $(NAME)

## ---- access / host ------------------------------------------------------
.PHONY: ssh host-sync
ssh: ## SSH to a VM through the Bastion (VM=app|ops)
	scripts/ssh.sh $(or $(VM),app) $(CMD)

host-sync: ## rsync host/<VM>/ to /opt/core and re-run bootstrap.sh (VM=app|ops)
	scripts/host-sync.sh $(or $(VM),app)

## ---- secrets / guardrails -----------------------------------------------
.PHONY: secret-put free-tier drift
secret-put: ## Create/update a Vault secret: NAME=core-secret-x [FILE=path] (prompts hidden if no FILE)
	scripts/secret-put.sh $(NAME) $(FILE)

free-tier: ## List resources and flag anything not Always-Free
	scripts/check-free-tier.sh

drift: ## Compare Cloudflare IPv4 ranges with core-nsg-app rules
	scripts/cf-ip-drift-local.sh
