# Build the FlashSystem-snapshot-capable proxmox-csi-plugin controller.
#
# This is a THIN FORK, on purpose. It clones upstream at a pinned tag, drops in
# one new file and applies one patch to one file, and builds upstream's own
# controller entry point. No IBM-specific code enters the vendored tree beyond
# pkg/csi/flashsystem.go, and the patch is five hunks in pkg/csi/controller.go
# — which is what makes rebasing onto a new upstream tag a small job rather
# than a merge.
#
# Only the CONTROLLER is rebuilt. The node plugin is untouched: snapshots are
# a controller-service concern, and attach/mount already work on the stock
# node image. Keep the stock node image in the chart.
#
#   docker build -f Dockerfile -t <registry>/proxmox-csi-flashsystem:v0.20.0-fs1 .
#
# See ../csi/README.md for what this changes and why.

ARG UPSTREAM_TAG=v0.20.0
ARG UPSTREAM_REPO=https://github.com/sergelogvinov/proxmox-csi-plugin.git
# Pin the commit as well as the tag: a tag can be moved, and this fork's whole
# safety argument rests on the patch applying to code that has been read.
ARG UPSTREAM_COMMIT=a7aacee7a2144a43be08503068fe0b9caf3d0b4e

# --platform=$BUILDPLATFORM: run the builder NATIVELY on whoever is building,
# and cross-compile from there. The final binary's arch comes from
# GOARCH=${TARGETARCH} below, so the artifact is identical either way — but
# without this, buildx pulls the TARGET-arch golang image and emulates the
# whole stage under QEMU, upstream's test suite included. On an arm64 laptop
# building for linux/amd64 that is the difference between a couple of minutes
# and a very long coffee. CGO_ENABLED=0 is what makes the cross-compile need
# no toolchain.
#
# Note the tests at the end of this stage therefore run on the BUILD arch.
# That is fine here and arguably better: they are pure-Go logic tests, and
# `make verify` runs them natively too.
FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine3.24 AS builder

RUN apk add --no-cache git
WORKDIR /src

ARG UPSTREAM_TAG
ARG UPSTREAM_REPO
ARG UPSTREAM_COMMIT

RUN git clone --depth 1 --branch "${UPSTREAM_TAG}" "${UPSTREAM_REPO}" . \
 && ACTUAL="$(git rev-parse HEAD)" \
 && if [ "${ACTUAL}" != "${UPSTREAM_COMMIT}" ]; then \
        echo "FATAL: ${UPSTREAM_TAG} resolves to ${ACTUAL}, expected ${UPSTREAM_COMMIT}." >&2; \
        echo "The tag moved, or the pin is stale. Re-read the patch against the" >&2; \
        echo "new tree before changing this value." >&2; \
        exit 1; \
    fi

# The new backend, then the patch. `git apply` without --3way on purpose: a
# fuzzy apply onto shifted code is exactly the failure this build must refuse.
COPY flashsystem.go /src/pkg/csi/flashsystem.go
COPY patches/ /patches/
RUN git apply --verbose /patches/*.patch

# Upstream's own tests, with the patch in place. A fork that ships without
# running them is how a rebase silently breaks a behaviour nobody re-checked;
# one of these (TestListSnapshots) already caught a regression in this patch.
RUN go build ./... && go vet ./pkg/csi/ && go test ./pkg/csi/ ./pkg/utils/...

ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags "-s -w" \
      -o /out/proxmox-csi-controller ./cmd/controller

FROM gcr.io/distroless/static-debian13:nonroot AS proxmox-csi-flashsystem-controller

LABEL org.opencontainers.image.title="proxmox-csi-flashsystem-controller"
LABEL org.opencontainers.image.description="proxmox-csi-plugin controller with an IBM FlashSystem snapshot backend"
LABEL org.opencontainers.image.source="https://github.com/sergelogvinov/proxmox-csi-plugin"

COPY --from=builder /out/proxmox-csi-controller /bin/proxmox-csi-controller

ENTRYPOINT ["/bin/proxmox-csi-controller"]
