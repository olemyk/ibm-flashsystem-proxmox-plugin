package PVE::Storage;
use strict; use warnings;
use constant APIVER => 11;

# Enough of PVE::Storage for the API handlers to be INVOKED, not just
# inspected. The mutating CSI endpoints are wrapped in cluster_lock_storage,
# and an unlocked read-then-act create can duplicate array objects that only
# one of which is ever deletable - so the wrapping has to be asserted, which
# means calling the handlers.
our %CONFIG;          # storeid => scfg, set by the test
our @LOCKS;           # records ($storeid, $shared) per lock taken
our $LOCK_DEPTH = 0;  # non-zero while inside a lock

sub config { return { ids => { %CONFIG } }; }

sub storage_config {
    my ($cfg, $storeid) = @_;
    my $scfg = $cfg->{ids}{$storeid};
    die "storage '$storeid' does not exist\n" if !$scfg;
    return $scfg;
}

sub cluster_lock_storage {
    my ($storeid, $shared, $timeout, $code) = @_;
    push @LOCKS, { storeid => $storeid, shared => $shared };
    $LOCK_DEPTH++;
    my @r = eval { $code->() };
    my $err = $@;
    $LOCK_DEPTH--;
    die $err if $err;
    return wantarray ? @r : $r[0];
}
1;
