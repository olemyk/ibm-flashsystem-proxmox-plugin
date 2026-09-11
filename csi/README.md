# FlashSystem array snapshots from Kubernetes

A thin fork of `proxmox-csi-plugin` that makes `kubectl`-native
`VolumeSnapshot` work against IBM FlashSystem volumes served through Proxmox,
plus the Helm values and manifests to install and test it.

**Status: unvalidated against hardware.** The snapshot half rests on array
commands already running in production; the *restore* half rests on `mkvolume`,
which this project has never issued. See [Before you trust it](#before-you-trust-it).

---

## The problem, in one paragraph

Upstream refuses CSI snapshots when the Proxmox storage has `shared == 1`
(`pkg/csi/controller.go`, added in PR #590, first shipped in v0.19.1). That
guard is not careless. What the driver calls a snapshot is a full volume copy
through PVE's `/nodes/{node}/storage/{storage}/content/{volume}` endpoint —
which PVE's own source labels *"experimental code - do not use"* — and
`PVE::Storage::storage_migrate` returns the **source** volid unchanged for
same-storage shared volumes. So on shared storage that path creates nothing and
reports success. **Removing the guard does not buy slow copies. It buys a
no-op.** And `shared 1` cannot simply be turned off: it is what selects the
zone-less volume handle that lets a LUN attach on any node.

Meanwhile the array can snapshot properly — instantly, space-efficiently — and
the Proxmox storage plugin already drives that. It was just unreachable from
Kubernetes, because Proxmox exposes no per-volume snapshot verb: every snapshot
endpoint PVE offers is VM-scoped with no disk selector, so a snapshot of the CSI
holder VM would capture every PVC parked on it.

## What this does instead

```
VolumeSnapshot
  └─ csi-snapshotter ──▶ CreateSnapshot (this fork)
                            └─ POST /nodes/{node}/flashsystem/{storage}/snapshot
                                  (PVE API, driver's EXISTING Proxmox token)
                                  └─ FlashSystemPlugin.pm ──▶ addsnapshot
```

**No array credentials in Kubernetes.** The array password and the storage's
`fsprefix` both stay on the Proxmox side. This driver authenticates with the
same Proxmox token it already uses to provision and attach — and a PVE token is
scopeable by ACL to `/storage/<id>`, which a Storage Virtualize role cannot be:
ownership groups inherit from child pools, this array has none, and snapshots
are not an ownable object type at all. That matters because any array
credential that can snapshot can also `restorefromsnapshot`, which destroys
data *without deleting an object* and so trips no capacity or object-count
monitoring.

### Why it is not a second CSI driver

Adding a snapshot-only driver alongside the stock one looks tempting and is a
trap. Create and delete would work — `external-snapshotter` never compares
`VolumeSnapshotClass.driver` to the PV's driver on the single-snapshot path.
Restore is hard-blocked: `external-provisioner` refuses a
`VolumeSnapshotContent` whose driver differs from the StorageClass provisioner
(`controller.go`, present in v5.3.0, v6.0.0 and v6.3.0). It would test green and
fail on the first real restore.

## Contents

| | |
|---|---|
| `flashsystem.go` | The backend. One new file, dropped into `pkg/csi/`. |
| `patches/0001-…patch` | Seven hunks: six in `pkg/csi/controller.go`, one bumping the capability count in `controller_test.go`. Nothing else is touched. |
| `Dockerfile` | Clones upstream at a pinned tag **and commit**, applies both, runs upstream's tests, builds the controller. |
| `Makefile` | `make verify` (no docker), `make build`, `make push`. |
| `deploy/values-flashsystem.yaml` | Helm overlay for the upstream chart. |
| `deploy/volumesnapshotclass.yaml` | The chart ships none. |
| `deploy/smoke-test.yaml` | End-to-end test, part 1 — provision and write. |
| `deploy/smoke-test-restore.yaml` | Part 2 — snapshot and restore. Applied *after* the write job completes; checks restored bytes, not just binding. |

## Install

### 0. Prerequisites

The storage plugin must have the CSI endpoints (this repo's
`api/FlashSystemAPI.pm`), and snapshots must be enabled per storage:

```bash
pvesm set k8s-archive --fssnapshots 1
pvesh get /nodes/$(hostname)/flashsystem/k8s-archive/snapshot
```

The second command returning a list (even an empty one) proves the whole
array-facing path before Kubernetes is involved at all.

The snapshot CRDs and `snapshot-controller` are **not** part of any CSI driver
and will be absent on a cluster that has never snapshotted:

```bash
kubectl get crd volumesnapshots.snapshot.storage.k8s.io
kubectl -n kube-system get deploy snapshot-controller
```

The driver's Proxmox token needs `Datastore.Allocate` on the storages it
snapshots — `Datastore.Audit` is enough to *list* but deliberately not to
create or delete.

### 1. Verify the patch, then build

```bash
cd csi
make verify                                  # clone, patch, build, vet, test — no docker
make push REGISTRY=harbor.example.com/platform
```

`make verify` is worth running on its own before any rebase onto a new upstream
tag. It has already caught two regressions in this patch: upstream's
`TestListSnapshots` asserts an exact empty `Unimplemented` message, and
`TestControllerServiceControllerGetCapabilities` asserts an exact capability
*count* — which the `LIST_SNAPSHOTS` hunk has to bump from 9 to 10.

That capability is not optional. `external-snapshotter` treats an
unadvertised `LIST_SNAPSHOTS` as *assume the snapshot is valid*, so a
pre-provisioned `VolumeSnapshotContent` would report `readyToUse: true`
without the driver being asked anything — and that shortcut is the only place
readiness is decided on that path.

### 2. Install

Set `controller.plugin.image.repository` in the overlay to what `make push`
produced, then:

```bash
kubectl create namespace csi-proxmox
kubectl label namespace csi-proxmox \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=baseline \
  pod-security.kubernetes.io/warn=baseline

helm upgrade --install proxmox-csi-plugin \
  oci://ghcr.io/sergelogvinov/charts/proxmox-csi-plugin \
  --version 0.5.10 -n csi-proxmox \
  -f deploy/values-flashsystem.yaml -f your-cloud-config.yaml
kubectl apply -f deploy/volumesnapshotclass.yaml
```

The namespace is created by hand, with labels, because nothing else creates it
and a bare one is not enough: the node plugin runs privileged, so under a
`restricted` pod-security default its DaemonSet is rejected at admission and
every pod with a PVC hangs at ContainerCreating with the reason visible only in
the DaemonSet's events. `--create-namespace` would make exactly that bare
namespace, and the chart's own `createNamespace: true` cannot then adopt it.

**Both `-f` files, every time.** This overlay defines no `config.clusters`, the
chart renders its credentials Secret only when that list is non-empty, and it
mounts the Secret unconditionally. Omit the cloud-config and the controller
hangs in ContainerCreating on a fresh install — or, on an upgrade, helm deletes
the working Secret and rolls the pod in the same operation, taking provisioning,
attach and resize down for every existing PVC under a green `helm upgrade`.

There is deliberately no `--force-conflicts` here: it is not a Helm 3 flag, and
Helm 3 exits `Error: unknown flag` before rendering anything. On Helm 4, where
server-side apply conflicts on `.spec.storageCapacity` if anyone has patched
the CSIDriver by hand, add it back. On Helm 3 the equivalent is
`--take-ownership` (3.17+).

Then confirm the image actually took — the key is `controller.plugin.image`,
not a top-level `image`, and getting it wrong installs the stock controller
while looking configured:

```bash
kubectl -n csi-proxmox get deploy proxmox-csi-plugin-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 3. Test

```bash
kubectl apply -f deploy/smoke-test.yaml
kubectl -n fs-smoke wait --for=condition=complete job/fs-smoke-write --timeout=5m
kubectl apply -f deploy/smoke-test-restore.yaml
```

Two files, and the `wait` between them is not optional. The verify job re-reads
a marker and a 64 MiB checksum and **fails loudly** if they differ — that
comparison is the actual test, because a restore that binds but serves the
wrong bytes looks like a success everywhere else. Apply both at once and the
array snapshot is cut while the write is still in flight, so that comparison
fails on a working array and tells you nothing.

Step 3 needs `fsrestore` enabled (below). Until then `fs-smoke-restored` stays
Pending with a provisioner event naming the probe script — the gate working,
not a fault.

## Before you trust it

Split by what it rests on, because the two halves are not equally risky.

**Snapshot create / delete / list** use `addsnapshot`, `rmsnapshot` and
`lsvolumesnapshot` — in production on this fleet since 2026-08-12. Low risk.

**Restore** uses `mkvolume`, the one command family the storage plugin has never
issued; it deliberately chose `mkvolume`'s older sibling for allocation. Every
documented data-reduction-pool restriction on `mkvolume` concerns parameters
this call does not pass — but "documented as unrestricted" is worth exactly what
the `-warning` rejection was worth, which is to say a wasted afternoon.

So it ships **disabled**, behind its own flag rather than behind a README
sentence:

```bash
pvesm set k8s-archive --fsrestore 1      # only after the probe passes
```

Until that is set, `CreateVolume` from a snapshot fails with a message naming
the probe script. Snapshot create/delete/list work regardless — the two halves
are gated separately on purpose, so enabling the proven half does not enable
the unproven one.

**`fsreapsnapshots` is also off by default**, and should stay off. When the
array refuses to delete a volume because it still has snapshots, the default is
to let that refusal propagate: a failed `DeleteVolume` is retried by
`external-provisioner` and shows up in PVC events, whereas silently destroying
the volume's recovery points because someone ran `kubectl delete pvc` shows up
nowhere and cannot be undone.

Two behaviours to know before relying on this:

- **`thinclone` is the default and stays dependent** on its source snapshot for
  life. Deleting that snapshot is *deferred* by the array rather than freeing
  space, so `deletionPolicy: Delete` does not necessarily reclaim capacity
  while a restore is alive. `fsclonetype: clone` is independent but copies at
  IBM's default 2 MB/s — hours per 100 GiB.
- **Expanding a volume invalidates rollback** for every snapshot it already
  had: the array requires the same virtual capacity, and
  `allowVolumeExpansion` is on for every tier here.

## Rebasing

The fork is deliberately small so this stays cheap:

```bash
make verify UPSTREAM_TAG=v0.21.0
```

If the patch does not apply, read the new `CreateSnapshot`, `DeleteSnapshot` and
`CreateVolume` rather than reaching for `--3way`. The one invariant that must
survive any reshuffle is that **every dispatch happens before `checkVolume`** —
`checkVolume` resolves through the PVE content listing, the storage plugin
deliberately never lists snapshot objects there, and upstream turns its
`NotFound` into a *successful* delete. Move a dispatch below it and every
snapshot deletion reports success having freed nothing.

Update `UPSTREAM_COMMIT` in the `Dockerfile` at the same time; the build refuses
a tag that resolves elsewhere rather than patching code nobody has read.

## Worth sending upstream

Two things here are not FlashSystem-specific:

1. **`CreateSnapshot` returns the zoned handle** (`VolumeID()`) while shared
   volumes use the zone-less one (`VolumeSharedID()`). A two-line fix, correct
   on its own merits, and nobody has hit it because the guard fires first.
2. **`docs/volumesnapshot.md` documents none of the four refused backend
   classes** — shared, `rbd`, `cifs`/`pbs`, `lvm`+qcow2. Zero grep hits.

Lead any pluggable-backend conversation with **transfer formats**, not the
guard: this plugin implements no `volume_export`/`volume_import`, so
`volume_transfer_formats` intersects to empty and `storage_migrate` *dies* with
`shared 0`. Phrased as "you are rejecting storage that can snapshot", the report
invites the correct reply — *then don't mark it shared* — and the shared flag is
load-bearing.
