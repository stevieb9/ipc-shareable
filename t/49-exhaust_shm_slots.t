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
    create => 1,
    key => 1234,
    destroy => 1,
};

my $ok = eval {
    for my $alpha ('a' .. 'z', 'A' .. 'Z') {
        for my $num (0 .. 100) {
            # print "$alpha:$num\n";
            $hv{$alpha}->{$num} = $alpha;
            my $thing = $hv{$alpha}->{num};
            delete $hv{$alpha};
        }
    };
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
