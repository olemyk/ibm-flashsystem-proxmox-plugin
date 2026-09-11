package PVE::API2::FlashSystem;

# ---------------------------------------------------------------------------
# Read-only health & capacity API for `flashsystem` storages.
#
#   GET /nodes/{node}/flashsystem                      -> flashsystem storages
#   GET /nodes/{node}/flashsystem/{storage}            -> ['health']
#   GET /nodes/{node}/flashsystem/{storage}/health     -> one storage
#   GET /nodes/{node}/flashsystem/{storage}/overview   -> the whole array
#
# Proxmox has no API plugin registry, so this module is registered by
# appending a marker-wrapped block to PVE/API2/Nodes.pm — see
# install-flashsystem-api.sh, which also installs an APT hook to re-apply it
# after pve-manager upgrades. The GUI counterpart (a "FlashSystem" tab on the
# storage view) lives in flashsystem-gui.js.
#
# Every array read goes through the storage plugin's _cmd (429 retry, token
# cache) and each section is eval-guarded and time-bounded by a SHARED
# deadline: the whole collection fits inside ~25s because the
# pveproxy->pvedaemon proxy path caps requests at ~30s — independent
# per-section budgets would blow through it on a hung array and turn the
# designed partial-data response into a blunt proxy 5xx (VALIDATE the exact
# proxy timeout on a live node before raising the budget). A slow or
# unreachable array yields partial data with per-section errors, never a
# hung API worker. The health method is `protected` because resolving the
# REST credential reads root-only /etc/pve/priv/storage/<id>.pw.
#
# VALIDATE: the lseventlog filter (`fixed=no`) and the exact field names of
# lssystem/lsportfc/lseventlog concise views vary by firmware — confirm on a
# demo array before trusting the events/ports sections. Unknown fields are
# simply omitted (whitelist extraction), so mismatches degrade to empty
# sections rather than errors.
# ---------------------------------------------------------------------------

use strict;
use warnings;

use JSON ();
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::Storage::Plugin;

# The storage plugin provides _cmd/_one/_volname_from_array/_pool_usage. On a
# node it loads by module name; in the unit tests it has already been loaded
# from a flat file path, so only require it when it is not there yet.
BEGIN {
    unless (defined &PVE::Storage::Custom::FlashSystemPlugin::_cmd) {
        require PVE::Storage::Custom::FlashSystemPlugin;
    }
}

use base qw(PVE::RESTHandler);

# ---- pure view helpers (unit-tested in tests/t_api.pl) --------------------

# Copy only the listed keys that actually exist — firmware differences in
# concise-view fields degrade to omissions, never errors.
sub _whitelist {
    my ($h, @keys) = @_;
    return {} if ref($h) ne 'HASH';
    return { map { $_ => $h->{$_} } grep { defined $h->{$_} } @keys };
}

sub _system_view {
    my ($sys) = @_;
    return _whitelist($sys, qw(name code_level product_name topology));
}

sub _pool_view {
    my ($g) = @_;
    return {} if ref($g) ne 'HASH';
    my $v = _whitelist($g, qw(name status data_reduction
        capacity free_capacity used_capacity
        physical_capacity physical_free_capacity));
    # The same physical-over-effective preference status() uses: this is the
    # number people provision against (see UPSTREAM.md 1b).
    my ($total, $free, $used) = PVE::Storage::Custom::FlashSystemPlugin::_pool_usage($g);
    $v->{provision_total} = $total;
    $v->{provision_free}  = $free;
    $v->{provision_used}  = $used;
    $v->{provision_used_pct} = $total ? int($used * 100 / $total + 0.5) : 0;
    return $v;
}

sub _volumes_view {
    my ($vdisks, $scfg) = @_;
    $vdisks = [] if ref($vdisks) ne 'ARRAY';
    my ($ours, $bytes) = (0, 0);
    my $shape = qr/\Avm-\d+-$PVE::Storage::Custom::FlashSystemPlugin::VOLNAME_SUFFIX\z/a;
    for my $v (@$vdisks) {
        my $name = PVE::Storage::Custom::FlashSystemPlugin::_volname_from_array($scfg, $v->{name} // '');
        next if !defined $name;
        # The prefix alone is not enough: list_images ALSO requires the PVE
        # volume shape, and without that test a storage with no fsprefix —
        # where the translation is a pass-through — claims every object in
        # the pool. Observed live 2026-08-26: a prefix-less storage reported
        # 6 volumes / 5.6 TB while PVE managed 4 / 103 GB, the difference
        # being another consumer's volumes in a shared pool.
        next if $name !~ $shape;
        $ours++;
        $bytes += (($v->{capacity} // 0) + 0);
    }
    return {
        pool_total        => scalar(@$vdisks),
        ours              => $ours,
        ours_provisioned  => $bytes,
    };
}

# An unfixed event is not necessarily a problem. `fixed=no` also returns the
# array's informational chatter — SAS discovery, "Virtual Disk Copy Format
# Completed" — which on a working system runs to four figures: 1317 on the
# 8.7.0.3 demo array, of which exactly ONE was actionable. Alerts are the
# events carrying a real error code; informational events carry an empty one.
# Everything is counted, only alerts are listed, so a single 1867 pool-space
# warning cannot hide behind a thousand copy-format notices.
#
# Note this is ARRAY-WIDE: lseventlog is a system log, not a pool log, so
# every storage on the same array reports the same alerts.
#
# VALIDATE (payload optimisation, not correctness): Storage Virtualize also
# accepts a server-side `alert=yes` filter. Confirm the REST spelling on an
# array and the fetch shrinks from ~1300 rows to a handful; the client-side
# split below stays as the belt either way.
sub _events_view {
    my ($events, $max, $filtered) = @_;
    $events = [] if ref($events) ne 'ARRAY';
    $max //= 10;
    my @alerts = grep {
        defined $_->{error_code} && $_->{error_code} =~ /\A\s*[1-9][0-9]*\s*\z/
    } @$events;
    # Self-check on the server-side filter. A firmware that REJECTS the
    # alert/message/monitoring parameters makes the call die and we fall back
    # - that case is handled. The dangerous case is a firmware that silently
    # IGNORES them and returns the whole unfixed log anyway: we would then
    # hold the informational events but suppress the total that describes
    # them. If the filter had really applied, every row would be an alert; if
    # it did not, the total is meaningful and gets reported after all.
    $filtered = 0 if $filtered && scalar(@$events) != scalar(@alerts);

    my @sorted = sort { ($b->{sequence_number} // 0) <=> ($a->{sequence_number} // 0) } @alerts;
    my $last = $#sorted < $max - 1 ? $#sorted : $max - 1;
    my @recent = $last < 0 ? () : map {
        _whitelist($_, qw(sequence_number error_code description
            object_type object_name last_timestamp))
    } @sorted[0 .. $last];
    return {
        alerts   => scalar(@alerts),
        filtered => ($filtered ? 1 : 0),
        # Only meaningful when the WHOLE unfixed log was fetched. Under the
        # server-side alert filter the informational events this number
        # described are not in the payload at all, so reporting it would
        # restate the alert count under a second name and read as "there is
        # no informational chatter".
        ($filtered ? () : (unfixed_total => scalar(@$events))),
        recent   => \@recent,
    };
}

sub _ports_view {
    my ($ports, $max) = @_;
    $ports = [] if ref($ports) ne 'ARRAY';
    $max //= 16;
    my %by_status;
    $by_status{ lc($_->{status} // 'unknown') }++ for @$ports;
    my @rows = map {
        _whitelist($_, qw(id fc_io_port_id status port_speed attachment node_name))
    } @$ports[0 .. ($#$ports < $max - 1 ? $#$ports : $max - 1)];
    return {
        total     => scalar(@$ports),
        active    => ($by_status{active} // 0),
        by_status => \%by_status,
        ports     => \@rows,
    };
}

# ---- collection ------------------------------------------------------------

# The whole collection shares one deadline (see header): each section gets
# min(its cap, time remaining), and a section whose turn arrives after the
# deadline is skipped with an explicit error instead of silently stretching
# the request past the proxy timeout.
my $TOTAL_BUDGET = 25;    # seconds; pveproxy->pvedaemon caps at ~30 (VALIDATE)

# A section timeout is raised as an OBJECT, not a string. Callers that wrap an
# array call in their own eval - _fetch_events does, to detect a firmware that
# rejects a parameter - have to tell "the array is hung" apart from "that call
# was refused", and matching on the text of another sub's die message couples
# them and cannot be \z-anchored safely. Anything blessed into this class must
# be re-thrown, never handled.
my $TIMEOUT_CLASS = 'PVE::API2::FlashSystem::Timeout';

sub _budget {
    my ($deadline, $cap) = @_;
    my $left = $deadline - time();
    return 0 if $left <= 0;
    return $left < $cap ? $left : $cap;
}

# One bounded REST call per section; failures become {error} entries so the
# panel renders partial data instead of nothing.
sub _section {
    my ($errors, $key, $deadline, $cap, $code) = @_;
    my $timeout = _budget($deadline, $cap);
    if (!$timeout) {
        $errors->{$key} = 'skipped: time budget exhausted';
        return undef;
    }
    my $res = eval {
        local $SIG{ALRM} = sub { die bless { timeout => $timeout }, $TIMEOUT_CLASS };
        alarm $timeout;
        my $r = $code->();
        alarm 0;
        $r;
    };
    alarm 0;
    if (my $err = $@) {
        if (ref($err) eq $TIMEOUT_CLASS) {
            $errors->{$key} = "timeout after $err->{timeout}s";
            return undef;
        }
        chomp $err;
        $errors->{$key} = $err;
        return undef;
    }
    return $res;
}

# Short aliases: everything below talks to the array through the storage
# plugin's transport (429 retry, token cache).
sub _fscmd { return PVE::Storage::Custom::FlashSystemPlugin::_cmd(@_); }
sub _fsone { return PVE::Storage::Custom::FlashSystemPlugin::_one(@_); }

# ---- performance statistics -------------------------------------------------
#
# lssystemstats returns ONE ROW PER STATISTIC:
#   { stat_name, stat_current, stat_peak, stat_peak_time }
# and lsnodestats the same with node_id/node_name added. Confirmed against
# IBM's Storage Virtualize command reference (RESTful API, "lssystemstats" /
# "lsnodestats"); ~40 rows system-wide and ~40 per node, so both are cheap.
#
# stat_peak is the peak over the LAST FIVE MINUTES, which is the whole reason
# this is worth showing: a current sample taken while someone opens the panel
# misses the spike that made them open it. stat_peak_time is YYMMDDHHMMSS —
# the same format lseventlog uses, so the GUI reuses one formatter.
#
# Whitelisted like every other section: a firmware that adds or drops a
# statistic degrades to a missing row, never an error. compression_cpu_pc,
# power_w and temp_c are NOT in the 8.1.3 reference and are listed
# speculatively for newer firmware — they simply will not appear on 8.7 if
# the array does not report them.
our @STAT_NAMES = qw(
    cpu_pc compression_cpu_pc write_cache_pc total_cache_pc
    vdisk_io vdisk_mb vdisk_ms
    vdisk_r_io vdisk_r_mb vdisk_r_ms vdisk_w_io vdisk_w_mb vdisk_w_ms
    mdisk_io mdisk_mb mdisk_ms
    mdisk_r_io mdisk_r_mb mdisk_r_ms mdisk_w_io mdisk_w_mb mdisk_w_ms
    drive_io drive_mb drive_ms
    drive_r_io drive_r_mb drive_r_ms drive_w_io drive_w_mb drive_w_ms
    fc_io fc_mb iscsi_io iscsi_mb sas_io sas_mb
    power_w temp_c
);
my %STAT_WANTED = map { $_ => 1 } @STAT_NAMES;


# Statistics arrive as JSON strings. Anything non-numeric becomes undef rather
# than 0 so the GUI can distinguish "not reported" from "zero" — /a because
# these strings may be UTF-8 flagged and bare \d would match Unicode digits
# (the same bypass pinned as a regression test in tests/t_names.pl).
sub _num {
    my ($v) = @_;
    return undef if !defined $v || ref($v);
    return $v + 0 if $v =~ /\A-?\d+(?:\.\d+)?\z/a;
    return undef;
}

sub _stats_view {
    my ($rows) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    my $stats = {};
    for my $r (@$rows) {
        next if ref($r) ne 'HASH';
        my $n = $r->{stat_name};
        next if !defined $n || !$STAT_WANTED{$n};
        $stats->{$n} = {
            current   => _num($r->{stat_current}),
            peak      => _num($r->{stat_peak}),
            peak_time => $r->{stat_peak_time},
        };
    }
    return { stats => $stats, reported => scalar(@$rows) };
}

sub _node_stats_view {
    my ($rows) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    my %by_node;
    for my $r (@$rows) {
        next if ref($r) ne 'HASH';
        # Rows without a node identity are not per-node data; skip rather
        # than inventing a node called ''.
        my $node = $r->{node_name};
        $node = $r->{node_id} if !defined $node || !length $node;
        next if !defined $node || !length $node;
        my $n = $r->{stat_name};
        next if !defined $n || !$STAT_WANTED{$n};
        $by_node{$node}->{$n} = {
            current   => _num($r->{stat_current}),
            peak      => _num($r->{stat_peak}),
            peak_time => $r->{stat_peak_time},
        };
    }
    return { nodes => [ map { { node => $_, stats => $by_node{$_} } } sort keys %by_node ] };
}

# lssystemstats -history <a:b:c> returns a time series instead of a summary:
#   { sample_time, stat_name, stat_value }
# at the array's 5-second sample interval. Enough for a sparkline, which is
# what turns "34 ms right now" into "34 ms and climbing for two minutes".
#
# VALIDATE: the summary form of lssystemstats is confirmed on 8.7.0.3; the
# REST spelling of the -history parameter is NOT yet. The section is fetched
# separately and degrades to omission, so a wrong spelling costs a missing
# sparkline, never the panel.
# lssystemstats is absent from IBM's published REST OpenAPI schema for both
# 8.7.0 and 9.1.3 - while /lsnodestats is present - so it may not be
# reachable on every array even though the CLI documents it. This derives the
# same system view from the per-node rows, which ARE confirmed reachable.
#
# Throughput sums across canisters. Latency and percentages must NOT be
# summed: the honest aggregate is the WORST canister, which is also the one
# an operator needs to see. The result is marked `derived` so the panel can
# say where the numbers came from rather than quietly presenting an
# approximation as the array's own figure.
sub _derive_system_stats {
    my ($node_view) = @_;
    my $nodes = ($node_view && $node_view->{nodes}) || [];
    return undef if !@$nodes;
    my $stats = {};
    for my $n (@$nodes) {
        my $ns = $n->{stats} || {};
        for my $k (keys %$ns) {
            my $cur = $ns->{$k}->{current};
            next if !defined $cur;
            my $peak = $ns->{$k}->{peak};
            my $acc = $stats->{$k};
            if (!$acc) {
                $stats->{$k} = { current => $cur, peak => $peak,
                                 peak_time => $ns->{$k}->{peak_time} };
                next;
            }
            if ($k =~ /_(?:io|mb)\z/a) {
                $acc->{current} += $cur;
                # Only accumulate a peak that exists. Summing (undef // 0)
                # would turn "not reported" into a peak of 0 sitting below a
                # current sample taken inside the same five-minute window,
                # which reads as broken instrumentation rather than as
                # missing data - the undef-not-zero rule _num() exists for.
                $acc->{peak} = ($acc->{peak} // 0) + $peak if defined $peak;
            } else {
                $acc->{current} = $cur if $cur > $acc->{current};
                if (defined $peak && $peak > ($acc->{peak} // -1)) {
                    $acc->{peak} = $peak;
                    $acc->{peak_time} = $ns->{$k}->{peak_time};
                }
            }
        }
    }
    return { stats => $stats, derived => 1 };
}

sub _history_view {
    my ($rows, $keep) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    $keep //= 60;
    my %series;
    for my $r (@$rows) {
        next if ref($r) ne 'HASH';
        my $n = $r->{stat_name};
        next if !defined $n || !$STAT_WANTED{$n};
        my $v = _num($r->{stat_value});
        next if !defined $v;
        push @{ $series{$n} }, [ ($r->{sample_time} // ''), $v ];
    }
    my $out = {};
    for my $n (keys %series) {
        my @s = sort { $a->[0] cmp $b->[0] } @{ $series{$n} };
        @s = @s[ -$keep .. -1 ] if @s > $keep;
        $out->{$n} = [ map { $_->[1] } @s ];
    }
    return $out;
}

# lsthrottle lists every configured throttle: volume, host, host-cluster, pool
# and system-offload. Cheap (a handful of rows) and the most directly
# actionable answer to "why is this one slow" that the array offers, since a
# throttle is a deliberate cap rather than a symptom.
# Field spellings are IBM's, including the mixed case of IOPs_limit.
sub _throttles_view {
    my ($rows, $max) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    $max //= 25;
    my @kept = map {
        _whitelist($_, qw(throttle_id throttle_name object_id object_name
            throttle_type IOPs_limit bandwidth_limit_MB))
    } @$rows[ 0 .. ($#$rows < $max - 1 ? $#$rows : $max - 1) ];
    return { total => scalar(@$rows), throttles => \@kept };
}

# ---- per-volume consumption -------------------------------------------------
#
# Built from the CONCISE lsvdisk rows the pool section already fetches, so
# ranking costs NO extra REST calls.
#
# What that view carries decides what this can answer. IBM documents the
# concise lsvdisk columns as: id name IO_group_id IO_group_name status
# mdisk_grp_id mdisk_grp_name capacity type FC_id FC_name RC_id RC_name
# vdisk_UID fc_map_count copy_count fast_write_state se_copy_count RC_change
# compressed_copy_count volume_id volume_name function. There is deliberately
# no used_capacity there — real usage lives ONLY in the detailed view
# (lsvdisk <name>), i.e. one REST call per volume, which a panel sharing a
# rate limiter with pvestatd cannot afford across a whole pool.
#
# So the ranking is by PROVISIONED capacity. That is not a compromise on a
# thick cluster: a fully allocated volume reserves its whole size, so
# provisioned IS consumed and this ranking is exactly "what is eating the
# pool". Only for space-efficient volumes does provisioned become a ceiling
# rather than a fill, and _collect_fill() resolves those in a single extra
# call (lssevdiskcopy) when the pool can report them at all.
#
# Foreign volumes are counted, and named only when the caller can audit the
# whole storage tree (see the overview method). In a pool shared with other
# consumers — VMware, another cluster — the thing filling it is frequently
# not a PVE volume at all, and a ranking that silently omitted them would
# point the operator at the wrong tenant.

# Which storage owns an array object, or undef for a foreign one.
#
# Prefers a PREFIXED owner. A storage configured without fsprefix translates
# pass-through, so it matches any PVE-shaped name in its pool — including
# volumes that demonstrably belong to a prefixed storage sharing that pool.
# Checking prefixed storages first makes the attribution deterministic and
# correct whenever the real owner is knowable.
sub _classify_volume {
    my ($aname, $peers) = @_;
    my $shape = qr/\Avm-(\d+)-$PVE::Storage::Custom::FlashSystemPlugin::VOLNAME_SUFFIX\z/a;
    my $fallback;
    for my $p (@$peers) {
        my ($id, $s) = @$p;
        my $vn = PVE::Storage::Custom::FlashSystemPlugin::_volname_from_array($s, $aname);
        next if !defined $vn;
        my ($vmid) = $vn =~ $shape;
        next if !defined $vmid;
        my $hit = { storage => $id, volname => $vn, vmid => $vmid + 0 };
        return $hit if defined $s->{fsprefix} && length $s->{fsprefix};
        $fallback //= $hit;
    }
    return $fallback;
}

sub _top_volumes_view {
    my ($vdisks, $peers, %opt) = @_;
    $vdisks = [] if ref($vdisks) ne 'ARRAY';
    $peers  = [] if ref($peers)  ne 'ARRAY';
    my $limit = $opt{limit} // 10;
    my $with_names = $opt{foreign_names} ? 1 : 0;
    # When set, only this storage's volumes count as "ours" and the other
    # peers' become a third, separately labelled bucket. The storage tab
    # passes it; the pool-wide overview does not, because there every peer
    # legitimately is "ours".
    my $self = $opt{self};

    my (@ours, @foreign, @attention);
    my %vm;
    my $ours_bytes = 0;
    my $foreign_bytes = 0;
    my $sibling_count = 0;
    my $sibling_bytes = 0;

    for my $v (@$vdisks) {
        next if ref($v) ne 'HASH';
        my $aname = $v->{name};
        next if !defined $aname || !length $aname;
        my $cap = _num($v->{capacity}) // 0;
        # se_copy_count / compressed_copy_count are the concise view's only
        # signal that a volume is space-efficient rather than fully allocated.
        my $thin = ((_num($v->{se_copy_count}) // 0) > 0
                 || (_num($v->{compressed_copy_count}) // 0) > 0) ? 1 : 0;
        my $status = $v->{status};
        my $hit = _classify_volume($aname, $peers);

        if ($hit && defined $self && $hit->{storage} ne $self) {
            # Another flashsystem storage in THIS cluster sharing the pool.
            # Folding these into "foreign" is how a storage tab came to
            # attribute the cluster's own Kubernetes PVCs to the VMware
            # tenant next door - on the validation cluster a tier storage
            # and its CSI storage share one pool, so it was 10 TB of
            # self-inflicted blame. Aggregate
            # only: the caller has audit on THIS storage, not on its
            # siblings, so their volume names must not appear.
            $sibling_count++;
            $sibling_bytes += $cap;
            next;
        }
        if ($hit) {
            $ours_bytes += $cap;
            my $row = {
                name       => $hit->{volname},
                array_name => $aname,
                storage    => $hit->{storage},
                vmid       => $hit->{vmid},
                capacity   => $cap,
                thin       => $thin,
                (defined $status ? (status => $status) : ()),
            };
            push @ours, $row;
            # fast_write_state=corrupt is not a performance hint: it needs
            # recovervdisk/repairvdiskcopy and belongs beside offline, not
            # buried in a size ranking.
            my $fws = lc($v->{fast_write_state} // '');
            $row->{fast_write_state} = $v->{fast_write_state} if $fws eq 'corrupt';
            push @attention, $row
                if (defined $status && lc($status) ne 'online') || $fws eq 'corrupt';
            my $agg = $vm{ $hit->{vmid} } //= {
                vmid => $hit->{vmid}, disks => 0, capacity => 0, storages => {},
            };
            $agg->{disks}++;
            $agg->{capacity} += $cap;
            $agg->{storages}->{ $hit->{storage} } = 1;
        } else {
            $foreign_bytes += $cap;
            push @foreign, {
                ($with_names ? (name => $aname) : ()),
                capacity => $cap, thin => $thin,
                (defined $status ? (status => $status) : ()),
            };
        }
    }

    # Ties broken on a stable secondary key: equal-sized volumes are the
    # normal case (templates, same-spec VMs) and an unstable sort would
    # reshuffle the table on every Refresh for no reason.
    my $top = sub {
        my ($list) = @_;
        my @s = sort {
            $b->{capacity} <=> $a->{capacity}
                || ($a->{name} // '') cmp ($b->{name} // '')
                || ($a->{vmid} // 0) <=> ($b->{vmid} // 0)
        } @$list;
        return [ @s > $limit ? @s[ 0 .. $limit - 1 ] : @s ];
    };

    my @vms = map {
        { %{ $vm{$_} }, storages => [ sort keys %{ $vm{$_}->{storages} } ] }
    } keys %vm;

    return {
        volumes => $top->(\@ours),
        vms     => $top->(\@vms),
        ours    => { count => scalar(@ours),    capacity => $ours_bytes },
        foreign => { count => scalar(@foreign), capacity => $foreign_bytes,
                     volumes => $top->(\@foreign) },
        # Present only on the storage-scoped view, so the panel can tell
        # "another storage of ours" from "another tenant entirely".
        (defined $self
            ? (siblings => { count => $sibling_count, capacity => $sibling_bytes })
            : ()),
        # Capped like every other list: an array in a bad way must not turn
        # one API response into thousands of rows.
        attention => [ @attention > $limit ? @attention[ 0 .. $limit - 1 ] : @attention ],
        attention_total => scalar(@attention),
    };
}

# Real per-volume FILL, for space-efficient volumes, in ONE call.
#
# lssevdiskcopy lists every thin-provisioned or compressed COPY on the array
# with its used / real / free capacity, filterable by pool. So the fill of a
# whole pool costs one request rather than one per volume - which matters
# more than it sounds here: the array executes ONE CLI command at a time
# cluster-wide, behind a 10 req/s cap, on a box VMware is also driving.
#
# Fully allocated volumes never appear in the output, and rightly so: their
# used capacity IS their provisioned capacity, so there is nothing to fetch
# and nothing to draw.
#
# Note the emitted keys are mdisk_grp_id / mdisk_grp_name - IBM's own prose
# on this command says mdiskgrp_name without the underscore, and the prose is
# wrong; the worked example output is authoritative.
sub _sev_fill_view {
    my ($rows) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    my $by_name = {};
    my $usable = 0;
    for my $r (@$rows) {
        next if ref($r) ne 'HASH';
        my $n = $r->{vdisk_name};
        next if !defined $n || !length $n;
        my $used = _num($r->{used_capacity});
        my $real = _num($r->{real_capacity});
        # In a data reduction pool these fields come back BLANK (IBM,
        # documented per field). _num turns '' into undef, so a DRP row lands
        # here contributing nothing - the caller reports the pool as
        # unreported rather than as empty.
        next if !defined $used && !defined $real;
        $usable++;
        $by_name->{$n} = {
            used       => $used,
            real       => $real,
            free       => _num($r->{free_capacity}),
            autoexpand => $r->{autoexpand},
            warning    => $r->{warning},
        };
    }
    return { by_name => $by_name, copies => scalar(@$rows), usable => $usable };
}

# Attach fill to ranked rows.
#
# The DENOMINATOR depends on autoexpand, and getting it wrong inverts the
# meaning of the bar:
#   autoexpand on  -> used / provisioned. real_capacity grows on demand, so
#                     the pool is the real constraint.
#   autoexpand off -> used / real_capacity. There is no growth, and reaching
#                     100% takes the volume OFFLINE.
# This mirrors IBM's own -warning semantics on mkvdisk/addvdiskcopy.
sub _apply_fill {
    my ($vols, $map) = @_;
    my $by = ($map && $map->{by_name}) || {};
    my $hits = 0;
    for my $v (@$vols) {
        my $key = $v->{array_name};
        next if !defined $key;
        my $f = $by->{$key};
        next if !$f;
        my $expands = (($f->{autoexpand} // '') eq 'on') ? 1 : 0;
        $v->{used} = $f->{used} if defined $f->{used};
        $v->{real} = $f->{real} if defined $f->{real};
        $v->{autoexpand} = $expands;
        $v->{fill_basis} = $expands ? 'provisioned' : 'allocated';
        my $denom = $expands ? $v->{capacity} : $f->{real};
        if (defined $f->{used} && $denom) {
            $v->{fill_pct} = int($f->{used} * 100 / $denom + 0.5);
            $hits++;
        }
    }
    return $hits;
}

# Per-pool fill, gated on what the pool can actually report.
#
# Returns the {available, reason} block the panel renders instead of a bar
# when fill is not knowable - a zero-width bar next to real capacity reads as
# "empty", which is exactly the wrong conclusion.
sub _collect_fill {
    my ($scfg, $storeid, $pool, $poolinfo, $vols, $errors, $deadline) = @_;

    if (!$poolinfo) {
        return { available => 0, reason => 'pool-capacity-unavailable' };
    }
    # IBM, per field: used_capacity / real_capacity / free_capacity are BLANK
    # for thin and compressed copies in a data reduction pool. Asking anyway
    # would spend a request to learn nothing.
    if (($poolinfo->{data_reduction} // '') eq 'yes') {
        return { available => 0, reason => 'data-reduction-pool' };
    }
    my $key = "fill:$pool";
    my $rows = _section($errors, $key, $deadline, 6, sub {
        _fscmd($scfg, 'lssevdiskcopy', undef,
            { filtervalue => "mdisk_grp_name=$pool", bytes => JSON::true },
            storeid => $storeid);
    });
    return { available => 0, reason => 'query-failed' } if exists $errors->{$key};
    my $map = _sev_fill_view($rows // []);
    my $hits = _apply_fill($vols, $map);
    return { available => 1, copies => $map->{copies}, measured => $hits };
}

# Unfixed ALERTS, cheaply.
#
# The obvious call - filtervalue=fixed=no - also returns the array's entire
# informational log: 1317 rows on the validation array, exactly one of them
# actionable. IBM's command reference documents dedicated flags for this
# (-alert / -message / -monitoring / -fixed), so all four are set explicitly
# rather than trusting defaults, and the payload drops to the alerts alone.
#
# VALIDATE: confirmed in the reference, not yet on hardware. A firmware that
# rejects the parameters makes the call fail, so this falls back to the
# known-good fixed=no form - the client-side split in _events_view stays
# either way and produces the same answer from the larger payload.
#
# Returns ($rows, $filtered). When filtered, the caller must NOT report a
# total-unfixed count: the rows no longer contain the informational events
# that count was describing.
sub _fetch_events {
    my ($scfg, $storeid) = @_;
    my $res = eval {
        _fscmd($scfg, 'lseventlog', undef,
            { alert => 'yes', message => 'no', monitoring => 'no', fixed => 'no' },
            storeid => $storeid);
    };
    my $err = $@;
    return ($res, 1) if !$err;

    # A TIMEOUT is the section deadline expiring, not the firmware refusing
    # the parameters - and swallowing it here is how a hung array becomes a
    # proxy 5xx. Once $SIG{ALRM} has fired the alarm is spent, so the fallback
    # would then run the ~1300-row query with nothing bounding it but LWP's
    # own 30s and the 429 backoff on top: comfortably past the ~30s
    # pveproxy->pvedaemon cap, holding a pvedaemon worker, and starving every
    # section after this one out of the shared budget.
    #
    # Re-throw, and _section records it as the timeout it is. When the first
    # call instead fails FAST (a CMMVC parameter rejection) the alarm is still
    # armed with the rest of the section's slice, so the fallback below is
    # bounded by it without needing an alarm of its own.
    die $err if ref($err) eq $TIMEOUT_CLASS;

    return (_fscmd($scfg, 'lseventlog', undef,
        { filtervalue => 'fixed=no' }, storeid => $storeid), 0);
}

sub _collect_health {
    my ($storeid, $scfg, $peers) = @_;
    # Defaulting to self alone keeps the old behaviour for any caller that
    # does not supply peers; the API method always does.
    $peers = [ [ $storeid, $scfg ] ] if ref($peers) ne 'ARRAY' || !@$peers;

    my $deadline = time() + $TOTAL_BUDGET;
    my $errors = {};
    # fsprefix is reported so the panel can flag its absence: an unprefixed
    # storage cannot be isolated from other consumers of the same pool, and
    # the option is fixed after creation.
    my $health = {
        storage   => $storeid,
        pool_name => $scfg->{fspool},
        prefix    => $scfg->{fsprefix},
    };

    my $sys = _section($errors, 'system', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_one(
            PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lssystem', undef, {}, storeid => $storeid));
    });
    $health->{system} = _system_view($sys) if $sys;

    my $pool = _section($errors, 'pool', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_one(
            PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lsmdiskgrp', $scfg->{fspool},
                { bytes => JSON::true }, storeid => $storeid));
    });
    $health->{pool} = _pool_view($pool) if $pool;

    # For the list sections an empty REST body means "no rows" (the plugin's
    # _cmd returns undef for empty bodies): render an explicit zero, and only
    # omit the section when its call actually failed.
    my $vdisks = _section($errors, 'volumes', $deadline, 10, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lsvdisk', undef,
            { filtervalue => "mdisk_grp_name=$scfg->{fspool}", bytes => JSON::true },
            storeid => $storeid);
    });
    if (!exists $errors->{volumes}) {
        $health->{volumes} = _volumes_view($vdisks // [], $scfg);
        # Ranked consumers for THIS storage, from the rows just fetched - no
        # extra REST call. Foreign volume names stay off here: the caller's
        # permission is on this storage, not on the whole pool.
        my $top = _top_volumes_view($vdisks // [], $peers,
            limit => 10, self => $storeid);
        $top->{fill} = _collect_fill($scfg, $storeid, $scfg->{fspool}, $pool,
            $top->{volumes}, $errors, $deadline);
        $health->{top} = $top;
    }

    my $filtered = 0;
    my $events = _section($errors, 'events', $deadline, 8, sub {
        my ($rows, $f) = _fetch_events($scfg, $storeid);
        $filtered = $f;
        return $rows;
    });
    $health->{events} = _events_view($events // [], undef, $filtered)
        if !exists $errors->{events};

    my $ports = _section($errors, 'ports', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lsportfc', undef, {}, storeid => $storeid);
    });
    $health->{ports} = _ports_view($ports // []) if !exists $errors->{ports};

    $health->{errors} = $errors if %$errors;
    return $health;
}

# ---- API methods -----------------------------------------------------------

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "List flashsystem storages defined on this node.",
    permissions => {
        description => "Only storages with Datastore.Audit or Datastore.Allocate are listed.",
        user => 'all',
    },
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                storage => { type => 'string' },
                pool    => { type => 'string', optional => 1 },
                address => { type => 'string', optional => 1 },
            },
        },
        links => [ { rel => 'child', href => '{storage}' } ],
    },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $cfg = PVE::Storage::config();

        my $res = [];
        for my $storeid (sort keys %{ $cfg->{ids} // {} }) {
            my $scfg = $cfg->{ids}->{$storeid};
            next if ($scfg->{type} // '') ne 'flashsystem';
            next if !$rpcenv->check_any($authuser, "/storage/$storeid",
                [ 'Datastore.Audit', 'Datastore.Allocate' ], 1);
            push @$res, {
                storage => $storeid,
                pool    => $scfg->{fspool},
                address => $scfg->{fsaddress},
            };
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'diridx',
    path => '{storage}',
    method => 'GET',
    description => "Index of available flashsystem storage reports.",
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object', properties => { subdir => { type => 'string' } } },
        links => [ { rel => 'child', href => '{subdir}' } ],
    },
    code => sub {
        return [ { subdir => 'health' }, { subdir => 'overview' },
                 { subdir => 'performance' }, { subdir => 'snapshot' },
                 { subdir => 'volume-from-snapshot' } ];
    },
});

__PACKAGE__->register_method({
    name => 'health',
    path => '{storage}/health',
    method => 'GET',
    description => "Array health and capacity overview for a flashsystem storage: "
        . "system identity, pool capacity (physical and effective), volume counts, "
        . "unfixed events and FC port state. Read-only; sections degrade "
        . "independently if the array is slow or unreachable.",
    # protected: resolving the REST credential reads root-only
    # /etc/pve/priv/storage/<id>.pw, which pveproxy's www-data cannot.
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $cfg = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $param->{storage});
        die "storage '$param->{storage}' is not a flashsystem storage\n"
            if ($scfg->{type} // '') ne 'flashsystem';

        # Every flashsystem storage on the same array AND pool, so volumes
        # owned by a sibling are recognised as this cluster's rather than
        # counted against another tenant. NOT permission-filtered, and
        # deliberately so: siblings are reported as a count and a total with
        # no names or storage ids, which is the same class of information as
        # the pool volume count this endpoint already returns.
        my $addr = $scfg->{fsaddress} // '';
        my $pool = $scfg->{fspool} // '';
        my $peers = [];
        for my $id (sort keys %{ $cfg->{ids} // {} }) {
            my $p = $cfg->{ids}->{$id};
            next if ($p->{type} // '') ne 'flashsystem';
            next if ($p->{fsaddress} // '') ne $addr;
            next if ($p->{fspool} // '') ne $pool;
            push @$peers, [ $id, $p ];
        }
        return _collect_health($param->{storage}, $scfg, $peers);
    },
});


# ---- datacenter-wide overview ---------------------------------------------

# Aggregate every flashsystem storage sharing one array. The array-wide facts
# (identity, ports, alerts) are fetched ONCE and each pool ONCE, however many
# storages use it — an 8-storage / 4-pool cluster costs 11 REST calls rather
# than the 40 a per-storage fan-out would. Same shared deadline as health(),
# so a slow array degrades to partial data instead of a proxy timeout.
#
# @peers is [[storeid, scfg], ...], already filtered by the caller for read
# permission: the overview must not leak storages the user cannot audit.
sub _collect_overview {
    my ($storeid, $scfg, $peers, %opt) = @_;

    my $deadline = time() + $TOTAL_BUDGET;
    my $errors = {};
    my $out = { array => $scfg->{fsaddress}, pools => [] };

    my $sys = _section($errors, 'system', $deadline, 8, sub {
        _fsone(_fscmd($scfg, 'lssystem', undef, {}, storeid => $storeid));
    });
    $out->{system} = _system_view($sys) if $sys;

    my $filtered = 0;
    my $events = _section($errors, 'events', $deadline, 8, sub {
        my ($rows, $f) = _fetch_events($scfg, $storeid);
        $filtered = $f;
        return $rows;
    });
    $out->{events} = _events_view($events // [], undef, $filtered)
        if !exists $errors->{events};

    my $ports = _section($errors, 'ports', $deadline, 8, sub {
        _fscmd($scfg, 'lsportfc', undef, {}, storeid => $storeid);
    });
    $out->{ports} = _ports_view($ports // []) if !exists $errors->{ports};

    my %by_pool;
    for my $p (@$peers) {
        push @{ $by_pool{ $p->[1]->{fspool} // '' } }, $p;
    }

    for my $pool (sort keys %by_pool) {
        my $entry = { pool => $pool, storages => [] };

        my $g = _section($errors, "pool:$pool", $deadline, 6, sub {
            _fsone(_fscmd($scfg, 'lsmdiskgrp', $pool, { bytes => JSON::true }, storeid => $storeid));
        });
        $entry->{capacity} = _pool_view($g) if $g;

        my $vdisks = _section($errors, "volumes:$pool", $deadline, 8, sub {
            _fscmd($scfg, 'lsvdisk', undef,
                { filtervalue => "mdisk_grp_name=$pool", bytes => JSON::true },
                storeid => $storeid);
        });
        # A failed or skipped lsvdisk must NOT publish zeros: "0 volumes"
        # beside real capacity reads as an empty pool, not as missing data.
        # Same rule _collect_health applies to its own list sections.
        my $vol_ok = !exists $errors->{"volumes:$pool"};
        $entry->{pool_volumes} = scalar(@{ $vdisks // [] }) if $vol_ok;

        # Ranked consumers for the pool, from the same rows - the per-pool
        # lsvdisk is fetched once and used three ways (count, per-storage
        # split, ranking), so this section adds no REST traffic of its own.
        if ($vol_ok) {
            my $top = _top_volumes_view($vdisks // [], $by_pool{$pool},
                limit => 10, foreign_names => $opt{foreign_names});
            $top->{fill} = _collect_fill($scfg, $storeid, $pool, $g,
                $top->{volumes}, $errors, $deadline);
            $entry->{top} = $top;
        }

        # One lsvdisk per pool, counted per storage by each storage's prefix.
        for my $p (@{ $by_pool{$pool} }) {
            my ($id, $s) = @$p;
            my $row = {
                storage   => $id,
                prefix    => $s->{fsprefix},
                thin      => ($s->{fsthin}      ? 1 : 0),
                snapshots => ($s->{fssnapshots} ? 1 : 0),
            };
            if ($vol_ok) {
                my $v = _volumes_view($vdisks // [], $s);
                $row->{volumes}     = $v->{ours};
                $row->{provisioned} = $v->{ours_provisioned};
            }
            push @{ $entry->{storages} }, $row;
        }
        push @{ $out->{pools} }, $entry;
    }

    $out->{errors} = $errors if %$errors;
    return $out;
}

__PACKAGE__->register_method({
    name => 'overview',
    path => '{storage}/overview',
    method => 'GET',
    description => "Array-wide overview for every flashsystem storage sharing "
        . "this storage's array: system identity, per-pool capacity, the storages "
        . "using each pool, FC port state and unfixed array alerts. Read-only. "
        . "Array facts and each pool are fetched once regardless of how many "
        . "storages share them.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $cfg = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $param->{storage});
        die "storage '$param->{storage}' is not a flashsystem storage\n"
            if ($scfg->{type} // '') ne 'flashsystem';

        my $addr = $scfg->{fsaddress} // '';
        my $peers = [];
        for my $id (sort keys %{ $cfg->{ids} // {} }) {
            my $s = $cfg->{ids}->{$id};
            next if ($s->{type} // '') ne 'flashsystem';
            next if ($s->{fsaddress} // '') ne $addr;
            next if !$rpcenv->check_any($authuser, "/storage/$id",
                [ 'Datastore.Audit', 'Datastore.Allocate' ], 1);
            push @$peers, [ $id, $s ];
        }
        # Foreign volume NAMES are array-wide information. A caller who can
        # audit one storage should not thereby learn what another tenant
        # keeps in the shared pool, so names need audit on the whole storage
        # tree; without it foreign consumers are still counted and sized,
        # just not named.
        my $foreign_names = $rpcenv->check_any($authuser, "/storage",
            [ 'Datastore.Audit', 'Datastore.Allocate' ], 1) ? 1 : 0;
        return _collect_overview($param->{storage}, $scfg, $peers,
            foreign_names => $foreign_names);
    },
});

# ---- performance ------------------------------------------------------------

# Deliberately a SEPARATE endpoint rather than more sections on overview.
# Capacity and performance are looked at at different moments, they fail
# independently, and a slow lssystemstats must not be able to starve the pool
# capacity the overview exists to show. Its own deadline, its own errors, and
# the panel fetches it only when the performance section is on screen.
sub _collect_performance {
    my ($storeid, $scfg) = @_;

    my $deadline = time() + $TOTAL_BUDGET;
    my $errors = {};
    my $out = { array => $scfg->{fsaddress} };

    my $sys = _section($errors, 'system', $deadline, 6, sub {
        _fsone(_fscmd($scfg, 'lssystem', undef, {}, storeid => $storeid));
    });
    $out->{system} = _system_view($sys) if $sys;

    # Per-node FIRST. lsnodestats is present in IBM's published REST schema;
    # lssystemstats is not (absent from both 8.7.0 and 9.1.3), even though the
    # CLI documents it - so the confirmed call is the one we depend on, and
    # the system-wide call is treated as the optimisation it is.
    my $nstats = _section($errors, 'nodes', $deadline, 8, sub {
        _fscmd($scfg, 'lsnodestats', undef, {}, storeid => $storeid);
    });
    $out->{nodes} = _node_stats_view($nstats // []) if !exists $errors->{nodes};

    my $stats = _section($errors, 'stats', $deadline, 8, sub {
        _fscmd($scfg, 'lssystemstats', undef, {}, storeid => $storeid);
    });
    # Gate on whether STATISTICS ARRIVED, not merely on whether the call
    # avoided dying. _cmd returns undef for a 2xx with an empty body, so a
    # firmware that answers lssystemstats with nothing produces no error and
    # an empty view - and the panel would then print "no statistics reported"
    # directly above a per-canister table full of live numbers.
    my $view = exists $errors->{stats} ? undef : _stats_view($stats // []);
    if ($view && %{ $view->{stats} }) {
        $out->{performance} = $view;
    } else {
        # Recoverable, not unavailable: derive the same view from the
        # per-node rows and say so, rather than reporting a failure beside
        # numbers we can perfectly well produce.
        my $derived = _derive_system_stats($out->{nodes});
        if ($derived) {
            $out->{performance} = $derived;
            delete $errors->{stats};
        } elsif ($view) {
            $out->{performance} = $view;
        }
    }

    my $thr = _section($errors, 'throttles', $deadline, 5, sub {
        _fscmd($scfg, 'lsthrottle', undef, {}, storeid => $storeid);
    });
    $out->{throttles} = _throttles_view($thr // []) if !exists $errors->{throttles};

    # Sparkline data. Last because it is the least certain (see _history_view)
    # and the most expendable: if the budget is gone by now, current+peak have
    # already answered the question.
    # Skipped entirely when lssystemstats itself was unreachable - there is
    # no point spending a second failing request on the same command.
    if ($out->{performance} && !$out->{performance}->{derived}) {
        my $hist = _section($errors, 'history', $deadline, 8, sub {
            _fscmd($scfg, 'lssystemstats', undef,
                # These must be the SPLIT read/write series, because those are
            # what the panel's sparkline column is keyed on. Asking for the
            # combined vdisk_io/vdisk_mb/vdisk_ms instead returns three
            # series no row ever looks up, so the column renders blank on
            # every array - indistinguishable from the -history REST spelling
            # being wrong, which is the very thing this call exists to prove.
            { history => 'vdisk_r_io:vdisk_w_io:vdisk_r_mb:vdisk_w_mb'
                       . ':vdisk_r_ms:vdisk_w_ms' }, storeid => $storeid);
        });
        $out->{history} = _history_view($hist // []) if !exists $errors->{history};
    }

    $out->{errors} = $errors if %$errors;
    return $out;
}

__PACKAGE__->register_method({
    name => 'performance',
    path => '{storage}/performance',
    method => 'GET',
    description => "Array-wide performance statistics: current and five-minute "
        . "peak values for front-end (volume), back-end (mdisk) and drive IOPS, "
        . "bandwidth and latency, per-node CPU and cache, configured throttles, "
        . "and a short history for the front-end series. Read-only. Values are "
        . "array-wide, not specific to this storage.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $cfg = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $param->{storage});
        die "storage '$param->{storage}' is not a flashsystem storage\n"
            if ($scfg->{type} // '') ne 'flashsystem';
        return _collect_performance($param->{storage}, $scfg);
    },
});

# ---- CSI snapshot surface -------------------------------------------------
#
# The reason these exist. A Kubernetes CSI driver needs to create, delete, list
# and restore array snapshots, and Proxmox exposes no per-volume snapshot verb
# to carry that: every snapshot endpoint PVE offers is VM-scoped with no disk
# selector, so a snapshot of the CSI holder VM would capture every PVC on it.
#
# The alternative to these endpoints is giving Kubernetes the array's
# credentials directly. That is worse in four concrete ways, and this is the
# whole argument for the split:
#
#   1. A Storage Virtualize role cannot be scoped to "these volumes". Ownership
#      groups inherit from CHILD pools and this array has none, and snapshots
#      are not an ownable object type at all. So the array-side credential is
#      necessarily broad; a PVE token is ACL-scopeable to /storage/<id>.
#   2. `fsprefix` would have to cross into Kubernetes and stay in step with
#      storage.cfg, making the naming contract load-bearing in two codebases.
#   3. Any leaked array credential that can snapshot can also
#      `restorefromsnapshot` — which destroys data WITHOUT deleting an object,
#      so it trips no capacity or object-count monitoring.
#   4. Kanister job pods run in the PROTECTED APPLICATION's namespace, so a
#      blueprint holding array credentials mounts them into a pod in every
#      namespace it backs up.
#
# All four are writes, so all four require Datastore.Allocate rather than the
# Datastore.Audit the reporting endpoints accept. protected => 1 because
# resolving the REST credential reads root-only /etc/pve/priv/storage/<id>.pw.

# Resolve and validate the storage once, the way every endpoint here needs it.
# Serialise the mutating CSI endpoints cluster-wide.
#
# Every write here is read-then-act: create probes lsvolumesnapshot for an
# existing row before addsnapshot, delete resolves an id before rmsnapshot,
# restore resolves a source before mkvolume. Storage Virtualize snapshot names
# are NOT system-unique, so two concurrent CreateSnapshots for the same CSI
# name both see "absent" and both succeed - leaving two array objects with the
# same name, of which csi_snapshot_delete can only ever remove the first. The
# second holds physical capacity that Kubernetes has no object for.
#
# That is not a theoretical race: external-snapshotter retries CreateSnapshot
# on any error, including a read-back that timed out after addsnapshot had
# already taken effect.
#
# cluster_lock_storage with $shared = 1 takes /etc/pve/priv/lock/storage-<id>
# through pmxcfs, so it holds across all 12 nodes rather than per-node -
# which is what this needs, since the driver may reach any node.
sub _fs_locked {
    my ($storeid, $scfg, $code) = @_;
    # PVE::Storage::Plugin->cluster_lock_storage - a CLASS METHOD on the
    # plugin base class, not a function in PVE::Storage. An earlier cut called
    # PVE::Storage::cluster_lock_storage, which does not exist anywhere in
    # PVE, and every API test passed anyway because the test stub had defined
    # the invented function. It failed on the first real CreateSnapshot with
    # "Undefined subroutine &PVE::Storage::cluster_lock_storage".
    #
    # Verified against /usr/share/perl5/PVE/Storage/Plugin.pm:759 on a node:
    #   sub cluster_lock_storage {
    #       my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
    #
    # $shared true  -> PVE::Cluster::cfs_lock_storage, i.e. through pmxcfs, so
    #                  the lock holds across all 12 nodes. This is the case
    #                  that matters: our storages are all shared 1, and the
    #                  driver may reach any node.
    # $shared false -> a local flock under /var/lock/pve-manager.
    # It dies on the inner code's error rather than swallowing it, so a failed
    # snapshot still surfaces to the caller.
    return PVE::Storage::Plugin->cluster_lock_storage(
        $storeid, $scfg->{shared}, undef, $code);
}

sub _fs_scfg {
    my ($storeid) = @_;
    my $cfg = PVE::Storage::config();
    my $scfg = PVE::Storage::storage_config($cfg, $storeid);
    die "storage '$storeid' is not a flashsystem storage\n"
        if ($scfg->{type} // '') ne 'flashsystem';
    die "storage '$storeid' does not have array snapshots enabled"
        . " (set 'fssnapshots 1' after validating firmware)\n"
        if !$scfg->{fssnapshots};
    return $scfg;
}

my $PLUGIN = 'PVE::Storage::Custom::FlashSystemPlugin';

__PACKAGE__->register_method({
    name => 'snapshot_list',
    path => '{storage}/snapshot',
    method => 'GET',
    description => "List array snapshots belonging to this storage. Scoped to the "
        . "storage's fsprefix, so the rest of the array's snapshot namespace - the "
        . "PVE VM estate's and any other consumer's - is not reported. Pass volname "
        . "to narrow to one volume. This is also the read half of orphan "
        . "reconciliation: the CSI driver's own ListSnapshots is unimplemented "
        . "upstream, so without this there is no way to diff array state against "
        . "VolumeSnapshotContent objects.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
            volname => { type => 'string', optional => 1,
                description => 'Restrict to snapshots of this volume.' },
        },
    },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my ($param) = @_;
        my $scfg = _fs_scfg($param->{storage});
        return $PLUGIN->csi_snapshot_list($scfg, $param->{storage}, $param->{volname});
    },
});

__PACKAGE__->register_method({
    name => 'snapshot_create',
    path => '{storage}/snapshot',
    method => 'POST',
    description => "Create an array snapshot of one volume, named deterministically "
        . "from the caller's snapshot name. IDEMPOTENT by that name: calling twice "
        . "returns the same snapshot rather than creating a second one, which is "
        . "what CSI CreateSnapshot requires of a retry. Refuses with ALREADY_EXISTS "
        . "when the derived array-side name is already in use by a DIFFERENT volume, "
        . "rather than aliasing two snapshots onto one array object.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Allocate' ] ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
            volname => { type => 'string',
                description => 'Volume to snapshot, e.g. vm-9999-pvc-<uuid>.' },
            name    => { type => 'string', maxLength => 256,
                description => "The caller's snapshot name, e.g. the CSI "
                    . "snapshot-<uuid>. Only its digest reaches the array: the "
                    . "63-character object-name cap leaves 9 characters for a "
                    . "snapshot name on a 4-character fsprefix." },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $scfg = _fs_scfg($param->{storage});
        return _fs_locked($param->{storage}, $scfg, sub {
            return $PLUGIN->csi_snapshot_create(
                $scfg, $param->{storage}, $param->{volname}, $param->{name});
        });
    },
});

__PACKAGE__->register_method({
    name => 'snapshot_delete',
    path => '{storage}/snapshot',
    method => 'DELETE',
    description => "Delete one array snapshot by its array-side name. IDEMPOTENT on "
        . "absence, which CSI DeleteSnapshot requires. Refuses to touch a snapshot "
        . "outside this storage's fsprefix, or one the array cannot positively "
        . "attribute to the owning volume - snapshot names are not system-unique on "
        . "Storage Virtualize, and this array's namespace is shared.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Allocate' ] ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node     => get_standard_option('pve-node'),
            storage  => get_standard_option('pve-storage-id'),
            snapname => { type => 'string', maxLength => 63,
                description => 'Array snapshot object name, as returned by the '
                    . 'create or list endpoints.' },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $scfg = _fs_scfg($param->{storage});
        return _fs_locked($param->{storage}, $scfg, sub {
            return $PLUGIN->csi_snapshot_delete($scfg, $param->{storage}, $param->{snapname});
        });
    },
});

__PACKAGE__->register_method({
    name => 'volume_from_snapshot',
    path => '{storage}/volume-from-snapshot',
    method => 'POST',
    description => "Create a NEW volume pre-populated from an existing array "
        . "snapshot, and return its PVE volume name. This is the restore half of CSI: "
        . "CreateVolume with a snapshot content source. The array does the "
        . "population (mkvolume -type thinclone|clone), and because list_images "
        . "enumerates the array rather than local metadata, the result is visible to "
        . "PVE immediately with nothing else to update.\n\n"
        . "NOT YET VALIDATED ON HARDWARE: mkvolume is the one command family this "
        . "plugin had never issued. Run tools/probe-clone-from-snapshot.sh first.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Allocate' ] ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node     => get_standard_option('pve-node'),
            storage  => get_standard_option('pve-storage-id'),
            snapname => { type => 'string', maxLength => 63,
                description => 'Array snapshot object name to populate from.' },
            volname  => { type => 'string', optional => 1,
                description => 'Name for the NEW volume. A CSI driver has already '
                    . 'minted this and embedded it in the PersistentVolume\'s '
                    . 'volumeHandle before asking for the restore, so it must be '
                    . 'honoured rather than replaced. Must match the plugin\'s '
                    . 'volume-name grammar and must not already exist.' },
            vmid     => get_standard_option('pve-vmid', {
                optional => 1,
                description => 'Owner VMID, used to derive a free volume name when '
                    . 'volname is not given. For CSI volumes the driver\'s holder id '
                    . '(9999 by default) - the placeholder every PVC volume is named '
                    . 'under. Exactly one of volname or vmid is required.' }),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $scfg = _fs_scfg($param->{storage});
        die "exactly one of 'volname' or 'vmid' is required\n"
            if defined($param->{volname}) == defined($param->{vmid});
        return _fs_locked($param->{storage}, $scfg, sub {
            return $PLUGIN->csi_volume_from_snapshot(
                $scfg, $param->{storage}, $param->{snapname},
                volname => $param->{volname}, vmid => $param->{vmid});
        });
    },
});

1;
