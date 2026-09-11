#!/usr/bin/env perl
#
# Unit tests for PVE::API2::FlashSystem — the health & capacity API
# (see UPSTREAM.md section 3). PVE's framework is stubbed; the pure view
# helpers are exercised with fixtures, and the registered API surface is
# asserted through the RESTHandler stub.
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

# The plugin must load first (the API module reuses its helpers).
# Dual-home: ../files/ in a vendored layout, ../ in the standalone repo.
my ($PLUGIN) = grep { -f } ("$BIN/../files/FlashSystemPlugin.pm",
                            "$BIN/../FlashSystemPlugin.pm");
require $PLUGIN;
my ($API) = grep { -f } ("$BIN/../files/FlashSystemAPI.pm",
                         "$BIN/../api/FlashSystemAPI.pm");
require $API;

my $M = 'PVE::API2::FlashSystem';

my $fail = 0;
sub ok_case {
    my ($name, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && $got eq $want);
    printf "%-34s %-30s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

# ---- registered API surface -------------------------------------------------
my $reg = PVE::RESTHandler::registered($M);
ok_case('registered method set',
    join(',', sort map { $_->{name} } @$reg),
    'diridx,health,index,overview,performance,snapshot_create,snapshot_delete,'
    . 'snapshot_list,volume_from_snapshot');
my ($health) = grep { $_->{name} eq 'health' } @$reg;
ok_case('health exists', ($health ? 'yes' : 'no'), 'yes');
# protected: the handler reads root-only /etc/pve/priv — must run in pvedaemon.
ok_case('health is protected', ($health && $health->{protected} ? 1 : 0), 1);
ok_case('health proxied to node', ($health && $health->{proxyto} // ''), 'node');
ok_case('health has perm check',
    ($health && $health->{permissions} && $health->{permissions}->{check} ? 'yes' : 'no'), 'yes');

my ($perf) = grep { $_->{name} eq 'performance' } @$reg;
ok_case('performance is protected', ($perf && $perf->{protected} ? 1 : 0), 1);
ok_case('performance path', ($perf && $perf->{path} // ''), '{storage}/performance');
ok_case('performance has perm check',
    ($perf && $perf->{permissions} && $perf->{permissions}->{check} ? 'yes' : 'no'), 'yes');

# ---- CSI snapshot surface: the WRITE endpoints -------------------------------
# These four are what lets a Kubernetes CSI driver drive array snapshots
# WITHOUT holding array credentials. Three properties are load-bearing and all
# three are silent if they regress, so they are pinned here:
#
#   Datastore.Allocate, not Audit  — a reader must not be able to create or
#       delete array objects. The reporting endpoints deliberately accept
#       Audit; these must not.
#   protected                      — the handler resolves the array credential
#       from root-only /etc/pve/priv/storage/<id>.pw, which pveproxy's www-data
#       cannot read. Without this the endpoint fails at runtime only.
#   proxyto node                   — the array credential and the REST session
#       live on the node, not on whichever node received the request.
for my $c (
    [ 'snapshot_list',        '{storage}/snapshot',             'GET',    0 ],
    [ 'snapshot_create',      '{storage}/snapshot',             'POST',   1 ],
    [ 'snapshot_delete',      '{storage}/snapshot',             'DELETE', 1 ],
    [ 'volume_from_snapshot', '{storage}/volume-from-snapshot', 'POST',   1 ],
) {
    my ($name, $path, $method, $write) = @$c;
    my ($m) = grep { $_->{name} eq $name } @$reg;
    ok_case("$name exists",     ($m ? 'yes' : 'no'), 'yes');
    ok_case("$name path",       ($m && $m->{path} // ''), $path);
    ok_case("$name method",     ($m && $m->{method} // ''), $method);
    ok_case("$name protected",  ($m && $m->{protected} ? 1 : 0), 1);
    ok_case("$name proxyto",    ($m && $m->{proxyto} // ''), 'node');
    my $perms = $m && $m->{permissions} && $m->{permissions}->{check};
    ok_case("$name has perm check", ($perms ? 'yes' : 'no'), 'yes');
    # The privilege list is the third element of ['perm', path, [privs], ...].
    my $privs = $perms && ref($perms) eq 'ARRAY' ? $perms->[2] : undef;
    my $has_audit = $privs && grep { $_ eq 'Datastore.Audit' } @$privs;
    if ($write) {
        ok_case("$name requires Allocate only",
            ($privs && @$privs == 1 && $privs->[0] eq 'Datastore.Allocate') ? 'yes' : 'no', 'yes');
        ok_case("$name rejects Audit", ($has_audit ? 'accepts' : 'rejects'), 'rejects');
    } else {
        ok_case("$name accepts Audit", ($has_audit ? 'yes' : 'no'), 'yes');
    }
}

# The volume-from-snapshot path must NOT collide with the snapshot path, or
# PVE's router would shadow one with the other.
ok_case('snapshot paths are distinct',
    (grep { ($_->{path} // '') eq '{storage}/volume-from-snapshot' } @$reg) ? 'yes' : 'no', 'yes');

# ---- _whitelist --------------------------------------------------------------
my $wl = PVE::API2::FlashSystem::_whitelist({ a => 1, b => undef, c => 3 }, qw(a b));
ok_case('whitelist keeps listed', $wl->{a}, 1);
ok_case('whitelist drops undef', (exists $wl->{b} ? 'yes' : 'no'), 'no');
ok_case('whitelist drops unlisted', (exists $wl->{c} ? 'yes' : 'no'), 'no');

# ---- _pool_view (real Pool0_Gold DRP fixture, same as t_status.pl) -----------
my $drp = {
    name => 'Pool0_Gold', status => 'online', data_reduction => 'yes',
    capacity                => '65120294141952',
    free_capacity           => '48911087566848',
    used_capacity           => '15124972175360',
    physical_capacity       => '14020451500032',
    physical_free_capacity  => '4550058049536',
};
my $pv = PVE::API2::FlashSystem::_pool_view($drp);
ok_case('pool: provision total = physical', $pv->{provision_total}, 14020451500032);
ok_case('pool: provision free  = physical', $pv->{provision_free},  4550058049536);
ok_case('pool: used pct rounded', $pv->{provision_used_pct}, 68);
ok_case('pool: reduction flag kept', $pv->{data_reduction}, 'yes');

# ---- _volumes_view ------------------------------------------------------------
my $scfg = { fsprefix => 'pvecl1' };
my $vols = PVE::API2::FlashSystem::_volumes_view([
    { name => 'pvecl1-vm-1-disk-0',  capacity => '100' },
    { name => 'other-vm-1-disk-0',   capacity => '50'  },   # foreign prefix
    { name => 'pvecl1-vm-2-state-x', capacity => '25'  },
    { name => 'pvecl1-tierlun-00',   capacity => '999' },   # ours, not a PVE volume
], $scfg);
ok_case('volumes: pool total', $vols->{pool_total}, 4);
ok_case('volumes: ours only', $vols->{ours}, 2);
ok_case('volumes: ours bytes', $vols->{ours_provisioned}, 125);

# A storage with NO fsprefix: the translation is a pass-through, so the shape
# test is the only thing keeping other consumers' volumes out of the count.
# Live 2026-08-26 this reported 6 volumes / 5.6 TB where PVE managed 4 / 103 GB.
my $noprefix = PVE::API2::FlashSystem::_volumes_view([
    { name => 'vm-102-disk-0',        capacity => '34359738368' },
    { name => 'vm-102-state-test',    capacity => '34808528896' },
    { name => 'pvecl1-vm-196-disk-0', capacity => '34359738368' },   # another storage's
    { name => 'volume-9f3a-openstack', capacity => '2750000000000' }, # not PVE at all
], {});
ok_case('volumes: prefixless PVE shapes only', $noprefix->{ours}, 2);
ok_case('volumes: prefixless pool total', $noprefix->{pool_total}, 4);
ok_case('volumes: prefixless bytes', $noprefix->{ours_provisioned}, 69168267264);

# ---- _events_view -------------------------------------------------------------
# Shapes taken verbatim from a live 8.7.0.3 array (FlashSystem 5200): the
# `fixed=no` query returned 1317 rows, of which exactly one carried an error
# code. Informational rows have error_code "" — they must be counted but
# never listed, or a real pool-space warning hides behind copy-format noise.
my $ev = PVE::API2::FlashSystem::_events_view([
    { sequence_number => '1569', error_code => '1867',
      description => 'Data reduction pool space warning',
      object_type => 'mdiskgrp', object_name => 'Pool1_Silver',
      last_timestamp => '260826031438', secret => 'x' },
    { sequence_number => '1568', error_code => '',
      description => 'SAS discovery occurred, configuration changes complete' },
    { sequence_number => '1565', error_code => '',
      description => 'Virtual Disk Copy Format Completed' },
    { sequence_number => '1400', error_code => '0',
      description => 'zero code is informational, not an alert' },
]);
ok_case('events: alerts only', $ev->{alerts}, 1);
ok_case('events: total counted', $ev->{unfixed_total}, 4);
ok_case('events: alert listed', $ev->{recent}[0]{error_code}, '1867');
ok_case('events: object name kept', $ev->{recent}[0]{object_name}, 'Pool1_Silver');
ok_case('events: informational not listed', scalar(@{ $ev->{recent} }), 1);
ok_case('events: unknown keys dropped',
    (exists $ev->{recent}[0]{secret} ? 'yes' : 'no'), 'no');

# All-informational log: zero alerts, empty list, total still reported.
my $quiet = PVE::API2::FlashSystem::_events_view([
    { sequence_number => '2', error_code => '', description => 'chatter' },
    { sequence_number => '1', description => 'no error_code key at all' },
]);
ok_case('events: quiet array = 0 alerts', $quiet->{alerts}, 0);
ok_case('events: quiet recent empty', scalar(@{ $quiet->{recent} }), 0);
ok_case('events: quiet total kept', $quiet->{unfixed_total}, 2);

# Newest-first ordering and the cap apply to alerts.
my $many = PVE::API2::FlashSystem::_events_view([
    { sequence_number => '10', error_code => '1867', description => 'a' },
    { sequence_number => '30', error_code => '1400', description => 'c' },
    { sequence_number => '20', error_code => '2030', description => 'b' },
], 2);
ok_case('events: alerts capped', scalar(@{ $many->{recent} }), 2);
ok_case('events: alerts newest first', $many->{recent}[0]{sequence_number}, '30');

# ---- _ports_view --------------------------------------------------------------
my $pp = PVE::API2::FlashSystem::_ports_view([
    { id => 1, status => 'active' },
    { id => 2, status => 'active' },
    { id => 3, status => 'inactive_unconfigured' },
]);
ok_case('ports: total', $pp->{total}, 3);
ok_case('ports: active', $pp->{active}, 2);
ok_case('ports: status buckets', $pp->{by_status}{inactive_unconfigured}, 1);

# ---- _budget (shared deadline: min(cap, remaining), floor 0) -----------------
my $now = time();
ok_case('budget: cap wins',      PVE::API2::FlashSystem::_budget($now + 100, 8), 8);
ok_case('budget: remaining wins', (PVE::API2::FlashSystem::_budget($now + 3, 8) <= 3
                                   && PVE::API2::FlashSystem::_budget($now + 3, 8) >= 2) ? 'in-range' : 'out', 'in-range');
ok_case('budget: exhausted -> 0', PVE::API2::FlashSystem::_budget($now - 1, 8), 0);

# ---- _system_view -------------------------------------------------------------
my $sv = PVE::API2::FlashSystem::_system_view(
    { name => 'demo', code_level => '8.7.0.0', console_IP => '192.0.2.1:443' });
ok_case('system: name kept', $sv->{name}, 'demo');
ok_case('system: IPs dropped', (exists $sv->{console_IP} ? 'yes' : 'no'), 'no');

# ---- overview: registered surface + peer/pool grouping ----------------------
# The datacenter panel calls ONE overview per array. Its value is the
# de-duplication: array facts once, each pool once, however many storages
# share it. Here we assert the registered method and the shape of the
# per-pool storage breakdown (the REST fan-out itself needs an array).
my ($ov) = grep { $_->{name} eq 'overview' } @$reg;
ok_case('overview registered', ($ov ? 'yes' : 'no'), 'yes');
ok_case('overview is protected', ($ov && $ov->{protected} ? 1 : 0), 1);
ok_case('overview path', ($ov && $ov->{path} // ''), '{storage}/overview');
ok_case('overview has perm check',
    ($ov && $ov->{permissions} && $ov->{permissions}->{check} ? 'yes' : 'no'), 'yes');

# index must expose the array address, or the panel cannot group by array
# and would issue one overview request per storage instead of per array.
my ($ix) = grep { $_->{name} eq 'index' } @$reg;
ok_case('index returns address',
    ($ix && $ix->{returns}{items}{properties}{address} ? 'yes' : 'no'), 'yes');

# Two storages sharing one pool, counted from a SINGLE lsvdisk result by
# each storage's own prefix — the saving the endpoint exists for.
my $shared = [
    { name => 'pvecl1_Gold-vm-1-disk-0', capacity => '100' },
    { name => 'k8sg-vm-9999-pvc-abc',    capacity => '50'  },
    { name => 'foreign-vm-1-disk-0',     capacity => '999' },
];
my $tier = PVE::API2::FlashSystem::_volumes_view($shared, { fsprefix => 'pvecl1_Gold' });
my $k8s  = PVE::API2::FlashSystem::_volumes_view($shared, { fsprefix => 'k8sg' });
ok_case('overview: tier storage sees its own', $tier->{ours}, 1);
ok_case('overview: k8s storage sees its own', $k8s->{ours}, 1);
ok_case('overview: neither sees the foreign one',
    ($tier->{ours} + $k8s->{ours} + 1), scalar(@$shared));

# ---- overview degradation: a failed section must never publish zeros --------
# The whole point of the panel is capacity truth. "0 volumes in pool" beside a
# real capacity bar reads as an empty pool, not as a failed query — so a
# section that errored must omit its fields, not zero them.
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        die "lsvdisk exploded\n" if $command eq 'lsvdisk';
        return [] if $command eq 'lseventlog' || $command eq 'lsportfc';
        return { name => 'demo', code_level => '8.7.0.3' } if $command eq 'lssystem';
        return {
            name => 'P1', status => 'online',
            capacity => '100', free_capacity => '40',
            physical_capacity => '100', physical_free_capacity => '40',
        };
    };
    my $degraded = PVE::API2::FlashSystem::_collect_overview(
        'S', { fsaddress => 'a', fspool => 'P1' },
        [ [ 'S', { fsaddress => 'a', fspool => 'P1', fsprefix => 'p' } ] ]);
    my $pool = $degraded->{pools}[0];
    ok_case('degrade: volume count omitted',
        (exists $pool->{pool_volumes} ? 'reported-as-zero' : 'omitted'), 'omitted');
    ok_case('degrade: storage volumes omitted',
        (exists $pool->{storages}[0]{volumes} ? 'reported-as-zero' : 'omitted'), 'omitted');
    ok_case('degrade: storage identity kept',
        $pool->{storages}[0]{prefix}, 'p');
    ok_case('degrade: capacity still reported',
        ($pool->{capacity} && $pool->{capacity}{provision_total} ? 'yes' : 'no'), 'yes');
    ok_case('degrade: failure recorded',
        (exists $degraded->{errors}{'volumes:P1'} ? 'yes' : 'no'), 'yes');
}


# ---- _num --------------------------------------------------------------------
# Statistics arrive as JSON strings; non-numeric must become undef, not 0, so
# "not reported" stays distinguishable from a real zero.
ok_case('num: integer string', PVE::API2::FlashSystem::_num('42'), 42);
ok_case('num: zero stays zero', PVE::API2::FlashSystem::_num('0'), 0);
ok_case('num: decimal', PVE::API2::FlashSystem::_num('1.5'), 1.5);
ok_case('num: empty -> undef', PVE::API2::FlashSystem::_num(''), undef);
ok_case('num: text -> undef', PVE::API2::FlashSystem::_num('n/a'), undef);
ok_case('num: undef -> undef', PVE::API2::FlashSystem::_num(undef), undef);
# Same Unicode-digit bypass pinned in t_names.pl: \d without /a matches these.
ok_case('num: fullwidth digits rejected',
    PVE::API2::FlashSystem::_num("\x{FF11}\x{FF12}"), undef);

# ---- _stats_view (real lssystemstats row shape) -------------------------------
my $stv = PVE::API2::FlashSystem::_stats_view([
    { stat_name => 'cpu_pc',    stat_current => '5',  stat_peak => '9',  stat_peak_time => '260826104304' },
    { stat_name => 'vdisk_ms',  stat_current => '34', stat_peak => '52', stat_peak_time => '260826103954' },
    { stat_name => 'vdisk_io',  stat_current => '2070', stat_peak => '2276', stat_peak_time => '260826103904' },
    { stat_name => 'made_up_stat', stat_current => '1', stat_peak => '1' },
]);
ok_case('stats: cpu current', $stv->{stats}{cpu_pc}{current}, 5);
ok_case('stats: latency peak', $stv->{stats}{vdisk_ms}{peak}, 52);
ok_case('stats: peak time kept', $stv->{stats}{vdisk_ms}{peak_time}, '260826103954');
ok_case('stats: unknown stat dropped',
    (exists $stv->{stats}{made_up_stat} ? 'yes' : 'no'), 'no');
ok_case('stats: raw row count', $stv->{reported}, 4);

# ---- _node_stats_view ---------------------------------------------------------
# The point of per-node data is spotting ONE hot canister, so grouping by node
# must survive interleaved rows (which is how the array emits them).
my $nv = PVE::API2::FlashSystem::_node_stats_view([
    { node_id => '1', node_name => 'node1', stat_name => 'cpu_pc',   stat_current => '5',  stat_peak => '9' },
    { node_id => '2', node_name => 'node2', stat_name => 'cpu_pc',   stat_current => '6',  stat_peak => '7' },
    { node_id => '1', node_name => 'node1', stat_name => 'vdisk_ms', stat_current => '3',  stat_peak => '8' },
    { node_id => '2', node_name => 'node2', stat_name => 'vdisk_ms', stat_current => '100', stat_peak => '104' },
    { stat_name => 'cloud_up_mb', stat_current => '0' },
]);
ok_case('nodestats: two nodes', scalar(@{ $nv->{nodes} }), 2);
ok_case('nodestats: sorted by name', $nv->{nodes}[0]{node}, 'node1');
ok_case('nodestats: hot canister visible', $nv->{nodes}[1]{stats}{vdisk_ms}{current}, 100);
ok_case('nodestats: node-less row skipped',
    (grep { !length $_->{node} } @{ $nv->{nodes} }) ? 'leaked' : 'skipped', 'skipped');

# ---- _history_view ------------------------------------------------------------
my $hv = PVE::API2::FlashSystem::_history_view([
    { sample_time => '260826104234', stat_name => 'vdisk_io', stat_value => '2041' },
    { sample_time => '260826104224', stat_name => 'vdisk_io', stat_value => '2120' },
    { sample_time => '260826104229', stat_name => 'vdisk_io', stat_value => '2102' },
    { sample_time => '260826104229', stat_name => 'bogus',    stat_value => '1' },
], 2);
ok_case('history: chronological order', join(',', @{ $hv->{vdisk_io} }), '2102,2041');
ok_case('history: keep-last applied', scalar(@{ $hv->{vdisk_io} }), 2);
ok_case('history: unknown series dropped', (exists $hv->{bogus} ? 'yes' : 'no'), 'no');

# ---- _throttles_view ----------------------------------------------------------
my $tv = PVE::API2::FlashSystem::_throttles_view([
    { throttle_id => '2', throttle_name => 'throttle2', object_id => '9',
      object_name => 'pvecl1_Gold-vm-124-disk-0', throttle_type => 'vdisk', IOPs_limit => '20' },
]);
ok_case('throttles: total', $tv->{total}, 1);
ok_case('throttles: mixed-case field kept', $tv->{throttles}[0]{IOPs_limit}, '20');
ok_case('throttles: blank bandwidth dropped',
    (exists $tv->{throttles}[0]{bandwidth_limit_MB} ? 'yes' : 'no'), 'no');

# ---- _classify_volume ---------------------------------------------------------
# A storage with no prefix translates pass-through, so it matches any
# PVE-shaped name in the pool. When a PREFIXED storage also matches, the
# prefixed one is the real owner and must win regardless of peer order.
my $prefixed = [ 'tier-gold', { fsprefix => 'pvecl1_Gold' } ];
my $bare     = [ 'legacy',    {} ];
my $c1 = PVE::API2::FlashSystem::_classify_volume('pvecl1_Gold-vm-124-disk-0', [ $bare, $prefixed ]);
ok_case('classify: prefixed owner wins', $c1->{storage}, 'tier-gold');
ok_case('classify: volname translated', $c1->{volname}, 'vm-124-disk-0');
ok_case('classify: vmid extracted', $c1->{vmid}, 124);
my $c2 = PVE::API2::FlashSystem::_classify_volume('vm-77-disk-1', [ $prefixed, $bare ]);
ok_case('classify: bare storage claims unprefixed', $c2->{storage}, 'legacy');
ok_case('classify: foreign object unowned',
    PVE::API2::FlashSystem::_classify_volume('VMWARE_LUN_04', [ $prefixed, $bare ]), undef);
ok_case('classify: array snapshot object unowned',
    PVE::API2::FlashSystem::_classify_volume('pvecl1_Gold-vm-124-disk-0.snap1', [ $prefixed ]), undef);

# ---- _top_volumes_view --------------------------------------------------------
my @pool_rows = (
    { name => 'pvecl1_Gold-vm-124-disk-0', capacity => '107374182400', status => 'online', se_copy_count => '0' },
    { name => 'pvecl1_Gold-vm-124-disk-1', capacity => '53687091200',  status => 'online', se_copy_count => '0' },
    { name => 'pvecl1_Gold-vm-900-disk-0', capacity => '10737418240',  status => 'offline', se_copy_count => '1' },
    { name => 'VMWARE_PROD_LUN0',          capacity => '2199023255552', status => 'online', se_copy_count => '0' },
);
my $tvv = PVE::API2::FlashSystem::_top_volumes_view(\@pool_rows, [ $prefixed ], limit => 2);
ok_case('top: largest ours first', $tvv->{volumes}[0]{name}, 'vm-124-disk-0');
ok_case('top: limit honoured', scalar(@{ $tvv->{volumes} }), 2);
ok_case('top: our count', $tvv->{ours}{count}, 3);
ok_case('top: our bytes summed', $tvv->{ours}{capacity}, 171798691840);
# The foreign LUN is by far the biggest thing in the pool - counting it is the
# whole point, since on a shared pool it is often what is filling it.
ok_case('top: foreign counted', $tvv->{foreign}{count}, 1);
ok_case('top: foreign bytes', $tvv->{foreign}{capacity}, 2199023255552);
ok_case('top: foreign unnamed by default',
    (exists $tvv->{foreign}{volumes}[0]{name} ? 'named' : 'anonymous'), 'anonymous');
ok_case('top: offline volume flagged', $tvv->{attention}[0]{name}, 'vm-900-disk-0');
ok_case('top: attention total', $tvv->{attention_total}, 1);
# A corrupt fast-write state is a repair job, not a slow disk - it must reach
# the attention list even while the volume reports itself online.
my $corrupt = PVE::API2::FlashSystem::_top_volumes_view([
    { name => 'pvecl1_Gold-vm-500-disk-0', capacity => '1073741824',
      status => 'online', fast_write_state => 'corrupt' },
], [ $prefixed ], limit => 5);
ok_case('top: corrupt flagged despite online', $corrupt->{attention_total}, 1);
ok_case('top: corrupt state reported', $corrupt->{attention}[0]{fast_write_state}, 'corrupt');

# ---- _sev_fill_view / _apply_fill --------------------------------------------
# autoexpand ON: real_capacity grows, so the meaningful denominator is the
# PROVISIONED size.
my $fmap = PVE::API2::FlashSystem::_sev_fill_view([
    { vdisk_name => 'pvecl1_Gold-vm-124-disk-0', used_capacity => '5368709120',
      real_capacity => '10737418240', free_capacity => '5368709120',
      autoexpand => 'on', warning => '80' },
    { vdisk_name => 'pvecl1_Gold-vm-124-disk-1', used_capacity => '9126805504',
      real_capacity => '10737418240', autoexpand => 'off' },
    # A data reduction pool returns these fields BLANK; such a row must not
    # be treated as a volume with zero usage.
    { vdisk_name => 'pvecl1_Gold-vm-900-disk-0', used_capacity => '',
      real_capacity => '', free_capacity => '' },
]);
ok_case('fill: blank DRP row skipped',
    (exists $fmap->{by_name}{'pvecl1_Gold-vm-900-disk-0'} ? 'kept' : 'skipped'), 'skipped');
ok_case('fill: usable count', $fmap->{usable}, 2);
ok_case('fill: raw copy count', $fmap->{copies}, 3);

my $frows = [
    { array_name => 'pvecl1_Gold-vm-124-disk-0', capacity => 107374182400 },
    { array_name => 'pvecl1_Gold-vm-124-disk-1', capacity => 107374182400 },
    { array_name => 'pvecl1_Gold-vm-777-disk-0', capacity => 107374182400 },
];
my $hits = PVE::API2::FlashSystem::_apply_fill($frows, $fmap);
ok_case('fill: rows measured', $hits, 2);
# 5 GiB used of 100 GiB provisioned.
ok_case('fill: autoexpand uses provisioned', $frows->[0]{fill_pct}, 5);
ok_case('fill: basis provisioned', $frows->[0]{fill_basis}, 'provisioned');
# 8.5 GiB of a fixed 10 GiB allocation - 85%, and at 100% the volume goes
# OFFLINE. Measuring this against the provisioned size would have read 8%.
ok_case('fill: no-autoexpand uses allocated', $frows->[1]{fill_pct}, 85);
ok_case('fill: basis allocated', $frows->[1]{fill_basis}, 'allocated');
ok_case('fill: unlisted volume untouched',
    (exists $frows->[2]{fill_pct} ? 'set' : 'unset'), 'unset');

# ---- _derive_system_stats -----------------------------------------------------
# lssystemstats is absent from IBM's published REST schema, so the per-node
# derivation is a shipped path, not a theoretical one.
my $derived = PVE::API2::FlashSystem::_derive_system_stats({ nodes => [
    { node => 'node1', stats => {
        vdisk_io => { current => 1000, peak => 1200 },
        vdisk_ms => { current => 3,    peak => 8,  peak_time => '260826104224' },
        cpu_pc   => { current => 5,    peak => 9 } } },
    { node => 'node2', stats => {
        vdisk_io => { current => 1500, peak => 1800 },
        vdisk_ms => { current => 100,  peak => 104, peak_time => '260826105624' },
        cpu_pc   => { current => 6,    peak => 7 } } },
] });
ok_case('derive: throughput summed', $derived->{stats}{vdisk_io}{current}, 2500);
ok_case('derive: latency NOT summed', $derived->{stats}{vdisk_ms}{current}, 100);
ok_case('derive: worst canister peak', $derived->{stats}{vdisk_ms}{peak}, 104);
ok_case('derive: peak time follows the peak',
    $derived->{stats}{vdisk_ms}{peak_time}, '260826105624');
ok_case('derive: percentage takes max', $derived->{stats}{cpu_pc}{current}, 6);
ok_case('derive: marked as derived', $derived->{derived}, 1);
ok_case('derive: no nodes -> undef',
    PVE::API2::FlashSystem::_derive_system_stats({ nodes => [] }), undef);
ok_case('top: thin flag from se_copy_count', $tvv->{attention}[0]{thin}, 1);
# Per-VM rollup: two disks on one VM must aggregate, not appear twice.
my ($vm124) = grep { $_->{vmid} == 124 } @{ $tvv->{vms} };
ok_case('top: vm disks aggregated', $vm124->{disks}, 2);
ok_case('top: vm bytes aggregated', $vm124->{capacity}, 161061273600);
ok_case('top: vm storages listed', join(',', @{ $vm124->{storages} }), 'tier-gold');

my $named = PVE::API2::FlashSystem::_top_volumes_view(\@pool_rows, [ $prefixed ],
    limit => 5, foreign_names => 1);
ok_case('top: foreign named when permitted',
    $named->{foreign}{volumes}[0]{name}, 'VMWARE_PROD_LUN0');

# ---- _events_view filtered/unfiltered ------------------------------------------
my @evrows = (
    { sequence_number => '120', error_code => '1867', description => 'DRP space warning' },
    { sequence_number => '119', error_code => '',     description => 'Copy format completed' },
);
my $unfiltered = PVE::API2::FlashSystem::_events_view(\@evrows, 10, 0);
ok_case('events: alerts counted', $unfiltered->{alerts}, 1);
ok_case('events: total kept when unfiltered', $unfiltered->{unfixed_total}, 2);
# Under the server-side alert filter the informational rows are absent, so a
# "total unfixed" drawn from the payload would restate the alert count and
# read as "no informational events at all".
my $filtered = PVE::API2::FlashSystem::_events_view([ $evrows[0] ], 10, 1);
ok_case('events: total omitted when filtered',
    (exists $filtered->{unfixed_total} ? 'present' : 'omitted'), 'omitted');
ok_case('events: filtered flag set', $filtered->{filtered}, 1);
# A firmware that IGNORES the alert parameters returns the whole log while the
# caller still believes it filtered. The row/alert mismatch gives that away,
# and the total must come back rather than being suppressed.
my $ignored = PVE::API2::FlashSystem::_events_view(\@evrows, 10, 1);
ok_case('events: ignored filter detected', $ignored->{filtered}, 0);
ok_case('events: total restored when filter ignored', $ignored->{unfixed_total}, 2);



# ---- end-to-end: the alert-filter fallback through _collect_overview ---------
# _fetch_events returns a TWO-element list from inside a _section callback whose
# result is consumed as a scalar. If the flag failed to reach _events_view the
# panel would mislabel its own event counts, and no pure-helper test would show
# it — so exercise the whole path.
{
    no warnings 'redefine';
    my @seen;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        push @seen, [ $command, $params ];
        if ($command eq 'lseventlog') {
            # First form (the alert flags) is rejected, as an older firmware
            # would; the fallback must then run and be reported as unfiltered.
            die "CMMVC5709E bad parameter\n" if exists $params->{alert};
            return [ { sequence_number => '9', error_code => '1867',
                       description => 'DRP space warning' },
                     { sequence_number => '8', error_code => '',
                       description => 'chatter' } ];
        }
        return [] if $command eq 'lsportfc';
        return { name => 'demo', code_level => '8.7.0.3' } if $command eq 'lssystem';
        return [] if $command eq 'lsvdisk';
        return [] if $command eq 'lssevdiskcopy';
        return { name => 'P1', status => 'online', data_reduction => 'no',
                 capacity => '100', free_capacity => '40' };
    };
    my $ov = PVE::API2::FlashSystem::_collect_overview(
        'S', { fsaddress => 'a', fspool => 'P1' },
        [ [ 'S', { fsaddress => 'a', fspool => 'P1', fsprefix => 'p' } ] ]);
    ok_case('e2e: events survived the fallback', $ov->{events}{alerts}, 1);
    ok_case('e2e: fallback reported as unfiltered', $ov->{events}{filtered}, 0);
    ok_case('e2e: informational total available', $ov->{events}{unfixed_total}, 2);
    ok_case('e2e: no error recorded for events',
        (exists $ov->{errors}{events} ? 'yes' : 'no'), 'no');
    my $tried = join ',', map { $_->[0] } grep { $_->[0] eq 'lseventlog' } @seen;
    ok_case('e2e: both event forms attempted', $tried, 'lseventlog,lseventlog');
    # A standard pool must actually ask for fill.
    ok_case('e2e: fill queried on standard pool',
        (grep { $_->[0] eq 'lssevdiskcopy' } @seen) ? 'yes' : 'no', 'yes');
    ok_case('e2e: fill marked available', $ov->{pools}[0]{top}{fill}{available}, 1);
}

# ---- end-to-end: a data reduction pool must not be asked for fill -----------
# IBM documents the lssevdiskcopy capacity fields as blank in a DRP, so asking
# spends one of the array's scarce serialised CLI slots to learn nothing. Every
# pvecl1 tier is a DRP, making this the production path rather than an edge.
{
    no warnings 'redefine';
    my @seen;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        push @seen, $command;
        return [] if $command =~ /\A(?:lseventlog|lsportfc|lsvdisk|lssevdiskcopy)\z/;
        return { name => 'demo' } if $command eq 'lssystem';
        return { name => 'P1', status => 'online', data_reduction => 'yes',
                 capacity => '100', free_capacity => '40',
                 physical_capacity => '100', physical_free_capacity => '40' };
    };
    my $ov = PVE::API2::FlashSystem::_collect_overview(
        'S', { fsaddress => 'a', fspool => 'P1' },
        [ [ 'S', { fsaddress => 'a', fspool => 'P1', fsprefix => 'p' } ] ]);
    ok_case('drp: fill not queried',
        (grep { $_ eq 'lssevdiskcopy' } @seen) ? 'queried' : 'skipped', 'skipped');
    ok_case('drp: reason reported',
        $ov->{pools}[0]{top}{fill}{reason}, 'data-reduction-pool');
    ok_case('drp: fill marked unavailable',
        $ov->{pools}[0]{top}{fill}{available}, 0);
}

# ---- end-to-end: performance falls back when lssystemstats is unreachable ----
# lssystemstats is absent from IBM's published REST schema, so this is a
# shipped path. The section must not read as "unavailable" when the numbers
# were in fact produced.
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        die "CMMVC5707E unknown command\n" if $command eq 'lssystemstats';
        return [] if $command eq 'lsthrottle';
        return { name => 'demo' } if $command eq 'lssystem';
        return [
            { node_name => 'node1', stat_name => 'vdisk_io', stat_current => '1000', stat_peak => '1200' },
            { node_name => 'node2', stat_name => 'vdisk_io', stat_current => '1500', stat_peak => '1800' },
            { node_name => 'node1', stat_name => 'vdisk_ms', stat_current => '3',    stat_peak => '8' },
            { node_name => 'node2', stat_name => 'vdisk_ms', stat_current => '100',  stat_peak => '104' },
        ] if $command eq 'lsnodestats';
        return [];
    };
    my $perf = PVE::API2::FlashSystem::_collect_performance(
        'S', { fsaddress => 'a', fspool => 'P1' });
    ok_case('perf: derived from nodes', $perf->{performance}{derived}, 1);
    ok_case('perf: throughput summed', $perf->{performance}{stats}{vdisk_io}{current}, 2500);
    ok_case('perf: worst-canister latency', $perf->{performance}{stats}{vdisk_ms}{current}, 100);
    ok_case('perf: stats error cleared once recovered',
        (exists $perf->{errors}{stats} ? 'still-errored' : 'cleared'), 'cleared');
    ok_case('perf: history skipped on derived',
        (exists $perf->{history} ? 'fetched' : 'skipped'), 'skipped');
}



# ---- three-way split: ours / siblings / another tenant -----------------------
# pvecl1 puts Gold (prefix pvecl1_Gold) and k8s-gold (prefix k8sg) on the SAME
# Pool0_Gold. Without a `self` notion the storage tab counted its own sibling's
# Kubernetes PVCs as the VMware tenant's, which on the real cluster was ~10 TB
# of misdirected blame - and the operator escalates a capacity ticket to the
# storage team for their own growth.
{
    my $gold = [ 'Gold',     { fsprefix => 'pvecl1_Gold' } ];
    my $k8s  = [ 'k8s-gold', { fsprefix => 'k8sg' } ];
    my @rows = (
        { name => 'pvecl1_Gold-vm-124-disk-0', capacity => '100', status => 'online' },
        { name => 'k8sg-vm-9999-pvc-abc',      capacity => '200', status => 'online' },
        { name => 'k8sg-vm-9999-pvc-def',      capacity => '300', status => 'online' },
        { name => 'VMWARE_LUN0',               capacity => '900', status => 'online' },
    );
    my $scoped = PVE::API2::FlashSystem::_top_volumes_view(\@rows, [ $gold, $k8s ],
        limit => 10, self => 'Gold');
    ok_case('split: ours is only this storage', $scoped->{ours}{count}, 1);
    ok_case('split: sibling counted separately', $scoped->{siblings}{count}, 2);
    ok_case('split: sibling bytes separate', $scoped->{siblings}{capacity}, 500);
    ok_case('split: tenant volume still foreign', $scoped->{foreign}{count}, 1);
    ok_case('split: tenant bytes not inflated', $scoped->{foreign}{capacity}, 900);
    # Sibling volumes must never reach a named list - the caller has audit on
    # this storage, not on its siblings.
    ok_case('split: sibling absent from ranking',
        join(',', map { $_->{name} } @{ $scoped->{volumes} }), 'vm-124-disk-0');
    # A sibling's offline volume is not this storage's problem to raise.
    my $sib_off = PVE::API2::FlashSystem::_top_volumes_view(
        [ { name => 'k8sg-vm-9999-pvc-abc', capacity => '10', status => 'offline' } ],
        [ $gold, $k8s ], limit => 5, self => 'Gold');
    ok_case('split: sibling offline not our attention', $sib_off->{attention_total}, 0);

    # The pool-wide overview passes no `self`, so every peer is legitimately
    # ours and no sibling bucket appears at all.
    my $pooled = PVE::API2::FlashSystem::_top_volumes_view(\@rows, [ $gold, $k8s ], limit => 10);
    ok_case('split: overview counts all peers as ours', $pooled->{ours}{count}, 3);
    ok_case('split: overview has no sibling bucket',
        (exists $pooled->{siblings} ? 'present' : 'absent'), 'absent');
    ok_case('split: overview foreign unchanged', $pooled->{foreign}{count}, 1);
}

# ---- blocker regression: a section timeout must NOT trigger the heavy fallback
# _section raises its timeout as a blessed object precisely so _fetch_events can
# tell "array hung" from "firmware refused the parameter". Swallowing it ran the
# ~1300-row fallback with the alarm already spent - unbounded, straight past the
# ~30s proxy cap, starving every later section out of the shared budget.
{
    no warnings 'redefine';
    my $calls = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        if ($command eq 'lseventlog') {
            $calls++;
            # Emulate the section alarm firing during the first attempt.
            die bless { timeout => 8 }, 'PVE::API2::FlashSystem::Timeout';
        }
        return [];
    };
    my $errors = {};
    my $res = PVE::API2::FlashSystem::_section($errors, 'events', time() + 30, 8, sub {
        my ($rows, $f) = PVE::API2::FlashSystem::_fetch_events({ fsaddress => 'a' }, 'S');
        return $rows;
    });
    ok_case('timeout: fallback NOT attempted', $calls, 1);
    ok_case('timeout: recorded as a timeout',
        ($errors->{events} =~ /\Atimeout after 8s\z/a ? 'yes' : "no:$errors->{events}"), 'yes');
    ok_case('timeout: section returned nothing', $res, undef);
}

# A fast CMMVC rejection, by contrast, MUST fall through to the old form.
{
    no warnings 'redefine';
    my $calls = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command, $target, $params) = @_;
        return [] if $command ne 'lseventlog';
        $calls++;
        die "CMMVC5709E bad parameter\n" if exists $params->{alert};
        return [ { sequence_number => '1', error_code => '1867' } ];
    };
    my $errors = {};
    my $filtered = 1;
    my $rows = PVE::API2::FlashSystem::_section($errors, 'events', time() + 30, 8, sub {
        my ($r, $f) = PVE::API2::FlashSystem::_fetch_events({ fsaddress => 'a' }, 'S');
        $filtered = $f;
        return $r;
    });
    ok_case('reject: fallback attempted', $calls, 2);
    ok_case('reject: no error recorded', (%$errors ? 'errored' : 'clean'), 'clean');
    ok_case('reject: reported as unfiltered', $filtered, 0);
    ok_case('reject: rows came back', scalar(@{ $rows // [] }), 1);
}

# ---- derive: an EMPTY lssystemstats must fall back, not publish nothing ------
# _cmd returns undef for a 2xx with an empty body, so this path raises no error
# at all - the gate has to be "did statistics arrive", not "did the call live".
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        return undef if $command eq 'lssystemstats';   # 2xx, empty body
        return [ { node_name => 'n1', stat_name => 'vdisk_io', stat_current => '7' } ]
            if $command eq 'lsnodestats';
        return [];
    };
    my $perf = PVE::API2::FlashSystem::_collect_performance('S', { fsaddress => 'a' });
    ok_case('empty: derived anyway', $perf->{performance}{derived}, 1);
    ok_case('empty: value present', $perf->{performance}{stats}{vdisk_io}{current}, 7);
}

# ---- derive: an absent peak must stay absent, not become 0 -------------------
{
    my $d = PVE::API2::FlashSystem::_derive_system_stats({ nodes => [
        { node => 'n1', stats => { vdisk_io => { current => 100 } } },
        { node => 'n2', stats => { vdisk_io => { current => 150 } } },
    ] });
    ok_case('peak: throughput still summed', $d->{stats}{vdisk_io}{current}, 250);
    ok_case('peak: absent peak stays undef', $d->{stats}{vdisk_io}{peak}, undef);
}


# ---- the mutating CSI endpoints must hold the cluster storage lock ---------
# Every write here is read-then-act. Storage Virtualize snapshot names are NOT
# system-unique, so two concurrent CreateSnapshots for one CSI name both see
# "absent" and both addsnapshot -- and csi_snapshot_delete can then only ever
# remove the first, leaving the second holding physical capacity that
# Kubernetes has no object for. external-snapshotter retries CreateSnapshot on
# any error, including a read-back that timed out after addsnapshot took
# effect, so this is a reachable race and not a theoretical one.
{
    local %PVE::Storage::CONFIG = (
        'k8s-archive' => { type => 'flashsystem', fssnapshots => 1, shared => 1,
                           fsprefix => 'k8sa', fspool => 'Pool3_Archive',
                           fsrestore => 1 },
    );
    # Record what the handler asked the plugin to do, and whether it was
    # holding the lock at the time.
    my @calls;
    no warnings 'redefine';
    # NOT `local` inside the loop: local is scoped to the loop BODY, so each
    # override would be restored before the handlers below ever run. Save and
    # restore explicitly instead.
    my @methods = qw(csi_snapshot_create csi_snapshot_delete csi_snapshot_list
                     csi_volume_from_snapshot);
    my %orig;
    {
        no strict 'refs';
        for my $m (@methods) {
            $orig{$m} = \&{"PVE::Storage::Custom::FlashSystemPlugin::$m"};
            my $name = $m;
            *{"PVE::Storage::Custom::FlashSystemPlugin::$m"} = sub {
                push @calls, { method => $name, locked => ($PVE::Storage::LOCK_DEPTH > 0) };
                return {};
            };
        }
    }
    my $by_name = {};
    $by_name->{ $_->{name} } = $_ for @$reg;

    for my $t ([ 'snapshot_create', 1, { storage => 'k8s-archive',
                     volname => 'vm-9999-pvc-a', name => 'k10-snap-1' } ],
               [ 'snapshot_delete', 1, { storage => 'k8s-archive',
                     snapname => 'k8sa-vm-9999-pvc-a.3bcdefghi' } ],
               [ 'volume_from_snapshot', 1, { storage => 'k8s-archive',
                     snapname => 'k8sa-vm-9999-pvc-a.3bcdefghi', vmid => 4242 } ],
               # The read endpoint deliberately does NOT lock: it mutates
               # nothing, and taking a cluster lock on every reconciliation
               # poll would serialise reads against every write on the storage.
               [ 'snapshot_list', 0, { storage => 'k8s-archive' } ]) {
        my ($name, $want_lock, $param) = @$t;
        @calls = ();
        local @PVE::Storage::LOCKS = ();
        my $h = $by_name->{$name};
        ok_case("$name: registered", ($h ? 'yes' : 'no'), 'yes');
        next if !$h;
        eval { $h->{code}->($param) };
        ok_case("$name: handler ran", ($@ ? "died: $@" : 'ok'), 'ok');
        ok_case("$name: reached the plugin", scalar(@calls), 1);
        ok_case("$name: lock held during the call",
            (@calls ? ($calls[0]{locked} ? 1 : 0) : -1), $want_lock);
        ok_case("$name: locks taken", scalar(@PVE::Storage::LOCKS), $want_lock);
        if ($want_lock) {
            ok_case("$name: locks the right storage",
                $PVE::Storage::LOCKS[0]{storeid}, 'k8s-archive');
            # $shared must be passed through: with it false the lock is
            # per-node, and the driver may reach any of the 12 nodes.
            ok_case("$name: lock is cluster-wide",
                ($PVE::Storage::LOCKS[0]{shared} ? 1 : 0), 1);
        }
    }
    {
        no strict 'refs';
        *{"PVE::Storage::Custom::FlashSystemPlugin::$_"} = $orig{$_} for @methods;
    }
}

print $fail ? "\n$fail FAILURE(S)\n" : "\nall api cases pass\n";
exit($fail ? 1 : 0);
