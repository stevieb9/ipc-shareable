use warnings;
use strict;
use feature 'say';

use Data::Dumper;
use IPC::Shareable;
use Test::More;

my $segs_before = IPC::Shareable::seg_count();
my $sems_before = IPC::Shareable::sem_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

# array
{
    my @test_data = (
        [
            1,
            2,
            3,
            [
                26,
                [
                    30,
                    31,
                ],
            ],
        ],
    );

    tie my @a, 'IPC::Shareable', {create => 1, destroy => 1, tidy => 0, serializer => 'storable' };

    my $initial_seg_count = seg_count();

    is seg_count(), $initial_seg_count, "Initial array seg count ok";

    $a[0] = [3];
    is seg_count(), $initial_seg_count + 1, "After initial aref add, seg count ok";

    $a[0] = [1, 2];
    is seg_count(), $initial_seg_count + 1, "Overwriting an aref element replaces (doesn't leak) old child seg ok";

    $a[0] = [1, 2, 3];
    is seg_count(), $initial_seg_count + 1, "Same with overwriting the aref again";

    $a[0] = [1, 2, 3, [26, [30, 31]]];
    is seg_count(), $initial_seg_count + 3, "Overwriting with nested aref adds only net-new children";

    is_deeply \@a, \@test_data, "Nested arrays compare ok";

    IPC::Shareable->clean_up_all;
}

# hash
{
    my %test_data = (
        a => {
            a => 1,
            b => 2,
            c => 3,
            d => {
                z => 26,
                y => {
                    yy => 25,
                },
            },
        }
    );

    tie my %h, 'IPC::Shareable', {create => 1, destroy => 1, tidy => 0, serializer => 'storable' };

    my $initial_seg_count = seg_count();

    is seg_count(), $initial_seg_count, "Initial href seg count ok";

    $h{a} = {a => 1};
    is seg_count(), $initial_seg_count + 1, "After initial href add, seg count ok";

    $h{a} = {a => 1, b => 2};
    is seg_count(), $initial_seg_count + 1, "Overwriting an href element replaces (doesn't leak) old child seg ok";

    $h{a} = {a => 1, b => 2, c => 3};
    is seg_count(), $initial_seg_count + 1, "Same with overwriting the href again";

    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26}};
    is seg_count(), $initial_seg_count + 2, "Overwriting with nested href adds only net-new children";

    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};
    is seg_count(), $initial_seg_count + 4, "Overwriting with deeper nested href adds only net-new children";

    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};
    is seg_count(), $initial_seg_count + 6, "Overwriting with same structure again adds only net-new children";

    is_deeply \%h, \%test_data, "Shared memory hash matches test data ok";

    IPC::Shareable->clean_up_all;
}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::seg_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";
my $sems_after = IPC::Shareable::sem_count();
is $sems_after, $sems_before, "All semaphore sets cleaned up ok";

done_testing;

sub seg_count {
    my $count = `ipcs -m | wc -l`;
    chomp $count;
    $count =~ s/\s+//g;
    return $count;
}
