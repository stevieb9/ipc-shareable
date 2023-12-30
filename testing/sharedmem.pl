use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable::SharedMem;
use IPC::SysV qw(:all);

my $seg = IPC::Shareable::SharedMem->new(12345, 1024, IPC_CREAT);

print Dumper $seg;