use warnings;
use strict;

use IPC::Shareable;
use Test::More;

my $segs_before = IPC::Shareable::shm_count();
my $sems_before = IPC::Shareable::sem_count();
warn "Segs Before $segs_before\n" if $ENV{PRINT_SEGS};

tie my $sv, 'IPC::Shareable', {destroy => 1, serializer => 'storable' };

$sv = 'foo';
is $sv, 'foo', "SCALAR created ok, and set to 'foo'";

# This is a regression test for the
# bug fixed by using Scalar::Util::reftype
# instead of looking for HASH, SCALAR, ARRAY
# in the stringified version of the scalar.

for my $mod (qw/HASH SCALAR ARRAY/){
    # --- TIESCALAR
    my $sv;
    tie($sv, 'IPC::Shareable', { destroy => 'yes' , serializer => 'storable' })
        or die ('this was not expected to die here');

    $sv = $mod.'foo';
    is $sv, $mod.'foo', "SCALAR regression store/fetch ok";
}

# FETCH from a never-written scalar segment returns undef (empty segment path)
{
    tie my $sv, 'IPC::Shareable', { key => 'sv10e', create => 1, destroy => 1 , serializer => 'storable' };
    is $sv, undef, "FETCH on never-written scalar returns undef ok";
}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs, even those created in separate procs, cleaned up ok";
my $sems_after = IPC::Shareable::sem_count();
is $sems_after, $sems_before, "All semaphore sets cleaned up ok";

done_testing();
