package HTTP::Request;
#
# Test-only shim; see tests/stub/LWP/UserAgent.pm for why these exist.
# Constructed only inside _cmd, which every suite overrides, so this needs to
# be constructible and to record enough that the UserAgent stub's refusal can
# name the request it refused.
#
use strict;
use warnings;

sub new {
    my ($class, $method, $uri) = @_;
    return bless { method => $method, uri => $uri, headers => {} }, $class;
}

sub header {
    my ($self, $k, $v) = @_;
    $self->{headers}{$k} = $v if defined $v;
    return $self->{headers}{$k};
}

sub content {
    my ($self, $c) = @_;
    $self->{content} = $c if defined $c;
    return $self->{content};
}
1;
