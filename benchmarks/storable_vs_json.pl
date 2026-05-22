#!/usr/bin/env perl
use warnings;
use strict;

use Benchmark qw(:all) ;
use Data::Dumper;
use IPC::Shareable;
use JSON qw(-convert_blessed_universally);
use Storable qw(freeze thaw);

if (@ARGV < 1){
    print "\n Need test count argument...\n\n";
    exit;
}

my %j_hash;
my %s_hash;

#timethese($ARGV[0],
#    {
#        json    => \&json,
#        store   => \&storable,
#    },
#);

cmpthese($ARGV[0],
    {
        json    => \&json,
        store   => \&storable,
    },
);

sub default {
     return {
        a => 1,
        b => 2,
        c => [qw(1 2 3)],
        d => {z => 26, y => 25},
    };
}

sub _run_ops {
    my ($h) = @_;

    # scalar values
    $h->{count}  = 42;
    $h->{label}  = 'hello world';
    $h->{ratio}  = 3.14159;
    $h->{flag}   = 0;

    # nested hash
    $h->{nested} = { x => 10, y => 20, z => { deep => 'value' } };

    # array ref
    $h->{list}   = [1, 2, 3, 4, 5];

    # array of hashes
    $h->{records} = [
        { id => 1, name => 'alice' },
        { id => 2, name => 'bob'   },
        { id => 3, name => 'carol' },
    ];

    # mixed-depth structure
    $h->{config} = {
        debug   => 1,
        servers => [qw(alpha beta gamma)],
        limits  => { max => 100, min => 0 },
    };

    # reads of written values
    my $v1 = $h->{count};
    my $v2 = $h->{nested}{z}{deep};
    my $v3 = $h->{list}[2];
    my $v4 = $h->{records}[1]{name};
    my $v5 = $h->{config}{limits}{max};
}

sub json {
    my $base_data = default();

    if (! %j_hash) {
        tie %j_hash, 'IPC::Shareable', {
            create     => 1,
            destroy    => 1,
            serializer => 'json'
        };
    }

    %j_hash = %$base_data;

    $j_hash{struct1} = {a => [qw(b c d)]};

    _run_ops(\%j_hash);

    tied(%j_hash)->clean_up_all;
}
sub storable {
    my $base_data = default();

    if (! %s_hash) {
        tie %s_hash, 'IPC::Shareable', {
            create     => 1,
            destroy    => 1,
            serializer => 'storable'
        };
    }

    %s_hash = %$base_data;

    $s_hash{struct1} = {a => [qw(b c d)]};

    _run_ops(\%s_hash);

    tied(%s_hash)->clean_up_all;
}

__END__

# As of: 4f53428d

        Rate store  json
store 196/s    --  -14%
json  227/s   16%    --

# As of: f3f0868f (after XS changes)

        Rate store  json
store 248/s    --  -13%
json  284/s   15%    --
