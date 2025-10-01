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

my %s_hash;
my $iter = 0;

if (! %s_hash) {
    tie %s_hash, 'IPC::Shareable', {
        create     => 1,
        destroy    => 1,
        key        => 'testing',
        serializer => 'storable'
    };
}

print Dumper \%s_hash;

timethese($ARGV[0],
    {
        store   => \&storable,
    },
);

tied(%s_hash)->clean_up_all;

sub storable {
    $s_hash{"10.10.1.$iter"}->{$iter} = time();
    $iter++;
}

__END__
