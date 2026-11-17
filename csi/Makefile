# Build and publish the FlashSystem-snapshot-capable CSI controller.
#
#   make build                     # build locally, no push
#   make push REGISTRY=harbor.example.com/platform
#   make verify                    # apply the patch in a temp tree and run
#                                  # upstream's tests. No docker needed.
#
# REGISTRY is required for push. TAG encodes both halves of what is inside:
# the upstream tag it was built from, and this fork's revision.

UPSTREAM_TAG   ?= v0.20.0
FORK_REV       ?= fs1
TAG            ?= $(UPSTREAM_TAG)-$(FORK_REV)
IMAGE          ?= proxmox-csi-flashsystem-controller
REGISTRY       ?=
PLATFORMS      ?= linux/amd64

ifeq ($(REGISTRY),)
FULL_IMAGE = $(IMAGE):$(TAG)
else
FULL_IMAGE = $(REGISTRY)/$(IMAGE):$(TAG)
endif

.PHONY: help
help:
	@printf 'FlashSystem CSI controller\n\n'
	@printf '  make verify                      apply the patch and run upstream tests (no docker)\n'
	@printf '  make build                       build the image locally\n'
	@printf '  make push REGISTRY=<host>/<proj> build and push\n'
	@printf '  make print-image                 show the image reference that would be used\n\n'
	@printf 'Current: %s\n' '$(FULL_IMAGE)'

.PHONY: print-image
print-image:
	@printf '%s\n' '$(FULL_IMAGE)'

.PHONY: build
build:
	docker build \
	  --build-arg UPSTREAM_TAG=$(UPSTREAM_TAG) \
	  --platform $(PLATFORMS) \
	  --target proxmox-csi-flashsystem-controller \
	  -t $(FULL_IMAGE) .

.PHONY: push
push:
ifeq ($(REGISTRY),)
	@printf 'REGISTRY is required for push, e.g.\n  make push REGISTRY=harbor.example.com/platform\n' >&2; exit 1
endif
	docker buildx build \
	  --build-arg UPSTREAM_TAG=$(UPSTREAM_TAG) \
	  --platform $(PLATFORMS) \
	  --target proxmox-csi-flashsystem-controller \
	  -t $(FULL_IMAGE) --push .

# Everything the Dockerfile does, minus the container: clone, patch, build,
# vet, test. Useful for checking a rebase onto a new upstream tag before
# spending a docker build on it.
.PHONY: verify
verify:
	@set -eu; \
	tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf 'cloning %s at %s\n' proxmox-csi-plugin "$(UPSTREAM_TAG)"; \
	git clone --quiet --depth 1 --branch "$(UPSTREAM_TAG)" \
	  https://github.com/sergelogvinov/proxmox-csi-plugin.git "$$tmp/src"; \
	cp flashsystem.go "$$tmp/src/pkg/csi/flashsystem.go"; \
	cd "$$tmp/src"; \
	printf 'applying patches\n'; \
	git apply --verbose ../../patches/*.patch 2>/dev/null \
	  || git apply --verbose $(CURDIR)/patches/*.patch; \
	printf 'gofmt\n';  test -z "$$(gofmt -l pkg/csi/)" || { gofmt -l pkg/csi/; exit 1; }; \
	printf 'build\n';  go build ./...; \
	printf 'vet\n';    go vet ./pkg/csi/; \
	printf 'test\n';   go test ./pkg/csi/ ./pkg/utils/...; \
	printf '\nOK: patch applies to %s and upstream tests pass.\n' "$(UPSTREAM_TAG)"
