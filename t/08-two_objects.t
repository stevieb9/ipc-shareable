use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;
use Test::SharedFork;

my $mod = 'IPC::Shareable';

my $ph = $mod->new(key => 'hash2', create => 1, destroy => 1);
my $pa = $mod->new(key => 'array2', create => 1, destroy => 1, var => 'ARRAY');

$ph->{parent} = 'parent';
$pa->[0] = 'parent';

print "h: $ph->{parent}\n";
print "a: $pa->[0]\n";

IPC::Shareable->clean_up_all;

done_testing();
