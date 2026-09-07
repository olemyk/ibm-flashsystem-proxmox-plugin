package PVE::Storage::Custom::FlashSystemPlugin;

# ---------------------------------------------------------------------------
# Custom Proxmox VE storage plugin for IBM Storage FlashSystem.
#
# Drives the FlashSystem via the Storage Virtualize REST API (v1, port 7443):
#   - auth:            POST /rest/v1/auth  (X-Auth-Username/Password) -> token
#   - command:         POST /rest/v1/<command>            (params in JSON body)
#   - targeted command:POST /rest/v1/<command>/<object>   (object in the URL)
#   - responses are JSON; POST is the only verb.
#   - list commands (lsvdisk/lsmdiskgrp) report exact byte counts with the
#     valueless `-bytes` flag, encoded as JSON boolean: `{ bytes => JSON::true }`.
#     (`-unit b` is NOT accepted here — it only applies to the size-taking
#     commands mkvdisk/expandvdisksize.)
#   - `expandvdisksize` takes the DELTA to add, not an absolute size.
#
# Volumes are raw block LUNs, named `vm-<vmid>-disk-<N>` (Proxmox convention),
# reachable on every node as /dev/mapper/3<vdisk_UID> via FC + multipath. The
# vdisk is mapped once to the host cluster (`fshostgroup`); each node just
# rescans on activate and flushes its own multipath map on deactivate. This is
# what lets proxmox-csi hot-plug the disk onto whichever node runs the pod.
#
# STATUS: validated in production against FlashSystem firmware 8.7 (FC +
# dm-multipath, 12-node PVE 9.2 cluster): provisioning, live migration,
# move-disk, resize, snapshots incl. RAM state, delete, Kubernetes CSI
# volumes. Thin provisioning (fsthin) is validated on a standard pool
# (firmware 8.7.0.3, FlashSystem 5200) but not yet on a data reduction
# pool — see the VALIDATE note in _mkvdisk_params. Search this file for
# "VALIDATE:" for the remaining environment- and firmware-specific
# decisions to confirm on YOUR array before production.
# ---------------------------------------------------------------------------

use strict;
use warnings;

use JSON qw(encode_json decode_json);
use LWP::UserAgent;
use HTTP::Request;

use PVE::Tools qw(run_command);
use PVE::Storage;
use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

use constant REST_PORT => 7443;

# How long to wait for a host block device to catch up with an array-side
# resize.
#
# Measured, not guessed. On a FlashSystem 5200 (8.7.0.3) a +1G expand was
# still not visible to READ CAPACITY after SIXTY seconds of continuous
# rescanning - all 8 paths held the old size - and the identical rescan issued
# by hand a few minutes later picked it up at once. So the array's commit can
# lag well past a minute, and the first cut of this timeout (60s) turned a
# slow success into a hard failure.
#
# Formatting is NOT the mechanism, which is worth writing down because it is
# the obvious suspect and it is wrong: the successful rescan happened while
# the volume was still background-formatting at 60%, and an earlier one at
# 44%. Capacity is published independently of the format.
#
# Two minutes. The earlier 300s was compensating for the wrong mechanism -
# a rescan-per-iteration loop that never let any rescan finish. With a single
# rescan the kernel re-reads capacity in seconds, so this is margin, not a
# working figure. The cost of
# waiting is a resize task that takes a while and says so; the cost of not
# waiting is a guest that cannot use capacity the array has already committed,
# and an operator whose only safe recovery is a manual rescan. Note the attach
# path passes budget => 0 and never waits at all.
#
# A variable rather than a constant so the tests can exercise the give-up path
# in under a second; nothing in production should change it.

# ---- Plugin identity / schema -------------------------------------------

sub type { return 'flashsystem'; }

# Match whatever the running Proxmox expects, so the module always loads on a
# supported host instead of being rejected for a hardcoded version.
sub api { return PVE::Storage::APIVER; }

sub plugindata {
    # Block LUNs for VM disk images only.
    return { content => [ { images => 1, rootdir => 1 }, { images => 1 } ] };
}

sub properties {
    return {
        fsaddress => { description => 'FlashSystem management IP/host', type => 'string' },
        fsuser    => { description => 'Storage Virtualize REST username', type => 'string' },
        fspassword => { description => 'REST password (prefer the .pw file, see README)', type => 'string' },
        fspool    => { description => 'Storage pool (mdiskgrp) to allocate from', type => 'string' },
        fshostgroup => { description => 'Host cluster the Proxmox nodes belong to', type => 'string' },
        fsiogrp   => { description => 'I/O group for new vdisks (default io_grp0)', type => 'string' },
        fssnapshots => { description => 'Enable array snapshots (validate firmware first)', type => 'boolean' },
        fsprefix  => { description => 'Prefix for array-side object names, e.g. the cluster name. Required when several clusters share a pool.', type => 'string' },
        fsthin    => { description => 'Thin-provision new volumes (mkvdisk -rsize 2% -autoexpand -warning 80%). Affects new volumes only; existing ones keep their allocation.', type => 'boolean' },
    };
}

sub options {
    return {
        fsaddress   => { fixed => 1 },
        fspool      => { fixed => 1 },
        fsuser      => {},
        fspassword  => { optional => 1 },
        fshostgroup => {},
        fsiogrp     => { optional => 1 },
        fssnapshots => { optional => 1 },
        fsprefix    => { optional => 1, fixed => 1 },
        fsthin      => { optional => 1 },
        content     => { optional => 1 },
        nodes       => { optional => 1 },
        disable     => { optional => 1 },
        shared      => { optional => 1 },
    };
}

# ---- REST transport ------------------------------------------------------

my $UA = LWP::UserAgent->new(
    timeout  => 30,
    # VALIDATE: the array's management cert is typically self-signed. Pin a CA
    # or import the cert instead of disabling verification for production.
    ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0 },
);

my %TOKENS;    # fsaddress -> auth token (re-fetched on 401)

sub _password {
    my ($scfg, $storeid) = @_;
    # Prefer a root-only password file over a plaintext value in storage.cfg.
    if (defined $storeid) {
        my $file = "/etc/pve/priv/storage/$storeid.pw";
        if (-f $file) {
            my $pw = PVE::Tools::file_read_firstline($file);
            return $pw if defined $pw && length $pw;
        }
    }
    return $scfg->{fspassword};
}

sub _auth {
    my ($scfg, $storeid) = @_;
    my $addr = $scfg->{fsaddress};
    return $TOKENS{$addr} if $TOKENS{$addr};

    my $pw = _password($scfg, $storeid);
    die "flashsystem: no REST password (set fspassword or /etc/pve/priv/storage/<id>.pw)\n"
        if !defined $pw || !length $pw;

    my $res = $UA->post(
        "https://$addr:" . REST_PORT . "/rest/v1/auth",
        'Content-Type'    => 'application/json',
        'X-Auth-Username' => $scfg->{fsuser},
        'X-Auth-Password' => $pw,
    );
    die "flashsystem: auth failed: " . $res->status_line . "\n" unless $res->is_success;
    my $tok = decode_json($res->decoded_content)->{token}
        or die "flashsystem: auth returned no token\n";
    return $TOKENS{$addr} = $tok;
}

# Run one Storage Virtualize command. $target (optional) is a vdisk/pool name
# placed in the URL for object-scoped commands (rmvdisk, expandvdisksize, ...).
sub _cmd {
    my ($scfg, $command, $target, $params, %opt) = @_;
    $params //= {};
    my $url = "https://$scfg->{fsaddress}:" . REST_PORT . "/rest/v1/$command";
    $url .= '/' . $target if defined $target && length $target;

    my $send = sub {
        my ($token) = @_;
        my $req = HTTP::Request->new(POST => $url);
        $req->header('Content-Type' => 'application/json');
        $req->header('Accept'       => 'application/json');
        $req->header('X-Auth-Token' => $token);
        $req->content(encode_json($params));
        return $UA->request($req);
    };

    # LOCAL PATCH (see UPSTREAM.md): retry on HTTP 429. The array throttles
    # its REST API, and the steady-state load is real — pvestatd polls every
    # flashsystem storage from every node — so any provisioning burst on top
    # (a template import, CSI churn) can draw 429 on an unlucky call. Honor
    # Retry-After when it is sane, else back off 1/2/4s. Bounded: under
    # status()'s 10s alarm a sleep is interrupted by ALRM and reported as
    # inactive, exactly as a slow array would be.
    my @backoff = (1, 2, 4);
    my $res;
    while (1) {
        $res = $send->(_auth($scfg, $opt{storeid}));
        if ($res->code == 401) {    # token expired -> re-auth once
            delete $TOKENS{ $scfg->{fsaddress} };
            $res = $send->(_auth($scfg, $opt{storeid}));
        }
        last if $res->code != 429 || !@backoff;
        my $delay = shift @backoff;
        my $ra = $res->header('Retry-After');
        $delay = $ra if defined $ra && $ra =~ /^\d{1,2}$/ && $ra >= 1 && $ra <= 10;
        sleep $delay;
    }

    my $body = $res->decoded_content // '';
    if (!$res->is_success) {
        die "flashsystem: $command failed: " . $res->status_line . " $body\n";
    }
    return undef if !length $body;
    my $data = eval { decode_json($body) };
    die "flashsystem: $command: bad JSON response: $body\n" if $@;
    return $data;
}

# lsvdisk/lsmdiskgrp for a single object return a 1-element array on some
# firmwares and a bare object on others — normalise to a hashref.
sub _one {
    my ($data) = @_;
    return $data->[0] if ref($data) eq 'ARRAY';
    return $data;
}

# ---- PVE volname <-> array object name -----------------------------------
#
# PVE volnames stay canonical (vm-<vmid>-disk-<N>): PVE core validates that
# pattern in find_free_diskname, migration and backup, so a prefixed volname
# would be rejected outside this plugin. The prefix therefore lives only on the
# array side, and this plugin is the translation layer.
#
# Without it, the array object name IS the PVE volname, so two clusters sharing
# a pool collide the moment both have a VM with the same VMID, list each other's
# disks (list_images can only filter on pool + the vm-<vmid>- pattern), and can
# delete each other's volumes through an ordinary free_image. Pools map to
# service tiers here, so sharing them across clusters is the normal case, not
# an edge case.

sub _arrayname {
    my ($scfg, $volname) = @_;
    my $p = $scfg->{fsprefix};
    return $volname if !defined $p || !length $p;
    return "$p-$volname";
}

# Inverse, for names coming back from the array. Returns undef when the object
# does not belong to this storage, which is what keeps one cluster's disks out
# of another's list_images.
sub _volname_from_array {
    my ($scfg, $aname) = @_;
    my $p = $scfg->{fsprefix};
    return $aname if !defined $p || !length $p;
    return undef if index($aname, "$p-") != 0;
    return substr($aname, length($p) + 1);
}

sub _vdisk {
    my ($scfg, $volname, $storeid) = @_;
    my $aname = _arrayname($scfg, $volname);
    my $v = _one(_cmd($scfg, 'lsvdisk', $aname, { bytes => JSON::true }, storeid => $storeid));
    die "flashsystem: vdisk '$aname' not found\n" if !$v || !$v->{name};
    return $v;
}

# multipath device id: '3' + lowercased vdisk_UID.
# VALIDATE: assumes multipath uses the WWID as the map name (user_friendly_names
# off, or an alias mapping the WWID). If you use friendly names, resolve the
# alias here instead.
sub _wwid_from_vdisk {
    my ($v) = @_;
    my $uid = $v->{vdisk_UID}
        or die "flashsystem: no vdisk_UID for '" . ($v->{name} // '?') . "'\n";
    return '3' . lc($uid);
}

sub _wwid {
    my ($scfg, $volname, $storeid) = @_;
    return _wwid_from_vdisk(_vdisk($scfg, $volname, $storeid));
}

# ---- Host mapping (tolerant / idempotent) --------------------------------

sub _map_volume {
    my ($scfg, $volname, $storeid) = @_;
    eval { _cmd($scfg, 'mkvolumehostclustermap', _arrayname($scfg, $volname), { hostcluster => $scfg->{fshostgroup} }, storeid => $storeid); };
    if (my $err = $@) {
        # already mapped is fine; anything else is real. The cluster-wide
        # mapping is created once and kept (until free_image), so every
        # re-activation after the first hits "already has a shared mapping":
        #   CMMVC9066E — volume already has a shared mapping to the host cluster
        # host-level "already mapped" codes are kept too, in case a firmware
        # reports the host-cluster case with one of them.
        die $err unless $err =~ /already mapped|already has a shared mapping|CMMVC9066E|CMMVC6071E|CMMVC5879E|CMMVC6070E/i;
    }
    return 1;
}

sub _unmap_volume {
    my ($scfg, $volname, $storeid) = @_;
    eval { _cmd($scfg, 'rmvolumehostclustermap', _arrayname($scfg, $volname), { hostcluster => $scfg->{fshostgroup} }, storeid => $storeid); };
    if (my $err = $@) {
        # not mapped / gone is fine.
        die $err unless $err =~ /does not exist|not mapped|CMMVC5753E|CMMVC5842E|CMMVC6071E/i;
    }
    return 1;
}

# ---- Host-side block device plumbing ------------------------------------

sub _rescan_scsi {
    # Prefer sg3-utils. Pass -r (remove) alongside -a (add) so a LUN whose
    # identity changed -- a reused LUN slot, or a volume whose vdisk_UID differs
    # after a rollback -- is pruned and rediscovered, instead of leaving a stale
    # device that masks the new wwid (multipath would assemble the OLD map and
    # the expected /dev/mapper/3<UID> never appears). -a alone cannot refresh a
    # changed LUN. This is what makes cross-node reattach self-heal.
    if (run_command([ 'sh', '-c', 'command -v rescan-scsi-bus.sh >/dev/null 2>&1' ], noerr => 1) == 0) {
        run_command([ 'rescan-scsi-bus.sh', '-a', '-r' ], noerr => 1);
    } else {
        run_command([ 'sh', '-c', 'for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h"; done' ], noerr => 1);
    }
}

# Where the kernel publishes block devices, and where multipath publishes its
# maps. Variables purely so the tests can drive the device helpers against a
# fixture; nothing else should set them.
our $SYSFS_BLOCK = '/sys/block';
our $MAPPER_DIR  = '/dev/mapper';

# Untaint a sysfs device name, or return undef if it is not one.
#
# PVE runs its daemons under `perl -T`, and EVERY device name in this file
# arrives from readlink() or glob(), so every one of them is tainted. Perl
# permits tainted paths in a read open() but refuses them in a write open():
#
#   Insecure dependency in open while running with -T switch
#
# That asymmetry is why this hid for so long. _dev_size read sizes perfectly
# while every `echo 1 > .../rescan` and every `echo 1 > .../delete` this
# plugin ever issued failed - in an eval, unchecked, on all 8 paths, every
# time. From a shell the same writes always worked, so the array took the
# blame for a host-side bug. Measured live 2026-08-31 once the rescan counted
# its writes: "0 of 8 paths accepted the write".
#
# A regex capture is Perl's untaint operator, so this pattern does real work
# rather than laundering: no '/' means the name cannot escape $SYSFS_BLOCK,
# and '.' and '..' are refused outright.
sub _untaint_dev_name {
    my ($name) = @_;
    return undef if !defined $name || !length $name;
    return undef if $name eq '.' || $name eq '..';
    return $name =~ /\A([A-Za-z0-9][A-Za-z0-9._-]*)\z/a ? $1 : undef;
}

# Fully release a LUN from THIS node: flush the multipath map AND delete each
# underlying SCSI path device. Deleting the sd* devices is essential — if only
# the map is flushed, the stale path devices linger on the host, and when the
# array later reuses that SCSI LUN number for a NEW vdisk the rescan sees the
# slot as already populated ("0 new devices") and multipath reassembles the
# OLD wwid, so the new device never appears. Collect slaves before flushing.
sub _flush_device {
    my ($wwid) = @_;
    return 1 if !defined $wwid || !length $wwid;
    my $map = "$MAPPER_DIR/$wwid";

    my @sd;
    if (-e $map) {
        my $target = readlink($map);                   # e.g. "../dm-21"
        my $dm = defined $target ? (split m{/}, $target)[-1] : undef;
        if (defined $dm && -d "$SYSFS_BLOCK/$dm/slaves") {
            @sd = map { (split m{/}, $_)[-1] } glob "$SYSFS_BLOCK/$dm/slaves/*";
        }
    }

    run_command([ 'multipath', '-f', $wwid ], noerr => 1);

    # Deleting these is not best-effort housekeeping - the comment above is the
    # bug. A silent failure here leaves stale sd nodes that capture the LUN
    # number when the array reuses it, so say so instead of discarding it.
    my ($gone, $stuck, $why) = (0, 0, undef);
    for my $sd (@sd) {
        my $name = _untaint_dev_name($sd);
        if (!defined $name) {
            $stuck++;
            $why //= "$sd: not a usable device name";
            next;
        }
        my $del = "$SYSFS_BLOCK/$name/device/delete";
        my $done = eval {
            open(my $fh, '>', $del) or die "open: $!\n";
            print {$fh} "1\n" or die "write: $!\n";
            close $fh or die "close: $!\n";
            1;
        };
        if ($done) {
            $gone++;
        } else {
            $stuck++;
            if (!defined $why) { $why = $@; chomp $why; $why = "$sd: $why"; }
        }
    }
    warn sprintf("flashsystem: flushed the map for %s but %d of %d SCSI paths "
        . "could not be deleted (%s). Stale path devices make the array's next "
        . "reuse of these LUN numbers reassemble the OLD map.\n",
        $wwid, $stuck, $gone + $stuck, $why) if $stuck;
    return 1;
}

# After an array-side expandvdisksize the underlying SCSI paths and the
# multipath map still report the OLD size, so the hypervisor/guest cannot use
# the new capacity. Re-read each path's capacity, then grow the map. Runs on
# THIS node only (where the resize is driven); other nodes pick up the new size
# on their next activate_volume rescan.
# Size of a block device from sysfs, in bytes. /sys/block/<dev>/size is in
# 512-byte sectors regardless of the device's logical block size.
sub _dev_size {
    my ($dev) = @_;
    return undef if !defined $dev || !length $dev;
    open(my $fh, '<', "$SYSFS_BLOCK/$dev/size") or return undef;
    my $sectors = <$fh>;
    close $fh;
    return undef if !defined $sectors;
    chomp $sectors;
    return undef if $sectors !~ /\A\d+\z/a;
    return $sectors * 512;
}

# The dm-N node behind the mapper entry, or undef when it cannot be named.
#
# readlink is the fast path and is already load-bearing elsewhere in this file,
# but /dev/mapper/<wwid> is only a symlink when udev created it - libdevmapper's
# fallback makes a real block device node, and then readlink yields nothing.
# Without a second route that case costs a full settle timeout and then blames
# the FC paths, which is the same misdirection this change exists to remove.
sub _dm_node {
    my ($map) = @_;
    my $target = readlink($map);
    if (defined $target) {
        my $dm = (split m{/}, $target)[-1];
        # Return the CAPTURE, not $dm: readlink() output is tainted, and an
        # untainted dm name is what makes the write opens below legal.
        return $1 if defined $dm && $dm =~ /\A(dm-\d+)\z/a;
    }
    # Fall back to the kernel's own name map. Deliberately not stat/rdev
    # arithmetic: dev_t bit-packing is easy to get subtly wrong in Perl.
    my $want = (split m{/}, $map)[-1];
    for my $f (glob "$SYSFS_BLOCK/dm-*/dm/name") {
        open(my $fh, '<', $f) or next;
        my $name = <$fh>;
        close $fh;
        next if !defined $name;
        chomp $name;
        next if $name ne $want;
        return _untaint_dev_name((split m{/}, $f)[-3]);    # <dm-N> from the path
    }
    return undef;
}

# Ask every SCSI path under a dm node to re-read its capacity.
#
# Returns (accepted, total, first_error). The old version skipped unwritable
# paths silently and threw away close() errors, which made "the rescan never
# happened" indistinguishable in the task log from "the array is slow to
# publish the new capacity". Those two need opposite responses, and telling
# them apart is the entire difficulty of this failure mode - so count the
# writes that actually landed and report the first one that did not. sysfs
# surfaces write errors at close() as readily as at print(), so both are
# checked.
sub _rescan_paths {
    my ($dm) = @_;
    return (0, 0, 'no dm slaves') if !defined $dm || !-d "$SYSFS_BLOCK/$dm/slaves";
    my ($ok, $total, $err) = (0, 0, undef);
    for my $slave (glob "$SYSFS_BLOCK/$dm/slaves/*") {
        my $sd = _untaint_dev_name((split m{/}, $slave)[-1]);
        $total++;
        if (!defined $sd) {
            $err //= ((split m{/}, $slave)[-1] // '?') . ': not a usable device name';
            next;
        }
        my $rescan = "$SYSFS_BLOCK/$sd/device/rescan";
        my $done = eval {
            open(my $fh, '>', $rescan) or die "open: $!\n";
            print {$fh} "1\n" or die "write: $!\n";
            close $fh or die "close: $!\n";
            1;
        };
        if ($done) {
            $ok++;
        } elsif (!defined $err) {
            $err = $@;
            chomp $err;
            $err = "$sd: $err";
        }
    }
    return ($ok, $total, $err);
}

sub _paths_min_size {
    my ($dm) = @_;
    return undef if !defined $dm || !-d "$SYSFS_BLOCK/$dm/slaves";
    my $min;
    for my $slave (glob "$SYSFS_BLOCK/$dm/slaves/*") {
        my $b = _dev_size((split m{/}, $slave)[-1]);
        return undef if !defined $b;
        $min = $b if !defined $min || $b < $min;
    }
    return $min;
}

sub _path_sizes {
    my ($dm) = @_;
    return 'none' if !defined $dm || !-d "$SYSFS_BLOCK/$dm/slaves";
    my @p = map {
        my $sd = (split m{/}, $_)[-1];
        my $b = _dev_size($sd);
        "$sd=" . (defined $b ? $b : '?');
    } glob "$SYSFS_BLOCK/$dm/slaves/*";
    return @p ? join(' ', @p) : 'none';
}

our $RESIZE_SETTLE_TIMEOUT = 120;

# Seconds between polls, and between the occasional re-nudge of the SCSI
# rescan. Variables for the same reason as the timeout: so the tests can drive
# the loop without spending real wall-clock seconds.
our $RESIZE_POLL_INTERVAL   = 2;
our $RESIZE_RESCAN_INTERVAL = 30;

# Propagate an array-side resize to THIS node's block device.
#
# expandvdisksize returns as soon as the array accepts the request - the new
# capacity is not yet visible to a host READ CAPACITY. Rescanning once and
# accepting whatever comes back is therefore a race, and it loses: observed
# live 2026-08-31, every path still read the old size, the dm map followed
# them, and QEMU failed the guest-side grow with "Cannot grow device files" -
# an error three layers from the cause, on a resize the array had already
# completed. A manual rescan minutes later succeeded instantly while the array
# was still background-formatting the added capacity, which rules formatting
# out and leaves plain timing.
#
# So: check, and only if the device is behind, rescan and re-check until it
# catches up or the budget runs out. The previous version swallowed every
# error and returned success regardless.
#
# best_effort => 1 warns instead of dying, and budget => N overrides the settle
# time. activate_volume passes both: a device that will not catch up must not
# stop a VM from starting, and must not delay one either. With budget => 0 it
# makes exactly ONE corrective pass and never sleeps - the attach path is on
# every VM start and every migration, so it has to stay cheap even when
# something is off.
sub _resize_host_device {
    my ($wwid, $want, %opt) = @_;
    my $map = "$MAPPER_DIR/$wwid";

    # Not attached on this node, which is the normal case for every node not
    # running the guest: deactivate_volume flushes the map, and the next
    # activate_volume discovers the LUN fresh at its current size. Nothing to
    # propagate, nothing stale.
    return 1 if !-e $map;

    my $dm = _dm_node($map);
    if (!defined $dm) {
        # Say this immediately. Spending the whole settle budget to report
        # "unreadable" would point the operator at the FC paths, which are
        # fine - exactly the misdirection this function exists to end.
        my $msg = "flashsystem: cannot resolve a dm device for $map; "
            . "host-side size propagation skipped\n";
        return _resize_failed($msg, $opt{best_effort});
    }

    # The common case by far - including every activate_volume - is that the
    # device is already correct. Check before doing any work.
    my $size = _dev_size($dm);
    return 1 if !defined $want || (defined $size && $size >= $want);

    my $budget = defined $opt{budget} ? $opt{budget} : $RESIZE_SETTLE_TIMEOUT;
    my $deadline = time() + $budget;
    my $started = time();
    my $told = 0;

    # Rescan ONCE, then wait for the kernel to finish re-reading capacity.
    #
    # The obvious loop - rescan, resize, check, repeat - does not work, and the
    # way it fails is worth recording. Measured live 2026-08-31: 300 seconds of
    # rescanning every second left all 8 paths on the old size, and the same
    # rescan issued by hand with a 5-second pause picked the new size up at
    # once. Re-triggering a SCSI rescan while one is still in flight appears to
    # stop any of them completing, so the loop was thrashing the mechanism it
    # was waiting on. Nudge occasionally; mostly just wait.
    my ($rok, $rtotal, $rerr) = _rescan_paths($dm);
    my $passes = 1;
    my $last_rescan = time();
    my $settled = 0;

    while (1) {
        select(undef, undef, undef, $RESIZE_POLL_INTERVAL);

        # The paths carry the array's capacity; the map can only follow them,
        # so resizing it before they have caught up achieves nothing.
        my $pmin = _paths_min_size($dm);
        if (defined $pmin && $pmin >= $want) {
            run_command([ 'multipathd', 'resize', 'map', $wwid ], noerr => 1);
            # Re-resolve: a map reassembled underneath us can land on a
            # different dm number, and checking the wrong device is how this
            # would quietly report success again.
            $dm = _dm_node($map) // $dm;
            $size = _dev_size($dm);
            if (defined $size && $size >= $want) {
                $settled = 1;
                last;
            }
        }
        last if time() >= $deadline;

        if (time() - $last_rescan >= $RESIZE_RESCAN_INTERVAL) {
            my ($o, $t, $e) = _rescan_paths($dm);
            ($rok, $rtotal) = ($o, $t);
            $rerr = $e if defined $e;
            $passes++;
            $last_rescan = time();
        }
        # PVE captures stderr into the task log, so a long settle reads as
        # work rather than as a wedged task.
        if ($budget > 30 && time() - $started >= $told + 30) {
            $told = time() - $started;
            warn sprintf("flashsystem: waiting for %s to reach %d bytes "
                . "(paths at %s) - %ds of %ds\n",
                $map, $want, (defined $pmin ? $pmin : 'unreadable'), $told, $budget);
        }
    }
    return 1 if $settled;

    # Nothing above confirmed the device, so $size is still the value read
    # BEFORE the loop ran - the old `if !defined $size` guard made this a
    # no-op, because $size was always already defined. Re-read it. multipathd
    # resizes maps on its own once it notices the paths grew, so the device
    # can be correct here without any poll having seen it, and reporting the
    # pre-loop snapshot fails those resizes for no reason.
    $size = _dev_size($dm);
    return 1 if defined $size && $size >= $want;

    # NOTE the wording. Do NOT tell the operator to retry the resize: PVE
    # derives its base size from volume_size_info, which this plugin answers
    # from the ARRAY - already at the new size. Re-entering the increment in
    # the GUI therefore expands the array a second time, permanently, because
    # shrinking is refused. The GUI only ever sends an increment, and
    # qemu-server early-returns when the absolute requested size already
    # matches, so there is no dialog gesture that re-runs only this half.
    # Starting or migrating the guest does, via activate_volume.
    # Report whether the rescans were even accepted. Without this the log
    # shows only "the paths did not move", which reads as an array problem
    # whether the cause was the array or a write this node never made.
    my $rsum = sprintf("%s pass(es), %s of %s paths accepted the write%s",
        $passes, (defined $rok ? $rok : '?'), (defined $rtotal ? $rtotal : '?'),
        (defined $rerr ? "; first error: $rerr" : ''));

    return _resize_failed(sprintf(
        "flashsystem: the array holds this volume at %d bytes but this node's "
        . "device is %s and did not catch up within %ds.\n"
        . "  device: %s\n  paths:  %s\n  rescans: %s\n"
        . "DO NOT re-run the resize - PVE sizes from the array, so the GUI "
        . "increment would grow it again and that cannot be undone.\n"
        . "Recover by rescanning this node: for each path above "
        . "'echo 1 > /sys/block/<sd>/device/rescan', then "
        . "'multipathd resize map %s'. Stopping and starting the guest, or "
        . "migrating it, also re-syncs the device. Once the device is right, "
        . "'qm rescan --vmid <id>' realigns the VM config, which is the half "
        . "a failed resize leaves behind - it reads the array and writes the "
        . "config, so it never grows anything.\n",
        $want, (defined $size ? "$size bytes" : 'unreadable'),
        $budget, $map, _path_sizes($dm), $rsum, $wwid), $opt{best_effort});
}

sub _resize_failed {
    my ($msg, $best_effort) = @_;
    die $msg if !$best_effort;
    warn $msg;
    return 0;
}

# ---- Naming --------------------------------------------------------------

# LOCAL PATCH (see UPSTREAM.md): one volname grammar for parse_volname,
# alloc_image and list_images, instead of enumerating disk-N and state-*.
#
# PVE core generates more shapes than the original enumeration: disk-<N>,
# state-<snap> (RAM snapshots), cloudinit, fleece-<N> (backup fleecing) — and
# the Kubernetes CSI driver adds pvc-<uuid>. All of them are just raw block
# LUNs to this plugin; the fsprefix, not the name shape, is what keeps foreign
# objects out of this storage.
#
# The generic arm deliberately has NO dot: our array snapshot objects are
# named "<volname>.<snap>" (_snap_name), so a snapshot of a disk can never
# round-trip through list_images as a phantom volume, whatever a firmware
# chooses to report in lsvdisk. Only the state- arm keeps dots, matching
# upstream's charset for PVE-supplied state names — the plugin never
# snapshots state volumes, so no plugin-created object matches that arm
# with a snapshot suffix appended.
#
# /a and \z are load-bearing: names come back from decode_json, which can
# hand us UTF-8-flagged strings. Without /a, \w and \d match Unicode
# lookalikes (fullwidth digits pass \d), and a plain $ anchor accepts a
# trailing newline — both would flow straight into REST URLs and volids.
our $VOLNAME_SUFFIX = qr/(?:state-[A-Za-z0-9][\w\-.]*|[A-Za-z0-9][\w\-]*)/a;

sub parse_volname {
    my ($class, $volname) = @_;
    # ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
    if ($volname =~ m/\A(vm-(\d+)-$VOLNAME_SUFFIX)\z/a) {
        return ('images', $1, $2, undef, undef, 0, 'raw');
    }
    die "flashsystem: unable to parse volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    die "flashsystem: snapshot paths are not addressable\n" if defined $snapname;
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $path = '/dev/mapper/' . _wwid($scfg, $volname, $storeid);
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

# ---- Allocation ----------------------------------------------------------

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;    # $size in KiB
    die "flashsystem: only raw volumes are supported (got '$fmt')\n" if $fmt ne 'raw';

    $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt) if !$name;
    # One grammar for every consumer — PVE's disk/state/cloudinit/fleece names
    # and the Kubernetes CSI driver's pvc-<uuid> names. See $VOLNAME_SUFFIX.
    die "flashsystem: illegal name '$name' for VM $vmid\n"
        if $name !~ m/\Avm-\Q$vmid\E-$VOLNAME_SUFFIX\z/a;

    # Storage Virtualize caps object names at 63 characters, and the fsprefix,
    # the volname and (later) a ".<snapshot>" suffix all share that budget.
    # Enforce the hard cap here, where the error is actionable — mkvdisk would
    # only fail with an opaque CMMVC error. Snapshot headroom is deliberately
    # NOT reserved: state and pvc volumes near the cap are still usable disks;
    # _snap_name enforces its own limit per snapshot attempt.
    my $aname = _arrayname($scfg, $name);
    die 'flashsystem: array object name \'' . $aname . '\' is ' . length($aname)
        . " chars (max 63): fsprefix '" . ($scfg->{fsprefix} // '')
        . "' + '-' + volname '$name' must fit in 63 - use a shorter fsprefix"
        . " for this storage (fixed at creation)\n"
        if length($aname) > 63;

    my $bytes = $size * 1024;    # KiB -> bytes
    _cmd($scfg, 'mkvdisk', undef, _mkvdisk_params($scfg, $aname, $bytes), storeid => $storeid);
    return $name;
}

# Build the mkvdisk parameter set. Factored out so the thin-provisioning
# shape is unit-testable without an array (tests/t_names.pl).
#
# LOCAL PATCH (see UPSTREAM.md): optional thin provisioning via `fsthin`.
# Bare mkvdisk creates FULLY ALLOCATED volumes — the full provisioned size is
# reserved in the pool at creation (confirmed live 2026-08-25), which also
# bypasses a data reduction pool's thin/dedup layer. `mkvdisk -rsize` is used
# rather than the newer mkvolume because it behaves the same on standard
# pools and DRPs — relevant since IBM is moving away from DRPs.
# Validated 2026-08-26 on a STANDARD pool (FlashSystem 5200, firmware
# 8.7.0.3): mkvdisk accepted rsize '2%', autoexpand as a JSON boolean and
# warning '80%'. A 100 GiB volume was created with 5 GiB real capacity, the
# array reported "Capacity savings: Thin-provisioned" at an 80% warning
# threshold, and real capacity grew ahead of the data on write — autoexpand
# confirmed working.
#
# ANSWERED 2026-09-07, and the answer is no: data reduction pools apply their
# own rules to space-efficient volumes, were NOT covered by the test above,
# and the array refused thin volumes when fsthin was enabled against four DRP
# -backed storages on a production cluster. It was reverted the same day. The
# standard-pool validation does NOT carry over to a DRP - so treat fsthin as
# a STANDARD-POOL feature until someone demonstrates otherwise. (IBM is
# moving away from DRPs, so the standard-pool path above is the
# strategically relevant one anyway.)
#
# This is also self-consistent with how a DRP already behaves: the pool does
# its own thin/dedup/compression, so a "fully allocated" vdisk in a DRP is
# not the straightforward waste it would be on a standard pool - and
# lssevdiskcopy reports blank capacity fields for space-efficient copies in a
# DRP, which is why the consumption view already skips those pools entirely.
# VALIDATE: thin means overcommit — have array-side physical-free alerting in
# place before enabling on pools shared with other workloads, and note IBM's
# hint that capacity reporting changes in 9.x firmware.
sub _mkvdisk_params {
    my ($scfg, $aname, $bytes) = @_;
    my $p = {
        name     => $aname,
        mdiskgrp => $scfg->{fspool},
        iogrp    => ($scfg->{fsiogrp} // 'io_grp0'),
        size     => $bytes,
        unit     => 'b',
    };
    if ($scfg->{fsthin}) {
        $p->{rsize}      = '2%';        # real capacity reserved up front
        $p->{autoexpand} = JSON::true;  # grow real capacity on demand
        $p->{warning}    = '80%';       # array event at 80% of virtual size
    }
    return $p;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    # Release this node's block device before removing the vdisk. deactivate_volume
    # normally did this already; repeat it for the direct `pvesm free` path (no VM
    # lifecycle) so we never leave stale SCSI devices behind to mask a future LUN.
    my $wwid = eval { _wwid($scfg, $volname, $storeid) };
    _flush_device($wwid) if $wwid;
    _unmap_volume($scfg, $volname, $storeid);
    _cmd($scfg, 'rmvdisk', _arrayname($scfg, $volname), {}, storeid => $storeid);
    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    my $vdisks = _cmd(
        $scfg, 'lsvdisk', undef,
        { filtervalue => "mdisk_grp_name=$scfg->{fspool}", bytes => JSON::true },
        storeid => $storeid,
    ) // [];

    my $res = [];
    foreach my $v (@$vdisks) {
        my $aname = $v->{name} // next;
        # Objects belonging to another storage sharing this pool (a different
        # fsprefix, or none) are not ours.
        my $name = _volname_from_array($scfg, $aname);
        next if !defined $name;
        # Report everything that parses as a PVE volume (disk, state,
        # cloudinit, fleece, pvc) — foreign objects were already dropped by
        # the prefix check above, and the dot-free grammar keeps our own
        # "<volname>.<snap>" snapshot objects out even if a firmware lists
        # them as vdisks.
        next if $name !~ m/\Avm-(\d+)-$VOLNAME_SUFFIX\z/a;
        my $owner = $1;
        my $volid = "$storeid:$name";
        if ($vollist) {
            next if !grep { $_ eq $volid } @$vollist;
        } elsif (defined $vmid) {
            next if $owner ne $vmid;
        }
        push @$res, {
            volid  => $volid,
            format => 'raw',
            size   => ($v->{capacity} // 0) + 0,
            vmid   => $owner,
        };
    }
    return $res;
}

# LOCAL PATCH (see UPSTREAM.md): report physical capacity when the pool has it.
#
# Data-reduction pools on self-compressing drives report `capacity` in
# EFFECTIVE terms — physical scaled by the drives' assumed compression ratio —
# while what can actually still be stored is bounded by physical_capacity /
# physical_free_capacity. The gap is not academic: on 2026-08-12 the Gold pool
# reported 44 TiB free effective with 4.1 TiB physically left, and a DRP that
# hits physical-full takes every volume in it offline. PVE's capacity bar is
# what people provision against, so it gets the conservative number.
# Provisioned-over-total is normal for PVE thin storages. Standard pools have
# no physical_* fields and keep upstream behaviour unchanged.
sub _pool_usage {
    my ($g) = @_;
    my $total = ($g->{capacity}      // 0) + 0;
    my $free  = ($g->{free_capacity} // 0) + 0;
    my $used  = ($g->{used_capacity} // ($total - $free)) + 0;
    my $ptotal = ($g->{physical_capacity}      // 0) + 0;
    my $pfree  = ($g->{physical_free_capacity} // 0) + 0;
    if ($ptotal > 0) {
        ($total, $free, $used) = ($ptotal, $pfree, $ptotal - $pfree);
    }
    return ($total, $free, $used, 1);
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    # pvestatd calls this every cycle; never let a slow/unreachable array stall
    # it. Bound the REST round-trip and report inactive on timeout/error rather
    # than blocking or dying.
    #
    # LOCAL PATCH (see UPSTREAM.md): cache the lsmdiskgrp result per
    # (array, pool) within one pvestatd cycle — several storages share a pool
    # (tier + k8s pairs), so 8 storages cost 4 REST calls instead of 8, and a
    # throttled or down array is probed once per cycle, not once per storage.
    # $cache lives for a single cycle, so the numbers stay fresh.
    $cache //= {};
    my $ckey = "flashsystem/$scfg->{fsaddress}/$scfg->{fspool}";
    if (!exists $cache->{$ckey}) {
        my $g = eval {
            local $SIG{ALRM} = sub { die "timeout\n"; };
            alarm 10;
            my $r = _one(_cmd($scfg, 'lsmdiskgrp', $scfg->{fspool}, { bytes => JSON::true }, storeid => $storeid));
            alarm 0;
            $r;
        };
        alarm 0;
        $cache->{$ckey} = ($@ || !$g) ? 0 : $g;    # cache the failure too
    }
    my $g = $cache->{$ckey} or return (0, 0, 0, 0);    # inactive, not a hang
    return _pool_usage($g);
}

# ---- Storage / volume activation ----------------------------------------

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    _auth($scfg, $storeid);    # fail fast if the array is unreachable / creds wrong
    return 1;
}

sub deactivate_storage { return 1; }

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    die "flashsystem: cannot activate a snapshot directly\n" if $snapname;

    _map_volume($scfg, $volname, $storeid);
    my $vdisk = _vdisk($scfg, $volname, $storeid);
    my $wwid  = _wwid_from_vdisk($vdisk);
    my $dev   = "/dev/mapper/$wwid";

    _rescan_scsi();
    run_command([ 'multipath', '-a', $wwid ], noerr => 1);    # whitelist the wwid
    run_command([ 'multipath' ],             noerr => 1);     # (re)assemble maps

    for my $try (1 .. 30) {
        last if -e $dev;
        run_command([ 'multipath' ], noerr => 1) if $try % 5 == 0;
        select(undef, undef, undef, 0.5);
    }
    if (!-e $dev) {
        # Failure-safe: don't leave a half-mapped orphan behind. With
        # queue_if_no_path, a mapped-but-pathless LUN makes host LVM scans
        # (vgs) hang - which is how a failed migrate wedged nodes before. Flush
        # this node's map + delete its paths before failing.
        _flush_device($wwid);
        die "flashsystem: $dev did not appear after mapping '$volname'\n";
    }

    # Re-sync capacity against the array. rescan-scsi-bus.sh -a -r and a plain
    # `multipath` handle discovery and map assembly; neither re-reads capacity
    # on a device that was already attached. Without this there is NO operator
    # gesture that repairs a device left behind by a resize whose host half
    # failed - the GUI sends only increments and qemu-server early-returns when
    # the absolute size already matches what the array reports. With it,
    # stopping and starting the guest, or migrating it, is the fix.
    #
    # Best effort on purpose: a capacity mismatch must never stop a VM from
    # starting, and the fast path here is a single sysfs read.
    eval { _resize_host_device($wwid, $vdisk->{capacity} + 0, best_effort => 1, budget => 0) };
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1 if $snapname;
    # The cluster-wide mapping stays until free_image; here we just release this
    # node's multipath map so the node cleanly detaches (RWO reattach elsewhere).
    my $wwid = eval { _wwid($scfg, $volname, $storeid) };
    return 1 if !$wwid;
    _flush_device($wwid);
    return 1;
}

# ---- Resize --------------------------------------------------------------

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;    # $size = new absolute, bytes
    # One lsvdisk for both the current size and the wwid. The array rate-limits
    # REST hard enough that a live 429 has been seen from ordinary polling.
    my $v = $class->_vdisk_or_die($scfg, $volname, $storeid);
    my $cur = $v->{capacity} + 0;
    die "flashsystem: shrinking is not supported ($cur -> $size)\n" if $size < $cur;

    my $delta = $size - $cur;
    # expandvdisksize adds the delta.
    _cmd($scfg, 'expandvdisksize', _arrayname($scfg, $volname), { size => $delta, unit => 'b' }, storeid => $storeid)
        if $delta > 0;

    # Deliberately NOT conditional on $delta, so that any caller arriving with
    # the array already at the target still gets the host half done. Note this
    # is a safety net rather than an operator-facing retry: PVE sizes from
    # volume_size_info (which this plugin answers from the array), and
    # qemu-server early-returns when the requested absolute size already
    # matches - so no GUI or `qm resize` gesture reaches here once the array
    # has grown. activate_volume is the path that actually recovers a device
    # left behind, which is why it propagates too.
    _resize_host_device(_wwid_from_vdisk($v), $size);
    return 1;
}

sub _vdisk_or_die { my ($class, $scfg, $volname, $storeid) = @_; return _vdisk($scfg, $volname, $storeid); }

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my $size = _vdisk($scfg, $volname, $storeid)->{capacity} + 0;
    return wantarray ? ($size, 'raw', $size, undef) : $size;
}

# ---- Snapshots (opt-in) --------------------------------------------------
# Uses the Storage Virtualize "Snapshot" function (addsnapshot / rmsnapshot /
# restorefromsnapshot), present on ~8.5.1+ (verified live on 8.7). We snapshot
# a single "loose" volume (no volume group), so rmsnapshot/restorefromsnapshot
# must identify it by system-wide snapshot ID — passing only the name is
# rejected (CMMVC5707E). _snapshot_id() resolves name -> ID via lsvolumesnapshot.
# On older arrays without this function, use FlashCopy instead. Disabled unless
# the storage is configured with `fssnapshots 1`.

sub _snap_name {
    my ($volname, $snap) = @_;
    my $n = "$volname.$snap";
    $n =~ s/[^A-Za-z0-9_.-]/_/g;    # array names: alnum . _ - only
    # 63 is the Storage Virtualize object-name limit. The fsprefix, the volume
    # name and the PVE snapshot name all share that budget.
    die "flashsystem: snapshot name '$n' too long (max 63)\n" if length($n) > 63;
    return $n;
}

# Resolve a loose-volume snapshot's system-wide ID from its (deterministic)
# name. Returns undef if not present (so delete can be idempotent).
sub _snapshot_id {
    my ($scfg, $volname, $snap, $storeid) = @_;
    my $sname = _snap_name(_arrayname($scfg, $volname), $snap);
    my $list = _cmd($scfg, 'lsvolumesnapshot', undef, {}, storeid => $storeid) // [];
    for my $s (@$list) {
        return $s->{snapshot_id} if ($s->{snapshot_name} // '') eq $sname;
    }
    return undef;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    die "flashsystem: snapshots disabled (set 'fssnapshots 1' after validating firmware)\n"
        if !$scfg->{fssnapshots};
    my $id = _vdisk($scfg, $volname, $storeid)->{id};
    _cmd($scfg, 'addsnapshot', undef,
        { name => _snap_name(_arrayname($scfg, $volname), $snap), volumes => $id }, storeid => $storeid);
    return undef;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};
    my $sid = _snapshot_id($scfg, $volname, $snap, $storeid);
    die "flashsystem: snapshot '$snap' for '$volname' not found\n" if !defined $sid;
    my $vid = _vdisk($scfg, $volname, $storeid)->{id};
    _cmd($scfg, 'restorefromsnapshot', undef,
        { snapshotid => $sid, volumes => $vid }, storeid => $storeid);
    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};
    my $sid = _snapshot_id($scfg, $volname, $snap, $storeid);
    return undef if !defined $sid;    # already gone -> idempotent
    _cmd($scfg, 'rmsnapshot', undef, { snapshotid => $sid }, storeid => $storeid);
    return undef;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;
    # snapshot: the array Snapshot function, only when enabled.
    return 1 if $feature eq 'snapshot' && !$snapname && $scfg->{fssnapshots};
    # copy: full clone. PVE copies the data itself through the block-device
    # path (qemu-img convert / drive-mirror); the plugin just supplies a fresh
    # target LUN via alloc_image. Not from a snapshot -- snapshots aren't
    # addressable as block devices (see path()).
    return 1 if $feature eq 'copy' && !$snapname;
    # NB: linked clones / templates ('clone', 'template') are intentionally
    # NOT advertised -- the plugin has no base-image (COW) support.
    return undef;
}

1;
