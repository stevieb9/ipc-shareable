#!/usr/bin/env perl
use warnings;
use strict;

use Benchmark qw(:all) ;
use IPC::Shareable;
use JSON qw(-convert_blessed_universally);
use Storable qw(freeze thaw);

if (@ARGV < 1){
    print "\n Need test count argument...\n\n";
    exit;
}

timethese($ARGV[0],
    {
        json    => \&json,
        store   => \&storable,
    },
);

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
sub json {
    my $base_data = default();

    tie my %hash, 'IPC::Shareable', 'json', {
        create  => 1,
        destroy => 1,
        serializer => 'json'
    };

    %hash = %$base_data;

    $hash{struct} = {a => [qw(b c d)]};

    tied(%hash)->clean_up_all;

}
sub storable {
    my $base_data = default();

    tie my %hash, 'IPC::Shareable', 'stor', {
        create  => 1,
        destroy => 1,
        serializer => 'storable'
    };

    %hash = %$base_data;

    $hash{struct} = {a => [qw(b c d)]};

    tied(%hash)->clean_up_all;
}

__END__
