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

my $k = tie my $sv, 'IPC::Shareable', {
    create => 1,
    destroy => 1,
    size => 1,
};

my $ok = eval {
    $sv = "more than one byte";
    1;
};

is $ok, undef, "Overwriting the byte boundary size of an shm barfs ok";
like $@, qr/exceeds shared segment size/, "...and the error is sane";

(tied $sv)->clean_up_all;

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
