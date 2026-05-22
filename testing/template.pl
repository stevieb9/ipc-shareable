use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;

my $k = tie my %h, 'IPC::Shareable', { key => 0x1a2b, create => 1, destroy => 1 };

$h{nested} = {x => 1, y => 2};

my $m = tied(%h)->seg_map;

print $m;