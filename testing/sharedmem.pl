use warnings;
use strict;

use Data::Dumper;
use IPC::SharedMem;
use IPC::SysV qw(:all);

my $seg = IPC::SharedMem->new(12345, 1024, IPC_CREAT|0666);

print Dumper $seg->stat;

$seg->remove;
