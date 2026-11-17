package LWP::UserAgent;
#
# Test-only shim. libwww-perl is not core, and the CI runner does not have it
# (the role installs it on nodes via flashsystem_plugin_packages).
#
# This has to exist even though no test performs a request: the plugin builds
# its user agent at FILE SCOPE — `my $UA = LWP::UserAgent->new(...)` — so `use`
# and `new` run at module load, before any test can intervene.
#
use strict;
use warnings;

sub new { my ($class, %opt) = @_; return bless { %opt }, $class }

# Deliberately fatal, and the most useful line in this file. A stub that
# returned a plausible HTTP::Response would let a test believe it had talked to
# an array and assert happily against fiction. All 50+ interception points in
# this suite override _cmd, one level above here; if this fires, a test meant
# to do that and did not.
sub request {
    my ($self, $req) = @_;
    my $where = eval { $req->{method} . ' ' . $req->{uri} } // 'a request';
    die "LWP::UserAgent stub: a test reached the real HTTP path ($where)."
      . " Override PVE::Storage::Custom::FlashSystemPlugin::_cmd instead.\n";
}

sub ssl_opts { }
sub timeout  { }
sub agent    { }
1;
