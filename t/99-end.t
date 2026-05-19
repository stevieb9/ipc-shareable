use 5.006;
use strict;
use warnings;

use IPC::Shareable;
use Test::More;

BEGIN {
    use_ok( 'IPC::Shareable' ) || print "Bail out!\n";
}

tie my %store, 'IPC::Shareable', {key => 'async_tests', destroy => 1, serializer => 'storable' };

my $start_segs = $store{segs};
my $start_sems = $store{sems};

IPC::Shareable::clean_up_all;

my $segs = IPC::Shareable::shm_count();
my $sems = IPC::Shareable::sem_count();

is $segs, $start_segs, "All test segments cleaned up after test run";
is $sems, $start_sems, "All test semaphores cleaned up after test run";

if ($ENV{PRINT_SEGS}) {
    warn "Started with $start_segs, ending with $segs\n";
}

done_testing();