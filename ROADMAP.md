# Roadmap

Ordered by intent, not commitment. Items marked **(design ready)** have an
agreed approach; the rest are open.

## 1. Health & capacity overview in the PVE GUI — SHIPPED (experimental)

Landed as `api/FlashSystemAPI.pm` + the "FlashSystem" storage tab + the
Datacenter -> FlashSystem panel (`{storage}/overview`), see UPSTREAM.md
section 3. Still open within this item:

- **Field validation across firmwares**: the events/ports/statistics sections
  use whitelist extraction, so unknown field names degrade to empty sections —
  they need confirming per firmware (8.7 confirmed on 8.7.0.3; 9.x unknown).
  Note `iser_io`/`iser_mb` exist at 8.7.0 and are **removed** at 9.1.0, and
  `nvme_*` are absent before 8.4 — treat the statistic list as a set to
  intersect at runtime, never a fixed schema.
- **Not yet validated on hardware**: the datacenter panel as a whole, the
  performance endpoint, and per-volume fill. The storage tab's original
  sections are validated (8.7.0.3); everything added since has unit coverage
  only.
- **Two specific probes** the first hardware run should settle:
  (1) is `lssystemstats` reachable over REST v1 on this array — check
  `https://<array>:7443/rest/explorer/`; the derived fallback ships either
  way. (2) does the `lseventlog` alert filter actually apply, or is it
  silently ignored (the code detects the latter, but confirm which path ran).
  A third — the `*_ms` unit — was answered by IBM on 2026-09-15 from array
  output: **milliseconds**, and the panel labels them. Attested on 9.1.0.2 and
  8.3.1.10; this fleet runs 8.7.x, between them, so it is an inference across
  versions — see `UPSTREAM.md` section 4.
- **Mirrored volumes are missed**: `lsvdisk` is filtered server-side on
  `mdisk_grp_name`, which reports `many` for mirrored volumes, so they fall
  out of pool counts and rankings. The fix is an unfiltered fetch scoped
  client-side on `parent_mdisk_grp_name`; it changes production-validated
  counting behaviour, so it wants its own change and its own validation.
- **Per-volume fill in data reduction pools**: IBM reports the
  `lssevdiskcopy` capacity fields as blank in a DRP, and the only documented
  alternative — `used_capacity_before_reduction` — is detailed-view only,
  i.e. one serialised call per volume. Worth offering as an explicit
  on-demand drill-down for a single volume; never as part of the always-on
  view. This matters wherever every tier is a DRP, which was the case
  on the cluster this was validated against.
- **More sections once validated**: `lsenclosurebattery`, drive summary,
  reduction-savings figures, `lsvdiskprogress` / `lsvdisksyncprogress` (a
  volume actively formatting or resyncing explains latency), `lsmdisk`
  `path_count` vs `max_path_count` (a lost path to one FC switch), and
  `lsarray` `raid_status`.
- **Per-volume performance, if it is ever wanted**: only the
  `/dumps/iostats` XML carries it — `lsdumps` + `download`, plus `cpdumps`
  for the non-config canister. Cumulative counters needing a two-sample
  diff, written once per `startstats` interval (default 5 min), ~80 minutes
  of retention. Ship it opt-in with the sample timestamp beside every number,
  or not at all. Reading only the config node silently under-reports every
  volume driven through both canisters.
- **Complementary path**: a small Prometheus exporter for shops that already
  run Grafana — the PVE panel is at-a-glance state, Grafana is history and
  alerting. Shares the metric list with the API module.

## 2. Thin provisioning refinements

`fsthin` ships as `mkvdisk -rsize 2% -autoexpand`, plus `-warning 80%` on
standard pools only — a data reduction pool rejects `-warning` on a thin
volume (`CMMVC9236E`) and the plugin detects the pool type and omits it. See
UPSTREAM.md §1e for the full parameter table.

Open:

- **Per-storage `rsize` / `warning` knobs.** Still worth having, with a new
  wrinkle: `-rsize`'s *value* is ignored inside a DRP (only its presence
  decides thin vs thick), so a knob would be meaningful on standard pools and
  decorative on DRPs. Say so in the description if it ships.
- **`mkvolume` semantics for allocation.** Now has a concrete data point in
  each direction. Against: `mkvdisk -rsize` needed a per-pool-type parameter
  set, which is an argument for `mkvolume` on DRPs specifically. For: this
  change *does* now issue `mkvolume`, but only for clone-from-snapshot (§8),
  so the calling convention will be proven for one path before anyone
  considers moving allocation onto it. Note IBM moving away from DRPs does
  not retire the question — all four production tiers are DRPs today.
- **A tested online thick→thin conversion** (`addvdiskcopy -autodelete`).
  Newly load-bearing rather than merely nice: `fsthin 0` is not a rollback, it
  affects new volumes only, so this procedure is the *only* undo. Kasten's
  existing PVCs are thick and are the obvious first candidates.
- **Physical-free alerting is the gate on all of it.** A DRP thin volume has
  no per-volume capacity warning at all (IBM handle it at the pool layer),
  and `lssevdiskcopy` reports blank capacity fields for space-efficient
  copies in a DRP, so per-volume fill is unavailable too. Pool-layer alerting
  is the whole story, and it does not exist yet.

## 3. Firmware 9.x capacity fields

Adapt `_pool_usage()` to whatever 9.x reports (see README open question 2).
The function is deliberately tiny and fixture-tested — new firmware means new
fixtures from a real `lsmdiskgrp -bytes`, then the preference logic.

## 4. TLS CA pinning (`fscafile`)

Replace `verify_hostname => 0` with an optional CA bundle path option;
verification on by default when the option is set.

## 5. `rename_volume` support

`chvdisk -name` makes array-side rename trivial; implementing
`rename_volume` enables clean `qm disk move --target-vmid` reassignment
(today: attach-by-volid). Prerequisite for tidy rebuild-OS-keep-data flows.

## 6. Base image / template support (maybe)

`create_base` via array-side rename plus grammar support for `base-*` names
would allow `qm template` on this storage. Deliberately deferred: full clones
work, and COW-less "templates" are just renamed volumes — the value is
convenience, the cost is a wider grammar and more state to reason about.

## 7. Rate-limit tuning from documented numbers

The 429 backoff (1/2/4s, Retry-After honored) is empirical. If IBM documents
the actual limits per firmware (README open question 3), tune to them.

## 8. Hardware validation of clone-from-snapshot — partly closed

`mkvolume` was the one command family this plugin had never issued. That is no
longer true: on 2026-09-14/15 the CSI restore path
(`csi_volume_from_snapshot`) issued `mkvolume -type thinclone` against pmcl01
at firmware 8.7 and the whole chain held — write into a PVC, snapshot, restore
into a new PVC, attach on a **different** Proxmox host, read the bytes back
identical, then delete. Both Kubernetes tiers.

What that run did **not** settle, and what keeps this section open:

- **`clone_image` has still never run.** Same array command, different caller,
  different guard, PVE's own clone plumbing on top (`qm clone --snapshot
  --full 0`).
- **`fsclonetype: clone` has never run.** Only `thinclone` was exercised. The
  independent form starts a background copy at IBM's default 2 MB/s and
  nothing here polls it to completion — see the scratch-VM follow-ups at the
  end of this section.
- **Questions 2, 4 and 5 below are untouched by it** — the run never issued
  `restorefromsnapshot`, never removed a snapshot a thinclone still depended
  on, and never exercised `-filtervalue`.
- **Question 1 is unlikely ever to be answered here, and that is fine.** It
  turns on the pool type behind the tiers that ran, which this repo does not
  record. It is also aimed at a pool type IBM is phasing out — open question 1
  in the README is precisely about what replaces DRP guidance — so treat the
  DRP case as untested rather than as work outstanding. Anyone porting this to
  a data reduction pool should run the probe there; nobody needs to
  retro-document ours.
- **Question 3 is narrower than it looks.** No ordinary delete asks probe
  assertion O — whether `rmvdisk` succeeds while snapshots are still
  *present* — because `free_image` reaps a volume's snapshots before issuing
  it.

`tools/probe-clone-from-snapshot.sh` remains the gate for any array that is
not this one, and answers all of it in one pass on scratch objects. Ordered by
what a wrong answer costs:

1. Does the snapshot form work on a **loose** volume in a **DRP** over REST
   v1? Every IBM example uses a volume group. If not, the plugin has to own
   volume-group lifecycle, which collides with its loose-volume assumptions
   throughout.
2. Does `restorefromsnapshot` change `vdisk_UID`? If it does, in-place
   rollback is unsafe even when performed correctly, and the failure mode is a
   node-wide LVM hang rather than an error. The claim that it does appears
   exactly once in this repository — an unsourced comment in `_rescan_scsi` —
   with no test and no changelog entry, and IBM is silent both ways.
3. Does a bare `rmvdisk` (what `free_image` issues) delete a thinclone?
4. Is `rmsnapshot` refused while a thinclone depends on the snapshot, or
   deferred into `dependent_deleting` — and is a deferred snapshot still
   visible to a plain `lsvolumesnapshot`? If it is invisible, the plugin's
   "no id found → already gone → idempotent" reports successful deletions
   that never free capacity.
5. Does `lsvolumesnapshot` honour `-filtervalue`, or accept and ignore it?

Two follow-ups need a scratch VM rather than only the array: whether
`activate_volume` attaches a clone (it carries a *second* snapshot refusal,
not only the one in `path()`), and whether a `-type clone` reads correctly
before its population completes at IBM's 2 MB/s default.

Not yet done and worth doing regardless: `fsclonetype` has **no GUI field**,
so the Add/Edit dialog cannot set it (see UPSTREAM.md §2 for what that form
exposes). It is settable via `pvesm set` and defaults sensibly, so this is a
convenience gap, not a functional one.
