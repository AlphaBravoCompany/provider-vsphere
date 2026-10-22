# ====================================================================================
# Setup Project

PROJECT_NAME ?= provider-vsphere
PROJECT_REPO ?= github.com/AlphaBravoCompany/$(PROJECT_NAME)

export TERRAFORM_VERSION ?= 1.5.7

# Do not allow a version of terraform greater than 1.5.x, due to versions 1.6+ being
# licensed under BSL, which is not permitted.
TERRAFORM_VERSION_VALID := $(shell [ "$(TERRAFORM_VERSION)" = "`printf "$(TERRAFORM_VERSION)\n1.6" | sort -V | head -n1`" ] && echo 1 || echo 0)

export TERRAFORM_PROVIDER_SOURCE ?= vmware/vsphere
export TERRAFORM_PROVIDER_REPO ?= https://github.com/vmware/terraform-provider-vsphere
export TERRAFORM_PROVIDER_VERSION ?= 2.15.1
export TERRAFORM_PROVIDER_DOWNLOAD_NAME ?= terraform-provider-vsphere
# releases.hashicorp.com has no 2.15.1 build; the release artifacts live on GitHub. The provider
# runs in-process (no-fork), so the runtime image downloads nothing from here; the value is kept
# only as the exported variable the upjet template carries.
export TERRAFORM_PROVIDER_DOWNLOAD_URL_PREFIX ?= https://github.com/vmware/terraform-provider-vsphere/releases/download/v$(TERRAFORM_PROVIDER_VERSION)
export TERRAFORM_NATIVE_PROVIDER_BINARY ?= terraform-provider-vsphere_v$(TERRAFORM_PROVIDER_VERSION)
export TERRAFORM_DOCS_PATH ?= docs/resources


PLATFORMS ?= linux_amd64 linux_arm64

# -include will silently skip missing files, which allows us
# to load those files with a target in the Makefile. If only
# "include" was used, the make command would fail and refuse
# to run a target until the include commands succeeded.
-include build/makelib/common.mk

# ====================================================================================
# Setup Output

-include build/makelib/output.mk

# ====================================================================================
# Setup Go

# Set a sane default so that the nprocs calculation below is less noisy on the initial
# loading of this file
NPROCS ?= 1

# By default we reduce the go test parallelism (-p) to half the number of CPU cores.
GO_TEST_PARALLEL := $(shell echo $$(( $(NPROCS) / 2 )))

GOLANGCILINT_VERSION ?= 2.13.0
GO_STATIC_PACKAGES = $(GO_PROJECT)/cmd/provider $(GO_PROJECT)/cmd/generator
GO_LDFLAGS += -X $(GO_PROJECT)/internal/version.Version=$(VERSION)
GO_SUBDIRS += cmd internal apis
-include build/makelib/golang.mk

# ====================================================================================
# Setup Kubernetes tools

KIND_VERSION = v0.31.0
CRDDIFF_VERSION = v0.12.1
CROSSPLANE_CLI_VERSION = v2.2.1
# Crossplane version that controlplane.up installs for local-deploy (e2e-lab uses E2E_CROSSPLANE_VERSION)
CROSSPLANE_VERSION = 2.2.1
-include build/makelib/k8s_tools.mk

# ====================================================================================
# Setup Images

# The runtime image is embedded in the xpkg (crossplane xpkg build --embed-runtime-image), so
# no standalone image is published. Keep REGISTRY_ORGS empty: a plain image push from
# imagelight.mk would go to $(REGISTRY_ORGS)/provider-vsphere:$(VERSION) and overwrite the
# multi-arch xpkg index published at that same repo:tag.
REGISTRY_ORGS ?=
IMAGES = $(PROJECT_NAME)
-include build/makelib/imagelight.mk

# ====================================================================================
# Setup XPKG

# `make publish` pushes one multi-arch OCI index (linux_amd64 + linux_arm64 xpkgs) with
# `crossplane xpkg push` to docker.io/alphabravodevops/provider-vsphere:$(VERSION).
# - Publishing requires a prior interactive `docker login docker.io`; the crossplane CLI reads
#   only the local docker config and no registry credential is stored in this repository.
# - Publishing runs only on main/master/release-* branches (RELEASE_BRANCH_FILTER; pass
#   BRANCH_NAME=... explicitly when needed) and only from a clean tree (version.isdirty).
# - The docker.io/ host is used on purpose: go-containerregistry (used by the crossplane CLI)
#   normalizes docker.io to index.docker.io, and docker.io/alphabravodevops/provider-vsphere:<tag>
#   is the exact package reference consumers pin.
# See RELEASING.md for the full release runbook.
XPKG_REG_ORGS ?= docker.io/alphabravodevops
# `make promote` is a no-op for Docker Hub: the `latest` tag is moved explicitly with
# `docker buildx imagetools create` after the lab e2e passes (see RELEASING.md).
XPKG_REG_ORGS_NO_PROMOTE ?= docker.io/alphabravodevops
XPKGS = $(PROJECT_NAME)
-include build/makelib/xpkg.mk

# ====================================================================================
# Fallthrough

# run `make help` to see the targets and options

# We want submodules to be set up the first time `make` is run.
# We manage the build/ folder and its Makefiles as a submodule.
# The first time `make` is run, the includes of build/*.mk files will
# all fail, and this target will be run. The next time, the default as defined
# by the includes will be run instead.
fallthrough: submodules
	@echo Initial setup complete. Running make again . . .
	@make

# `crossplane xpkg build --examples-root` packs every YAML file under examples/, whether git
# tracks it or not, so a filled-in credentials Secret left there (such as an ignored
# examples/providerconfig/secret.yaml) would be published inside the package. Refuse to build or
# publish a package while examples/ holds any untracked or git-ignored file. The guard fails
# closed: if git status cannot run, nothing is packaged. It is hooked into build.init (fails
# before anything is compiled), the package build and the package push.
check-examples-untracked:
	@status="$$(git status --ignored --porcelain -- $(XPKG_EXAMPLES_DIR))" || { $(ERR) cannot list untracked files under $(XPKG_EXAMPLES_DIR), refusing to package examples ; exit 1; } ; \
	untracked="$$(printf '%s\n' "$$status" | grep -E '^(\?\?|!!) ' || true)" ; \
	if [ -n "$$untracked" ]; then \
		$(ERR) refusing to package examples: these untracked or git-ignored files under $(XPKG_EXAMPLES_DIR) would be packed into the xpkg ; \
		printf '%s\n' "$$untracked" ; \
		$(ERR) move them out of the repository, filled-in credentials especially, then retry ; \
		exit 1 ; \
	fi

build.init: check-examples-untracked
$(foreach x,$(XPKGS),xpkg.build.$(x)): check-examples-untracked
$(foreach r,$(XPKG_REG_ORGS),$(foreach x,$(XPKGS),xpkg.release.publish.$(r).$(x))): check-examples-untracked

.PHONY: check-examples-untracked

# NOTE(hasheddan): we force image building to happen prior to xpkg build so that
# we ensure image is present in daemon.
xpkg.build.provider-vsphere: do.build.images

# NOTE: we ensure the crossplane CLI is installed prior to running platform-specific
# build steps in parallel to avoid encountering an installation race condition, and we
# refuse a BSL-licensed Terraform version before anything else runs. The template's $(UP)
# prerequisite is dropped: crossplane/build's k8s_tools.mk defines CROSSPLANE_CLI but no UP.
build.init: $(CROSSPLANE_CLI) check-terraform-version

# ====================================================================================
# Setup Terraform for fetching provider schema
TERRAFORM := $(TOOLS_HOST_DIR)/terraform-$(TERRAFORM_VERSION)
TERRAFORM_WORKDIR := $(WORK_DIR)/terraform
TERRAFORM_PROVIDER_SCHEMA := config/schema.json

check-terraform-version:
ifneq ($(TERRAFORM_VERSION_VALID),1)
	$(error invalid TERRAFORM_VERSION $(TERRAFORM_VERSION), must be less than 1.6.0 since that version introduced a not permitted BSL license))
endif

# Order-only (|): the guard still runs, and fails, before any download, but being phony it no
# longer marks the cached binary out of date, so Terraform is downloaded once per version.
$(TERRAFORM): | check-terraform-version
	@$(INFO) installing terraform $(HOSTOS)-$(HOSTARCH)
	@mkdir -p $(TOOLS_HOST_DIR)/tmp-terraform
	@curl -fsSL https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/terraform_$(TERRAFORM_VERSION)_$(SAFEHOST_PLATFORM).zip -o $(TOOLS_HOST_DIR)/tmp-terraform/terraform.zip
	@unzip $(TOOLS_HOST_DIR)/tmp-terraform/terraform.zip -d $(TOOLS_HOST_DIR)/tmp-terraform
	@mv $(TOOLS_HOST_DIR)/tmp-terraform/terraform $(TERRAFORM)
	@rm -fr $(TOOLS_HOST_DIR)/tmp-terraform
	@$(OK) installing terraform $(HOSTOS)-$(HOSTARCH)

$(TERRAFORM_PROVIDER_SCHEMA): $(TERRAFORM)
	@$(INFO) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)
	@mkdir -p $(TERRAFORM_WORKDIR)
	@echo '{"terraform":[{"required_providers":[{"provider":{"source":"'"$(TERRAFORM_PROVIDER_SOURCE)"'","version":"'"$(TERRAFORM_PROVIDER_VERSION)"'"}}],"required_version":"'"$(TERRAFORM_VERSION)"'"}]}' > $(TERRAFORM_WORKDIR)/main.tf.json
	@$(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) init > $(TERRAFORM_WORKDIR)/terraform-logs.txt 2>&1
	@$(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) providers schema -json=true > $(TERRAFORM_PROVIDER_SCHEMA) 2>> $(TERRAFORM_WORKDIR)/terraform-logs.txt
	@$(OK) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)

pull-docs:
	@if [ ! -d "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" ]; then \
  		mkdir -p "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" && \
		git clone -c advice.detachedHead=false --depth 1 --filter=blob:none --branch "v$(TERRAFORM_PROVIDER_VERSION)" --sparse "$(TERRAFORM_PROVIDER_REPO)" "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)"; \
	fi
	@git -C "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" sparse-checkout set "$(TERRAFORM_DOCS_PATH)"
	@# The upjet scraper keys each resource by the last segment of the doc's page_title. Upstream
	@# vsphere_entity_permissions.md and vsphere_role.md use human titles ("VMware vSphere: Role"),
	@# which --resource-prefix cannot fix (it only applies when the title is empty), so rewrite any
	@# title that is not a lowercase identifier to the resource name derived from the file name.
	@# Idempotent: identifier titles are left untouched.
	@for f in "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)/$(TERRAFORM_DOCS_PATH)"/*.md; do \
		name="vsphere_$$(basename "$$f" .md | sed 's/^vsphere_//')"; \
		sed -i -E '/^page_title: /{/: [a-z0-9_]+"$$/!s/.*/page_title: "VMware vSphere: '"$$name"'"/}' "$$f"; \
	done

generate.init: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs

.PHONY: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs check-terraform-version
# ====================================================================================
# Targets

# Print the Go build and module cache paths. CI caches the go.cachedir path between runs.
go.cachedir:
	@go env GOCACHE

go.mod.cachedir:
	@go env GOMODCACHE

# Update the submodules, such as the common build scripts.
submodules:
	@git submodule sync
	@git submodule update --init --recursive

# This is for running out-of-cluster locally, and is for convenience. Running
# this make target will print out the command which was used. For more control,
# try running the binary directly with different arguments.
run: go.build
	@$(INFO) Running the provider locally out-of-cluster . . .
	@# To see other arguments that can be provided, run the command with --help instead
	$(GO_OUT_DIR)/provider --debug

# ====================================================================================
# End to End Testing
CROSSPLANE_NAMESPACE = crossplane-system
-include build/makelib/local.xpkg.mk
-include build/makelib/controlplane.mk

local-deploy: build controlplane.up local.xpkg.deploy.provider.$(PROJECT_NAME)
	@$(INFO) running locally built provider
	@$(KUBECTL) wait provider.pkg $(PROJECT_NAME) --for condition=Healthy --timeout 5m
	@$(KUBECTL) -n crossplane-system wait --for=condition=Available deployment --all --timeout=5m
	@$(OK) running locally built provider

# Lab end-to-end test. Run manually by a human against the CURRENT kube context.
# Lab vCenter credentials and VM placement IDs are read from the environment by the script.
E2E_CROSSPLANE_VERSION ?= 2.4.2
E2E_PROVIDER_PACKAGE ?= docker.io/alphabravodevops/$(PROJECT_NAME):$(VERSION)
e2e-lab:
	@$(INFO) running lab e2e against the current kube context
	@E2E_CROSSPLANE_VERSION="$(E2E_CROSSPLANE_VERSION)" E2E_PROVIDER_PACKAGE="$(E2E_PROVIDER_PACKAGE)" bash cluster/test/e2e-lab.sh || $(FAIL)
	@$(OK) running lab e2e against the current kube context

# crddiff is published only by github.com/upbound/uptest (v0.12.0 and later). The template's
# github.com/crossplane/uptest/cmd/crddiff does not exist at any version, so `go run` of it fails
# with "unknown revision". crossplane-contrib/provider-upjet-{aws,azure,gcp} use this module at
# v0.12.1, and crossplane/build pins cleanupexamples from the same module and version.
CRDDIFF := $(TOOLS_HOST_DIR)/crddiff-$(CRDDIFF_VERSION)

$(CRDDIFF):
	@$(INFO) installing crddiff $(CRDDIFF_VERSION)
	@mkdir -p $(TOOLS_HOST_DIR)/tmp-crddiff || $(FAIL)
	@GOBIN=$(TOOLS_HOST_DIR)/tmp-crddiff $(GOHOST) install github.com/upbound/uptest/cmd/crddiff@$(CRDDIFF_VERSION) || $(FAIL)
	@mv $(TOOLS_HOST_DIR)/tmp-crddiff/crddiff $(CRDDIFF) || $(FAIL)
	@rm -fr $(TOOLS_HOST_DIR)/tmp-crddiff
	@$(OK) installing crddiff $(CRDDIFF_VERSION)

# Breaking changes are reported, not fatal (template behavior). crddiff exits 1 both after
# printing a breaking-change report (lines starting with `Version "`) and on its own errors
# (`<binary>: error: ...`), so the report is recognized by its output. The target fails when
# crddiff cannot run: it cannot be installed, or it exits non-zero without a report.
crddiff: $(CRDDIFF)
	@$(INFO) Checking breaking CRD schema changes
	@tool_failed=0 ; \
	for crd in $${MODIFIED_CRD_LIST}; do \
		if ! git cat-file -e "$${GITHUB_BASE_REF}:$${crd}" 2>/dev/null; then \
			echo "CRD $${crd} does not exist in the $${GITHUB_BASE_REF} branch. Skipping..." ; \
			continue ; \
		fi ; \
		echo "Checking $${crd} for breaking API changes..." ; \
		changes_detected=$$($(CRDDIFF) revision --enable-upjet-extensions <(git cat-file -p "$${GITHUB_BASE_REF}:$${crd}") "$${crd}" 2>&1) ; \
		rc=$$? ; \
		if [[ $$rc == 1 ]] && printf '%s\n' "$${changes_detected}" | grep -q '^Version "' ; then \
			printf "\033[31m"; echo "Breaking change detected!"; printf "\033[0m" ; \
			echo "$${changes_detected}" ; \
			echo ; \
		elif [[ $$rc != 0 ]] ; then \
			$(ERR) crddiff could not check $${crd}, exit code $$rc ; \
			echo "$${changes_detected}" ; \
			echo ; \
			tool_failed=1 ; \
		fi ; \
	done ; \
	[[ $$tool_failed == 0 ]] || $(FAIL)
	@$(OK) Checking breaking CRD schema changes

.PHONY: submodules fallthrough run e2e-lab

# ====================================================================================
# Special Targets

define CROSSPLANE_MAKE_HELP
Crossplane Targets:
    submodules            Update the submodules, such as the common build scripts.
    run                   Run the provider locally, out-of-cluster. Useful for development.
    e2e-lab               Run the lab end-to-end test against the current kube context (manual, human-run only).

endef
export CROSSPLANE_MAKE_HELP

crossplane.help:
	@echo "$$CROSSPLANE_MAKE_HELP"

help-special: crossplane.help

.PHONY: crossplane.help help-special
