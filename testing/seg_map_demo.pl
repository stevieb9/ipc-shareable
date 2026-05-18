#!/usr/bin/env perl
use warnings;
use strict;
use IPC::Shareable;

# Start fresh
IPC::Shareable->clean_up_all;

# Simple scalar
my $ks = tie my $sv, 'IPC::Shareable', { key => 'demo1', create => 1, destroy => 1, serializer => 'storable' };
$sv = 'hello';

# Protected hash with a nested child
my $kh = tie my %h, 'IPC::Shareable', {
    key        => 'demo2',
    create     => 1,
    destroy    => 1,
    protected  => 42,
    serializer => 'storable',
};
$h{nested} = { x => 1, y => 2 };

# Trigger child creation by reading back
my $val = $h{nested}{x};

print "=== Scalar segment ===\n";
print $ks->seg_map;

print "\n=== Protected hash segment (with nested child) ===\n";
print $kh->seg_map;

IPC::Shareable->clean_up_protected(42);
IPC::Shareable->clean_up_all;
