package JSON;
#
# Test-only shim, and a REAL implementation rather than a fake.
#
# The plugin uses JSON (libjson-perl) because every PVE node has it:
# pve-manager depends on it, and the role installs it explicitly through
# flashsystem_plugin_packages. A CI runner is not a PVE node, and run.sh's
# stated contract is that this suite "runs anywhere perl exists" — which was
# untrue the moment the module gained a non-core dependency. The GitLab
# validate job proved it by dying on `perl -T -I stub -c`, the very first
# command in the suite, before a single case ran.
#
# So the dependency is satisfied here from JSON::PP, core since perl 5.14.
# encode_json/decode_json ARE JSON::PP's, so round-tripping, UTF-8 handling
# and boolean objects behave exactly as they do on a node; only the provider
# changes. A hand-rolled encoder would have been a second implementation to
# get wrong, and the plugin's `-bytes` flags depend on real boolean objects.
#
use strict;
use warnings;
use JSON::PP ();
use Exporter 'import';

our @EXPORT    = qw(encode_json decode_json);
our @EXPORT_OK = qw(encode_json decode_json to_json from_json);

*encode_json = \&JSON::PP::encode_json;
*decode_json = \&JSON::PP::decode_json;
*to_json     = \&JSON::PP::encode_json;
*from_json   = \&JSON::PP::decode_json;

# Storage Virtualize's valueless flags go out as JSON booleans —
# `{ bytes => JSON::true }` — so these must be the same blessed objects
# JSON::PP serialises as bare `true`/`false`, not 1/0.
sub true  { JSON::PP::true() }
sub false { JSON::PP::false() }
sub null  { undef }

# is_bool is used by the suite itself, to assert that a valueless array flag
# really went out as a JSON boolean rather than as 1. Delegating means the
# predicate and the objects it inspects come from the same implementation.
sub is_bool { return JSON::PP::is_bool($_[0]) }

# The plugin uses only the functional interface. Fail loudly rather than hand
# back something that does not behave like JSON's OO API.
sub new {
    die "JSON stub: the OO interface is not implemented."
      . " The plugin uses encode_json/decode_json; if that changed, extend"
      . " tests/stub/JSON.pm to match.\n";
}
1;
