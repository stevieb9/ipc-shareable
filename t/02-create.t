use warnings;
use strict;

use IPC::Shareable;
use Test::More;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before $segs_before\n" if $ENV{PRINT_SEGS};

my $ok = eval {
    tie my $sv, 'IPC::Shareable', {key => 'test02', destroy => 1};
    1;
};

is $ok, undef, "We croak ok if create is not set and segment doesn't yet exist";
like $@, qr/Could not acquire/, "...and error is sane.";

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs, even those created in separate procs, cleaned up ok";

done_testing;

