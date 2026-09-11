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
1;
