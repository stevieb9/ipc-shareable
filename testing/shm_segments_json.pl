#!/usr/bin/perl

use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;

tie my %h, 'IPC::Shareable', {
    key        => '0x2ABC0001',
    create     => 1,
    destroy    => 1,
    serializer => 'json',
};

$h{a} = 1;
$h{b} = 'hello';
$h{c} = {
    x => 10,
    y => 20,
};
$h{d} = {
    p => 'foo',
    q => 'bar',
};

my $segs = IPC::Shareable->shm_segments;

print Dumper($segs);
