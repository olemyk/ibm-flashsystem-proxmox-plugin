package PVE::Storage;
use strict; use warnings;
use constant APIVER => 11;

# Enough of PVE::Storage for the API handlers to be INVOKED, not just
# inspected, so the cluster lock around the mutating CSI endpoints can be
# asserted rather than assumed.
#
# NOTE: cluster_lock_storage does NOT live here. It is a class method on
# PVE::Storage::Plugin, and this file used to define it as a plain function in
# PVE::Storage - an API that exists nowhere in PVE. Every test passed against
# the invention, and the real failure surfaced only on the first CreateSnapshot
# against a live node. A stub that defines something the real module lacks is
# worse than no stub: it manufactures confidence. See tests/stub/PVE/Storage/
# Plugin.pm, and the install-time symbol check in the role's api.yml.
our %CONFIG;          # storeid => scfg, set by the test

sub config { return { ids => { %CONFIG } }; }

sub storage_config {
    my ($cfg, $storeid) = @_;
    my $scfg = $cfg->{ids}{$storeid};
    die "storage '$storeid' does not exist\n" if !$scfg;
    return $scfg;
}
1;
