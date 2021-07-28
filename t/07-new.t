use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;
use Test::SharedFork;

my $mod = 'IPC::Shareable';

my $awake = 0;
local $SIG{ALRM} = sub { $awake = 1 };

# locking

my $pid = fork;
defined $pid or die "Cannot fork: $!\n";

if ($pid == 0) {
    # child

    sleep unless $awake;

    my $ch = $mod->new(key => 'hash2');
    $ch->{child} = 'child';

    my $ca = $mod->new(key => 'array2', var => 'ARRAY');
    $ca->[1] = 'child';

    my $cs = $mod->new(key => 'scalar2', var => 'SCALAR');
    $$cs = 'child';

    exit;
} else {
    # parent

    IPC::Shareable->clean_up_all;

    my $ph = $mod->new(key => 'hash2', create => 1, destroy => 1);
    my $pa = $mod->new(key => 'array2', create => 1, destroy => 1, var => 'ARRAY');
    my $ps = $mod->new(key => 'scalar2', create => 1, destroy => 1, var => 'SCALAR');

    kill ALRM => $pid;
    waitpid($pid, 0);

    $pa->[0] = 'parent';
    $ph->{parent} = 'parent';
    $$ps = "parent";


    IPC::Shareable->clean_up_all;
}

done_testing();
