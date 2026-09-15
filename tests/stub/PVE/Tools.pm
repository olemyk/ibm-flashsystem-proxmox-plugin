package PVE::Tools;
use strict; use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(run_command);
# Records every argv so tests can pin the flags the plugin passes. The SCSI
# rescan flags are load-bearing and were learned from a production failure, so
# they need an assertion rather than a comment.
our @CALLS;
our %RC;          # first argv word -> exit code the stub should return
sub run_command {
    my ($cmd, %opt) = @_;
    push @CALLS, [ ref $cmd eq 'ARRAY' ? @$cmd : $cmd ];
    my $key = ref $cmd eq 'ARRAY' ? $cmd->[0] : $cmd;
    return exists $RC{$key} ? $RC{$key} : 0;
}
sub file_read_firstline { return '' }
1;
