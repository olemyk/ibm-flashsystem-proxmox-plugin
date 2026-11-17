package PVE::Storage::Plugin;
use strict; use warnings;

# Records its arguments and DERIVES the answer from $vmid, rather than
# returning a constant. A constant made every clone_image naming assertion
# pass regardless of what clone_image actually passed — so dropping the 'raw'
# format, or handing it the SOURCE volume's vmid instead of the clone
# target's, would have stayed green here and surfaced only on hardware.
our @FIND_FREE_CALLS;
sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt) = @_;
    push @FIND_FREE_CALLS, { storeid => $storeid, vmid => $vmid, fmt => $fmt };
    return "vm-$vmid-disk-0";
}

# cluster_lock_storage lives HERE because that is where PVE has it:
# /usr/share/perl5/PVE/Storage/Plugin.pm:759, a class method whose real
# signature is ($class, $storeid, $shared, $timeout, $func, @param). The
# leading $class is the part that matters — calling it as a plain function
# silently shifts every argument by one, and the previous stub encoded exactly
# that mistake, so the suite validated a call PVE could never serve.
our @LOCKS;           # one entry per lock taken, for the tests to assert on
our $LOCK_DEPTH = 0;  # non-zero while inside a lock

sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
    die "cluster_lock_storage: called as a function, not a method\n"
        if !defined $class || $class !~ /^PVE::Storage/;
    push @LOCKS, { storeid => $storeid, shared => $shared, timeout => $timeout };
    $LOCK_DEPTH++;
    my @r = eval { $func->(@param) };
    my $err = $@;
    $LOCK_DEPTH--;
    die $err if $err;       # real one dies too; a swallowed error would hide a failed snapshot
    return wantarray ? @r : $r[0];
}
1;
