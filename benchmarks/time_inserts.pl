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
        serializer => 'storable',
        size => 655365,
    };
}

my $t = time();

for (1..1000) {
    storable($_);
    $iter++;
}

my $end = time() - $t;

print "Elapsed: $end seconds\n";

tied(%s_hash)->clean_up_all;

sub storable {
    $s_hash{"10.10.1.$iter"}->{time} = time();
    $s_hash{"10.10.1.$iter"}->{iter} = $iter;
}

__END__
