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
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

tie my %hv, 'IPC::Shareable', {destroy => 1};

$hv{a} = 'foo';

is $hv{a}, 'foo', "data created and set ok";

tied(%hv)->clean_up;

is %hv, '', "data is removed after tied(\$data)->clean_up()";

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
