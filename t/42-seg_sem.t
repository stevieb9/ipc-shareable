use warnings;
use strict;

use Carp;
use Data::Dumper;
use IPC::Shareable;
use Test::More;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my $k = tie my $sv, 'IPC::Shareable', 'test', { create => 1, destroy => 1 };

# seg()

my @seg_keys = qw(
    id
    key
    key_hex
    flags
    mode
    type
    size
);

my $knot_seg = $k->seg;
my $tied_seg = (tied $sv)->seg;

is ref $knot_seg, 'IPC::Shareable::SharedMem', "knot seg() is the proper object";
is ref $tied_seg, 'IPC::Shareable::SharedMem', "tied seg() is the proper object";

is keys %$knot_seg, scalar @seg_keys, "knot hash has the proper number of keys";
is keys %$tied_seg, scalar @seg_keys, "tied hash has the proper number of keys";

for (@seg_keys) {
    is exists $knot_seg->{$_}, 1, "$_ key exists in knot hash ok";
    is exists $tied_seg->{$_}, 1, "$_ key exists in tied hash ok";
}

is $knot_seg->id, $tied_seg->id, "knot and tied seg() hashes have the same id";

# sem()

my $knot_sem = $k->sem();
my $tied_sem = (tied $sv)->sem;

is ref $knot_sem, 'IPC::Semaphore', "knot sem() is the proper object";
is ref $tied_sem, 'IPC::Semaphore', "tied sem() is the proper object";

is $knot_sem->id, $tied_sem->id, "knot and tied sem() hashes have the same id";

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();

