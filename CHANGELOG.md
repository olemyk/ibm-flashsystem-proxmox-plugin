# Changelog

Pre-release history, condensed from internal deployment tags. Dates are when
the change reached a 12-node production cluster (PVE 9.2, firmware 8.7).

## Unreleased — 2026-09-10

Kubernetes CSI snapshot support: four new PVE API endpoints, a thin fork of
`proxmox-csi-plugin` (`csi/`), and the Helm bundle to install and test it.
**Unvalidated against hardware.**

- **Four CSI endpoints** under `/nodes/{node}/flashsystem/{storage}/` —
  snapshot create/list/delete and volume-from-snapshot. The CSI driver calls
  them with its **existing Proxmox token**, so no array credential enters
  Kubernetes and `fsprefix` never leaves the Proxmox side. Writes require
  `Datastore.Allocate`; only the listing accepts `Datastore.Audit`.
- **`csi_*` plugin methods** carrying the naming contract. The array caps
  object names at 63 chars, leaving exactly nine for a snapshot name on a
  4-char prefix, so the array-side component is
  `base32(top 45 bits of sha256(csi name))` with **a leading digit** —
  deterministic, because CSI `CreateSnapshot` is idempotent by name. The
  leading digit is load-bearing, not cosmetic: `pve-snapshot-name` is
  `/^[a-z][a-z0-9_-]+$/i`, and nine characters is the *only* PVE snapshot-name
  length that fits the 63-char cap on a `k8s-*` storage, so a shape check
  alone let `qm snapshot <vm> preupdate` parse as a CSI snapshot — after which
  `csi_snapshot_list` reported the operator's rollback point to Kubernetes as a
  leaked orphan and `csi_snapshot_delete` `rmsnapshot`ed it, while PVE's
  vmconfig still listed it so the loss surfaced only at `qm rollback`. Minting
  ours outside PVE's grammar makes the two namespaces structurally disjoint,
  and `volume_snapshot` refuses a CSI-shaped name from the other direction. A component that already belongs to
  a **different** volume is refused with `ALREADY_EXISTS` rather than aliased:
  aliasing would return a handle pointing at another PVC's snapshot.
- **`fsrestore`, default off.** The restore path rests on `mkvolume`, which
  this plugin has never issued. Gated separately from `fssnapshots` so
  enabling the production-proven half does not enable the unproven one. It
  gates **both** `mkvolume` call sites — `csi_volume_from_snapshot` *and*
  `clone_image`. Gating only the first left `qm clone <vmid> <new> --snapshot
  <s> --full 0` issuing the unvalidated command with the flag at its default,
  on a fleet where `fssnapshots` has been on since 2026-08-12.
  `volume_has_feature` also stops advertising `clone` while the gate is
  closed, so qemu-server refuses before the plugin is reached.
- **`fsreapsnapshots`, default off.** Previously `free_image` always reaped a
  volume's snapshots when the array refused to delete it. That turns
  `kubectl delete pvc` into silent destruction of every recovery point, so the
  refusal now propagates unless this is explicitly enabled.
- **Only `active` counts as ready, everywhere.** IBM's `lsvolumesnapshot`
  reference: *"Ready: If the snapshot is not triggered. Active: Maintain the
  snapshot image."* So `Ready` is the opposite of usable. Beyond
  `ready_to_use`, all three commands that need a real point-in-time image now
  refuse without one — `volume_snapshot_rollback`, `clone_image` and
  `csi_volume_from_snapshot` — because `restorefromsnapshot` overwrites a
  volume's contents *without deleting any object*, so it trips no capacity or
  object-count monitoring. An unknown or absent state refuses, like the
  `volume_size_mismatch` guard beside it.
- **`PVE::Storage::cluster_lock_storage` does not exist.** The lock below was
  added calling it, and it got through because `tests/stub/PVE/Storage.pm`
  *defined* the invented function — so 213 API cases validated an API PVE has
  never had. It failed on the first live `CreateSnapshot` with `Undefined
  subroutine`. The real symbol is a CLASS METHOD on the plugin base class,
  `PVE::Storage::Plugin->cluster_lock_storage($storeid, $shared, $timeout,
  $func, @param)` (`/usr/share/perl5/PVE/Storage/Plugin.pm:759`), which with
  `$shared` true locks through `PVE::Cluster::cfs_lock_storage` — pmxcfs, i.e.
  genuinely cluster-wide, which is what was wanted.
  Three things changed, not one: the call site; the stub, which now lives in
  the right package with the real signature and *refuses a function-style
  call*, so reintroducing the mistake fails a test; and the role's `api.yml`,
  which now asserts at install time that the PVE symbols the module calls
  actually resolve. That last gap is why this reached production — the
  post-install check exercised the INDEX endpoint and the 12-node verification
  was a GET, so both passed while every POST was broken. A symbol resolved at
  call time is invisible to `perl -c`.
- **The mutating CSI endpoints hold the cluster storage lock.** Every write is
  read-then-act, and Storage Virtualize snapshot names are not system-unique,
  so two concurrent `CreateSnapshot`s for one CSI name both saw "absent" and
  both succeeded — leaving two array objects of which `csi_snapshot_delete`
  can only ever remove the first. `external-snapshotter` retries on any error,
  including a read-back that timed out after `addsnapshot` had taken effect, so
  this was reachable. The read endpoint deliberately does not lock.
- **Delete tells absence from unattributable.** `_snapshots_for` dropped a
  disagreeing `volume_name` in non-strict mode too, so the loose re-scan that
  exists to catch this could not see it and returned `reason: 'absent'` — which
  the Go side maps to nil and Kubernetes records as reclaimed capacity, for a
  snapshot still holding it. A new `any_owner` mode matches on the name alone
  for exactly this comparison, and never for anything that acts on the row.
- **Create reads back strictly**, matching delete. On a firmware that omits
  `volume_name`, every create used to succeed and every delete fail
  permanently; it now fails on the first snapshot, while nothing has leaked.
- **`LIST_SNAPSHOTS` is advertised** (a sixth patch hunk). Unadvertised,
  `external-snapshotter` treats it as *assume the snapshot is valid* and reports
  a pre-provisioned `VolumeSnapshotContent` `readyToUse: true` without asking
  the driver — and that shortcut is the only place readiness is decided on that
  path. Upstream's `TestControllerServiceControllerGetCapabilities` pins the
  capability count, so the patch bumps 9 → 10 in `controller_test.go`.
- **The suite could not run on a bare perl**, which is what a CI runner is.
  `run.sh` claims it "runs anywhere perl exists", but the module's `use JSON`,
  `use LWP::UserAgent` and `use HTTP::Request` are non-core — installed on every
  node by `flashsystem_plugin_packages`, absent on a runner — and `use` runs at
  BEGIN, so `perl -T -I stub -c`, the FIRST command in the suite, died before a
  single case ran. All three are now shimmed in `tests/stub`, JSON delegating to
  core `JSON::PP` so booleans and round-tripping stay real rather than faked.
  The `LWP::UserAgent` shim's `request` is deliberately fatal: a plausible fake
  response would let a test assert against fiction. Since `stub` is first on
  `@INC` the shims win everywhere, so the suite now behaves identically on a
  laptop and on the runner.
- **`tools/probe-clone-from-snapshot.sh` could not run at all.** `fs()`
  assigned `FS_HTTP` inside the command substitution every one of its ~29 call
  sites wraps it in, so the parent's copy stayed empty for the whole run:
  `fs_ok()` was always false and the probe died at step 0 against a healthy
  array, printing `lsmdiskgrp failed (HTTP )` beside the successful body. The
  status now crosses the subshell boundary through a temp file, read with
  `fs_http()`. This is the script that gates `fsrestore`, so until now that
  flag could not honestly be enabled.
- **The install commands were wrong in two ways.** `--force-conflicts` is not a
  Helm 3 flag (`helm upgrade` exits `Error: unknown flag` before rendering);
  and the command inside `values-flashsystem.yaml` omitted the cloud-config,
  which renders **zero** credential Secrets while still mounting one — a fresh
  install hangs in `ContainerCreating`, and an *upgrade* deletes the working
  Secret and rolls the pod in the same operation, taking provisioning, attach
  and resize down for every existing PVC under a green `helm upgrade`.
- **`smoke-test.yaml` is split in two.** Applied as one file it cut the array
  snapshot concurrently with the 64 MiB write and started the verify job
  immediately, so the checksum comparison — the actual test — failed on a
  working array. Part 2 (`smoke-test-restore.yaml`) is applied after
  `job/fs-smoke-write` completes. Cleanup order is now documented too: with
  `thinclone`, the restored volume pins its source snapshot and the array
  defers that snapshot's removal, which is indistinguishable from a delete
  that silently freed nothing.
- **`ready` was inverted.** IBM's `lsvolumesnapshot` reference defines
  *"Ready: If the snapshot is not triggered"* — the opposite of
  `ready_to_use`. The allowlist accepted both `active` and `ready`, so
  Kubernetes would have been told a snapshot was usable before any
  point-in-time image existed. Now `active` only, with anything unrecognised
  treated as not-ready.
- **Snapshot names are constrained to the digest grammar.** Without it, every
  ordinary PVE snapshot on the same storage (`<vdisk>.vzdump`, a GUI snapshot)
  parsed as a CSI snapshot — so listing reported them to Kubernetes, delete
  accepted a handle naming one, and restore would clone from one.
- **Delete distinguishes absent from unattributable.** Only genuine absence is
  reported as success, which is what the CSI spec requires. A row the array
  lists but cannot attribute to the owning volume is an error, because
  reporting it deleted leaks physical capacity in a data reduction pool.
- **Restore resolves its source strictly** (`strict => 1`), and the
  target-name existence check fails **closed**: only the plugin's own
  not-found error may be read as absence, so an unreachable array no longer
  looks like a free name.
- 24 further unit cases (163 → 187), including one per documented array
  snapshot state.

## Unreleased — 2026-09-09

Array-side capability for Kubernetes volume snapshots. Everything below is
**unvalidated against hardware** except the DRP diagnosis;
`tools/probe-clone-from-snapshot.sh` is the gate.

- **`fsthin` works on a data reduction pool.** The 2026-09-07 failure was one
  parameter, not the feature: a DRP rejects `-warning` on a thin volume with
  `CMMVC9236E`, which is *parameter validation* — the `80%` value is never
  evaluated and it fails on an empty pool too. `_mkvdisk_params` takes a
  fourth argument `$drp` and omits `warning` when set; new `_pool_is_drp`
  supplies it from one `lsmdiskgrp`, called only when `fsthin` is on so the
  thick path stays at exactly one REST call. `-rsize` is kept even though a
  DRP ignores its value, because dropping it silently produces **thick**
  volumes; `-autoexpand` turns out to be *required* there and was already
  sent. A DRP thin volume has no per-volume capacity warning at all, so
  pool-layer alerting becomes the whole alerting story — UPSTREAM.md §1e.
- **Clone from snapshot** via PVE's `clone_image` hook and the array's
  `mkvolume -type thinclone|clone -fromsourcevolume -fromsnapshotid -name`.
  The derived volume gets a conforming PVE volname, so `list_images` surfaces
  it with nothing else to update. New per-storage `fsclonetype`: `thinclone`
  (default — instant and space-efficient, permanently dependent on the source
  snapshot) or `clone` (independent after a background copy at IBM's 2 MB/s
  default). `volume_has_feature` advertises `clone` **only** with a snapname
  and `fssnapshots`; base images and templates remain unsupported. Testable
  with `qm clone --snapshot --full 0` (the `--full 0` is required: a full clone
  never calls the plugin's clone hook), no Kubernetes required.
- **`volume_rollback_is_possible` is now overridden** — it previously
  inherited an unconditional yes. Refuses when `lsvolumesnapshot` reports
  `volume_size_mismatch=yes`, which the array would refuse anyway but with an
  opaque CMMVC. Matters because `allowVolumeExpansion` is on for every
  Kubernetes tier, so a routine PVC resize invalidates rollback for every
  snapshot that volume already had.
- **Snapshot lookups are scoped to one volume.** `_snapshot_id` matched on
  `snapshot_name` alone across an unfiltered system-wide `lsvolumesnapshot`,
  first match wins, feeding `restorefromsnapshot` directly — and Storage
  Virtualize snapshot names are not system-unique (hence `rmsnapshot`'s
  `-parentuid`), on an array shared with the whole VM estate and a VMware
  estate. New `_snapshots_for` scopes by the `<arrayname>.` prefix plus a
  `volume_name` cross-check. Correctness, not performance.
- **`free_image` reaps the volume's own snapshots before `rmvdisk`**, which
  is issued with no `-force` and so is refused rather than forced on a busy
  volume. Scoped to `<arrayname>.*`, never a broad sweep.
- **`_cmd` re-authenticates on 403 as well as 401.** IBM documents token
  expiry as 403, and the lifetime as a maximum session rather than an idle
  timeout, so polling cannot keep a token warm past it.
- `alloc_image` warns at creation time when `fssnapshots` is on and the array
  name leaves no room for a snapshot name. The fix is a shorter `fsprefix`,
  which is fixed at storage creation, so the first snapshot attempt months
  later is a bad time to find out.
- 78 new unit cases in `tests/t_names.pl` (39 → 117) covering both DRP parameter sets,
  the clone parameter builder, the feature-advertisement matrix, snapshot
  scoping (including a name that matches while `volume_name` disagrees), the
  rollback guard, `clone_image`'s error paths, `_pool_is_drp`'s memoisation
  and its deliberate non-caching of failures, `alloc_image`'s one-REST-call
  invariant on the thick path, and the snapshot-headroom warning boundary.
  The `find_free_diskname` stub now records its arguments instead of
  returning a constant — as a constant it made every clone naming assertion
  pass regardless of what `clone_image` actually passed.

## Unreleased — 2026-08-31

- **Resize verifies the host device instead of assuming it.**
  `expandvdisksize` returns before the array commits the new capacity to a
  host `READ CAPACITY`, so a single immediate rescan races it and loses —
  seen live on a 20G→50G production resize where all 8 paths still read the
  old size, the plugin returned success, and QEMU failed the guest-side grow
  with `Cannot grow device files`. Now polls to the requested size and dies
  naming the array size, the device size, every path size and the recovery.
  Background formatting is not the blocker: a manual rescan succeeded while
  the array was still formatting at 44%.
- **The failure message says DO NOT re-run the resize**, because PVE sizes
  from `volume_size_info` (answered from the array, already grown) and the
  GUI only sends increments — so retrying expands the volume a second time,
  permanently. `activate_volume` now re-syncs capacity best-effort, making
  stop/start or migrate the supported recovery; previously no operator
  gesture reached host propagation at all.
- `_dm_node` no longer assumes `/dev/mapper/<wwid>` is a symlink (it is a
  real device node without udev), validates the result, falls back to
  `/sys/block/dm-*/dm/name`, and fails immediately rather than after the
  full settle budget. The dm node is re-resolved each iteration, so a map
  reassembled underneath the loop cannot make it check the wrong device.
- One `lsvdisk` per resize instead of two.
- `$MAPPER_DIR` and `$RESIZE_SETTLE_TIMEOUT` are documented test seams:
  the settle loop now runs against a fixture, and swapping
  `_resize_host_device`'s parameters produces 10 test failures where the
  previous tests stayed green.
- **A rescan that never landed is no longer indistinguishable from an array
  that is slow to publish.** `_rescan_paths` skipped unwritable paths
  silently and discarded `close()` errors, so both failures produced the
  same log line: the paths did not move. It now returns
  `(accepted, total, first_error)` and the failure message reports them
  (`rescans: 4 pass(es), 8 of 8 paths accepted the write`). `$SYSFS_BLOCK`
  joins the test seams, so `_rescan_paths` is exercised against a fixture
  `/sys/block` instead of being stubbed out in every test — it was the only
  sub in the resize path with no coverage at all.
- **The final verdict re-reads the device.** `$size` was captured before the
  settle loop and only refreshed inside the branch that had already
  succeeded, which made `$size = _dev_size($dm) if !defined $size` a no-op.
  multipathd resizes maps on its own once it notices the paths grew, so a
  device could be correct at the deadline and still be reported as failed.
- The failure message and the runbook now name `qm rescan --vmid <id>` for
  the config half of a failed resize: it reads `volume_size_info` and writes
  the VM config, so unlike the GUI dialog it cannot grow the array.
- **Root cause: Perl taint mode.** PVE runs `pvedaemon` under `perl -T`.
  Device names come from `readlink()`/`glob()` and are tainted, and Perl
  allows a tainted path in a read `open()` but refuses it in a write one -
  so every SCSI rescan this plugin ever issued died with `Insecure
  dependency in open`, in an `eval`, unchecked, on all 8 paths. `_dev_size`
  read the same paths fine and a shell `echo 1 > .../rescan` always worked,
  so the array was blamed for a host-side bug. Found by the rescan
  accounting above, on its first failure. It also explains why `qm resize`
  succeeded where the GUI failed: same handler, different process, only one
  tainted. The array commits in ~40s.
- **`_flush_device` had the same defect** writing `.../device/delete`, so
  detach never removed stale SCSI path devices - the exact condition that
  makes the array's next reuse of a LUN number reassemble the old map. It
  also discarded the result; it now untaints, counts and warns, and has
  tests where it previously had none.
- **The test suite runs under `-T`.** This is the structural fix: the suite
  stayed green for the whole life of the bug because it ran untainted while
  production did not. Reinstating either untaint now fails 4 cases for the
  rescan and 2 for the flush.

## Unreleased — 2026-08-26

- **Performance endpoint + Datacenter performance section**:
  `GET /nodes/{node}/flashsystem/{storage}/performance` returns front-end,
  back-end and drive IOPS/bandwidth/latency with five-minute peaks,
  per-canister CPU/cache/latency, configured throttles, and a short
  front-end history for sparklines. `lsnodestats` is the primary source —
  `lssystemstats` is absent from IBM's published REST schema for both 8.7.0
  and 9.1.3, so when it is unreachable the same view is derived from the
  per-node rows (throughput summed, latency and percentages from the worst
  canister, flagged `derived`). Separate endpoint on its own deadline so a
  slow statistics call cannot starve the capacity view. Latency is rendered
  **without a unit**: IBM's 8.7 docs contradict themselves on whether the
  `*_ms` statistics are microseconds or milliseconds, and guessing is a
  1000x error.
- **Ranked consumption** in both `overview` (per pool) and `health` (per
  storage): largest volumes, per-guest rollup, and the volumes in the pool
  this cluster does not manage — computed from the concise `lsvdisk` rows
  those sections already fetch, so no extra array traffic. The GUI joins
  VMIDs to VM names from the resource store, and columns are click-sortable.
- **Per-volume fill in one call**: `lssevdiskcopy` per pool replaces any
  per-volume fan-out, which matters because the array runs one CLI command
  at a time cluster-wide behind a 10 req/s cap. The denominator follows
  `autoexpand` — with it off, 100% of `real_capacity` takes the volume
  offline. Skipped entirely on data reduction pools, where IBM documents
  these fields as blank; the panel says so rather than drawing an empty bar.
- **Cheaper alerts**: `lseventlog` now sends `alert=yes message=no
  monitoring=no fixed=no` rather than fetching the whole unfixed log, with a
  fallback when a firmware rejects the parameters and an arithmetic
  self-check for one that silently ignores them.
- `fast_write_state=corrupt` surfaced beside offline volumes — it needs
  `recovervdisk`, and a size ranking is the wrong place to learn that.
  Attention rows render first and unranked, so a small offline volume in a
  pool of large ones cannot hide below the top ten.
- **Three buckets on the storage tab**: a sibling flashsystem storage sharing
  the pool is counted separately from another tenant. Folding siblings into
  "foreign" made a tier storage attribute its own cluster's Kubernetes PVCs to
  the VMware volumes next door.
- **Theme-safe styling**: one injected stylesheet replaces ~100 inline style
  attributes. The previous inline colours were broken under one theme or the
  other — the datacenter panel assumed dark, the health panel assumed light.
  Text is now `currentColor` plus `opacity` and lines are neutral rgba greys,
  so no theme detection is needed; only four semantic hues are absolute, and
  a test asserts nothing else creeps back. Performance renders as a tile grid
  with sparklines, and peaks print the time alone since they cover the last
  five minutes.
- **GUI render tests** (`tests/t_gui.js`, stubbed ExtJS, skipped without node):
  two defects found in review were renderer-only — data the API computed,
  returned and unit-tested that nothing ever displayed — which no Perl test
  can see.

- **Health & capacity API + "FlashSystem" storage tab** (experimental):
  `PVE::API2::FlashSystem` exposes read-only
  `GET /nodes/{node}/flashsystem/{storage}/health` — system identity, pool
  capacity (physical and effective), volume counts, unfixed events, FC port
  state — registered into the API tree by a verified, marker-wrapped patch
  to `PVE/API2/Nodes.pm` with an APT re-apply hook. The GUI tab mounts via a
  guarded `PVE.panel.Config` override. Sections are eval-guarded and
  time-bounded. Validated on a FlashSystem 5200 running 8.7.0.3 — all
  whitelisted field names matched. Events are split into alerts (non-zero
  error code) and total unfixed: the raw `fixed=no` count is dominated by
  informational chatter (1317 events on the validation array, one of them
  actionable), which would otherwise bury a real pool-space warning.
- **Datacenter overview**: a "FlashSystem" entry in the Datacenter menu
  beside Ceph, served by `GET /nodes/{node}/flashsystem/{storage}/overview` —
  every pool on the array and which storages share each one, with prefix,
  thin/thick and volume counts. De-duplicated server-side: array facts once,
  each pool once, so an 8-storage / 4-pool cluster costs 11 REST calls instead
  of 40 and the panel makes one request per array. `index` gained `address`
  for grouping. Peers are permission-filtered, and failed sections omit their
  fields rather than reporting zeros.
- **Thin provisioning** (`fsthin`): opt-in `mkvdisk -rsize 2% -autoexpand
  -warning 80%` for new volumes, with a matching GUI checkbox. Off by
  default; bare mkvdisk volumes are fully allocated (confirmed via
  `lsvdisk` `capacity` == `real_capacity`), which also bypasses DRP
  thin/dedup. Validated on a standard pool (5200 / 8.7.0.3): 100 GiB
  presented, 5 GiB real, autoexpand growing on write. Data reduction pools
  remain untested for this path.
- First public packaging: de-branded headers, documentation-range IPs in
  test fixtures, dual-home test harness (runs from this repo layout and
  from a vendored `files/` layout unchanged).

## 2026-08-18

- **Retry HTTP 429** from the array's REST throttling (Retry-After honored
  when 1–10s, else 1/2/4s backoff). Found live: pvestatd polling 9 storages
  (8 production + a trial storage) from 12 nodes is ~11 req/s
  steady state; a template import on top drew `mkvdisk failed: 429`.
- **Per-cycle status cache**: `status()` caches `lsmdiskgrp` per
  (array, pool) in pvestatd's cycle cache — storages sharing a pool cost one
  REST call, and a down array is probed once per cycle, not once per storage.
  Failures are cached too.

## 2026-08-17

- **Volume-name grammar widened** to everything PVE and its ecosystem
  actually generate: `disk-N`, `state-*`, `cloudinit`, `fleece-N`, and
  Kubernetes CSI `pvc-<uuid>`. The original enumeration lived in three
  places (alloc, parse, list) and rejected all but the first two — a CSI
  volume would have been uncreatable, unattachable, and invisible.
- **63-char array-name gate** at allocation, with an actionable error
  (prefix + volname budget) instead of an opaque CMMVC failure. The CSI name
  shape (48 chars) makes the budget real.
- **Regex hardening** after adversarial review, with regression tests:
  `\z` anchors (plain `$` accepts a trailing newline), `/a` flag (bare
  `\w`/`\d` match Unicode lookalikes in UTF-8-flagged JSON strings —
  fullwidth digits passed `\d`).

## 2026-08-13

- **Per-storage prefixes** after a live `CMMVC6035E`: array volume names are
  global across pools, so a prefix shared by two storages collides on the
  first move-disk between them. Prefix isolation (list/delete refuse foreign
  objects) is unit-tested, including near-miss prefixes.
- **Physical capacity preferred** in `status()` on data reduction pools:
  effective capacity (physical × assumed compression) invited provisioning a
  shared pool to physical-full, which takes every volume in it offline.
  Observed gap at the time: 44 TiB "free" effective vs 4 TiB physical.

## 2026-08-12 — initial production deployment

- Fleet rollout of the whitepaper-derived plugin with fixes discovered en
  route: `-bytes` (not `-unit`) on list commands (`CMMVC5709E`), snapshot
  remove/restore by `-snapshotid` (`CMMVC5707E`), idempotent host-cluster
  mapping (`CMMVC9066E` tolerated), storeid-keyed password file resolution,
  stale-SCSI cleanup on cross-node reattach (`rescan-scsi-bus.sh`),
  host-side resize propagation, full-clone support, and GUI Add/Edit
  dialogs (pve-manager has no frontend plugin API; the installer appends a
  marker-wrapped snippet and an APT hook re-applies it after upgrades).
- Operational hard requirement documented: host LVM `global_filter`
  (allow-list + reject-all) — without it, guest LVM appears on the host and
  a pathless LUN hangs `vgs`/pvestatd and takes down the node's management
  plane.
