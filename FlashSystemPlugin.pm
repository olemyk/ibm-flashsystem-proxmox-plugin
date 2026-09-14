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
# volumes. Thin provisioning (fsthin) works on standard pools AND on data
# reduction pools; the DRP case needs one parameter omitted, see
# _mkvdisk_params. Clone-from-snapshot (clone_image) is implemented but NOT
# yet hardware-validated — tools/probe-clone-from-snapshot.sh answers every
# open question about it in one pass. Search this file for
# "VALIDATE:" for the remaining environment- and firmware-specific
# decisions to confirm on YOUR array before production.
# ---------------------------------------------------------------------------

use strict;
use warnings;

use Digest::SHA qw(sha256);
use POSIX ();
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
        fsthin    => { description => 'Thin-provision new volumes (mkvdisk -rsize 2% -autoexpand, plus -warning 80% on standard pools only). Affects new volumes only; existing ones keep their allocation.', type => 'boolean' },
        fsrestore => { description => 'Allow creating volumes FROM snapshots (mkvolume -fromsnapshotid). Default off: mkvolume is the one command family this plugin has never issued against an array. Run tools/probe-clone-from-snapshot.sh, then enable.', type => 'boolean' },
        fsreapsnapshots => { description => 'When deleting a volume the array refuses because it still has snapshots, DESTROY those snapshots and retry. Default off: a volume delete should not silently destroy recovery points.', type => 'boolean' },
        fsclonetype => { description => "Array volume type for clone-from-snapshot: 'thinclone' (instant, space-efficient, stays dependent on the source snapshot) or 'clone' (independent once a background copy finishes, consumes full capacity).", type => 'string', enum => [ 'thinclone', 'clone' ], default => 'thinclone' },
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
        fsclonetype => { optional => 1 },
        fsrestore   => { optional => 1 },
        fsreapsnapshots => { optional => 1 },
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
        # Was this token served from the cache, or minted just now? Only a
        # cached one can be stale, and that distinction is what keeps a real
        # authorization denial from being retried as an expiry.
        my $cached = exists $TOKENS{ $scfg->{fsaddress} };
        $res = $send->(_auth($scfg, $opt{storeid}));
        # Token expired -> re-auth once. BOTH codes, deliberately: the array
        # has been observed answering 401, but IBM's REST documentation says
        # an expired token surfaces as 403 ("Upon expiration, an error code of
        # 403 occurs that indicates the loss of authorization"), and the
        # documented lifetime is a MAXIMUM session (default 60 min,
        # configurable 10 min - 2 h), NOT an idle timeout — so polling cannot
        # keep a token warm past it. Whichever code this firmware returns, one
        # branch is dead code rather than a bug; handling only 401 would turn
        # an hourly token roll into a hard failure for a long-lived consumer.
        #
        # Gated on $cached because 403 is overloaded: Storage Virtualize also
        # returns it for a command the authenticated role may not run. Without
        # the gate, a rmvdisk storm against an under-privileged user would
        # re-auth on every call, and each re-auth deletes the %TOKENS entry
        # SHARED by every storage this process polls - so one wrong role turns
        # into 2x the request volume against a 3 req/s auth limit, and a
        # permission error presents as a throttling failure.
        if ($cached && ($res->code == 401 || $res->code == 403)) {
            my $first = $res;
            delete $TOKENS{ $scfg->{fsaddress} };
            $res = $send->(_auth($scfg, $opt{storeid}));
            # If a FRESH token gets the same answer, this was never expiry -
            # it is an authorization refusal (a role that may not run this
            # command), and the FIRST response carries the CMMVC that says so.
            # Reporting the retry's body instead would hide the real cause
            # behind a second identical 403.
            $res = $first if $res->code == 401 || $res->code == 403;
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

# Rows from lsvdiskhostmap, normalised.
#
# lsvdiskhostmap, and ONLY lsvdiskhostmap: it is the one we have watched work.
# A host-CLUSTER mapping renders there as one row per member host, so a
# correctly mapped volume on pmcl01 returns twelve (observed 2026-09-14).
#
# An earlier cut of this read-back used lsvolumehostclustermap. Against this
# array it returned something that was not a list of rows - what exactly was
# never established, and is NOT recorded here as "the command does not exist",
# because that was an inference from a parser crash and nothing more. Had it
# shipped, every map error would have died with "could not be read back",
# which is worse than the bug it replaced.
#
# The rule this file keeps relearning: build only on array behaviour that has
# been observed, and write down what was observed rather than what it implies.
sub _hostmap_rows {
    my ($scfg, $volname, $storeid) = @_;
    my $rows = _cmd($scfg, 'lsvdiskhostmap', _arrayname($scfg, $volname),
        {}, storeid => $storeid);
    $rows = [] if !defined $rows;
    $rows = [ $rows ] if ref($rows) eq 'HASH';
    return [] if ref($rows) ne 'ARRAY';
    return [ grep { ref($_) eq 'HASH' } @$rows ];
}

# Host names as the ARRAY knows them, for diagnostics only. Deliberately never
# used to decide anything: the array's host names match the PVE node names on
# this fleet by convention, not by guarantee, and a convention must not be able
# to fail an attach.
sub _hostmap_names {
    my ($rows) = @_;
    my @n = grep { defined && length } map { $_->{host_name} } @$rows;
    return @n ? join(',', @n) : '(none reported)';
}

sub _map_volume {
    my ($scfg, $volname, $storeid) = @_;
    my $aname = _arrayname($scfg, $volname);
    eval { _cmd($scfg, 'mkvolumehostclustermap', $aname,
        { hostcluster => $scfg->{fshostgroup} }, storeid => $storeid); };
    my $err = $@;
    return 1 if !$err;    # happy path: no read-back, no extra REST call

    # The old code matched the error text against a list of "already mapped"
    # codes and called anything matching a success. Three of those codes -
    # CMMVC6071E, CMMVC5879E, CMMVC6070E - are HOST-level, included on the guess
    # that "a firmware might report the host-cluster case with one of them".
    # A volume already mapped to an INDIVIDUAL host reports exactly those, and
    # that is a refusal, not a success: the LUN then reaches that one host and
    # no other, while every other node fails to attach with a message implying
    # a mapping happened.
    #
    # This is what happened on 2026-09-14, and the chain matters because the
    # obvious reading of it is wrong:
    #
    #   * the k8s node needing the volume (nosvgvik8sctrl03) runs on
    #     nosvgsmpm007, so activate_volume ran there - the right node.
    #   * the LUN had 8 paths on nosvgsmpm003, which hosts a DIFFERENT k8s node
    #     (ctrl02) and is a plausible home for the clone's source volume.
    #   * "8 paths on one node, none on eleven" does NOT by itself prove a
    #     host-scoped mapping, because only the node running activate_volume
    #     rescans - a correct cluster mapping looks the same until the others
    #     look. That reading was withdrawn once, correctly.
    #   * what settles it: nosvgsmpm007 looked exhaustively and found nothing -
    #     rescan-scsi-bus.sh -a -r, then -a -r -u, then a full wildcard
    #     "- - -" scan of every target and LUN, then a grep of every
    #     sd*/device/wwid. A host-CLUSTER mapping presents to all twelve at
    #     once, so 003 could not hold it while 007 searched that hard and came
    #     back empty.
    #
    # Host-scoped, therefore - exactly what a swallowed CMMVC6071E produces.
    # Asking what is true instead of parsing why the array said no is also
    # correct idempotency: an existing mapping reads as mapped regardless of
    # which code the firmware chose to report.
    my $rows = eval { _hostmap_rows($scfg, $volname, $storeid) };
    my $read_err = $@;

    # An unreadable array must not be read as "mapped" - but it must not be
    # read as "unmapped" either. Report both failures and let the caller's
    # device poll be the arbiter.
    if ($read_err) {
        warn "flashsystem: could not read back the host mapping for '$aname'"
            . " after a failed map; proceeding to the device poll.\n"
            . "  map: $err  read-back: $read_err";
        return 1;
    }

    # Rows present means SOMETHING is mapped. Deliberately not asserting that
    # this node is among them: the check would rest on array host names
    # matching PVE node names, and a naming convention must never be able to
    # fail an attach. activate_volume's device poll decides, and its failure
    # message carries this mapping so the answer is one read away.
    return 1 if @$rows;

    die "flashsystem: '$aname' is not mapped to anything. The host-cluster map"
        . " to '" . ($scfg->{fshostgroup} // '') . "' was refused and the array"
        . " reports no mapping of any kind, so no node can see this volume.\n"
        . "  array said: $err";
}

sub _unmap_volume {
    my ($scfg, $volname, $storeid) = @_;
    my $aname = _arrayname($scfg, $volname);
    eval { _cmd($scfg, 'rmvolumehostclustermap', $aname,
        { hostcluster => $scfg->{fshostgroup} }, storeid => $storeid); };
    my $err = $@;
    return 1 if !$err;    # happy path: no read-back, no extra REST call

    # Same principle as _map_volume, and for the same reason. The swallow list
    # here used to be /does not exist|not mapped|CMMVC5753E|CMMVC5842E|
    # CMMVC6071E/ - and it missed CMMVC9069E, "Volume does not have a shared
    # mapping to this host cluster", whose wording matches neither "does not
    # exist" nor "not mapped". So an ALREADY-UNMAPPED volume killed free_image,
    # and DeleteVolume failed for a volume that was already in the state we
    # wanted. Seen on pmcl01 2026-09-14, repeatedly, in the PVE task log.
    #
    # Enumerating one more code would just be the next guess. Ask the array
    # instead: if nothing is mapped, the unmap has achieved its purpose no
    # matter which code any firmware chose to report.
    my $rows = eval { _hostmap_rows($scfg, $volname, $storeid) };
    my $read_err = $@;

    # Unreadable: do NOT assume unmapped. free_image's rmvdisk is the backstop -
    # the array refuses to delete a mapped volume - so surfacing the original
    # error is safe and honest here.
    die $err if $read_err;
    return 1 if !@$rows;

    die "flashsystem: '$aname' is STILL mapped to " . scalar(@$rows)
        . " host(s) after rmvolumehostclustermap: " . _hostmap_names($rows)
        . "\n  array said: $err";
}

# ---- Host-side block device plumbing ------------------------------------

sub _rescan_scsi {
    # TWO passes, and neither replaces the other.
    #
    # 1. rescan-scsi-bus.sh -a -r -u, when sg3-utils is installed. It is the
    #    only one of the two that can REMOVE a LUN the array has stopped
    #    reporting (-r) or refresh one whose identity changed because the array
    #    RECYCLED the slot (-u). -u earned its place on 2026-09-14: it reported
    #    "8 remapped or resized device(s) found" at LUN 21, which -a -r had
    #    never surfaced. Note it then says "0 device(s) removed" - it flags the
    #    change and the refresh completes asynchronously, which is why
    #    activate_volume polls in tens of seconds rather than a handful.
    #
    # 2. A full FC-host scan, ALWAYS, even when the script ran. The script
    #    infers its LUN range from what the node ALREADY has, so a node that
    #    has never discovered a high LUN walks a handful, finds nothing, and
    #    honestly reports "0 new or changed device(s) found" while the LUN sits
    #    there presented and unseen.
    #
    #    Measured 2026-09-14: nosvgsmpm010 sat at maxLUN 3 with attaches
    #    failing and the array insisting the volume was mapped to all twelve
    #    hosts. One "- - -" to its FC hosts took it to maxLUN 22 INSTANTLY and
    #    the missing /dev/mapper/3<UID> appeared. That explained the entire
    #    failure pattern: attach worked on the three nodes hosting the k8s VMs
    #    - already discovered to LUN 22-24 through sheer activity - and failed
    #    on the nine that had not. Kubernetes schedules anywhere.
    #
    # fc_host ONLY, and that filter is load-bearing. A wildcard over every
    # /sys/class/scsi_host/host* reaches the local SAS controller (the HPE
    # Smart Array holding the ZFS mirror), where sas_user_scan blocks in
    # UNINTERRUPTIBLE D state while holding the SCSI scan mutex - it wedged
    # nosvgsmpm010 for 368+ seconds with two stacked unkillable tasks:
    #
    #   scsi_scan_target / scan_channel_zero [scsi_transport_sas]
    #   / sas_user_scan [scsi_transport_sas] / store_scan
    #
    # Over FC the identical scan returns instantly. The array is behind the
    # QLogic HBAs and nothing else, so scanning anything else is pure risk.
    if (run_command([ 'sh', '-c', 'command -v rescan-scsi-bus.sh >/dev/null 2>&1' ], noerr => 1) == 0) {
        run_command([ 'rescan-scsi-bus.sh', '-a', '-r', '-u' ], noerr => 1);
    }
    run_command([ 'sh', '-c',
        'for h in /sys/class/fc_host/host*; do'
        . ' [ -e "$h" ] || continue;'
        . ' echo "- - -" > "/sys/class/scsi_host/$(basename "$h")/scan" 2>/dev/null;'
        . ' done' ], noerr => 1);
    return 1;
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

    # Snapshot headroom is not RESERVED (see above), but when snapshots are
    # enabled it is worth saying at creation time that this volume will never
    # be able to take one - otherwise the first failure is a snapshot attempt
    # months later, and the fix (a shorter fsprefix) is fixed at creation.
    # Warn rather than die: an unsnapshottable disk is still a usable disk,
    # which is exactly why the headroom was never reserved.
    if ($scfg->{fssnapshots}) {
        my $headroom = 63 - length($aname) - 1;    # -1 for the '.' separator
        warn "flashsystem: '$aname' is " . length($aname) . " chars, leaving $headroom"
            . " for a snapshot name - snapshots of this volume will fail."
            . " Use a shorter fsprefix (fixed at storage creation).\n"
            if $headroom < 1;
    }

    my $bytes = $size * 1024;    # KiB -> bytes
    # One extra REST call, and only on the thin path: the thick path stays at
    # exactly one call, as it has always been.
    my $drp = $scfg->{fsthin} ? _pool_is_drp($scfg, $storeid) : 0;
    _cmd($scfg, 'mkvdisk', undef, _mkvdisk_params($scfg, $aname, $bytes, $drp), storeid => $storeid);
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
# ANSWERED 2026-09-07 on a DRP, and the answer is ONE PARAMETER, not the
# whole feature. Enabling fsthin against four DRP-backed storages failed
# every allocation with:
#
#   CMMVC9236E The pool specified is a data reduction pool. Volumes or
#   volume copies which are thin provisioned and created from a data
#   reduction pool can not use the -warning parameter.
#
# That is PARAMETER VALIDATION, not a capacity check: the 80% value is never
# evaluated, and it fails identically on an empty pool. "We are over 80%" is
# the obvious wrong inference from the error text. Of the three parameters
# this function adds, exactly one is illegal in a DRP:
#
#   -rsize       accepted, but its VALUE IS IGNORED in a DRP - only presence
#                or absence decides thin vs thick. So there is no 2%
#                contingency reserve in a DRP; keep it because dropping it
#                would silently produce THICK volumes with no error at all.
#   -autoexpand  not merely legal but REQUIRED for a thin/compressed volume
#                in a DRP - mkvdisk fails without it. Already set.
#   -warning     rejected outright (above). Omitted when $drp.
#
# Consequence worth knowing: a DRP thin volume therefore has NO per-volume
# capacity warning at all, and IBM's stated reason is that "the warning level
# value cannot be set because capacity reporting is handled at the pool
# level". Pool-layer alerting is not an adjacent nicety once fsthin is on -
# it is the entire alerting story. See UPSTREAM.md.
#
# $drp is passed IN rather than looked up here so this stays a pure function
# and tests/t_names.pl can cover it without an array. An undefined $drp is
# falsy, so pre-existing three-argument callers behave as a standard pool.
#
# VALIDATE: thin means overcommit — have array-side physical-free alerting in
# place before enabling on pools shared with other workloads, and note IBM's
# hint that capacity reporting changes in 9.x firmware.
sub _mkvdisk_params {
    my ($scfg, $aname, $bytes, $drp) = @_;
    my $p = {
        name     => $aname,
        mdiskgrp => $scfg->{fspool},
        iogrp    => ($scfg->{fsiogrp} // 'io_grp0'),
        size     => $bytes,
        unit     => 'b',
    };
    if ($scfg->{fsthin}) {
        $p->{rsize}      = '2%';        # presence = thin; value ignored in a DRP
        $p->{autoexpand} = JSON::true;  # required in a DRP, harmless elsewhere
        # Rejected on DRP thin volumes with CMMVC9236E - see above.
        $p->{warning}    = '80%' if !$drp;
    }
    return $p;
}

# Is fspool a data reduction pool? DRPs reject some space-efficient mkvdisk
# parameters that standard pools accept, so allocation has to know.
#
# lsmdiskgrp reports data_reduction as yes|no. Deliberately a separate call
# rather than threading status()'s per-cycle cache in here: allocation is
# rare, and that cache is scoped to one pvestatd cycle, so it would not be
# warm on the alloc path anyway.
#
# Returns 0 on any error, which matches upstream's standard-pool default. The
# cost of that choice is an honest one: a transient lsmdiskgrp failure makes
# the subsequent mkvdisk fail with CMMVC9236E instead — confusing, but not
# damaging, and it recovers on retry. The alternative (die with an actionable
# message) trades a self-healing failure for a hard one, so the fallback wins
# unless allocation errors turn out to be hard to trace in practice.
#
# Memoised for the life of the process, alongside %TOKENS. A pool's
# data_reduction attribute cannot change under a running node, and the caller
# is inside PVE::Storage::vdisk_alloc's cluster_lock_storage — so under CSI
# churn an un-memoised lookup adds a round-trip per PVC while holding that
# lock, and on a throttled array up to 7s of 429 backoff (1+2+4) with it.
# Deliberately NOT status()'s $cache, which is scoped to one pvestatd cycle
# and so would never be warm on the allocation path anyway. A failure is not
# cached: it is transient by assumption, and caching a 0 would pin the wrong
# parameter set until the daemon restarted.
my %DRP;    # "<address>/<pool>" -> 1|0
sub _pool_is_drp {
    my ($scfg, $storeid) = @_;
    my $key = "$scfg->{fsaddress}/$scfg->{fspool}";
    return $DRP{$key} if exists $DRP{$key};
    my $g = eval { _one(_cmd($scfg, 'lsmdiskgrp', $scfg->{fspool}, {}, storeid => $storeid)) };
    return 0 if !$g;
    return $DRP{$key} = (($g->{data_reduction} // '') eq 'yes') ? 1 : 0;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    # Release this node's block device before removing the vdisk. deactivate_volume
    # normally did this already; repeat it for the direct `pvesm free` path (no VM
    # lifecycle) so we never leave stale SCSI devices behind to mask a future LUN.
    # ALREADY GONE IS SUCCESS. CSI requires DeleteVolume to be idempotent, and
    # external-provisioner retries routinely - a lost or slow first response is
    # enough. Without this the retry dies (the array answers CMMVC5754E for
    # every command naming a volume that no longer exists, including the
    # mapping read-back in _unmap_volume) and the PVC sits in Terminating
    # forever. `pvesm free` on an already-deleted volume failed the same way.
    #
    # Fail CLOSED on anything else, exactly as csi_volume_from_snapshot does:
    # an unreachable array, a 401/403 or an exhausted 429 backoff must never be
    # read as "already deleted", or a live volume is reported destroyed and the
    # capacity leaks with nothing referencing it.
    my $vdisk = eval { _vdisk($scfg, $volname, $storeid) };
    if (!$vdisk) {
        my $err = $@;
        return undef if defined($err) && $err =~ /CMMVC5754E|\bnot found\b/i;
        die $err if $err;
        return undef;
    }
    my $wwid = eval { _wwid_from_vdisk($vdisk) };
    _flush_device($wwid) if $wwid;
    _unmap_volume($scfg, $volname, $storeid);

    # Delete FIRST, and only reap snapshots if that was refused.
    #
    # rmvdisk is issued with no -force, so a volume the array still considers
    # busy is REFUSED rather than destroyed. That is the safe direction, but it
    # strands the delete: `pvesm free` and the CSI DeleteVolume path both
    # arrive here and neither has anywhere to put the error except a task log.
    # Snapshots are the busy-ness this plugin creates, so this plugin clears
    # them - but ONLY once the array has said they are what is in the way.
    #
    # Order matters and the obvious order is wrong. Reaping first means an
    # irreversible rmsnapshot per snapshot, and then an rmvdisk that can still
    # fail for an unrelated reason (a host mapping this node did not create, a
    # CMMVC8957E volume-protection window). The caller is then left owning a
    # volume whose every recovery point has been destroyed, by a command they
    # asked to DELETE that volume. Delete-then-reap keeps the destructive step
    # conditional on the delete actually being blocked, and leaves the happy
    # path at exactly the one REST call it has always been.
    my $aname = _arrayname($scfg, $volname);
    eval { _cmd($scfg, 'rmvdisk', $aname, {}, storeid => $storeid) };
    my $err = $@;
    return undef if !$err;

    # Scoped to "<arrayname>.*" via _snapshots_for, with strict attribution,
    # and NEVER a broad sweep: the array's snapshot namespace is flat and
    # system-wide, so anything this plugin cannot positively tie to this volume
    # belongs to someone else. Deliberately not gated on fssnapshots - that
    # flag governs whether snapshots may be CREATED, and objects created while
    # it was on still have to be cleanable after it is turned off.
    # OPT-IN, default off. Reaping here is destructive and the request that
    # triggers it says "delete this volume", not "delete its recovery points":
    # a CSI DeleteVolume from `kubectl delete pvc` reaches exactly this code.
    # Letting the rmvdisk refusal propagate is the safer default - a failed
    # DeleteVolume is retried by external-provisioner and shows up in PVC
    # events, whereas a silent reap shows up nowhere and cannot be undone.
    die $err if !$scfg->{fsreapsnapshots};

    my $snaps = eval { _snapshots_for($scfg, $volname, $storeid, strict => 1) };
    die $err if !defined $snaps || !@$snaps;    # nothing to clear -> the original error stands

    for my $s (@$snaps) {
        eval { _cmd($scfg, 'rmsnapshot', undef, { snapshotid => $s->{id} }, storeid => $storeid) };
        warn "flashsystem: could not remove snapshot '$s->{name}' while deleting"
            . " '$volname': $@" if $@;
    }

    # One retry. If it still refuses, the original error is the informative
    # one - it names what the array objected to before anything was touched.
    eval { _cmd($scfg, 'rmvdisk', $aname, {}, storeid => $storeid) };
    if ($@) {
        die "flashsystem: '$volname' could not be deleted. First attempt: $err"
            . "After clearing " . scalar(@$snaps) . " snapshot(s), retry: $@";
    }
    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    my $vdisks = _cmd(
        $scfg, 'lsvdisk', undef,
        { filtervalue => "mdisk_grp_name=$scfg->{fspool}", bytes => JSON::true },
        storeid => $storeid,
    );
    # Normalise the shape, for the same reason _one() exists: this array family
    # answers some single-object queries with a bare object instead of a
    # one-element array. A pool holding exactly ONE volume is the case that
    # would hit it here, and the symptom was a hard "Not an ARRAY reference"
    # out of `pvesm list`. Defensive rather than observed - an arrayref, the
    # normal answer, passes through untouched.
    $vdisks = [] if !defined $vdisks;
    $vdisks = [ $vdisks ] if ref($vdisks) eq 'HASH';
    return [] if ref($vdisks) ne 'ARRAY';

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

    # 120 x 0.5s = 60s, not the 15s this used to allow.
    #
    # Measured on pmcl01 2026-09-14, attaching a fresh clone to VM 164 on
    # nosvgsmpm003. The array had RECYCLED LUN 21, so rescan-scsi-bus.sh -u
    # reported 8 remapped devices - and refreshing them is ASYNCHRONOUS. The
    # first attach ran the rescan, whitelisted the wwid, polled its 15s, found
    # nothing and failed. The attacher retried 2 seconds later; that attempt
    # discovered NOTHING NEW ("0 new, 0 remapped, 0 removed") and succeeded,
    # because udev and multipath had finished settling in the meantime.
    #
    # So the device was always coming - the budget was just too small. On a node
    # carrying hundreds of SCSI devices the rescan alone takes ~14s and
    # udevadm settle is explicitly "can take a while". 15s left nothing for the
    # part that actually matters.
    #
    # A second rescan partway through, because a recycled LUN sometimes needs
    # one: the first pass notices the identity changed, the second finds the
    # settled device. It costs ~14s and only runs when the fast path has
    # already failed, so a normal attach never pays for it.
    my $rescanned_again = 0;
    for my $try (1 .. 120) {
        last if -e $dev;
        run_command([ 'multipath' ], noerr => 1) if $try % 5 == 0;
        if ($try == 40 && !$rescanned_again) {
            $rescanned_again = 1;
            _rescan_scsi();
            run_command([ 'multipath', '-a', $wwid ], noerr => 1);
            run_command([ 'multipath' ], noerr => 1);
        }
        select(undef, undef, undef, 0.5);
    }
    if (!-e $dev) {
        # Name the mapping in the failure. "did not appear after mapping"
        # implies a mapping happened and says nothing about WHERE - which cost
        # a long afternoon on 2026-09-14, when the volume was mapped to exactly
        # one host and the node waiting for it was a different one.
        my $rows = eval { _hostmap_rows($scfg, $volname, $storeid) } // [];
        my $where = @$rows
            ? scalar(@$rows) . " host(s): " . _hostmap_names($rows)
            : "NOTHING - the array reports no host mapping for this volume";
        warn "flashsystem: '$volname' is mapped to $where; this node is "
            . (eval { (POSIX::uname())[1] } // '?') . ".\n";
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

# Every snapshot object belonging to ONE volume, as [{id, name}, ...].
#
# lsvolumesnapshot is system-wide and unfiltered, so this list contains the
# whole VM estate's snapshots and anything else sharing the array. Scoping is
# done here, once, by the two facts that make it safe:
#   - our snapshot names are "<arrayname>.<snap>" by construction
#     (_snap_name), so the source volume is a literal prefix of the name;
#   - lsvolumesnapshot reports volume_name, so the association can be
#     cross-checked rather than inferred from the name alone.
#
# -filtervalue is deliberately NOT used: it is documented for lsvolumesnapshot
# but this plugin has only ever proved it works for lsvdisk, and a filter that
# is silently ignored would look identical to one that worked. Scope
# client-side until someone confirms the accepted attribute list on this
# firmware (`lsvolumesnapshot -filtervalue?`).
# $strict changes what an UNATTRIBUTABLE row does, and the two callers want
# opposite things:
#
#   strict = 0 (read paths: _snapshot_id, volume_rollback_is_possible)
#       a row with no volume_name is accepted on the name prefix alone, so
#       a firmware that omits the field still works.
#   strict = 1 (the destructive path: free_image)
#       volume_name must be PRESENT and equal. Anything this plugin cannot
#       positively attribute to this volume is skipped with a warning rather
#       than fed to rmsnapshot. Failing open is fine for a lookup and not
#       fine for a delete.
#
# Returns [{ id, name, row }, ...]; `row` is the raw lsvolumesnapshot record,
# so a caller needing another field reads it from the SAME row this scoping
# selected instead of re-scanning and re-deciding.
sub _snapshots_for {
    my ($scfg, $volname, $storeid, %opt) = @_;
    my $aname = _arrayname($scfg, $volname);
    my $list = _cmd($scfg, 'lsvolumesnapshot', undef, {}, storeid => $storeid);
    # Normalise, for the same reason _one() exists: some firmwares answer with
    # a bare object rather than a one-element array.
    $list = [] if !defined $list;
    $list = [ $list ] if ref($list) eq 'HASH';
    return [] if ref($list) ne 'ARRAY';

    my $res = [];
    for my $s (@$list) {
        next if ref($s) ne 'HASH';
        my $sname = $s->{snapshot_name};
        next if !defined $sname || !length $sname;
        # The '.' is load-bearing: without it "vm-9999-pvc-a" would also
        # match every snapshot of "vm-9999-pvc-aa".
        next if index($sname, "$aname.") != 0;
        # Names are NOT system-unique on Storage Virtualize - which is exactly
        # why rmsnapshot offers -parentuid and -volumegroup as alternatives to
        # a bare name - so a name match alone is not proof of association.
        my $vn = $s->{volume_name};
        # any_owner: match on the NAME alone, ignoring attribution. Only for
        # callers that need to distinguish "the array has no such row" from
        # "the array has one it attributes elsewhere" - never for anything
        # that then acts on the row.
        if (!defined $vn || !length $vn) {
            if ($opt{strict} && !$opt{any_owner}) {
                warn "flashsystem: skipping snapshot '$sname': the array did not report"
                    . " volume_name, so it cannot be attributed to '$aname'\n";
                next;
            }
        } elsif ($vn ne $aname && !$opt{any_owner}) {
            next;
        }
        push @$res, { id => $s->{snapshot_id}, name => $sname, row => $s };
    }
    return $res;
}

# Resolve a loose-volume snapshot's system-wide ID from its (deterministic)
# name. Returns undef if not present (so delete can be idempotent).
#
# NB the ID is derived, never stored: the NAME is the durable identity here
# and the ID is whatever the array currently calls it. Any consumer that
# persists one of the two should persist the name.
sub _snapshot_id {
    my ($scfg, $volname, $snap, $storeid) = @_;
    my $sname = _snap_name(_arrayname($scfg, $volname), $snap);
    for my $s (@{ _snapshots_for($scfg, $volname, $storeid) }) {
        return $s->{id} if $s->{name} eq $sname;
    }
    return undef;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    die "flashsystem: snapshots disabled (set 'fssnapshots 1' after validating firmware)\n"
        if !$scfg->{fssnapshots};
    # Keep the two namespaces disjoint from BOTH ends. _csi_snap_component
    # mints a leading digit precisely because pve-snapshot-name cannot, so this
    # is unreachable through `qm snapshot` today -- it is here so the invariant
    # is enforced locally rather than inherited from a PVE schema that could
    # change under us, and so a caller reaching the plugin by another route
    # cannot mint a PVE snapshot into the CSI namespace.
    die "flashsystem: snapshot name '$snap' is reserved for CSI snapshots\n"
        if defined $snap && $snap =~ /\A[2-7][a-z2-7]{8}\z/;
    my $id = _vdisk($scfg, $volname, $storeid)->{id};
    _cmd($scfg, 'addsnapshot', undef,
        { name => _snap_name(_arrayname($scfg, $volname), $snap), volumes => $id }, storeid => $storeid);
    return undef;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};
    # The ROW, not just the id: _snapshot_id discards `state`, and this is the
    # DESTRUCTIVE action - restorefromsnapshot overwrites the volume's contents
    # without deleting any object, so it trips no capacity or object-count
    # monitoring. volume_rollback_is_possible checks the same thing, and this
    # repeats it deliberately: PVE calls the guard first, but a caller reaching
    # the plugin directly does not, and this one cannot be un-done.
    # strict => 1 as well, because the id resolved here is what gets restored.
    my $sname = _snap_name(_arrayname($scfg, $volname), $snap);
    my ($found) = grep { $_->{name} eq $sname }
        @{ _snapshots_for($scfg, $volname, $storeid, strict => 1) };
    die "flashsystem: snapshot '$snap' for '$volname' not found\n" if !$found;
    _assert_snap_active($found->{row}{state}, $snap, 'restore');
    my $sid = $found->{id};
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

# ---- Clone from snapshot -------------------------------------------------
#
# The one array-side primitive this plugin did not have. `mkvolume` — NOT
# mkvdisk, which is what every other allocation here uses — is the command
# that pre-populates a NEW volume from an EXISTING snapshot:
#
#   mkvolume -type thinclone|clone -pool <pool> \
#            -fromsourcevolume <source vdisk> -fromsnapshotid <id> \
#            -name <new vdisk> -iogrp <grp>
#
# Two properties make this fit the existing design with no other change.
# `-name` is the caller's choice (1-63 alphanumeric), so the derived volume
# can be given a conforming PVE volname directly; and list_images()
# enumerates the ARRAY rather than any local metadata, so a volume created
# this way appears in `pvesm list` with nothing to update. There is no
# -size on this form: the snapshot's capacity decides it, and PVE sizes the
# result from volume_size_info, which this plugin answers from the array.
#
# The volume-group variant (mkvolumegroup -type clone -fromsnapshotid) is the
# wrong command here: it names only the GROUP, not its member volumes, so the
# derived vdisks cannot be made to match the grammar list_images keys on.
#
# thinclone vs clone is a real trade rather than two speeds of one thing,
# which is why it is a per-storage option (fsclonetype) and not a constant:
#
#   thinclone  instant, near-zero capacity, and dependent on the source
#              snapshot for its whole life - removing that snapshot is
#              DEFERRED into `dependent_deleting` rather than freeing space.
#              The default, because these pools are data reduction pools that
#              thin-provision anyway, and because the alternative writes a
#              full copy into pools already at 78-80% PHYSICAL.
#   clone      independent once a background copy completes. IBM's default
#              copy rate is 2 MB/s - hours for a large volume. Whether the
#              volume reads correctly BEFORE that finishes is NOT answered by
#              the probe script (it needs a scratch VM to attach the clone);
#              the probe reports the population rate, and the read test is
#              the follow-up its Summary block spells out.
#
# A thinclone is not a dead end: volume-group membership is mutable, so
# `chvdisk -volumegroup` then `converttoclone` then `chvdisk -novolumegroup`
# promotes one to independent without this plugin having to own volume groups.
#
# VALIDATE: NOT yet run against hardware. mkvolume is the one command family
# this plugin has never issued, and it was deliberately avoided for
# allocation (see _mkvdisk_params). Every documented DRP restriction on
# mkvolume concerns parameters this call does not pass (-warning,
# -noautoexpand, -grainsize), but "documented as unrestricted" is not
# "observed working" - the -warning rejection above is precisely what that
# distinction costs. Run tools/probe-clone-from-snapshot.sh first.
# The die is a backstop for a hand-edited storage.cfg. properties() declares
# an enum, and PVE::JSONSchema enforces it, so `pvesm set --fsclonetype junk`
# is already rejected before it reaches the plugin.
sub _clone_type {
    my ($scfg) = @_;
    my $t = $scfg->{fsclonetype} // 'thinclone';
    die "flashsystem: invalid fsclonetype '$t' (want 'thinclone' or 'clone')\n"
        if $t ne 'thinclone' && $t ne 'clone';
    return $t;
}

# Factored out so the parameter shape is unit-testable without an array
# (tests/t_names.pl), exactly as _mkvdisk_params is.
# NB no -iogrp, deliberately, and unlike _mkvdisk_params. IBM's documented
# default for both clone types is the SOURCE VOLUME's I/O group, and a
# thin-clone is constrained to it - so sending $scfg->{fsiogrp} would at best
# restate the default and at worst conflict with it, since fsiogrp is not a
# fixed option and can be changed after volumes already exist. Omitting it is
# simpler AND strictly safer than passing a value that can disagree.
sub _mkvolume_clone_params {
    my ($scfg, $src_aname, $new_aname, $snapshot_id) = @_;
    return {
        type             => _clone_type($scfg),
        pool             => $scfg->{fspool},
        fromsourcevolume => $src_aname,
        fromsnapshotid   => $snapshot_id,
        name             => $new_aname,
    };
}

# PVE's clone hook. Called as clone_image($scfg, $storeid, $volname, $vmid,
# $snap) and expected to return the NEW volname, which PVE then treats as an
# ordinary volume on this storage - so activate_volume, path() and the FC
# attach path all take over unchanged from here.
#
# Reachable today with no Kubernetes and no CSI work at all, which makes this
# the cheapest possible end-to-end test of the restore path:
#
#   qm snapshot <vmid> s1
#   qm clone <vmid> <newvmid> --snapshot s1 --full 0
#
# `--full 0` is REQUIRED and is easy to get wrong. For a non-template VM
# qemu-server defaults $full to !is_template($conf), i.e. a FULL clone, and a
# full clone never calls this hook - it dies first with "Full clone feature is
# not supported for a snapshot of ...". Note also that PVE refuses --storage
# and --format alongside --full 0, and that the web UI's Clone dialog offers
# Linked Clone only for templates, so this path is CLI-only today.
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;
    die "flashsystem: snapshots disabled (set 'fssnapshots 1' after validating firmware)\n"
        if !$scfg->{fssnapshots};
    # The SECOND mkvolume call site, and it needs the same gate as the first.
    # Gating only csi_volume_from_snapshot left `qm clone <vmid> <new>
    # --snapshot <s> --full 0` issuing the never-validated mkvolume with
    # fsrestore at its default -- while properties(), the CHANGELOG and
    # csi/README all promise that flag is what prevents exactly this.
    die "flashsystem: restore-from-snapshot is disabled on '$storeid'."
        . " mkvolume has not been validated on this array - run"
        . " tools/probe-clone-from-snapshot.sh, then set 'fsrestore 1'.\n"
        if !$scfg->{fsrestore};
    # Only the from-snapshot form exists. A linked clone off a base image
    # needs COW semantics this plugin does not have, and volume_has_feature
    # advertises accordingly - so this is a guard against a caller that
    # ignored the advertisement, not a reachable path.
    die "flashsystem: clone requires a snapshot (no base-image/template support)\n"
        if !defined $snap || !length $snap;

    # The ROW, not just the id: _snapshot_id discards `state`, so this path
    # (PVE's own `qm clone <vmid> <new> --snapshot <s> --full 0`) issued
    # mkvolume -fromsnapshotid against a snapshot with no maintained image.
    # strict => 1 too: the id resolved here becomes -fromsnapshotid, and
    # cloning the wrong snapshot serves another volume's data with no error.
    my $sname = _snap_name(_arrayname($scfg, $volname), $snap);
    my ($found) = grep { $_->{name} eq $sname }
        @{ _snapshots_for($scfg, $volname, $storeid, strict => 1) };
    die "flashsystem: snapshot '$snap' for '$volname' not found\n" if !$found;
    _assert_snap_active($found->{row}{state}, $snap, 'clone from');
    my $sid = $found->{id};

    my $name = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');
    my $new_aname = _arrayname($scfg, $name);
    # Same hard cap, same actionable error as alloc_image: mkvolume would
    # otherwise fail with an opaque CMMVC.
    die 'flashsystem: array object name \'' . $new_aname . '\' is ' . length($new_aname)
        . " chars (max 63): use a shorter fsprefix for this storage"
        . " (fixed at creation)\n"
        if length($new_aname) > 63;

    _cmd($scfg, 'mkvolume', undef,
        _mkvolume_clone_params($scfg, _arrayname($scfg, $volname), $new_aname, $sid),
        storeid => $storeid);
    return $name;
}

# Whether PVE may roll this volume back to $snapname.
#
# Overridden deliberately. The inherited default is an unconditional yes, and
# restorefromsnapshot is the one operation here that destroys data without
# deleting an object - so it trips no capacity or object-count monitoring and
# leaves no trace to reconcile against.
#
# Two refusals, both cheap:
#
#   1. A volume expanded since the snapshot was taken. The array refuses the
#      restore itself ("the volumes being restored must be the same virtual
#      capacity as when the snapshot was added"), but it exposes
#      volume_size_mismatch on the snapshot so the refusal can be an
#      actionable message instead of a CMMVC. This matters more than it
#      looks: allowVolumeExpansion is enabled on every Kubernetes tier here,
#      so an ordinary PVC resize silently invalidates rollback for every
#      snapshot that volume already had.
#   2. Snapshots are disabled, in which case there is nothing to roll back to.
#
# What this does NOT try to check is whether a guest is using the volume.
# That guard is unimplementable at this layer: the host-cluster mapping is
# created once and kept until free_image (see deactivate_volume), so a
# mapping-based test would refuse always. PVE's own rollback path stops the
# VM first and dies if it is still running, and THAT is the safety contract
# this plugin relies on - which is exactly why an automated caller outside
# PVE's guest lifecycle must not drive rollback.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snapname, $blockers) = @_;
    $blockers //= [];    # the base class does the same; callers may omit it
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};

    my $sname = _snap_name(_arrayname($scfg, $volname), $snapname);

    # Resolve through the SAME scoped lookup volume_snapshot_rollback will use,
    # so the guard and the action cannot decide about different objects. An
    # earlier cut re-implemented the scan inline and matched on snapshot_name
    # alone, which meant a foreign row sharing that name could satisfy the
    # guard while the rollback then acted on ours (or the reverse).
    my $snaps = eval { _snapshots_for($scfg, $volname, $storeid) };

    # A guard that cannot read the array must REFUSE, not permit. `// []` here
    # would fold every REST failure - unreachable array, exhausted 429 backoff,
    # a token roll landing on 403 - into "no rows", and no rows means no match,
    # which would fall through to a confident yes.
    die "flashsystem: cannot verify rollback safety for '$volname': $@" if !defined $snaps;

    my ($found) = grep { $_->{name} eq $sname } @$snaps;
    if (!$found) {
        push @$blockers, $snapname;
        die "flashsystem: snapshot '$snapname' for '$volname' not found\n";
    }

    # The array refuses a restore when the volume's virtual capacity has
    # changed since the snapshot was taken ("the volumes being restored must
    # be the same virtual capacity as when the snapshot was added"), and
    # reports it as volume_size_mismatch. Worth catching here because the
    # array's own refusal is an opaque CMMVC, and because allowVolumeExpansion
    # is enabled on every Kubernetes tier - so an ordinary PVC resize
    # invalidates rollback for every snapshot that volume already had.
    #
    # VALIDATE: whether volume_size_mismatch appears in the UNFILTERED
    # lsvolumesnapshot listing, or only in the detailed per-id view. If it is
    # detail-only this is silently permissive, which is why an absent field is
    # treated as unknown-and-refuse rather than as 'no'. The probe script dumps
    # a raw row so this can be settled and the branch simplified.
    # restorefromsnapshot against a snapshot the array is not maintaining an
    # image for destroys the volume's contents without deleting any object, so
    # it trips no capacity or object-count monitoring. Same unknown-and-refuse
    # rule as volume_size_mismatch below: only 'active' is a maintained image.
    my $st = $found->{row}{state};
    if (!_snap_is_ready($st)) {
        push @$blockers, $snapname;
        die "flashsystem: cannot roll '$volname' back to '$snapname': the array reports"
            . " state '" . (defined $st && length $st ? $st : 'unknown') . "', not"
            . " 'active', so there is no point-in-time image to restore from.\n";
    }

    my $mm = $found->{row}{volume_size_mismatch};
    if (!defined $mm || !length $mm) {
        die "flashsystem: cannot determine whether '$volname' still matches the capacity"
            . " it had at snapshot '$snapname' (the array did not report"
            . " volume_size_mismatch). Refusing rather than guessing; clone the snapshot"
            . " to a new volume instead.\n";
    }
    if ($mm eq 'yes') {
        push @$blockers, $snapname;
        die "flashsystem: cannot roll '$volname' back to '$snapname': the volume has been"
            . " resized since the snapshot was taken, and the array requires the same"
            . " virtual capacity. Clone the snapshot to a new volume instead.\n";
    }
    return 1;
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
    # clone: ONLY from a snapshot, and only when snapshots are on. The array
    # does the population (mkvolume -fromsnapshotid, see clone_image), so this
    # is a real new LUN rather than a COW overlay.
    #
    # Note the deliberate asymmetry with 'copy' above, which requires
    # !$snapname: a snapshot is not addressable as a block device (path()
    # refuses it, and so does activate_volume), so PVE cannot read one to copy
    # it. Cloning is the array-side path to the same outcome, and it is the
    # only one available from a snapshot.
    # $running is deliberately ignored. The array populates the clone from a
    # point-in-time snapshot, not from the live volume, so a running guest on
    # the SOURCE cannot affect the result - which is the whole reason to do
    # this array-side rather than through a copy.
    # fsrestore as well as fssnapshots: advertising a feature the plugin then
    # refuses makes PVE offer the operation and fail inside the hook. With the
    # gate closed qemu-server's own volume_has_feature check refuses first,
    # which is the clean refusal.
    return 1 if $feature eq 'clone' && $snapname && $scfg->{fssnapshots} && $scfg->{fsrestore};
    # NB: base images / templates ('template', and 'clone' WITHOUT a snapshot)
    # are still intentionally NOT advertised -- the plugin has no base-image
    # (COW) support, and a "template" here would just be a renamed volume.
    return undef;
}

# ---- CSI snapshot surface -------------------------------------------------
#
# These four entry points exist so a Kubernetes CSI driver can drive array
# snapshots WITHOUT holding array credentials. They are called from
# PVE::API2::FlashSystem over the ordinary PVE API, authenticated with the
# driver's existing PVE token and authorised per-storage by a PVE ACL - which
# is dramatically more scopeable than any Storage Virtualize role, and keeps
# both the array password and `fsprefix` on this side of the boundary.
#
# They are class methods rather than plugin hooks because PVE's storage API has
# no per-volume snapshot verb to hang them on: every snapshot endpoint PVE
# exposes is VM-scoped, with no disk selector.

# The array-side snapshot NAME is the durable identity here; the numeric id is
# a derived lookup result (see _snapshot_id). CSI needs the reverse of what the
# array offers, so the naming has to carry three properties at once:
#
#   deterministic  CSI CreateSnapshot is idempotent BY NAME. A retry must
#                  recompute the same array object, or every timeout leaves a
#                  duplicate snapshot behind and the caller never learns.
#   short          it lives in _snap_name's budget: 63 - len(fsprefix) - 1 -
#                  len(volname) - 1. On a 4-char prefix with the 48-char CSI
#                  volname that is exactly NINE characters. A CSI snapshot name
#                  is `snapshot-<uuid>` at 45, so it cannot be used directly.
#   collidable-
#   detectably     nine characters cannot be collision-free, so the scheme must
#                  make a collision VISIBLE rather than silent - see below.
#
# base32 (RFC4648 lowercase, no padding) over the top 45 bits of a SHA-256 of
# the CSI name: 9 characters, 45 bits, alphabet a-z2-7 which is entirely inside
# _snap_name's [A-Za-z0-9_.-] so nothing is sanitised away. Collision
# probability within ONE volume - the scope that governs, since the digest sits
# under `<vdisk>.` - is ~1.4e-8 at a thousand snapshots of that volume.
#
# Hex was the obvious alternative and is worse: 9 hex chars is 36 bits, 512x
# more collisions for no benefit.
sub _csi_snap_component {
    my ($csi_name) = @_;
    die "flashsystem: empty CSI snapshot name\n" if !defined $csi_name || !length $csi_name;
    my @al = split //, 'abcdefghijklmnopqrstuvwxyz234567';
    # 48 bits from the first six digest bytes, then drop the low 3 so exactly
    # 45 are consumed.
    my $v = 0;
    $v = ($v << 8) | $_ for unpack('C6', sha256($csi_name));
    $v >>= 3;
    # The FIRST symbol is a digit, and that is load-bearing rather than
    # cosmetic. A shape check alone does not separate our snapshots from PVE's:
    # `pve-snapshot-name` is /^[a-z][a-z0-9_-]+$/i, so an operator's own
    # `qm snapshot <vm> preupdate` produces a 9-character component inside
    # [a-z2-7] and used to parse as one of ours -- after which csi_snapshot_list
    # reported their rollback point to Kubernetes as a leaked CSI orphan and
    # csi_snapshot_delete rmsnapshot'ed it. Every PVE snapshot name must start
    # with a LETTER, so minting ours with a leading DIGIT makes the two
    # namespaces structurally disjoint instead of merely unlikely to collide.
    # Costs 2.4 bits of the 45 (six leading symbols instead of 32).
    my $s = '';
    for (1 .. 8) { $s = $al[ $v & 31 ] . $s; $v >>= 5; }
    return substr('234567', $v % 6, 1) . $s;
}

# CSI CreateSnapshot. Idempotent by $csi_name, and REFUSES rather than
# silently aliasing when the derived component already belongs to a different
# volume - which is the failure this whole scheme has to defend against. A
# truncated digest that collided and was treated as "already exists" would
# return a handle pointing at ANOTHER PVC's snapshot, and the caller would
# restore someone else's data with no error anywhere. The gRPC contract for
# that case is ALREADY_EXISTS, so the message is tagged for the driver to map.
sub csi_snapshot_create {
    my ($class, $scfg, $storeid, $volname, $csi_name) = @_;
    die "flashsystem: snapshots disabled (set 'fssnapshots 1')\n" if !$scfg->{fssnapshots};
    $class->parse_volname($volname);    # reject anything not ours, before the array

    my $comp  = _csi_snap_component($csi_name);
    my $aname = _arrayname($scfg, $volname);
    my $sname = _snap_name($aname, $comp);    # enforces the 63-char cap

    # Cross-volume collision check FIRST, over the same system-wide listing the
    # idempotency probe needs anyway, so this costs no extra REST call.
    my $list = _cmd($scfg, 'lsvolumesnapshot', undef, {}, storeid => $storeid);
    $list = [] if !defined $list;
    $list = [ $list ] if ref($list) eq 'HASH';
    my $existing;
    for my $r (@$list) {
        next if ref($r) ne 'HASH';
        my $n = $r->{snapshot_name};
        next if !defined $n || !length $n;
        if ($n eq $sname) {
            # Cross-check before accepting this as a replay. Snapshot names are
            # NOT system-unique on Storage Virtualize, and every other reader in
            # this file applies this check. Without it, a same-named row
            # belonging to another volume would be returned as "already
            # created" - so CreateSnapshot would report success for a snapshot
            # that was never cut, and hand back a handle to someone else's.
            my $rvn = $r->{volume_name};
            if (!defined $rvn || !length $rvn || $rvn eq $aname) {
                $existing = $r;
            } else {
                die "flashsystem: ALREADY_EXISTS: array snapshot '$sname' already exists"
                    . " and belongs to volume '$rvn', not '$aname'\n";
            }
            next;
        }
        # Same digest under a different volume: report it rather than alias.
        next if $n !~ /\A(.+)\.\Q$comp\E\z/;
        die "flashsystem: ALREADY_EXISTS: CSI snapshot name '$csi_name' maps to array"
            . " component '.$comp', which is already in use by volume '$1'. Refusing to"
            . " alias two snapshots onto one array object.\n";
    }

    my $vdisk = _vdisk($scfg, $volname, $storeid);
    if (!$existing) {
        # addsnapshot returns the new id in its body on firmwares that report
        # it; the read-back below is authoritative either way, so the response
        # is not trusted for anything destructive.
        _cmd($scfg, 'addsnapshot', undef, { name => $sname, volumes => $vdisk->{id} },
            storeid => $storeid);
        # strict => 1, matching the DELETE path. csi_snapshot_delete resolves
        # strictly, so a firmware that omits volume_name would let every create
        # succeed and every delete fail permanently - snapshots accumulating
        # physical capacity with no way to remove them through this plugin.
        # Failing here instead makes that firmware visible on the first
        # snapshot, when external-snapshotter is still retrying and nothing has
        # been leaked.
        my ($found) = grep { $_->{name} eq $sname }
            @{ _snapshots_for($scfg, $volname, $storeid, strict => 1) };
        die "flashsystem: addsnapshot reported success but '$sname' is not listed as a"
            . " snapshot of '$aname'. If the array did not report volume_name, this"
            . " firmware cannot support the CSI snapshot path: delete resolves the same"
            . " way and would never match.\n"
            if !$found;
        $existing = $found->{row};
    }

    # size_bytes is REQUIRED by CSI and lsvolumesnapshot carries no capacity
    # field, so it is captured from the parent HERE, at snapshot time, and
    # treated as immutable afterwards. Reading it later would return the
    # parent's CURRENT capacity, which is the wrong number after any expand.
    return {
        snapshot_name  => $sname,
        snapshot_id    => $existing->{snapshot_id},
        source_volname => $volname,
        size_bytes     => ($vdisk->{capacity} // 0) + 0,
        # The array reports `time` as YYMMDDHHMMSS in its own timezone, which
        # is not something to convert blind. The driver stamps creation_time
        # itself on first success; this is passed through for diagnostics.
        array_time     => $existing->{time},
        state          => $existing->{state},
        ready          => _snap_is_ready($existing->{state}),
    };
}

# Is a snapshot state a USABLE point-in-time image?
#
# Only 'active'. IBM's lsvolumesnapshot reference defines the states as:
#
#   Ready:    If the snapshot is not triggered.
#   Active:   Maintain the snapshot image.
#   Deleting: Process of deleting.
#   Failed.
#
# So 'Ready' is the OPPOSITE of ready_to_use - it means no image has been cut
# yet. An earlier cut of this code allowed both, which would have reported a
# usable restore point to Kubernetes for a snapshot that did not exist. That is
# the worst failure this feature can have, so the allowlist is deliberately
# one value and anything unrecognised is not-ready.
# Refuse an operation that needs a real point-in-time image. IBM's
# lsvolumesnapshot states: "Ready: If the snapshot is not triggered. Active:
# Maintain the snapshot image." So anything but 'active' means there is nothing
# to read, and an unknown or absent state is treated the same way rather than
# optimistically - the same unknown-and-refuse rule the size-mismatch and
# name-length guards in this file use.
sub _assert_snap_active {
    my ($state, $snapname, $what) = @_;
    return 1 if _snap_is_ready($state);
    die "flashsystem: refusing to $what '$snapname': the array reports state '"
        . (defined $state && length $state ? $state : 'unknown')
        . "', not 'active', so it is not maintaining a point-in-time image.\n";
}

sub _snap_is_ready {
    my ($state) = @_;
    return 0 if !defined $state;
    return (lc($state) eq 'active') ? 1 : 0;
}

# CSI DeleteSnapshot. Addressed by the array snapshot NAME, and idempotent on
# absence, which the CSI spec requires ("if a snapshot corresponding to the
# specified snapshot_id does not exist ... the Plugin MUST reply 0 OK").
#
# Resolves through _snapshots_for so the name+volume_name cross-check applies:
# snapshot names are not system-unique on Storage Virtualize, and this array's
# namespace is shared with the whole VM estate.
sub csi_snapshot_delete {
    my ($class, $scfg, $storeid, $snapname) = @_;
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};
    my ($volname) = _volname_from_snapname($scfg, $snapname);
    return { deleted => 0, reason => 'not-ours' } if !defined $volname;

    my ($found) = grep { $_->{name} eq $snapname }
        @{ _snapshots_for($scfg, $volname, $storeid, strict => 1) };
    if (!$found) {
        # strict => 1 SKIPS a row the array cannot attribute to this volume, so
        # "no strict match" covers two very different situations. Only genuine
        # absence may be reported as success - CSI requires DeleteSnapshot to
        # return OK when the snapshot is already gone. A row that EXISTS but
        # could not be attributed must be an error, or a snapshot that is still
        # holding physical capacity gets reported as deleted.
        # any_owner => 1 is the whole point of this second pass. Without it the
        # helper drops a disagreeing volume_name in NON-strict mode too, so a
        # snapshot that exists but is attributed elsewhere came back as
        # 'absent' - which FSDeleteSnapshot maps to nil and Kubernetes records
        # as reclaimed capacity, for a snapshot still holding it.
        my ($loose) = grep { $_->{name} eq $snapname }
            @{ _snapshots_for($scfg, $volname, $storeid, any_owner => 1) };
        die "flashsystem: refusing to delete '$snapname': the array lists it but does"
            . " not attribute it to '" . _arrayname($scfg, $volname) . "'."
            . " Not deleting something this plugin cannot prove it owns.\n" if $loose;
        return { deleted => 0, reason => 'absent' };
    }

    _cmd($scfg, 'rmsnapshot', undef, { snapshotid => $found->{id} }, storeid => $storeid);
    return { deleted => 1, snapshot_id => $found->{id} };
}

# Recover the PVE volname that owns an array snapshot object, or undef when the
# name does not belong to this storage. `<fsprefix>-<volname>.<component>`, so
# strip the prefix and take everything before the LAST dot - state volumes are
# allowed dots by the volname grammar, so a greedy match is required.
sub _volname_from_snapname {
    my ($scfg, $snapname) = @_;
    return undef if !defined $snapname || !length $snapname;
    my $inner = _volname_from_array($scfg, $snapname);
    return undef if !defined $inner;
    return undef if $inner !~ /\A(.+)\.([^.]+)\z/;
    my ($volname, $comp) = ($1, $2);
    # The component must be one WE minted. Without this, every ordinary PVE
    # snapshot on the same storage - `<vdisk>.vzdump`, a GUI snapshot, a Veeam
    # one - parses as a CSI snapshot, because they share the fsprefix and the
    # same "<arrayname>.<something>" shape. All three consumers would then act
    # on them: list would report them to Kubernetes, delete would accept a
    # handle naming one, and restore would clone from one.
    return undef if $comp !~ /\A[2-7][a-z2-7]{8}\z/;
    return undef if !eval { PVE::Storage::Custom::FlashSystemPlugin->parse_volname($volname); 1 };
    return ($volname, $comp);
}

# CSI ListSnapshots, and the read half of orphan reconciliation. Scoped to this
# storage's fsprefix; optionally to one volume.
#
# The driver's own ListSnapshots is Unimplemented upstream, so without this
# there is no way to diff array state against VolumeSnapshotContent objects -
# and on a data reduction pool a leaked snapshot holds physical capacity in a
# pool shared with production VMs.
sub csi_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};

    # size_bytes and ready must be present in EVERY reply, not just create's.
    # A consumer decoding into a typed struct gets zero values for missing
    # keys, so an omitted `ready` reads as not-ready forever and an omitted
    # `size_bytes` reads as a zero-length snapshot. One lsvdisk per distinct
    # SOURCE VOLUME, not per snapshot, so the cost is bounded.
    my %size;
    my $size_of = sub {
        my ($vn) = @_;
        $size{$vn} //= eval { (_vdisk($scfg, $vn, $storeid)->{capacity} // 0) + 0 } // 0;
        return $size{$vn};
    };

    return [ map { {
                snapshot_name  => $_->{name},
                snapshot_id    => $_->{id},
                source_volname => $volname,
                state          => $_->{row}{state},
                ready          => _snap_is_ready($_->{row}{state}),
                size_bytes     => $size_of->($volname),
            } } @{ _snapshots_for($scfg, $volname, $storeid) } ]
        if defined $volname && length $volname;

    my $list = _cmd($scfg, 'lsvolumesnapshot', undef, {}, storeid => $storeid);
    $list = [] if !defined $list;
    $list = [ $list ] if ref($list) eq 'HASH';
    my $res = [];
    for my $r (@$list) {
        next if ref($r) ne 'HASH';
        my ($vn) = _volname_from_snapname($scfg, $r->{snapshot_name});
        next if !defined $vn;
        # Same cross-check _snapshots_for applies: a name that parses as ours
        # is not proof, because names are not system-unique.
        my $rvn = $r->{volume_name};
        next if defined $rvn && length $rvn && $rvn ne _arrayname($scfg, $vn);
        push @$res, {
            snapshot_name  => $r->{snapshot_name},
            snapshot_id    => $r->{snapshot_id},
            source_volname => $vn,
            state          => $r->{state},
            ready          => _snap_is_ready($r->{state}),
            size_bytes     => $size_of->($vn),
        };
    }
    return $res;
}

# CSI CreateVolume with a snapshot source. Mints a fresh PVE-conforming volname
# for $vmid and has the array populate it - the same primitive clone_image
# uses, addressed by array snapshot name instead of PVE snapshot name.
#
# Returns the new volname. list_images() enumerates the array, so the volume is
# visible to PVE immediately with nothing else to update.
sub csi_volume_from_snapshot {
    my ($class, $scfg, $storeid, $snapname, %opt) = @_;
    die "flashsystem: snapshots disabled\n" if !$scfg->{fssnapshots};
    # A SEPARATE gate from fssnapshots, and off by default. Snapshot
    # create/delete rest on commands that have been in production here since
    # 2026-08-12; this path rests on mkvolume, which this plugin has never
    # issued against an array. Shipping both behind one flag would enable the
    # unvalidated half the moment anyone enables the validated one, and a
    # README saying "run the probe first" is documentation, not a gate.
    die "flashsystem: restore-from-snapshot is disabled on '$storeid'."
        . " mkvolume has not been validated on this array - run"
        . " tools/probe-clone-from-snapshot.sh, then set 'fsrestore 1'.\n"
        if !$scfg->{fsrestore};
    my ($src_volname) = _volname_from_snapname($scfg, $snapname);
    die "flashsystem: '$snapname' is not a snapshot on storage '$storeid'\n"
        if !defined $src_volname;

    # strict => 1: this is a destructive-adjacent path, not a read. The id
    # resolved here becomes mkvolume's -fromsnapshotid, so a row the array
    # cannot positively attribute to $src_volname must not be a clone source -
    # cloning the wrong snapshot serves another volume's data with no error.
    my ($found) = grep { $_->{name} eq $snapname }
        @{ _snapshots_for($scfg, $src_volname, $storeid, strict => 1) };
    die "flashsystem: snapshot '$snapname' not found (or not attributable to"
        . " '$src_volname')\n" if !$found;
    # The row is in hand and carries `state`; not checking it meant mkvolume
    # -fromsnapshotid was issued against snapshots the plugin had ALREADY
    # computed to be unusable. Reachable without any array fault: a snapshot
    # reported 'active' at create time can later degrade (a DRP hitting its
    # physical ceiling), and external-snapshotter never re-checks a content
    # whose readyToUse is already true - so the CSI-side gate passes on a
    # stale value and the restore proceeds.
    _assert_snap_active($found->{row}{state}, $snapname, 'clone from');

    # The CALLER usually owns the name. A CSI driver has already minted the
    # PVE volname and embedded it in the PersistentVolume's volumeHandle
    # before it asks for the restore, so minting another one here would
    # produce a volume the driver cannot address. Accept theirs, validate it
    # against the same grammar alloc_image enforces, and fall back to
    # find_free_diskname only for a caller that has no name in mind.
    my $name = $opt{volname};
    if (defined $name && length $name) {
        $class->parse_volname($name);    # same grammar alloc_image enforces
        # One TARGETED lsvdisk rather than a pool listing: the caller named
        # exactly one object, and mkvolume would otherwise fail with an opaque
        # CMMVC on a collision.
        # Fail CLOSED. _cmd dies on every non-2xx and on unparseable JSON, so a
        # bare eval would read "array unreachable", "auth refused", "429 backoff
        # exhausted" and "does not exist" all as absence - and then create a
        # volume over a name that may already be in use. Only the plugin's own
        # not-found die may be treated as absence.
        my $clash = eval { _vdisk($scfg, $name, $storeid) };
        my $err = $@;
        # Storage Virtualize signals "no such object" as an ERROR STATUS -
        # 409 Conflict with CMMVC5754E - not as an empty 2xx body. _cmd dies on
        # every non-2xx, so _vdisk NEVER reaches its own "not found" die for the
        # absent case, and matching only /not found/ turned the one answer that
        # means "this name is free" into a refusal. That broke every K10 restore
        # and export, because K10 clones a snapshot into a name it has already
        # minted and embedded in the PV. tools/probe-clone-from-snapshot.sh got
        # this right in vol_exists() and the plugin did not.
        #
        # Still fail CLOSED for everything else. An unreachable array, a 401/403,
        # an exhausted 429 backoff or unparseable JSON must not read as absence,
        # or mkvolume runs over a name that may already be in use.
        #
        # CMMVC5754E also covers "the name supplied does not meet the naming
        # rules". Treating that as absent is deliberate and safe: parse_volname
        # and the 63-char gate have both already run, so a genuinely illegal
        # name fails at mkvolume with the array's own error rather than with a
        # misleading "cannot verify".
        my $absent = defined($err) && $err =~ /CMMVC5754E|\bnot found\b/i;
        die "flashsystem: cannot verify whether '$name' already exists on"
            . " '$storeid': $err" if !$clash && $err && !$absent;
        die "flashsystem: volume '$name' already exists on '$storeid'\n" if $clash;
    } else {
        my $vmid = $opt{vmid};
        die "flashsystem: csi_volume_from_snapshot needs volname or vmid\n"
            if !defined $vmid;
        $name = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');
    }
    my $new_aname = _arrayname($scfg, $name);
    die 'flashsystem: array object name \'' . $new_aname . '\' is ' . length($new_aname)
        . " chars (max 63): use a shorter fsprefix for this storage\n"
        if length($new_aname) > 63;

    _cmd($scfg, 'mkvolume', undef,
        _mkvolume_clone_params($scfg, _arrayname($scfg, $src_volname), $new_aname, $found->{id}),
        storeid => $storeid);

    my $v = _vdisk($scfg, $name, $storeid);
    return {
        volname        => $name,
        array_name     => $new_aname,
        size_bytes     => ($v->{capacity} // 0) + 0,
        source_volname => $src_volname,
        clone_type     => _clone_type($scfg),
    };
}

1;
