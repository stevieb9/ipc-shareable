use warnings;
use strict;

use IPC::Shareable;
use Test::More;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable';

my $knot = tie my %hv, $mod, {
    create  => 1,
    key     => 1234,
    destroy => 1,
    size    => 1_048_576,   # large enough that kernel slot limit is hit first
};

my $ok = eval {
    for my $i (1 .. 200) {
        # Each unique key creates one child segment.  No delete, so segments
        # accumulate until the kernel shm slot limit is reached.
        $hv{$i} = {val => $i};
    }
    1;
};

# print $@;

is $ok, undef, "If we try to use all available shm slots, we croak()";
like $@, qr/No space left on device/, "...and error is sane";

IPC::Shareable->clean_up_all;

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
