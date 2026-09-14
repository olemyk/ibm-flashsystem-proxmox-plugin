#!/usr/bin/env perl
#
# Unit tests for the volname grammar and the 63-char array-name gate
# (see files/UPSTREAM.md — both are local deviations).
#
# The grammar decides three things at once: what parse_volname will activate,
# what alloc_image will create, and what list_images will report as ours.
# Too strict and real consumers break (Kubernetes CSI pvc-<uuid> names,
# PVE's own cloudinit and fleece volumes — the original enumeration rejected
# all three). Too loose and an array snapshot object ("<volname>.<snap>")
# could round-trip through list_images as a phantom volume.
#
# The length gate exists because Storage Virtualize caps object names at 63
# and mkvdisk past the cap fails with an opaque CMMVC error. The boundary
# case is real: fsprefix 'pvecl1_Archive' (15 with separator) + the CSI
# name shape vm-9999-pvc-<36-char-uuid> (48) = exactly 63.
#
# Run:  run.sh in this directory

use strict; use warnings;
use FindBin;
# PVE runs its daemons under `perl -T`, so this suite does too. A plugin that
# passes here and then dies on the array with "Insecure dependency in open"
# is exactly what happened on 2026-08-31: every SCSI rescan and every path
# delete this plugin issued had been failing, unchecked, since the first
# release - while the same writes from a shell always worked.
#
# Taint mode rejects tainted @INC entries and a tainted require path, and
# FindBin derives both from $0. Untaint them HERE, in the harness, so the
# module under test still faces taint mode with ITS inputs (readlink, glob)
# tainted - which is the condition that actually matters.
# `our`, not `my`: a runtime `my` declaration re-initialises the variable to
# undef when execution reaches it, discarding what BEGIN put there.
our $BIN;
BEGIN { ($BIN) = $FindBin::Bin =~ m{\A(.*)\z}s; }
use lib "$BIN/stub";
# Dual-home: ../files/ in a vendored layout, ../ in the standalone repo.
my ($MOD) = grep { -f } ("$BIN/../files/FlashSystemPlugin.pm",
                         "$BIN/../FlashSystemPlugin.pm");
require $MOD;
my $P = 'PVE::Storage::Custom::FlashSystemPlugin';
my $A = \&PVE::Storage::Custom::FlashSystemPlugin::_arrayname;

my $uuid = '752b7aad-ac2f-43fe-b0aa-1c89bf01bc88';    # 36 chars, from the real CSI failure

my $fail = 0;
sub ok_case {
    my ($name, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && $got eq $want);
    printf "%-34s %-30s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

# ---- parse_volname: accepted shapes return (vtype, name, vmid) -------------
for my $c (
    ['disk',      'vm-101-disk-0',        101],
    ['state',     'vm-101-state-test',    101],
    ['state dot', 'vm-101-state-a.b',     101],    # PVE names these; dots allowed here only
    ['csi pvc',   "vm-9999-pvc-$uuid",   9999],
    ['cloudinit', 'vm-101-cloudinit',     101],
    ['fleece',    'vm-101-fleece-0',      101],
) {
    my ($label, $vol, $vmid) = @$c;
    my ($vt, $n, $id) = eval { $P->parse_volname($vol) };
    ok_case("parse $label", $@ ? '(died)' : "$vt/$id", "images/$vmid");
    ok_case("parse $label name", $@ ? '(died)' : $n, $vol);
}

# ---- parse_volname: rejected shapes ----------------------------------------
for my $c (
    ['empty suffix',   'vm-101-'],
    ['leading dot',    'vm-101-.bad'],
    ['snapshot shape', 'vm-101-disk-0.test'],    # array snapshot object — never a volume
    ['base image',     'base-101-disk-0'],       # no COW/template support
    ['non-numeric id', 'vm-abc-disk-0'],
    ['space',          'vm-101-disk 0'],
    # The three verified regex attacks (see UPSTREAM.md 1c): names arrive
    # from decode_json, which can hand back UTF-8-flagged strings.
    ['trailing newline',  "vm-101-disk-0\n"],           # $ would accept; \z must not
    ['fullwidth digits',  "vm-\x{FF11}\x{FF10}\x{FF11}-disk-0"],    # Unicode \d without /a
    ['unicode word chars', "vm-101-d\x{E4}t\x{E4}"],    # Unicode \w without /a
) {
    my ($label, $vol) = @$c;
    my $got = eval { $P->parse_volname($vol); 'parsed' } // 'rejected';
    ok_case("reject $label", $got, 'rejected');
}

# ---- alloc_image gates: both die before any REST call ----------------------
my $scfg = { fsprefix => 'pvecl1_Archive', fspool => 'Pool3_Archive' };

# The documented boundary: Archive's 15-char prefix + 48-char CSI name = 63.
ok_case('boundary arithmetic',
    length($A->($scfg, "vm-9999-pvc-$uuid")), 63);

# One past the boundary must fail with the actionable message, not CMMVC.
my $long = 'vm-9999-pvc-' . ('a' x 37);    # arrayname = 64
eval { $P->alloc_image('Archive', $scfg, 9999, 'raw', $long, 1024) };
ok_case('alloc >63 dies', ($@ && $@ =~ /max 63/) ? 'max-63 error' : "(!? $@)", 'max-63 error');
ok_case('alloc >63 names the fix', ($@ && $@ =~ /shorter fsprefix/) ? 'yes' : 'no', 'yes');

# Illegal shape still dies first, with the original error.
eval { $P->alloc_image('Archive', $scfg, 9999, 'raw', 'vm-9999-disk 0', 1024) };
ok_case('alloc illegal name dies', ($@ && $@ =~ /illegal name/) ? 'illegal-name error' : "(!? $@)",
    'illegal-name error');

# VMID in the name must match the owner PVE passed.
eval { $P->alloc_image('Archive', $scfg, 101, 'raw', "vm-9999-pvc-$uuid", 1024) };
ok_case('alloc vmid mismatch dies', ($@ && $@ =~ /illegal name/) ? 'illegal-name error' : "(!? $@)",
    'illegal-name error');

# Non-raw formats are still refused.
eval { $P->alloc_image('Archive', $scfg, 101, 'qcow2', 'vm-101-disk-0', 1024) };
ok_case('alloc qcow2 dies', ($@ && $@ =~ /only raw/) ? 'raw-only error' : "(!? $@)", 'raw-only error');

# ---- _mkvdisk_params: the thin-provisioning shape (fsthin) -----------------
# Bare mkvdisk = fully allocated (confirmed live 2026-08-25). fsthin adds
# rsize/autoexpand/warning; nothing else about the call may change.
use JSON ();
my $MK = \&PVE::Storage::Custom::FlashSystemPlugin::_mkvdisk_params;
my $thick = $MK->({ fspool => 'P' }, 'x-vm-1-disk-0', 1048576);
ok_case('thick: no rsize',        (exists $thick->{rsize} ? 'rsize' : 'none'), 'none');
ok_case('thick: no autoexpand',   (exists $thick->{autoexpand} ? 'yes' : 'none'), 'none');
ok_case('thick: no warning',      (exists $thick->{warning} ? 'yes' : 'none'), 'none');
ok_case('thick: size in bytes',   $thick->{size}, 1048576);
ok_case('thick: iogrp default',   $thick->{iogrp}, 'io_grp0');
my $thin = $MK->({ fspool => 'P', fsthin => 1, fsiogrp => 'io_grp1' }, 'x-vm-1-disk-0', 1048576);
ok_case('thin: rsize 2%',         $thin->{rsize}, '2%');
ok_case('thin: warning 80%',      $thin->{warning}, '80%');
# Must be a JSON boolean, not a plain 1: the array's valueless CLI flags are
# encoded as JSON true (the -bytes precedent) — "autoexpand":1 is a different
# request body than "autoexpand":true.
ok_case('thin: autoexpand JSON bool',
    (JSON::is_bool($thin->{autoexpand}) && $thin->{autoexpand}) ? 'true' : 'not-a-json-bool',
    'true');
ok_case('thin: size unchanged',   $thin->{size}, 1048576);
ok_case('thin: pool unchanged',   $thin->{mdiskgrp}, 'P');
ok_case('thin: iogrp override',   $thin->{iogrp}, 'io_grp1');
ok_case('thin: name unchanged',   $thin->{name}, 'x-vm-1-disk-0');

# ---- _mkvdisk_params: the data-reduction-pool parameter set ----------------
# A DRP rejects -warning on a thin volume (CMMVC9236E, live 2026-09-07 on
# Pool1_Silver) — parameter validation, not a capacity check, so it fails on
# an empty pool too. Of the three parameters fsthin adds, exactly one is
# illegal there.
my $thin_drp = $MK->({ fspool => 'P', fsthin => 1 }, 'x-vm-1-disk-0', 1048576, 1);
# Assert ABSENCE with exists, not falsiness: a warning key present-but-empty
# is still a rejected request body.
ok_case('drp thin: warning absent',
    (exists $thin_drp->{warning} ? 'present' : 'absent'), 'absent');
# rsize must SURVIVE. Its value is ignored inside a DRP (only presence
# decides thin vs thick), so dropping it as "meaningless there" would
# silently produce THICK volumes with no error anywhere — the exact failure
# this case exists to prevent.
ok_case('drp thin: rsize still present',   $thin_drp->{rsize}, '2%');
# autoexpand is not merely legal in a DRP, it is REQUIRED for a thin volume.
ok_case('drp thin: autoexpand JSON bool',
    (JSON::is_bool($thin_drp->{autoexpand}) && $thin_drp->{autoexpand}) ? 'true' : 'not-a-json-bool',
    'true');
ok_case('drp thin: size unchanged',        $thin_drp->{size}, 1048576);

# A DRP must not alter the thick path at all.
my $thick_drp = $MK->({ fspool => 'P' }, 'x-vm-1-disk-0', 1048576, 1);
ok_case('drp thick: no rsize',      (exists $thick_drp->{rsize} ? 'yes' : 'none'), 'none');
ok_case('drp thick: no autoexpand', (exists $thick_drp->{autoexpand} ? 'yes' : 'none'), 'none');
ok_case('drp thick: no warning',    (exists $thick_drp->{warning} ? 'yes' : 'none'), 'none');

# Pre-existing three-argument callers must keep standard-pool behaviour:
# undef $drp is falsy, so this holds with no shim. Pinned so it stays true
# rather than assumed.
my $thin_legacy = $MK->({ fspool => 'P', fsthin => 1 }, 'x-vm-1-disk-0', 1048576);
ok_case('legacy 3-arg call = standard pool', $thin_legacy->{warning}, '80%');

# ---- _clone_type / _mkvolume_clone_params ---------------------------------
# The from-snapshot restore primitive. mkvolume, not mkvdisk, and there is
# deliberately no -size: the snapshot's capacity decides it.
my $CT = \&PVE::Storage::Custom::FlashSystemPlugin::_clone_type;
my $CP = \&PVE::Storage::Custom::FlashSystemPlugin::_mkvolume_clone_params;

ok_case('clonetype: defaults to thinclone', $CT->({}), 'thinclone');
ok_case('clonetype: honours clone',         $CT->({ fsclonetype => 'clone' }), 'clone');
# Anything else must die here rather than reach the array as a bad -type.
eval { $CT->({ fsclonetype => 'linked' }) };
ok_case('clonetype: rejects garbage',
    ($@ && $@ =~ /invalid fsclonetype/) ? 'dies' : "(!? $@)", 'dies');

my $cp = $CP->({ fspool => 'Pool1_Silver' },
    "k8ss-vm-9999-pvc-$uuid", 'k8ss-vm-9999-pvc-restored', 42);
ok_case('clone: type default',      $cp->{type},             'thinclone');
ok_case('clone: pool',              $cp->{pool},             'Pool1_Silver');
ok_case('clone: fromsourcevolume',  $cp->{fromsourcevolume}, "k8ss-vm-9999-pvc-$uuid");
ok_case('clone: fromsnapshotid',    $cp->{fromsnapshotid},   42);
ok_case('clone: names the NEW vol', $cp->{name},             'k8ss-vm-9999-pvc-restored');
# No -size on the snapshot form: the snapshot's capacity decides it, and
# passing one is a different (rejected) invocation of mkvolume.
ok_case('clone: no size parameter', (exists $cp->{size} ? 'present' : 'absent'), 'absent');
# And no -iogrp: IBM's default is the SOURCE volume's I/O group, and a
# thinclone is constrained to it, so sending fsiogrp could conflict.
ok_case('clone: no iogrp parameter', (exists $cp->{iogrp} ? 'present' : 'absent'), 'absent');
my $cp2 = $CP->({ fspool => 'P', fsclonetype => 'clone', fsiogrp => 'io_grp1' }, 'src', 'dst', 7);
ok_case('clone: type override',     $cp2->{type},  'clone');
ok_case('clone: fsiogrp ignored',   (exists $cp2->{iogrp} ? 'present' : 'absent'), 'absent');

# ---- volume_has_feature: clone is snapshot-only ---------------------------
# The whole point of the advertisement: PVE must offer clone-from-snapshot
# and must NOT offer a base-image linked clone, because there is no COW
# support here.
my $fs_on  = { fssnapshots => 1, fsrestore => 1 };
my $fs_off = {};
# clone-from-snapshot is mkvolume, so it needs fsrestore as well as
# fssnapshots. Advertising it with the restore gate closed made PVE offer
# `qm clone --full 0`, which then issued the never-validated mkvolume -- the
# exact command fsrestore exists to hold back.
my $fs_norestore = { fssnapshots => 1 };
ok_case('feature clone+snap',       $P->volume_has_feature($fs_on,  'clone', 'S', 'vm-1-disk-0', 's1'), 1);
ok_case('feature clone, no snap',   $P->volume_has_feature($fs_on,  'clone', 'S', 'vm-1-disk-0', undef), undef);
ok_case('feature clone, snaps off', $P->volume_has_feature($fs_off, 'clone', 'S', 'vm-1-disk-0', 's1'), undef);
ok_case('feature clone, restore off',
    $P->volume_has_feature($fs_norestore, 'clone', 'S', 'vm-1-disk-0', 's1'), undef);
ok_case('feature snapshot, restore off',
    $P->volume_has_feature($fs_norestore, 'snapshot', 'S', 'vm-1-disk-0', undef), 1);
ok_case('feature template refused', $P->volume_has_feature($fs_on,  'template', 'S', 'vm-1-disk-0', undef), undef);
# Unchanged behaviour, pinned so the new arm cannot regress it.
ok_case('feature snapshot',         $P->volume_has_feature($fs_on,  'snapshot', 'S', 'vm-1-disk-0', undef), 1);
ok_case('feature copy',             $P->volume_has_feature($fs_on,  'copy', 'S', 'vm-1-disk-0', undef), 1);
ok_case('feature copy from snap',   $P->volume_has_feature($fs_on,  'copy', 'S', 'vm-1-disk-0', 's1'), undef);

# ---- _snapshots_for: scoping a system-wide listing to ONE volume ----------
# lsvolumesnapshot is unfiltered and system-wide, so its rows carry the whole
# VM estate's snapshots and anything else sharing the array. Two facts do the
# scoping and both are tested: the "<arrayname>." name prefix, and a
# volume_name cross-check for firmwares that report it. Snapshot names are
# NOT system-unique on Storage Virtualize — which is why rmsnapshot offers
# -parentuid — so a name match alone must never be treated as proof.
{
    my $SF = \&PVE::Storage::Custom::FlashSystemPlugin::_snapshots_for;
    my $SI = \&PVE::Storage::Custom::FlashSystemPlugin::_snapshot_id;
    my $sc = { fsprefix => 'k8ss', fspool => 'P' };
    my $rows = [
        { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1', volume_name => 'k8ss-vm-9999-pvc-a' },
        { snapshot_id => 2, snapshot_name => 'k8ss-vm-9999-pvc-a.s2', volume_name => 'k8ss-vm-9999-pvc-a' },
        # Another volume on the same storage.
        { snapshot_id => 3, snapshot_name => 'k8ss-vm-9999-pvc-b.s1', volume_name => 'k8ss-vm-9999-pvc-b' },
        # Another storage's prefix on the same array.
        { snapshot_id => 4, snapshot_name => 'k8sg-vm-9999-pvc-a.s1', volume_name => 'k8sg-vm-9999-pvc-a' },
        # The human tier's VM estate.
        { snapshot_id => 5, snapshot_name => 'pmcl01_Gold-vm-124-disk-0.wk3', volume_name => 'pmcl01_Gold-vm-124-disk-0' },
        # Name looks like ours, volume_name says otherwise: the exact
        # collision the cross-check exists for. Must be rejected.
        { snapshot_id => 6, snapshot_name => 'k8ss-vm-9999-pvc-a.s3', volume_name => 'something-else' },
        # A name that starts with ours but is a different volume (no dot
        # boundary) — the reason the prefix test includes the '.'.
        { snapshot_id => 7, snapshot_name => 'k8ss-vm-9999-pvc-aa.s1', volume_name => 'k8ss-vm-9999-pvc-aa' },
    ];
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return $rows };
    my $got = $SF->($sc, 'vm-9999-pvc-a', 'k8s-silver');
    ok_case('snapshots_for: count', scalar(@$got), 2);
    ok_case('snapshots_for: ids',   join(',', map { $_->{id} } @$got), '1,2');

    ok_case('snapshot_id: found',   $SI->($sc, 'vm-9999-pvc-a', 's2', 'k8s-silver'), 2);
    ok_case('snapshot_id: absent',  $SI->($sc, 'vm-9999-pvc-a', 'nope', 'k8s-silver'), undef);
    # s3's name matches but its volume_name does not. Resolving it would feed
    # the wrong snapshotid straight into restorefromsnapshot.
    ok_case('snapshot_id: wrong-volume rejected',
        $SI->($sc, 'vm-9999-pvc-a', 's3', 'k8s-silver'), undef);

    # A firmware that omits volume_name must still work, on the name alone.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { snapshot_id => 9, snapshot_name => 'k8ss-vm-9999-pvc-a.s1' } ];
    };
    ok_case('snapshots_for: volume_name absent',
        $SI->($sc, 'vm-9999-pvc-a', 's1', 'k8s-silver'), 9);
}

# ---- volume_rollback_is_possible: refuse a resized volume -----------------
# The array refuses the restore itself, but it reports volume_size_mismatch
# on the snapshot, so the refusal can be actionable rather than an opaque
# CMMVC. Not hypothetical: allowVolumeExpansion is on for every Kubernetes
# tier here, so an ordinary PVC resize invalidates rollback for every
# snapshot that volume already had.
{
    my $sc = { fsprefix => 'k8ss', fssnapshots => 1 };
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   state => 'active', volume_size_mismatch => 'yes' } ];
    };
    my $bl = [];
    eval { $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1', $bl) };
    ok_case('rollback: resized refused',
        ($@ && $@ =~ /resized since the snapshot/) ? 'dies' : "(!? $@)", 'dies');
    # PVE's replication pre-pass inspects $blockers; an empty one makes it
    # discard the error and schedule a blanket snapshot removal instead.
    ok_case('rollback: blocker recorded', join(',', @$bl), 's1');

    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active',
                   volume_size_mismatch => 'no' } ];
    };
    ok_case('rollback: same capacity allowed',
        $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1'), 1);

    # A foreign row sharing the name must not be able to satisfy the guard on
    # behalf of ours. Foreign row FIRST, and it is the permissive one.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { snapshot_id => 8, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'something-else', state => 'active',
                   volume_size_mismatch => 'no' },
                 { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active',
                   volume_size_mismatch => 'yes' } ];
    };
    eval { $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1') };
    ok_case('rollback: foreign row cannot vouch',
        ($@ && $@ =~ /resized since the snapshot/) ? 'dies' : "(!? $@)", 'dies');

    # A guard that cannot READ the array must refuse, not permit. Swallowing
    # the error into an empty list would fall through to a confident yes.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { die "flashsystem: 429\n" };
    eval { $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1') };
    ok_case('rollback: unreadable array refuses',
        ($@ && $@ =~ /cannot verify rollback safety/) ? 'dies' : "(!? $@)", 'dies');

    # An absent snapshot is a blocker, not a silent yes.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return [] };
    eval { $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1') };
    ok_case('rollback: absent snapshot dies',
        ($@ && $@ =~ /not found/) ? 'dies' : "(!? $@)", 'dies');

    # volume_size_mismatch missing entirely = unknown. Refuse rather than
    # assume 'no', because the field may be detailed-view only.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ];
    };
    eval { $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1') };
    ok_case('rollback: unknown mismatch refuses',
        ($@ && $@ =~ /cannot determine whether/) ? 'dies' : "(!? $@)", 'dies');

    eval { $P->volume_rollback_is_possible({}, 'k8s-silver', 'vm-9999-pvc-a', 's1') };
    ok_case('rollback: snaps off dies',
        ($@ && $@ =~ /snapshots disabled/) ? 'dies' : "(!? $@)", 'dies');

    # restorefromsnapshot destroys the volume's contents WITHOUT deleting any
    # object, so it trips no capacity or object-count monitoring. It must not
    # be allowed against a snapshot the array is not maintaining an image for.
    # 'ready' is the trap: IBM's lsvolumesnapshot documents it as "the snapshot
    # is NOT triggered", i.e. the opposite of usable.
    for my $st (qw(failed Ready ready deleting copying wat), '', undef) {
        my $label = defined $st ? (length $st ? $st : '(empty)') : '(absent)';
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            return [ { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                       volume_name => 'k8ss-vm-9999-pvc-a',
                       (defined $st ? (state => $st) : ()),
                       volume_size_mismatch => 'no' } ];
        };
        my $b = [];
        eval { $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1', $b) };
        ok_case("rollback: state '$label' refused",
            ($@ && $@ =~ /no point-in-time image/) ? 'dies' : "(!? $@)", 'dies');
        ok_case("rollback: state '$label' blocks", join(',', @$b), 's1');
    }
    # ...and 'active', the one state that IS a maintained image, still passes.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { snapshot_id => 1, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'Active',
                   volume_size_mismatch => 'no' } ];
    };
    ok_case('rollback: Active (any case) allowed',
        $P->volume_rollback_is_possible($sc, 'k8s-silver', 'vm-9999-pvc-a', 's1'), 1);
}

# ---- free_image: delete first, reap only if the array refuses -------------
# Reaping first means an irreversible rmsnapshot per snapshot and then an
# rmvdisk that can STILL fail, leaving the caller owning a volume whose every
# recovery point was destroyed by a command that did not delete it.
{
    my $sc = { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1,
               fsreapsnapshots => 1 };
    no warnings 'redefine';
    # Nothing in this file writes to the host, so _flush_device/_wwid are the
    # only other array touches; stub the lot and record the command order.
    local *PVE::Storage::Custom::FlashSystemPlugin::_wwid = sub { return undef };
    local *PVE::Storage::Custom::FlashSystemPlugin::_unmap_volume = sub { return 1 };

    # Happy path: rmvdisk succeeds, so nothing else is called at all.
    my @seq;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seq, $command;
        return {};
    };
    $P->free_image('k8s-silver', $sc, 'vm-9999-pvc-a', 0, 'raw');
    ok_case('free: one call on the happy path', join(',', @seq), 'rmvdisk');

    # Refused: reap, then retry once.
    @seq = ();
    my $rmvdisk_calls = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seq, $command;
        if ($command eq 'rmvdisk') {
            $rmvdisk_calls++;
            die "flashsystem: CMMVC8957E\n" if $rmvdisk_calls == 1;
            return {};
        }
        return [ { snapshot_id => 5, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a' } ] if $command eq 'lsvolumesnapshot';
        return {};
    };
    $P->free_image('k8s-silver', $sc, 'vm-9999-pvc-a', 0, 'raw');
    ok_case('free: reaps only after refusal',
        join(',', @seq), 'rmvdisk,lsvolumesnapshot,rmsnapshot,rmvdisk');

    # Refused with NOTHING to reap: the original array error must survive,
    # not be replaced by a confusing retry error.
    @seq = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seq, $command;
        die "flashsystem: CMMVC8478E original\n" if $command eq 'rmvdisk';
        return [];
    };
    eval { $P->free_image('k8s-silver', $sc, 'vm-9999-pvc-a', 0, 'raw') };
    ok_case('free: original error survives',
        ($@ && $@ =~ /CMMVC8478E original/) ? 'original' : "(!? $@)", 'original');
    ok_case('free: no rmsnapshot with nothing to reap',
        (grep { $_ eq 'rmsnapshot' } @seq) ? 'reaped' : 'none', 'none');

    # Strict attribution on the destructive path: a row the array cannot tie
    # to this volume (no volume_name) must NOT be fed to rmsnapshot.
    @seq = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seq, $command;
        die "flashsystem: CMMVC8957E\n" if $command eq 'rmvdisk';
        return [ { snapshot_id => 6, snapshot_name => 'k8ss-vm-9999-pvc-a.s1' } ]
            if $command eq 'lsvolumesnapshot';
        return {};
    };
    {
        local $SIG{__WARN__} = sub { };    # the skip warns on purpose
        eval { $P->free_image('k8s-silver', $sc, 'vm-9999-pvc-a', 0, 'raw') };
    }
    ok_case('free: unattributable snapshot not deleted',
        (grep { $_ eq 'rmsnapshot' } @seq) ? 'deleted' : 'skipped', 'skipped');

    # Reaping must not be gated on fssnapshots: objects created while it was
    # on still have to be cleanable after it is turned off.
    @seq = ();
    $rmvdisk_calls = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seq, $command;
        if ($command eq 'rmvdisk') {
            $rmvdisk_calls++;
            die "flashsystem: CMMVC8957E\n" if $rmvdisk_calls == 1;
            return {};
        }
        return [ { snapshot_id => 7, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a' } ] if $command eq 'lsvolumesnapshot';
        return {};
    };
    $P->free_image('k8s-silver', { fsprefix => 'k8ss', fspool => 'P',
        fsreapsnapshots => 1 }, 'vm-9999-pvc-a', 0, 'raw');
    ok_case('free: reaps with fssnapshots off',
        (grep { $_ eq 'rmsnapshot' } @seq) ? 'reaped' : 'none', 'reaped');

    # DEFAULT: no reap. A delete-the-volume request must not silently destroy
    # recovery points - CSI DeleteVolume from `kubectl delete pvc` lands here,
    # and a propagated refusal is retried and visible in PVC events whereas a
    # silent reap is neither.
    @seq = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seq, $command;
        die "flashsystem: CMMVC8957E\n" if $command eq 'rmvdisk';
        return [ { snapshot_id => 5, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                   volume_name => 'k8ss-vm-9999-pvc-a' } ] if $command eq 'lsvolumesnapshot';
        return {};
    };
    eval { $P->free_image('k8s-silver', { fsprefix => 'k8ss', fspool => 'P',
        fssnapshots => 1 }, 'vm-9999-pvc-a', 0, 'raw') };
    ok_case('free: default does NOT reap',
        (grep { $_ eq 'rmsnapshot' } @seq) ? 'reaped' : 'none', 'none');
    ok_case('free: default surfaces the refusal',
        ($@ && $@ =~ /CMMVC8957E/) ? 'propagated' : "(!? $@)", 'propagated');
}

# ---- _snapshots_for: response-shape normalisation -------------------------
# _one() exists in this file because some firmwares answer a single-object
# query with a bare hash instead of a one-element array. The snapshot scan
# must not assume an arrayref either.
{
    my $SF = \&PVE::Storage::Custom::FlashSystemPlugin::_snapshots_for;
    my $sc = { fsprefix => 'k8ss' };
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return { snapshot_id => 3, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                 volume_name => 'k8ss-vm-9999-pvc-a' };
    };
    my $got = $SF->($sc, 'vm-9999-pvc-a', 'S');
    ok_case('snapshots_for: bare hashref normalised', scalar(@$got), 1);

    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return undef };
    ok_case('snapshots_for: undef is empty',
        scalar(@{ $SF->($sc, 'vm-9999-pvc-a', 'S') }), 0);

    # A row that is not a hashref must be skipped, not crash the scan.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ 'junk', { snapshot_id => 4, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                           volume_name => 'k8ss-vm-9999-pvc-a' } ];
    };
    ok_case('snapshots_for: junk row skipped',
        scalar(@{ $SF->($sc, 'vm-9999-pvc-a', 'S') }), 1);
}

# ---- clone_image ----------------------------------------------------------
# The new volume must be a fresh PVE-conforming volname, never a derivative
# of the snapshot object's name: list_images' generic arm is dot-free by
# design, so "<vol>.<snap>" can never round-trip as a volume.
{
    my $sc = { fsprefix => 'k8ss', fspool => 'Pool1_Silver', fssnapshots => 1, fsrestore => 1 };
    my @sent;
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params, %opt) = @_;
        return [ { snapshot_id => 77, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        push @sent, [ $command, $params ];
        return { id => '31', message => 'Volume, id [31], successfully created' };
    };
    # Clone into a DIFFERENT vmid than the source, so the naming assertions
    # cannot pass by coincidence: the stub derives its answer from $vmid.
    @PVE::Storage::Plugin::FIND_FREE_CALLS = ();
    my $new = $P->clone_image($sc, 'k8s-silver', 'vm-9999-pvc-a', 4242, 's1');
    ok_case('clone_image: new volname',   $new, 'vm-4242-disk-0');
    ok_case('clone_image: uses mkvolume', $sent[0][0], 'mkvolume');
    ok_case('clone_image: resolved id',   $sent[0][1]{fromsnapshotid}, 77);
    ok_case('clone_image: source prefixed', $sent[0][1]{fromsourcevolume}, 'k8ss-vm-9999-pvc-a');
    ok_case('clone_image: target prefixed', $sent[0][1]{name}, 'k8ss-vm-4242-disk-0');
    # A dot in the new name would make the volume invisible to list_images.
    ok_case('clone_image: target dot-free',
        ($sent[0][1]{name} =~ /\./ ? 'has-dot' : 'clean'), 'clean');
    # find_free_diskname must be asked for the TARGET vmid and a raw volume.
    my $ff = $PVE::Storage::Plugin::FIND_FREE_CALLS[0] // {};
    ok_case('clone_image: asks for target vmid', $ff->{vmid}, 4242);
    ok_case('clone_image: asks for raw',         $ff->{fmt},  'raw');
    ok_case('clone_image: passes storeid',       $ff->{storeid}, 'k8s-silver');

    # An absent snapshot must not silently clone the live volume.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return [] };
    eval { $P->clone_image($sc, 'k8s-silver', 'vm-9999-pvc-a', 9999, 'missing') };
    ok_case('clone_image: unknown snap dies',
        ($@ && $@ =~ /not found/) ? 'dies' : "(!? $@)", 'dies');

    # No snapshot at all = a base-image linked clone, which is unsupported.
    eval { $P->clone_image($sc, 'k8s-silver', 'vm-9999-pvc-a', 9999, undef) };
    ok_case('clone_image: no snap dies',
        ($@ && $@ =~ /requires a snapshot/) ? 'dies' : "(!? $@)", 'dies');

    eval { $P->clone_image({ fsprefix => 'k8ss' }, 'k8s-silver', 'vm-9999-pvc-a', 9999, 's1') };
    ok_case('clone_image: snaps off dies',
        ($@ && $@ =~ /snapshots disabled/) ? 'dies' : "(!? $@)", 'dies');

    # THE SECOND mkvolume CALL SITE. Gating only csi_volume_from_snapshot left
    # `qm clone <vmid> <new> --snapshot <s> --full 0` issuing the unvalidated
    # mkvolume with fsrestore at its default -- on a fleet where fssnapshots
    # has been on since 2026-08-12 -- while properties(), the CHANGELOG and
    # csi/README all promise that flag is what prevents exactly this.
    eval { $P->clone_image({ fsprefix => 'k8ss', fspool => 'Pool1_Silver', fssnapshots => 1 },
        'k8s-silver', 'vm-9999-pvc-a', 4242, 's1') };
    ok_case('clone_image: fsrestore gate',
        ($@ && $@ =~ /restore-from-snapshot is disabled/) ? 'dies' : "(!? $@)", 'dies');
    ok_case('clone_image: gate names the probe',
        ($@ && $@ =~ /probe-clone-from-snapshot/) ? 'yes' : 'no', 'yes');
    # ...and it must refuse BEFORE issuing anything to the array.
    my @sent_gated;
    {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            push @sent_gated, $_[1]; return [];
        };
        eval { $P->clone_image({ fsprefix => 'k8ss', fspool => 'Pool1_Silver', fssnapshots => 1 },
            'k8s-silver', 'vm-9999-pvc-a', 4242, 's1') };
    }
    ok_case('clone_image: gate sends nothing', scalar(@sent_gated), 0);

    # mkvolume -fromsnapshotid against a snapshot with no maintained image.
    # _snapshot_id discarded `state`, so this path was issuing it blind while
    # the plugin had already computed the snapshot to be unusable.
    for my $st (qw(failed Ready deleting copying), undef) {
        my $label = defined $st ? $st : '(absent)';
        my @sent_st;
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my (undef, $command, undef, $params) = @_;
            return [ { snapshot_id => 77, snapshot_name => 'k8ss-vm-9999-pvc-a.s1',
                       volume_name => 'k8ss-vm-9999-pvc-a',
                       (defined $st ? (state => $st) : ()) } ]
                if $command eq 'lsvolumesnapshot';
            push @sent_st, $command;
            return { id => '31' };
        };
        eval { $P->clone_image($sc, 'k8s-silver', 'vm-9999-pvc-a', 4242, 's1') };
        ok_case("clone_image: state '$label' refused",
            ($@ && $@ =~ /not maintaining a point-in-time image/) ? 'dies' : "(!? $@)", 'dies');
        ok_case("clone_image: state '$label' sends no mkvolume",
            (grep { $_ eq 'mkvolume' } @sent_st) ? 'sent' : 'none', 'none');
    }
}

# ---- _map_volume: verify the mapping, never parse why the array said no ----
# The old swallow list treated HOST-level "already mapped" codes (CMMVC6071E,
# CMMVC5879E, CMMVC6070E) as a successful host-CLUSTER map, on a guess. That
# turns a refusal into a success: the LUN reaches one host and no other, and
# every other node then fails to attach with a message implying a mapping
# happened. 2026-09-14: 8 paths on nosvgsmpm003, zero on the other eleven.
#
# The read-back uses lsvdiskhostmap, where a host-CLUSTER mapping renders as
# one row per member host (twelve, observed). An earlier cut of this fix used
# lsvolumehostclustermap, which this firmware does not appear to have at all -
# it would have failed EVERY map error. Hence: only commands seen working.
{
    my $sc = { fsprefix => 'k8ss', fshostgroup => 'pmcl01' };
    no warnings 'redefine';
    my $MV = $P->can('_map_volume');
    local $SIG{__WARN__} = sub { };

    # Clean map: no read-back, so the happy path stays at one REST call.
    my @sent;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my (undef, $command) = @_; push @sent, $command; return {};
    };
    ok_case('map: clean map returns',     $MV->($sc, 'vm-1-disk-0', 'S'), 1);
    ok_case('map: happy path is one call', scalar(@sent), 1);
    ok_case('map: and it is the map call', $sent[0], 'mkvolumehostclustermap');

    # Refused but genuinely mapped -> success, whatever code was reported.
    # Idempotency by FACT, not by regex - including the host-level codes the
    # old list swallowed and the wordings no list would have anticipated.
    for my $code ('CMMVC9066E already has a shared mapping',
                  'CMMVC6071E already mapped to a host',
                  'CMMVC5879E some wording nobody enumerated') {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my (undef, $command) = @_;
            die "flashsystem: mkvolumehostclustermap failed: 409 $code\n"
                if $command eq 'mkvolumehostclustermap';
            return [ map { { host_name => "nosvgsmpm$_" } } qw(000 001 002) ]
                if $command eq 'lsvdiskhostmap';
            return [];
        };
        ok_case("map: refused but mapped ($code)",
            (eval { $MV->($sc, 'vm-1-disk-0', 'S') } // "died: $@"), 1);
    }

    # THE BUG: refused, and nothing is mapped. Used to return success.
    {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my (undef, $command) = @_;
            die "flashsystem: mkvolumehostclustermap failed: 409 CMMVC6071E\n"
                if $command eq 'mkvolumehostclustermap';
            return [] if $command eq 'lsvdiskhostmap';
            return [];
        };
        eval { $MV->($sc, 'vm-1-disk-0', 'S') };
        ok_case('map: refused + nothing mapped DIES',
            ($@ && $@ =~ /not mapped to anything/) ? 'dies' : "(!? $@)", 'dies');
        ok_case('map: the failure quotes the array',
            ($@ && $@ =~ /CMMVC6071E/) ? 'yes' : 'no', 'yes');
    }

    # Auth failure with nothing mapped must also die.
    {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my (undef, $command) = @_;
            die "flashsystem: mkvolumehostclustermap failed: 401 Unauthorized\n"
                if $command eq 'mkvolumehostclustermap';
            return [];
        };
        eval { $MV->($sc, 'vm-1-disk-0', 'S') };
        ok_case('map: auth failure dies',
            ($@ && $@ =~ /not mapped to anything/) ? 'dies' : "(!? $@)", 'dies');
    }

    # An UNREADABLE read-back must neither assert mapped nor unmapped: warn and
    # let activate_volume's device poll arbitrate. Dying here would make a
    # throttled array a hard attach failure.
    {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my (undef, $command) = @_;
            die "flashsystem: mkvolumehostclustermap failed: 409 CMMVC6071E\n"
                if $command eq 'mkvolumehostclustermap';
            die "flashsystem: lsvdiskhostmap failed: 429 Too Many Requests\n";
        };
        my $warned = 0;
        local $SIG{__WARN__} = sub { $warned++ if $_[0] =~ /could not read back/ };
        ok_case('map: unreadable read-back proceeds',
            (eval { $MV->($sc, 'vm-1-disk-0', 'S') } // "died: $@"), 1);
        ok_case('map: and says so',  $warned, 1);
    }

    # Shape tolerance, same as everywhere else in this file: a bare hash and a
    # junk row must not be read as "nothing is mapped".
    {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my (undef, $command) = @_;
            die "flashsystem: mkvolumehostclustermap failed: 409 CMMVC6071E\n"
                if $command eq 'mkvolumehostclustermap';
            return { host_name => 'nosvgsmpm000' } if $command eq 'lsvdiskhostmap';
            return [];
        };
        ok_case('map: bare hash row counts as mapped',
            (eval { $MV->($sc, 'vm-1-disk-0', 'S') } // "died: $@"), 1);
    }
}

# ---- the SCSI rescan flags ------------------------------------------------
# -a -r -u, and each covers a case the others miss. -u is the one that took a
# live failure to learn: -r only removes a LUN the array has stopped reporting,
# so when the array RECYCLES a LUN number to a different volume - constant once
# Kubernetes churns PVCs - the slot is neither new nor removed, -a -r leaves the
# stale device, multipath assembles the OLD map and /dev/mapper/3<UID> never
# appears. Nothing pinned these flags before nosvgsmpm007 failed to attach.
{
    local @PVE::Tools::CALLS = ();
    $P->can('_rescan_scsi')->();
    my ($rescan) = grep { $_->[0] eq 'rescan-scsi-bus.sh' } @PVE::Tools::CALLS;
    ok_case('rescan: uses rescan-scsi-bus.sh', ($rescan ? 'yes' : 'no'), 'yes');
    if ($rescan) {
        my %f = map { $_ => 1 } @$rescan;
        ok_case('rescan: -a (add new LUNs)',            ($f{'-a'} ? 1 : 0), 1);
        ok_case('rescan: -r (drop vanished LUNs)',      ($f{'-r'} ? 1 : 0), 1);
        ok_case('rescan: -u (catch REMAPPED LUNs)',     ($f{'-u'} ? 1 : 0), 1);
    }
    # The no-sg3-utils fallback must still scan, or a node without the package
    # silently stops discovering anything.
    local %PVE::Tools::RC = ( 'sh' => 1 );   # `command -v rescan-scsi-bus.sh` fails
    local @PVE::Tools::CALLS = ();
    $P->can('_rescan_scsi')->();
    my $fellback = grep { ($_->[-1] // '') =~ m{/sys/class/scsi_host} } @PVE::Tools::CALLS;
    ok_case('rescan: falls back to a sysfs scan', ($fellback ? 'yes' : 'no'), 'yes');
}

# ---- _pool_is_drp + alloc_image threading ---------------------------------
# The one line that actually chooses the parameter set on a production array
# is alloc_image's `my $drp = $scfg->{fsthin} ? _pool_is_drp(...) : 0`, and
# nothing exercised it: every other DRP case calls _mkvdisk_params directly
# with $drp already decided. So the thick path's one-REST-call invariant, and
# the DRP lookup itself, were both unasserted.
{
    my $DRP = \&PVE::Storage::Custom::FlashSystemPlugin::_pool_is_drp;
    no warnings 'redefine';

    # lsmdiskgrp answering as a bare hashref (some firmwares) and as a
    # one-element array (others) must both work — that is what _one() is for.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return { data_reduction => 'yes' };
    };
    ok_case('is_drp: yes (bare hash)', $DRP->({ fsaddress => 'a1', fspool => 'P1' }, 'S'), 1);
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        return [ { data_reduction => 'no' } ];
    };
    ok_case('is_drp: no (1-elem array)', $DRP->({ fsaddress => 'a2', fspool => 'P2' }, 'S'), 0);
    # Field absent -> behave as a standard pool (upstream default).
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return { name => 'P3' } };
    ok_case('is_drp: field absent -> 0', $DRP->({ fsaddress => 'a3', fspool => 'P3' }, 'S'), 0);
    # A failed lookup must NOT be cached: it is transient by assumption, and
    # caching a 0 would pin the wrong parameter set until the daemon restarts.
    my $calls = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        $calls++; die "flashsystem: 429\n";
    };
    my $sc4 = { fsaddress => 'a4', fspool => 'P4' };
    ok_case('is_drp: error -> 0',        $DRP->($sc4, 'S'), 0);
    $DRP->($sc4, 'S');
    ok_case('is_drp: failure not cached', $calls, 2);
    # A successful answer IS memoised for the life of the process.
    my $calls2 = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        $calls2++; return { data_reduction => 'yes' };
    };
    my $sc5 = { fsaddress => 'a5', fspool => 'P5' };
    $DRP->($sc5, 'S'); $DRP->($sc5, 'S'); $DRP->($sc5, 'S');
    ok_case('is_drp: success memoised',  $calls2, 1);
    # Keyed per (array, pool), not globally.
    $DRP->({ fsaddress => 'a5', fspool => 'OTHER' }, 'S');
    ok_case('is_drp: keyed per array+pool', $calls2, 2);
}

# alloc_image must consult _pool_is_drp ONLY on the thin path, and must thread
# the answer into mkvdisk. Recording the command sequence pins both the
# REST-call count and the resulting parameter set.
{
    my $sc_thin = { fsaddress => 'z1', fspool => 'Pz1', fsprefix => 'k8ss', fsthin => 1 };
    my $sc_thick = { fsaddress => 'z2', fspool => 'Pz2', fsprefix => 'k8ss' };
    no warnings 'redefine';
    my (@cmds, $mkparams);
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        push @cmds, $command;
        return { data_reduction => 'yes' } if $command eq 'lsmdiskgrp';
        $mkparams = $params if $command eq 'mkvdisk';
        return {};
    };
    @cmds = ();
    $P->alloc_image('S', $sc_thick, 101, 'raw', 'vm-101-disk-0', 1024);
    ok_case('alloc thick: one REST call', join(',', @cmds), 'mkvdisk');

    @cmds = ();
    $P->alloc_image('S', $sc_thin, 101, 'raw', 'vm-101-disk-0', 1024);
    ok_case('alloc thin: probes the pool', join(',', @cmds), 'lsmdiskgrp,mkvdisk');
    # The DRP answer must have reached the parameter set.
    ok_case('alloc thin on DRP: no warning',
        (exists $mkparams->{warning} ? 'present' : 'absent'), 'absent');
    ok_case('alloc thin on DRP: rsize kept', $mkparams->{rsize}, '2%');

    # Standard pool: warning restored, and still only two calls.
    @cmds = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        push @cmds, $command;
        return { data_reduction => 'no' } if $command eq 'lsmdiskgrp';
        $mkparams = $params if $command eq 'mkvdisk';
        return {};
    };
    $P->alloc_image('S', { %$sc_thin, fsaddress => 'z3', fspool => 'Pz3' },
        101, 'raw', 'vm-101-disk-0', 1024);
    ok_case('alloc thin on standard: warning', $mkparams->{warning}, '80%');
}

# ---- alloc_image: the snapshot-headroom boundary --------------------------
# A one-character predicate ($headroom < 1) with no coverage: both off-by-one
# mutations left the whole suite green.
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return {} };
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };

    # arrayname exactly 63 -> headroom 0 -> must warn (no snapshot possible).
    my $p63 = 'pvecl1_Archive';    # 14 chars + '-' = 15
    @warns = ();
    $P->alloc_image('S', { fsprefix => $p63, fspool => 'P', fssnapshots => 1 },
        9999, 'raw', "vm-9999-pvc-$uuid", 1024);
    ok_case('headroom 0 warns',
        (grep { /snapshots of this volume will fail/ } @warns) ? 'warned' : 'silent', 'warned');

    # arrayname 62 -> headroom 0 -> still warns (the predicate is < 1).
    @warns = ();
    $P->alloc_image('S', { fsprefix => 'pvecl1_Archiv', fspool => 'P', fssnapshots => 1 },
        9999, 'raw', "vm-9999-pvc-$uuid", 1024);
    ok_case('headroom 0 (62) warns',
        (grep { /snapshots of this volume will fail/ } @warns) ? 'warned' : 'silent', 'warned');

    # arrayname 61 -> headroom 1 -> exactly one char for a snapshot name, so
    # silent. This is the boundary: 12-char prefix + '-' + the 48-char CSI
    # volname = 61.
    @warns = ();
    $P->alloc_image('S', { fsprefix => 'pvecl1_Archi', fspool => 'P', fssnapshots => 1 },
        9999, 'raw', "vm-9999-pvc-$uuid", 1024);
    ok_case('headroom 1 silent',
        (grep { /snapshots of this volume will fail/ } @warns) ? 'warned' : 'silent', 'silent');

    # With snapshots off there is nothing to warn about.
    @warns = ();
    $P->alloc_image('S', { fsprefix => $p63, fspool => 'P' },
        9999, 'raw', "vm-9999-pvc-$uuid", 1024);
    ok_case('headroom: snaps off silent',
        (grep { /snapshots of this volume will fail/ } @warns) ? 'warned' : 'silent', 'silent');
}

# ---- the CSI snapshot surface --------------------------------------------
# The four entry points a Kubernetes CSI driver calls over the PVE API, so it
# never holds array credentials. The naming scheme is the load-bearing part:
# CSI CreateSnapshot is idempotent BY NAME, but only 9 characters fit inside
# _snap_name's budget on a k8s tier, so the component is a truncated digest —
# and a truncated digest that collided and was treated as "already exists"
# would hand back a handle pointing at ANOTHER PVC's snapshot.
{
    my $CC = \&PVE::Storage::Custom::FlashSystemPlugin::_csi_snap_component;
    my $VS = \&PVE::Storage::Custom::FlashSystemPlugin::_volname_from_snapname;

    # Deterministic, 9 chars, and inside _snap_name's charset (a-z2-7), so
    # nothing is sanitised away.
    my $c1 = $CC->('snapshot-8d7f3a21-1c4e-4a55-9b2e-77e0c1a9f001');
    ok_case('csi comp: 9 chars',      length($c1), 9);
    ok_case('csi comp: deterministic',
        $CC->('snapshot-8d7f3a21-1c4e-4a55-9b2e-77e0c1a9f001'), $c1);
    ok_case('csi comp: base32 charset',
        ($c1 =~ /\A[a-z2-7]{9}\z/ ? 'clean' : "dirty:$c1"), 'clean');
    # A different CSI name must give a different component (not a constant).
    ok_case('csi comp: varies with input',
        ($CC->('snapshot-aaaa') eq $CC->('snapshot-bbbb') ? 'same' : 'differs'), 'differs');
    # _snap_name must not alter it — if it did, the digest would not round-trip.
    my $sn = PVE::Storage::Custom::FlashSystemPlugin::_snap_name('k8ss-vm-9999-pvc-x', $c1);
    ok_case('csi comp: survives _snap_name', $sn, "k8ss-vm-9999-pvc-x.$c1");
    eval { $CC->('') };
    ok_case('csi comp: empty name dies',
        ($@ && $@ =~ /empty CSI snapshot name/) ? 'dies' : "(!? $@)", 'dies');
    # The whole point of 9: prefix(4) + '-' + volname(48) + '.' + comp(9) = 63.
    my $full = PVE::Storage::Custom::FlashSystemPlugin::_snap_name(
        $A->({ fsprefix => 'k8ss' }, "vm-9999-pvc-$uuid"), $c1);
    ok_case('csi comp: exactly fills 63', length($full), 63);

    # _volname_from_snapname: recover the owning volume, reject anything else.
    my $sc = { fsprefix => 'k8ss' };
    ok_case('from_snapname: ours',        ($VS->($sc, "k8ss-vm-9999-pvc-a.$c1"))[0], 'vm-9999-pvc-a');
    ok_case('from_snapname: foreign prefix', $VS->($sc, "k8sg-vm-9999-pvc-a.$c1"), undef);
    ok_case('from_snapname: no dot',      $VS->($sc, 'k8ss-vm-9999-pvc-a'), undef);
    ok_case('from_snapname: bad volname', $VS->($sc, 'k8ss-notavolume.abc'), undef);
    # The split must be on the LAST dot (state volumes are allowed dots), AND
    # the component must be one WE minted.
    ok_case('from_snapname: dotted state vol',
        ($VS->($sc, "k8ss-vm-101-state-a.b.$c1"))[0], 'vm-101-state-a.b');
    # A component that is not a 9-char base32 digest is NOT a CSI snapshot.
    # Without this, every ordinary PVE snapshot on the same storage parses as
    # one - and then list reports it, delete accepts a handle naming it, and
    # restore clones from it.
    ok_case('from_snapname: rejects vzdump',   $VS->($sc, 'k8ss-vm-101-disk-0.vzdump'), undef);
    ok_case('from_snapname: rejects short',    $VS->($sc, 'k8ss-vm-101-disk-0.s1'), undef);
    ok_case('from_snapname: rejects 10 chars', $VS->($sc, 'k8ss-vm-101-disk-0.3bcdefghij'), undef);
    ok_case('from_snapname: rejects base32-illegal',
        $VS->($sc, 'k8ss-vm-101-disk-0.abcdefgh1'), undef);   # '1' is not in a-z2-7
    ok_case('from_snapname: accepts 2-7 digits',
        ($VS->($sc, 'k8ss-vm-101-disk-0.2a2b3c4d5'))[0], 'vm-101-disk-0');
    # A component must START with a digit, and this is the property that keeps
    # the two snapshot namespaces disjoint rather than merely unlikely to
    # collide. pve-snapshot-name is /^[a-z][a-z0-9_-]+$/i, so a 9-character
    # operator snapshot name -- and on a k8s-* storage 9 is the ONLY length
    # that fits the 63-char array cap -- used to parse as one of ours. Then
    # csi_snapshot_list reported the operator's rollback point to Kubernetes as
    # a leaked orphan, and csi_snapshot_delete rmsnapshot'ed it while PVE's
    # vmconfig still listed it, so the loss surfaced only at `qm rollback`.
    ok_case('from_snapname: rejects leading letter',
        $VS->($sc, 'k8ss-vm-101-disk-0.a2b3c4d5e'), undef);
    for my $pve_name (qw(preupdate beforeupg migration baseline2 goldenimg
                         predeploy autodaily b4upgrade firstsnap)) {
        ok_case("from_snapname: rejects PVE name '$pve_name'",
            $VS->($sc, "k8ss-vm-101-disk-0.$pve_name"), undef);
    }
    # And from the other end: no PVE-side snapshot may be minted INTO the CSI
    # namespace, enforced locally rather than inherited from PVE's schema.
    my $csi_shaped = eval {
        $P->volume_snapshot({ fssnapshots => 1, fsprefix => 'k8ss' },
            'k8s-silver', 'vm-101-disk-0', '3abcdefgh'); 1 };
    ok_case('volume_snapshot: refuses a CSI-shaped name',
        ($csi_shaped ? 'accepted' : ($@ =~ /reserved for CSI/ ? 'reserved-error' : "other: $@")),
        'reserved-error');
    # Every component we mint must satisfy the grammar we parse.
    my $nonconforming = 0;
    for my $i (1 .. 2000) {
        $nonconforming++
            if $P->can('_csi_snap_component')->("pvc-snap-$i") !~ /\A[2-7][a-z2-7]{8}\z/;
    }
    ok_case('component: 2000 mints all conform', $nonconforming, 0);
}

# ---- _snap_is_ready: 'Ready' means NOT triggered -------------------------
# IBM's lsvolumesnapshot reference: "Ready: If the snapshot is not triggered.
# Active: Maintain the snapshot image." So Ready is the OPPOSITE of
# ready_to_use. An earlier cut of this code allowed both, which would have
# reported a usable restore point for a snapshot that had never been cut.
{
    my $RD = \&PVE::Storage::Custom::FlashSystemPlugin::_snap_is_ready;
    ok_case('ready: active',       $RD->('active'), 1);
    ok_case('ready: Active',       $RD->('Active'), 1);
    ok_case('ready: Ready is NOT', $RD->('Ready'),  0);
    ok_case('ready: ready is NOT', $RD->('ready'),  0);
    ok_case('ready: deleting',     $RD->('Deleting'), 0);
    ok_case('ready: failed',       $RD->('Failed'), 0);
    ok_case('ready: undef',        $RD->(undef),    0);
    ok_case('ready: unknown',      $RD->('wat'),    0);
}

# ---- csi_snapshot_create --------------------------------------------------
{
    my $sc = { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1 };
    my $CC = \&PVE::Storage::Custom::FlashSystemPlugin::_csi_snap_component;
    my $csi  = 'snapshot-8d7f3a21-1c4e-4a55-9b2e-77e0c1a9f001';
    my $comp = $CC->($csi);
    no warnings 'redefine';

    # Fresh create: probes the listing, adds, reads back.
    my @cmds;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        push @cmds, $command;
        return [] if $command eq 'lsvolumesnapshot' && @cmds == 1;
        return [ { snapshot_id => 12, snapshot_name => "k8ss-vm-9999-pvc-a.$comp",
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active',
                   time => '260909120000' } ] if $command eq 'lsvolumesnapshot';
        return { id => 7, name => 'k8ss-vm-9999-pvc-a', capacity => 1073741824 }
            if $command eq 'lsvdisk';
        return {};
    };
    my $r = $P->csi_snapshot_create($sc, 'S', 'vm-9999-pvc-a', $csi);
    ok_case('csi create: array name',  $r->{snapshot_name}, "k8ss-vm-9999-pvc-a.$comp");
    ok_case('csi create: id',          $r->{snapshot_id}, 12);
    # size_bytes must come from the PARENT at snapshot time: lsvolumesnapshot
    # has no capacity field, and reading it later gives the parent's CURRENT
    # size, which is wrong after any expand.
    ok_case('csi create: size from parent', $r->{size_bytes}, 1073741824);
    ok_case('csi create: ready',       $r->{ready}, 1);
    ok_case('csi create: issued addsnapshot',
        (grep { $_ eq 'addsnapshot' } @cmds) ? 'yes' : 'no', 'yes');

    # Idempotent retry: the object already exists, so NO addsnapshot.
    @cmds = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @cmds, $command;
        return [ { snapshot_id => 12, snapshot_name => "k8ss-vm-9999-pvc-a.$comp",
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        return { id => 7, name => 'k8ss-vm-9999-pvc-a', capacity => 1073741824 }
            if $command eq 'lsvdisk';
        return {};
    };
    my $r2 = $P->csi_snapshot_create($sc, 'S', 'vm-9999-pvc-a', $csi);
    ok_case('csi create: idempotent id', $r2->{snapshot_id}, 12);
    ok_case('csi create: no second addsnapshot',
        (grep { $_ eq 'addsnapshot' } @cmds) ? 'added' : 'none', 'none');

    # THE COLLISION CASE. The same digest component already belongs to a
    # DIFFERENT volume. Treating that as "already exists" would return a
    # handle pointing at another PVC's snapshot; it must refuse instead.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        return [ { snapshot_id => 99, snapshot_name => "k8ss-vm-9999-pvc-OTHER.$comp",
                   volume_name => 'k8ss-vm-9999-pvc-OTHER', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        return { id => 7, capacity => 1 } if $command eq 'lsvdisk';
        return {};
    };
    eval { $P->csi_snapshot_create($sc, 'S', 'vm-9999-pvc-a', $csi) };
    ok_case('csi create: cross-volume collision refused',
        ($@ && $@ =~ /ALREADY_EXISTS/) ? 'dies' : "(!? $@)", 'dies');
    ok_case('csi create: names the other volume',
        ($@ && $@ =~ /pvc-OTHER/) ? 'yes' : 'no', 'yes');

    # A volname that is not ours must be rejected before any array call.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { die "should not be called\n" };
    eval { $P->csi_snapshot_create($sc, 'S', 'not-a-volume', $csi) };
    ok_case('csi create: bad volname dies first',
        ($@ && $@ =~ /unable to parse/) ? 'dies' : "(!? $@)", 'dies');

    eval { $P->csi_snapshot_create({ fsprefix => 'k8ss' }, 'S', 'vm-9999-pvc-a', $csi) };
    ok_case('csi create: snaps off dies',
        ($@ && $@ =~ /snapshots disabled/) ? 'dies' : "(!? $@)", 'dies');
}

# ---- csi_snapshot_delete / list ------------------------------------------
{
    my $sc = { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1 };
    no warnings 'redefine';
    my @cmds;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @cmds, $command;
        return [ { snapshot_id => 21, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' },
                 { snapshot_id => 22, snapshot_name => 'k8ss-vm-9999-pvc-b.4klmnopqr',
                   volume_name => 'k8ss-vm-9999-pvc-b', state => 'active' },
                 { snapshot_id => 23, snapshot_name => 'pmcl01_Gold-vm-124-disk-0.wk3',
                   volume_name => 'pmcl01_Gold-vm-124-disk-0' } ]
            if $command eq 'lsvolumesnapshot';
        return {};
    };
    my $d = $P->csi_snapshot_delete($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi');
    ok_case('csi delete: deleted',   $d->{deleted}, 1);
    ok_case('csi delete: by id',     $d->{snapshot_id}, 21);
    ok_case('csi delete: rmsnapshot issued',
        (grep { $_ eq 'rmsnapshot' } @cmds) ? 'yes' : 'no', 'yes');

    # Absent must be a benign no-op: CSI requires 0 OK when the snapshot is
    # already gone.
    @cmds = ();
    my $d2 = $P->csi_snapshot_delete($sc, 'S', 'k8ss-vm-9999-pvc-a.5zzzzzzzz');
    ok_case('csi delete: absent is ok',   $d2->{deleted}, 0);
    ok_case('csi delete: absent reason',  $d2->{reason}, 'absent');
    ok_case('csi delete: no rmsnapshot',
        (grep { $_ eq 'rmsnapshot' } @cmds) ? 'issued' : 'none', 'none');

    # Another storage's object must never be touched.
    @cmds = ();
    my $d3 = $P->csi_snapshot_delete($sc, 'S', 'pmcl01_Gold-vm-124-disk-0.wk3');
    ok_case('csi delete: foreign is not-ours', $d3->{reason}, 'not-ours');
    ok_case('csi delete: foreign untouched',
        (grep { $_ eq 'rmsnapshot' } @cmds) ? 'issued' : 'none', 'none');

    # Listing is scoped to this storage's prefix, so the VM estate's snapshot
    # (row 23) must not appear.
    my $l = $P->csi_snapshot_list($sc, 'S');
    ok_case('csi list: count',  scalar(@$l), 2);
    ok_case('csi list: owners',
        join(',', map { $_->{source_volname} } @$l), 'vm-9999-pvc-a,vm-9999-pvc-b');
    my $l1 = $P->csi_snapshot_list($sc, 'S', 'vm-9999-pvc-a');
    ok_case('csi list: per-volume', scalar(@$l1), 1);
}

# ---- csi_volume_from_snapshot -------------------------------------------
{
    my $sc = { fsprefix => 'k8ss', fspool => 'Pool1_Silver', fssnapshots => 1,
               fsrestore => 1 };
    no warnings 'redefine';
    my @sent;
    # Explicit array state, so the existence check and the post-create read
    # back are answered by what has actually been created rather than by a
    # heuristic. A targeted lsvdisk on an absent name returns undef, which is
    # what _vdisk turns into its "not found" die.
    my %exists = ('k8ss-vm-9999-pvc-a' => 1);
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        return [ { snapshot_id => 31, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        if ($command eq 'lsvdisk') {
            return undef if !defined $target || !$exists{$target};
            return { id => 8, name => $target, capacity => 2147483648 };
        }
        if ($command eq 'mkvolume') {
            push @sent, [ $command, $params ];
            $exists{ $params->{name} } = 1;
            return { id => '41' };
        }
        push @sent, [ $command, $params ];
        return {};
    };
    my $c = $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi',
        vmid => 4242);
    ok_case('csi clone: new volname',   $c->{volname}, 'vm-4242-disk-0');
    ok_case('csi clone: uses mkvolume', $sent[0][0], 'mkvolume');
    ok_case('csi clone: from snap id',  $sent[0][1]{fromsnapshotid}, 31);
    ok_case('csi clone: source vdisk',  $sent[0][1]{fromsourcevolume}, 'k8ss-vm-9999-pvc-a');
    ok_case('csi clone: size read back', $c->{size_bytes}, 2147483648);
    ok_case('csi clone: type',          $c->{clone_type}, 'thinclone');

    # A CSI driver supplies the target name, because it has already put that
    # name in the PV's volumeHandle. Minting a different one here would
    # produce a volume the driver cannot address.
    my $c2 = $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi',
        volname => 'vm-9999-pvc-restored');
    ok_case('csi clone: honours caller volname', $c2->{volname}, 'vm-9999-pvc-restored');
    ok_case('csi clone: names it on the array',  $sent[-1][1]{name},
        'k8ss-vm-9999-pvc-restored');
    # A caller-supplied name still has to pass the grammar.
    eval { $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi',
        volname => 'not-a-volume') };
    ok_case('csi clone: bad volname dies',
        ($@ && $@ =~ /unable to parse/) ? 'dies' : "(!? $@)", 'dies');
    # And neither name nor vmid is a programming error, not a silent default.
    eval { $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi') };
    ok_case('csi clone: needs volname or vmid',
        ($@ && $@ =~ /needs volname or vmid/) ? 'dies' : "(!? $@)", 'dies');

    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub { return [] };
    eval { $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.5zzzzzzzz',
        vmid => 4242) };
    ok_case('csi clone: absent snap dies',
        ($@ && $@ =~ /not found/) ? 'dies' : "(!? $@)", 'dies');
    eval { $P->csi_volume_from_snapshot($sc, 'S', 'someone-else.3bcdefghi', vmid => 4242) };
    ok_case('csi clone: foreign snap dies',
        ($@ && $@ =~ /is not a snapshot on storage/) ? 'dies' : "(!? $@)", 'dies');

    # fsrestore is a SEPARATE gate from fssnapshots, default off: this path
    # rests on mkvolume, which has never been issued against an array, while
    # create/delete rest on commands in production since 2026-08-12.
    eval { $P->csi_volume_from_snapshot(
        { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1 },
        'S', 'k8ss-vm-9999-pvc-a.3bcdefghi', vmid => 4242) };
    ok_case('csi clone: fsrestore gate',
        ($@ && $@ =~ /restore-from-snapshot is disabled/) ? 'dies' : "(!? $@)", 'dies');
    ok_case('csi clone: gate names the probe',
        ($@ && $@ =~ /probe-clone-from-snapshot/) ? 'yes' : 'no', 'yes');

    # ---- the existence pre-check must read the ARRAY's not-found correctly --
    # Storage Virtualize answers "no such object" with 409 + CMMVC5754E, an
    # ERROR status, so _cmd dies and _vdisk never reaches its own not-found
    # die. Matching only /not found/ made the one reply meaning "this name is
    # free" abort the restore - which broke every K10 restore and export,
    # since K10 clones into a name it has already minted. It must still fail
    # CLOSED on everything else, or mkvolume runs over a live volume.
    for my $t (
        [ 'array says CMMVC5754E',
          "flashsystem: lsvdisk failed: 409 Conflict \"error code: 1, error text:"
          . " CMMVC5754E The specified object does not exist, or the name supplied"
          . " does not meet the naming rules.\"\n", 'proceeds' ],
        [ 'plugin says not found', "flashsystem: vdisk 'k8ss-vm-1-disk-0' not found\n", 'proceeds' ],
        [ 'auth refused',      "flashsystem: lsvdisk failed: 401 Unauthorized\n",        'refuses' ],
        [ 'forbidden',         "flashsystem: lsvdisk failed: 403 Forbidden\n",           'refuses' ],
        [ 'throttled out',     "flashsystem: lsvdisk failed: 429 Too Many Requests\n",   'refuses' ],
        [ 'array unreachable', "flashsystem: lsvdisk failed: 500 Internal Server Error\n",'refuses' ],
        [ 'bad JSON',          "flashsystem: lsvdisk: bad JSON response: <html>\n",      'refuses' ],
    ) {
        my ($label, $lsvdisk_err, $want) = @$t;
        my @issued;
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my ($scfg, $command, $target, $params) = @_;
            return [ { snapshot_id => 31, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                       volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ]
                if $command eq 'lsvolumesnapshot';
            die $lsvdisk_err if $command eq 'lsvdisk';
            push @issued, $command;
            return { id => '31' };
        };
        eval { $P->csi_volume_from_snapshot(
            { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1, fsrestore => 1 },
            'S', 'k8ss-vm-9999-pvc-a.3bcdefghi', volname => 'vm-4242-disk-0') };
        my $got = (grep { $_ eq 'mkvolume' } @issued) ? 'proceeds'
                : ($@ && $@ =~ /cannot verify whether/) ? 'refuses'
                : "(!? $@)";
        ok_case("csi clone existence: $label", $got, $want);
    }

    # And a volume that genuinely IS there must still stop the restore.
    {
        local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
            my ($scfg, $command) = @_;
            return [ { snapshot_id => 31, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                       volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ]
                if $command eq 'lsvolumesnapshot';
            return { name => 'k8ss-vm-4242-disk-0', capacity => 1 } if $command eq 'lsvdisk';
            return { id => '31' };
        };
        eval { $P->csi_volume_from_snapshot(
            { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1, fsrestore => 1 },
            'S', 'k8ss-vm-9999-pvc-a.3bcdefghi', volname => 'vm-4242-disk-0') };
        ok_case('csi clone existence: real collision still refuses',
            ($@ && $@ =~ /already exists/) ? 'dies' : "(!? $@)", 'dies');
    }

    # A row the array cannot attribute to the source volume must NOT become a
    # clone source: the id resolved here becomes mkvolume's -fromsnapshotid,
    # and cloning the wrong snapshot serves another volume's data silently.
    my @sent2;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        return [ { snapshot_id => 31,
                   snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi' } ]   # no volume_name
            if $command eq 'lsvolumesnapshot';
        push @sent2, $command;
        return {};
    };
    {
        local $SIG{__WARN__} = sub { };    # strict mode warns on the skip
        eval { $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi',
            vmid => 4242) };
    }
    ok_case('csi clone: unattributable snap dies',
        ($@ && $@ =~ /not found/) ? 'dies' : "(!? $@)", 'dies');
    ok_case('csi clone: no mkvolume issued',
        (grep { $_ eq 'mkvolume' } @sent2) ? 'issued' : 'none', 'none');

    # The existence check must FAIL CLOSED. _cmd dies on every non-2xx, so a
    # bare eval would read "array unreachable" as "name is free" and create a
    # volume over one that may already exist.
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        return [ { snapshot_id => 31, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                   volume_name => 'k8ss-vm-9999-pvc-a', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        die "flashsystem: lsvdisk failed: 429 Too Many Requests\n";
    };
    eval { $P->csi_volume_from_snapshot($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi',
        volname => 'vm-9999-pvc-new') };
    ok_case('csi clone: unverifiable existence refuses',
        ($@ && $@ =~ /cannot verify whether/) ? 'dies' : "(!? $@)", 'dies');
}

# ---- csi_snapshot_delete: absent and unattributable are DIFFERENT --------
# strict => 1 SKIPS a row the array cannot attribute, so "no strict match"
# covers two situations that must not share an answer. Only genuine absence
# may be success; a row that exists but cannot be attributed is still holding
# physical capacity, and reporting it deleted is the leak this design exists
# to avoid.
{
    my $sc = { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1 };
    no warnings 'redefine';
    my @cmds;
    local $SIG{__WARN__} = sub { };
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @cmds, $command;
        return [ { snapshot_id => 41,
                   snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi' } ]   # no volume_name
            if $command eq 'lsvolumesnapshot';
        return {};
    };
    eval { $P->csi_snapshot_delete($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi') };
    ok_case('csi delete: unattributable dies',
        ($@ && $@ =~ /does not attribute it/) ? 'dies' : "(!? $@)", 'dies');
    ok_case('csi delete: unattributable not removed',
        (grep { $_ eq 'rmsnapshot' } @cmds) ? 'removed' : 'none', 'none');

    # The harder half of the same case: volume_name PRESENT but DISAGREEING.
    # _snapshots_for drops such a row in non-strict mode too, so the loose
    # re-scan could not see it and the snapshot came back reason => 'absent' --
    # which FSDeleteSnapshot maps to nil and Kubernetes records as reclaimed
    # capacity, for a snapshot still holding it. any_owner => 1 is what makes
    # the second pass able to tell the two apart.
    @cmds = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @cmds, $command;
        return [ { snapshot_id => 41, snapshot_name => 'k8ss-vm-9999-pvc-a.3bcdefghi',
                   volume_name => 'k8ss-vm-1234-disk-9', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        return {};
    };
    my $mis = eval { $P->csi_snapshot_delete($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi') };
    ok_case('csi delete: mismatched owner dies',
        ($@ && $@ =~ /does not attribute it/) ? 'dies'
            : "(!? returned " . ($mis ? ($mis->{reason} // 'undef') : 'undef') . ")", 'dies');
    ok_case('csi delete: mismatched owner not removed',
        (grep { $_ eq 'rmsnapshot' } @cmds) ? 'removed' : 'none', 'none');

    # ...and genuine absence must STILL be a success, or DeleteSnapshot stops
    # being idempotent and external-snapshotter retries forever.
    @cmds = ();
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_; push @cmds, $command; return [];
    };
    my $gone = $P->csi_snapshot_delete($sc, 'S', 'k8ss-vm-9999-pvc-a.3bcdefghi');
    ok_case('csi delete: truly absent is absent', $gone->{reason}, 'absent');
    ok_case('csi delete: truly absent sends no rmsnapshot',
        (grep { $_ eq 'rmsnapshot' } @cmds) ? 'removed' : 'none', 'none');
}

# ---- csi_snapshot_create: a same-name row on ANOTHER volume ---------------
# The idempotency probe must not accept it as a replay. Doing so would report
# CreateSnapshot success for a snapshot that was never cut, and hand back a
# handle pointing at someone else's.
{
    my $sc = { fsprefix => 'k8ss', fspool => 'P', fssnapshots => 1 };
    my $csi = 'snapshot-8d7f3a21-1c4e-4a55-9b2e-77e0c1a9f001';
    my $comp = PVE::Storage::Custom::FlashSystemPlugin::_csi_snap_component($csi);
    no warnings 'redefine';
    my @cmds;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @cmds, $command;
        return [ { snapshot_id => 51, snapshot_name => "k8ss-vm-9999-pvc-a.$comp",
                   volume_name => 'a-different-volume', state => 'active' } ]
            if $command eq 'lsvolumesnapshot';
        return { id => 7, capacity => 1 } if $command eq 'lsvdisk';
        return {};
    };
    eval { $P->csi_snapshot_create($sc, 'S', 'vm-9999-pvc-a', $csi) };
    ok_case('csi create: same-name other-volume refused',
        ($@ && $@ =~ /ALREADY_EXISTS/) ? 'dies' : "(!? $@)", 'dies');
    ok_case('csi create: no addsnapshot on refusal',
        (grep { $_ eq 'addsnapshot' } @cmds) ? 'added' : 'none', 'none');
}

print $fail ? "\n$fail FAILURE(S)\n" : "\nall cases pass\n";
exit($fail ? 1 : 0);
