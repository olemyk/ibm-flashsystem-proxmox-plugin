# Provenance and deviations

This plugin started from the sample code in IBM's *Storage Virtualize +
Proxmox VE* whitepaper. Code comments reading `LOCAL PATCH (see UPSTREAM.md)`
point here: each numbered section below documents one deliberate deviation
from the whitepaper sample, why it exists, and what proved it. Dates are
production deployments (firmware 8.7, PVE 9.2, 12-node FC/multipath cluster).

## 1. `fsprefix` — per-storage namespacing of array objects

The sample names array volumes after the PVE volume verbatim
(`vm-124-disk-0`). Array volume names are **global across all pools** on one
system, so any two storages — same cluster or different clusters — sharing an
array collide the moment both hold a VM with the same VMID: identical object
names, mutual visibility in `list_images`, and the ability to delete each
other's disks through an ordinary `free_image`.

The `fsprefix` option (fixed at creation, one prefix per storage, never
shared) namespaces every object as `<prefix>-vm-<vmid>-…`. Two helpers do the
translation at the array boundary; `_volname_from_array` returns undef for
foreign objects, which is what keeps one storage's disks out of another's
listing. PVE-side volume names stay canonical — PVE core validates them in
`find_free_diskname`, migration and backup, so the prefix exists only on the
array. With no prefix configured both helpers are pass-throughs (sample
behavior unchanged).

Proven the hard way on 2026-08-13: a cluster-wide (rather than per-storage)
prefix collided with itself on the first move-disk between two of its own
storages — `CMMVC6035E The action failed as the object already exists`.
Unit tests cover both directions, round-trips, cross-tenant isolation and
near-miss prefixes (`tests/t_prefix.pl`).

## 1b. Physical capacity preferred in `status()`

On data reduction pools `lsmdiskgrp` reports `capacity`/`free_capacity` in
*effective* terms — physical × an assumed compression ratio for the
self-compressing drives. Observed live: a pool showing 44 TiB "free"
effective with 4.1 TiB physically left. A DRP driven to physical-full takes
**every volume in it offline**, and the PVE capacity bar is what people
provision against — so `_pool_usage()` prefers
`physical_capacity`/`physical_free_capacity` when present. Standard pools
carry no `physical_*` fields and keep sample behavior. Fixture-tested with
real `lsmdiskgrp -bytes` output (`tests/t_status.pl`).

## 1c. One volume-name grammar + the 63-character gate

The sample's name validation enumerated `disk-N` and `state-*` in three
separate regexes (`parse_volname`, `alloc_image`, `list_images`) — rejecting
names PVE itself generates (`vm-<id>-cloudinit`, `vm-<id>-fleece-N`) and
Kubernetes CSI's `vm-9999-pvc-<uuid>`. A CSI volume was uncreatable; had it
been created, it would also have been unattachable and invisible.

Replaced with one shared `$VOLNAME_SUFFIX` grammar. The generic arm is
deliberately dot-free so an array snapshot object (`<volname>.<snap>`) can
never round-trip through `list_images` as a phantom volume; only the
`state-` arm keeps dots (sample charset). All three matches are
`\z`-anchored and `/a`-flagged: names arrive from `decode_json` as possibly
UTF-8-flagged strings, where a plain `$` accepts a trailing newline and bare
`\w`/`\d` match Unicode lookalikes (fullwidth digits pass `\d`) — all three
bypasses were demonstrated live in adversarial review and are pinned as
regression tests (`tests/t_names.pl`).

`alloc_image` additionally enforces the Storage Virtualize 63-character
object-name cap with an actionable error (prefix + volname budget) instead of
letting `mkvdisk` fail with an opaque CMMVC. The budget is real: a 14-char
prefix plus the 48-char CSI name shape is exactly 63.

## 1d. 429 retry + per-cycle status cache

The array throttles its REST API. Steady-state load is real — pvestatd polls
every flashsystem storage from every node (~11 req/s with 9 storages ×
12 nodes) — and a provisioning burst on top drew
`mkvdisk failed: 429 Too Many Requests` live on 2026-08-18. `_cmd` retries
429 up to three times (Retry-After honored when 1–10s, else 1/2/4s backoff;
under `status()`'s 10s alarm a sleeping retry is interrupted and reported as
inactive, as intended). `status()` caches the `lsmdiskgrp` result per
(array, pool) in pvestatd's per-cycle cache — storages sharing a pool cost
one REST call per cycle, and a down array is probed once, not once per
storage. Cache-hit and cached-failure paths are unit-tested by seeding the
cache (`tests/t_status.pl`).

## 1e. Optional thin provisioning (`fsthin`)

Bare `mkvdisk` creates FULLY ALLOCATED volumes — confirmed live 2026-08-25
via `lsvdisk` (`capacity` == `real_capacity`) — which reserves the full
provisioned size and bypasses a DRP's thin/dedup layer. `fsthin 1` adds
`-rsize 2% -autoexpand`, plus `-warning 80%` on standard pools only (see
below); chosen over the newer `mkvolume` because rsize-thin is the mechanism
that exists on standard pools too, which matters as IBM moves away from DRPs. Affects NEW volumes only; existing
volumes convert online array-side via `addvdiskcopy -autodelete`.

**Validated 2026-08-26** on a **standard pool** (FlashSystem 5200, firmware
8.7.0.3): `mkvdisk` accepted `rsize` as `'2%'`, `autoexpand` as a JSON
boolean and `warning` as `'80%'`. A 100 GiB volume was created with 5 GiB
real capacity, reported by the array as *Capacity savings: Thin-provisioned*
at an 80% warning threshold, and real capacity grew ahead of the data as it
was written — autoexpand confirmed working.

**On a data reduction pool the parameter set differs by one flag.** Tested
2026-09-07 on four DRP-backed storages on a production cluster: every
allocation failed, and it was reverted the same day. The first reading of
that result — *"thin does not work on a DRP"* — was too broad. The array's
answer was specific:

```
CMMVC9236E The pool specified is a data reduction pool. Volumes or volume
copies which are thin provisioned and created from a data reduction pool
can not use the -warning parameter.
```

That is **parameter validation, not a capacity check**. The `80%` value is
never evaluated; it fails identically on an empty pool. *"We are over 80%"*
is the obvious wrong inference from the error text, and worth stating
explicitly because it is the inference everyone makes first.

Per IBM's `mkvdisk` reference, of the three parameters `fsthin` sends,
exactly one is illegal in a DRP:

| Parameter | In a data reduction pool |
|---|---|
| `-rsize 2%` | Accepted, but the **value is ignored** — only presence or absence decides thin vs thick, so there is no 2% contingency reserve in a DRP. Keep it anyway: dropping it as "meaningless there" would silently produce **thick** volumes with no error at all. |
| `-autoexpand` | Not merely legal but **required** for a thin or compressed volume — `mkvdisk` fails without it. Already sent. |
| `-warning 80%` | Rejected outright (above). Omitted when the pool is a DRP. |

`_mkvdisk_params` therefore takes a fourth argument, `$drp`, and omits
`warning` when it is set. The flag is passed **in** rather than looked up
inside, so the function stays pure and `tests/t_names.pl` covers both
parameter sets without an array; an undefined `$drp` is falsy, so
pre-existing three-argument callers keep standard-pool behaviour. The lookup
is `_pool_is_drp` (one `lsmdiskgrp`), called from `alloc_image` **only when
`fsthin` is set**, so the thick path stays at exactly one REST call as it
always was. It returns 0 on error, matching upstream's standard-pool
default: a transient `lsmdiskgrp` failure then produces a `CMMVC9236E` that
recovers on retry, which is preferable to turning a self-healing failure
into a hard one.

**Consequence worth knowing before enabling this.** A DRP thin volume has
**no per-volume capacity warning at all**, and IBM's stated reason is that
*"the warning level value cannot be set because capacity reporting is
handled at the pool level"*. Combine that with two other DRP facts — that
`lssevdiskcopy` returns blank capacity fields for space-efficient copies
(which is why the consumption view in §4 skips those pools outright), and
that the only documented alternative, `used_capacity_before_reduction`, is
detailed-view only, i.e. one serialised call per volume against an array
that runs one CLI command at a time — and the position after enabling thin
on a DRP is that **you can be told a pool is filling and have no supported
way to learn which volume did it.** Pool-layer alerting is not an adjacent
nicety here; it is the entire alerting story.

Also: `fsthin 0` is **not** a rollback. It affects new volumes only, and
undoing an existing allocation needs the `addvdiskcopy -autodelete`
conversion that ROADMAP item 2 still lists as undocumented.

This is otherwise consistent with the rest of DRP behaviour: the pool
already performs its own thin/dedup/compression, so a fully-allocated vdisk
inside a DRP is not the plain waste it would be on a standard pool.

**Thin means overcommit.** Have array-side physical-free alerting in place
before enabling on any pool shared with other workloads — a pool driven to
physical-full takes every volume in it offline.

## 1f. Clone from snapshot (`clone_image`, `fsclonetype`) — NOT YET VALIDATED

Upstream's sample advertises neither `clone` nor `template`, because it has
no base-image (COW) support. That stays true: what is added here is the
**from-snapshot** form only, which needs no COW because the array does the
population.

`clone_image` issues the one Storage Virtualize command family this plugin
had never touched:

```
mkvolume -type thinclone|clone -pool <pool> \
         -fromsourcevolume <source vdisk> -fromsnapshotid <id> \
         -name <new vdisk> -iogrp <grp>
```

Note it is `mkvolume`, not the `mkvdisk` every other allocation here uses —
`mkvdisk` has no from-snapshot form. Two properties make it fit the existing
design with nothing else changing:

- **`-name` is the caller's choice** (1–63 alphanumeric), so the derived
  volume can be given a conforming PVE volname directly; and
- **`list_images()` enumerates the array**, not any local metadata, so a
  volume created this way appears in `pvesm list` with nothing to update.

There is no `-size` on this form: the snapshot's capacity decides it, and PVE
sizes the result from `volume_size_info`, which this plugin answers from the
array.

The volume-group variant (`mkvolumegroup -type clone -fromsnapshotid`) is the
**wrong** command here: it names only the *group*, not its member volumes, so
the derived vdisks cannot be made to match the grammar `list_images` keys on.

### `fsclonetype` — thinclone or clone

A real trade rather than two speeds of one thing, hence a per-storage option:

| | |
|---|---|
| `thinclone` *(default)* | Instant, near-zero capacity, and **permanently dependent** on the source snapshot — removing that snapshot is deferred into a `dependent_deleting` state rather than freeing space. |
| `clone` | Independent once a background copy completes. IBM's default copy rate is **2 MB/s**, i.e. hours per 100 GiB. |

`thinclone` is the default because these pools are data reduction pools that
thin-provision anyway, and because the alternative writes a full physical
copy into pools already at 78–80% **physical**.

A thinclone is not a dead end: volume-group membership is mutable, so
`chvdisk -volumegroup` → `converttoclone` → `chvdisk -novolumegroup` promotes
one to independent without this plugin having to own volume groups.

### `volume_has_feature`

`clone` is advertised **only** with a `$snapname` *and* `fssnapshots`. The
asymmetry with `copy` (which requires `!$snapname`) is deliberate: a snapshot
is not addressable as a block device — `path()` refuses one and so does
`activate_volume` — so PVE cannot read a snapshot in order to copy it.
Cloning is the array-side route to the same outcome and the only one
available from a snapshot.

### `volume_rollback_is_possible`

Newly overridden; the inherited default is an unconditional yes.
`restorefromsnapshot` is the one operation here that destroys data **without
deleting an object**, so it trips no capacity or object-count monitoring and
leaves nothing to reconcile against.

It now refuses when `lsvolumesnapshot` reports `volume_size_mismatch=yes`.
The array refuses such a restore itself — *"the volumes being restored must
be the same virtual capacity as when the snapshot was added"* — but it
exposes the field, so the refusal can be an actionable message instead of a
CMMVC. This matters more than it looks: `allowVolumeExpansion` is enabled on
every Kubernetes tier, so an ordinary PVC resize silently invalidates
rollback for every snapshot that volume already had.

What it deliberately does **not** check is whether a guest is using the
volume. That guard is unimplementable at this layer: the host-cluster mapping
is created once and kept until `free_image`, so a mapping-based test would
refuse always. PVE's own rollback path stops the VM first and dies if it is
still running, and *that* is the safety contract this plugin relies on —
which is exactly why an automated caller outside PVE's guest lifecycle must
not drive rollback.

### Status: implemented, not validated

**`mkvolume` has never been issued against this array.** Every documented DRP
restriction on it concerns parameters this call does not pass (`-warning`,
`-noautoexpand`, `-grainsize`), but "documented as unrestricted" is not
"observed working" — and §1e above is exactly what that distinction costs.

`tools/probe-clone-from-snapshot.sh` settles it in one pass on scratch
objects, and answers the rest of the open set at the same time: whether the
snapshot form works on a **loose** volume (every IBM example uses a volume
group), whether `rmsnapshot` is refused or deferred while a thinclone
depends on the snapshot, whether a deferred snapshot is still visible to a
plain `lsvolumesnapshot` (if not, "no id found → already gone → idempotent"
silently reports successful deletions that free nothing), whether `rmvdisk`
succeeds on a volume that still has snapshots, and whether
`restorefromsnapshot` changes `vdisk_UID`. Run it on `k8s-archive` /
Pool3_Archive, never on a tight tier and never against a live PVC.

The cheapest end-to-end test needs no Kubernetes at all — but it is a
`mkvolume`, so it needs `fsrestore` too, and that is the point of the flag:

```
pvesm set <storage> --fsrestore 1                   # after the probe passes
qm snapshot <vmid> s1
qm clone <vmid> <newvmid> --snapshot s1 --full 0    # <- clone_image
```

Without `fsrestore`, `volume_has_feature` does not advertise `clone` and
qemu-server refuses before the plugin is reached. Earlier revisions gated only
`csi_volume_from_snapshot`, so this command was the way around the flag.

## 1g. Snapshot lookups are scoped to one volume

`_snapshot_id` previously matched on `snapshot_name` alone across an
**unfiltered, system-wide** `lsvolumesnapshot`, first match wins, and fed the
result straight into `restorefromsnapshot`. On this array that listing also
carries the whole PVE VM estate's snapshots and a VMware estate's, and
Storage Virtualize snapshot names are **not system-unique** — which is
precisely why `rmsnapshot` offers `-parentuid` and `-volumegroup` as
alternatives to a bare name. That makes it a correctness problem, not a
performance wart.

New `_snapshots_for` scopes the listing to one volume using the two facts
that make it safe: our snapshot names are `<arrayname>.<snap>` by
construction, so the source volume is a literal prefix; and
`lsvolumesnapshot` reports `volume_name`, so the association is
cross-checked rather than inferred from the name. A firmware that omits
`volume_name` still works, on the name alone.

`-filtervalue` is deliberately **not** used. It is documented for
`lsvolumesnapshot`, but this plugin has only ever proved it works for
`lsvdisk`, and a filter that is silently ignored looks identical to one that
worked. Scope client-side until `lsvolumesnapshot -filtervalue?` confirms the
accepted attributes on this firmware.

## 1h. `free_image` reaps the volume's own snapshots

`rmvdisk` is issued with **no `-force`**, so a volume the array considers busy
is refused rather than destroyed — the safe direction, but it strands the
delete, because `pvesm free` and the CSI `DeleteVolume` path both arrive here
and neither has anywhere to put the error except a task log. Snapshots are
the busy-ness this plugin creates, so this plugin now cleans them up first.

Scoped to `<arrayname>.*` via `_snapshots_for`, never a broad sweep: the
array's snapshot namespace is flat and system-wide, and anything outside this
volume's own prefix belongs to someone else. Best-effort per snapshot —
`rmvdisk` is the operation that decides whether the delete worked, and its
error is the one worth surfacing.

Which of "refused" or "silently destroyed" the array actually does is
assertion **O** in the probe script, and the two answers need opposite
follow-ups: a refusal argues for this reaping, silent destruction argues for
`reclaimPolicy: Retain` on the Kubernetes tiers.

## 1i. Token expiry: re-auth on 403 as well as 401

`_cmd` re-authenticated only on HTTP 401. IBM documents an expired REST token
as **403** (*"Upon expiration, an error code of 403 occurs that indicates the
loss of authorization"*), and the documented lifetime is a **maximum session**
(default 60 minutes, configurable 10 minutes – 2 hours), **not** an idle
timeout — so polling cannot keep a token warm past it.

This array has been observed returning 401. Both are now handled, which makes
one branch dead code rather than a bug either way; handling only 401 would
turn an hourly token roll into a hard failure for any long-lived consumer.

## 2. GUI Add/Edit dialogs

pve-manager has no frontend plugin API, so a custom storage type never
appears in the Add menu. `gui/flashsystem-gui.js` defines the input panel and
registers the type in `PVE.Utils.storageSchema`; the installer appends it to
`pvemanagerlib.js` inside marker comments and installs an APT Post-Invoke
hook that re-applies it after pve-manager upgrades rewrite that file.
Form fixes learned in production: a required Prefix field (create-only —
`fsprefix` is fixed and a storage created without one can never gain one),
`shared=1` defaulted on create (host-cluster-mapped volumes are inherently
shared; without it migration copies disks), the content selector restricted
to what a raw-block plugin can hold, and the Thin provision checkbox (1e).

After installing or updating the GUI extension, **restart the browser as a
process** — consoles open as popups that inherit the parent page's parsed JS
and show only a spinner until the browser restarts. No error appears
anywhere; this is very expensive to diagnose the first time.

## 3. Health & capacity API + "FlashSystem" storage tab

`api/FlashSystemAPI.pm` (`PVE::API2::FlashSystem`) exposes read-only

```
GET /nodes/{node}/flashsystem                      -> flashsystem storages
GET /nodes/{node}/flashsystem/{storage}/health     -> aggregate
```

— system identity, pool capacity (physical AND effective, same preference as
1b), volume counts (this storage vs the whole pool), unfixed events, FC port
state. Every array read goes through the plugin's `_cmd` (429 retry, token
cache), one bounded, eval-guarded call per section: a slow or unreachable
array yields partial data with per-section errors, never a hung API worker.
The health method is `protected` because resolving the REST credential reads
root-only `/etc/pve/priv/storage/<id>.pw`.

Proxmox has no API plugin registry, so `api/install-flashsystem-api.sh`
appends a marker-wrapped registration block to `PVE/API2/Nodes.pm` (executed
at module load), verifies `PVE::API2::Nodes` still loads — restoring the
original file if not — and installs an APT hook that re-applies the block
after pve-manager upgrades. The same mechanism the GUI extension uses.

The GUI side (in `gui/flashsystem-gui.js`) mounts a "FlashSystem" tab on the
storage view by overriding `PVE.panel.Config.initComponent` — the storage
browser assembles its tab items before Config consumes them, so the override
can add one without re-implementing the browser. Guarded so ExtJS-internals
drift in a future pve-manager degrades to "no tab", never a broken storage
view. Requires `Datastore.Audit` or `Datastore.Allocate` on the storage.

**Validated 2026-08-26** against an **IBM FlashSystem 5200, firmware
8.7.0.3**: all five sections returned content and every whitelisted field
name matched (`lssystem`: name/code_level/product_name/topology;
`lsmdiskgrp -bytes` incl. `physical_*` on a *standard* pool, where physical
equals effective and the preference is a correct no-op; `lsportfc`:
id/fc_io_port_id/status/port_speed/attachment/node_name; `lseventlog`:
sequence_number/error_code/description/object_type/object_name/last_timestamp).

That run also produced a design fix: `fixed=no` returns the array's
**informational** log as well as alerts — 1317 unfixed events, of which
exactly one (`1867 Data reduction pool space warning`) was actionable. The
view therefore splits `alerts` (events carrying a non-zero error code) from
`unfixed_total`, and lists only alerts; the panel shows a green check when
`alerts` is zero. `lseventlog` is a **system** log, so these are array-wide
— every storage on one array reports the same alerts.

### Datacenter overview

A second entry, **Datacenter -> FlashSystem** (beside Ceph), served by
`GET /nodes/{node}/flashsystem/{storage}/overview`: the same array facts plus
every pool in use on that array and which storages share each one, with their
prefix, thin/thick mode and volume counts.

The endpoint de-duplicates **server-side** — array identity, FC ports and
alerts fetched once, and each pool fetched once however many storages use it.
An 8-storage / 4-pool cluster therefore costs 11 REST calls rather than the 40
a per-storage fan-out would, and the panel issues one HTTP request per array.
That matters because this is a human-triggered burst against the same rate
limiter that already produced a live `429` (see the 2026-08-18 entry in
CHANGELOG.md). `index` gained an `address` field so the panel can group
storages by array without extra calls.

Peers are permission-filtered: the overview never reports a storage the caller
cannot audit, and a pool whose storages were all filtered out does not appear.
Sections that fail or run out of budget **omit** their fields rather than
reporting zeros — "0 volumes" beside a real capacity bar would read as an
empty pool instead of a failed query.

The menu entry mounts by overriding `PVE.panel.Config`, not `PVE.dc.Config`:
the latter assigns `me.items = []` as the first statement of its own
initComponent, so an override on it runs too early and the entry is silently
discarded.

**Still VALIDATE on other firmwares**: field names may differ (unknown
fields degrade to omissions, so a mismatch shows an empty section, never an
error).

### Cheaper alerts

`lseventlog` documents dedicated flags for exactly this problem, so the call
now sends `alert=yes message=no monitoring=no fixed=no` instead of
`filtervalue=fixed=no`, cutting the payload from the whole unfixed log to the
alerts alone.

Two failure modes, both handled. A firmware that **rejects** the parameters
makes the call die, and `_fetch_events` falls back to the known-good
`fixed=no` form. A firmware that silently **ignores** them is the dangerous
one — the caller would believe it filtered while holding the full log, and
would suppress the "N events array-wide" total that describes the
informational rows it is actually carrying. `_events_view` detects that by
arithmetic: had the filter applied, every row would be an alert, so a row
count above the alert count means it did not, and the total is reported after
all. The client-side alert/informational split remains either way.

## Host-side resize propagation

`expandvdisksize` returns as soon as the array accepts the request; the new
capacity is not yet visible to a host `READ CAPACITY`. The sample code, and
this plugin until v1.0.11, rescanned once immediately and accepted whatever
came back — which is a race, and it loses. Observed live 2026-08-31: a
20G→50G resize grew the array, every one of the 8 paths still read 20 GiB,
the dm map followed them, `volume_resize` returned success, and QEMU failed
the guest-side grow with `Cannot grow device files` — an error three layers
from the cause, on a resize the array had already completed. A manual rescan
minutes later worked instantly.

**The cause was Perl taint mode, and it was never the array.** PVE runs
`pvedaemon` under `perl -T`. Every device name here comes from `readlink()`
or `glob()` and is therefore tainted, and Perl permits a tainted path in a
*read* `open()` while refusing it in a *write* one:

```
Insecure dependency in open while running with -T switch
```

So every `echo 1 > /sys/block/<sd>/device/rescan` this plugin issued failed -
inside an `eval`, unchecked, on all 8 paths, every time - while `_dev_size`
read those same paths without complaint and the identical write by hand from
a shell always worked, because a login shell is not tainted. The array
publishes new capacity in about 40 seconds; the host had simply never asked.

It also explains why `qm resize` from a shell succeeded where the GUI resize
failed: the same API handler, a different process, and only one of them
tainted.

Anyone porting this sample into a PVE storage plugin should assume taint mode
and **run their tests under `-T`**. This suite did not, and stayed green for
the entire life of the bug. Three plausible explanations - background
formatting, array commit latency, and rescan thrashing - were investigated
and falsified before the instrumentation that counted whether the writes were
accepted at all settled it in one failure.

`_resize_host_device` now checks first, and only if the device is behind does
it rescan, resize the map and re-check, until the requested size is reached or
a bounded budget expires — then it **dies**, naming the array size, the device
size, every path size and the recovery. Failing loudly is the point.

Two things this exposed that are easy to get wrong:

**There is no safe operator retry.** PVE derives its base size from
`volume_size_info`, which this plugin answers from the array — already grown.
The GUI resize dialog only ever sends an increment, so re-entering it expands
the volume a **second** time, permanently, since shrinking is refused. And
qemu-server early-returns when the requested absolute size already matches, so
no dialog or `qm resize` gesture reaches host propagation at all. The failure
message therefore says *do not re-run the resize*, and `activate_volume` now
re-syncs capacity best-effort, which makes starting or migrating the guest the
supported recovery. For the config half - the array grown, the VM config left
behind - `qm rescan --vmid <id>` is the repair: it reads `volume_size_info`
and writes the config, so unlike the GUI dialog it cannot ask the array to
grow anything.

**A rescan that never landed looks exactly like a slow array.** Both produce
the same observable - the paths did not move - and they need opposite
responses. The first version skipped unwritable paths silently and discarded
`close()` errors, so the task log could not tell them apart, and a day of
diagnosis went into a question the instrumentation should have answered.
`_rescan_paths` returns `(accepted, total, first_error)` and the failure
message carries them:

```
rescans: 4 pass(es), 8 of 8 paths accepted the write
```

`8 of 8` means the writes landed and the array is genuinely not publishing;
`0 of 8` with an error means the host never asked - which is what it turned
out to be. Worth building in from the start rather than after the fact.

`_flush_device` carried the identical defect on `.../device/delete`, so the
detach path had never removed stale SCSI path devices either. That is the
condition its own comment warns about: the array's next reuse of those LUN
numbers reassembles the OLD wwid and the new volume never appears. Both write
sites now pass the device name through a validating untaint - no `/`, so the
name cannot escape `$SYSFS_BLOCK`, and `.`/`..` refused.

**Only the node running the guest can be stale.** `deactivate_volume` flushes
this node's map and `activate_volume` rediscovers the LUN at its current size,
so the other nodes in a cluster hold no device to go stale. An earlier
assumption that a fleet-wide rescan was needed after every resize was wrong.

## 4. Performance and per-volume consumption

### `{storage}/performance`

A third read-only endpoint, array-wide rather than storage-scoped, feeding a
Performance section in the Datacenter panel:

```
GET /nodes/{node}/flashsystem/{storage}/performance
```

Front-end (`vdisk_*`), back-end (`mdisk_*`) and drive IOPS, bandwidth and
latency; per-canister CPU, cache and latency; configured throttles; and a
short front-end history for sparklines. `stat_peak` is the peak over the
**last five minutes**, which is the reason this is worth showing at all — a
sample taken as the panel opens misses the spike that made someone open it.

It is a **separate endpoint on its own deadline**, not more sections on
`overview`, and the panel paints it into its own target. Capacity and
performance are read at different moments and fail independently; a slow
statistics call must not be able to delay or starve the pool capacity the
overview exists to show.

**`lsnodestats` is the primary source, not `lssystemstats`.** The
system-wide command is documented in the CLI reference but is absent from
IBM's published REST OpenAPI schema for both 8.7.0 and 9.1.3, while
`/lsnodestats` is present. It very probably works — but "probably" is not a
dependency, so the confirmed call is the one that is depended on and
`lssystemstats` is treated as the optimisation it is. When it fails,
`_derive_system_stats` rebuilds the same view from the per-node rows:
throughput summed across canisters, latency and percentages taken from the
**worst** canister rather than averaged, and the result marked `derived` so
the panel says where the numbers came from instead of passing an
approximation off as the array's own figure.

**Latency values are rendered without a unit.** IBM's 8.7 documentation
contradicts itself on the `*_ms` statistics: the `stat_name` descriptions say
microseconds, the attribute table reads as milliseconds, and the Performance
statistics page states the CLI always displays microseconds. Guessing is a
1000x error in one direction, so the raw value is shown with a note until it
is compared against the array's own GUI. **VALIDATE**: read `vdisk_ms` and
check it against the array's volume latency chart at the same moment — on a
healthy flash array ~0.2–1.0 reads as milliseconds and ~200–1000 as
microseconds.

**Per-volume performance does not exist and is not implied.** The 8.7 CLI
reference contains no `ls*` command with per-volume IOPS or latency, the REST
schemas contain no performance endpoint, and the array's own GUI has no
per-volume chart either — its Performance tab is system- and node-level,
drawing the same statistics shown here. The only route is the
`/dumps/iostats` XML, written once per `startstats` interval (default five
minutes), retained for ~16 files per node, cumulative since node start, split
per canister, and reachable over REST only for the config node. That is a
separate opt-in feature with a timestamp beside every number, not something
to hide inside an at-a-glance panel.

What the panel offers instead is the honest set of suspects: front-end
latency next to back-end latency (IBM's own way to separate "the cache or
host is slow" from "the drives are slow"), per-canister imbalance, and
`lsthrottle` — a configured cap is the one per-object answer the array gives
outright, and on an array shared with VMware the system-wide `offload`
throttle is a realistic culprit.

### Ranked consumption

Both `overview` (per pool) and `health` (per storage) now return a `top`
block: the largest volumes, a per-guest rollup, and the volumes in the pool
that this cluster does not manage.

The ranking is computed from the concise `lsvdisk` rows those sections
**already fetch**, so it adds no array traffic. That constrains what it can
say, and the constraint is worth stating: the concise view carries no
`used_capacity` — real usage lives only in the detailed per-volume view. On
thick volumes that costs nothing, because a fully allocated volume reserves
its whole size and provisioned *is* consumed. Only space-efficient volumes
have a fill distinct from their size.

For those, `_collect_fill` makes **one** `lssevdiskcopy` call per pool rather
than one detailed call per volume. That is not a micro-optimisation: the
array runs one CLI command at a time cluster-wide, behind a 10 req/s cap and
four connections, on a box VMware is also driving, and a live `429` has
already been observed from ordinary pvestatd polling.

The denominator depends on `autoexpand`, and inverting it inverts the
meaning of the bar. With autoexpand **on**, `real_capacity` grows on demand
and the fill is `used / provisioned`. With it **off** there is no growth and
the fill is `used / real_capacity` — reaching 100% there takes the volume
**offline**. This mirrors IBM's own `-warning` semantics on
`mkvdisk`/`addvdiskcopy`, and the panel labels which basis it used.

**Data reduction pools report no per-volume fill at all.** IBM documents
`used_capacity`, `real_capacity` and `free_capacity` as blank for thin and
compressed copies in a DRP. `_collect_fill` therefore checks
`lsmdiskgrp`'s `data_reduction` — from the call the pool section already
makes — and skips the query entirely rather than spending a request to
learn nothing. The panel then says per-volume fill is not reported for a DRP,
instead of drawing an empty bar that would read as "this volume is empty".
Every tier on the cluster this was validated against is a DRP, so this is
the normal path there, not the edge case.

**Volumes this cluster does not manage are counted, and named only with
audit on the whole storage tree.** On a pool shared with VMware or another
cluster the largest consumer is frequently not a PVE volume, and a ranking
that omitted them would point the operator at the wrong tenant. Names are a
step beyond counts, so they need `Datastore.Audit` on `/storage` rather than
on one storage; without it the foreign consumers still appear as a count and
a total.

Attribution prefers a **prefixed** owner. A storage configured without
`fsprefix` translates pass-through and therefore matches any PVE-shaped name
in its pool, including volumes that demonstrably belong to a prefixed
storage sharing it; checking prefixed storages first makes attribution
deterministic whenever the real owner is knowable.

`fast_write_state=corrupt` is surfaced beside offline volumes rather than
left in a size ranking — it needs `recovervdisk`/`repairvdiskcopy` and is a
repair job, not a capacity observation.

**Three buckets, not two, on the storage tab.** `overview` is pool-scoped, so
every flashsystem storage sharing the pool is legitimately "ours". `health` is
storage-scoped, and folding its siblings into the foreign bucket made a
storage blame another tenant for its own cluster's volumes — on a cluster
where a tier storage and its Kubernetes CSI storage share a pool, that is
every PVC. `_top_volumes_view` therefore takes a `self` option: with it set, a
volume owned by another peer becomes a separately labelled `siblings`
aggregate, counted and sized but never named, since the caller's permission is
on this storage and not on its siblings.

**Section timeouts are raised as an object, not a string.** `_fetch_events`
wraps its first call in an `eval` to detect a firmware that rejects the alert
parameters — and that `eval` also catches the `SIG{ALRM}` die from the
section deadline. Read as a rejection, a timeout would send the ~1300-row
fallback with the alarm already spent: nothing armed, LWP's own 30s plus 429
backoff on top, comfortably past the ~30s proxy cap, holding a pvedaemon
worker and starving every later section out of the shared budget. The
deadline therefore dies with a blessed object that callers must re-throw, so
"the array is hung" is distinguishable from "that call was refused" without
matching on another sub's message text. When the first call fails *fast*, the
section alarm is still armed and bounds the fallback with no extra machinery.

**Volumes needing attention render first and unranked.** They are not sorted
by size and must not depend on making the top ten — a small offline volume in
a pool of multi-terabyte ones would never surface. `fast_write_state=corrupt`
matters especially: it arrives *with* `status=online`, so a status column
alone displays it as healthy when it actually needs `recovervdisk` before the
guest will start.

### Styling

Both panels share one injected stylesheet rather than inline style attributes,
and nothing in it hardcodes a light or a dark value. That is a correctness
matter, not taste: PVE ships both themes, and the first cut had each panel
broken under the opposite one — the datacenter panel painted dark greys
(`#888` text, a `#2a2a2a` bar track) while the older health panel painted the
reverse (an `#eee` bar with `#000` text, a white block on the dark theme).

Two rules make it theme-proof without detecting the theme at all: text is
`currentColor` and muted text is `opacity`, both relative to whatever the
theme already chose; lines and fills are `rgba(128,128,128,a)`, a neutral grey
that reads correctly over white and over near-black alike. Only four semantic
hues are absolute, and they are used on icons and bars rather than on body
text, so legibility never depends on them. `tests/t_gui.js` asserts no other
absolute colour reaches the file.

Performance renders as a tile grid — label, large value, peak with its time,
sparkline — because the question it answers is "is anything wrong right now",
which a dense table of numbers does not answer at a glance. Peaks print the
time only: `stat_peak` covers the last five minutes, so the date is always
today.

**Known gap (inherited).** Both sections filter `lsvdisk` server-side on
`mdisk_grp_name`, which does not match **mirrored** volumes — those report
`many`. A mirrored volume is therefore missing from the pool's counts and
ranking. The fix is to fetch unfiltered and scope client-side on
`parent_mdisk_grp_name`, at the cost of a cluster-wide result set; it is not
made here because it changes the pre-existing volume-count behaviour that is
validated in production.
