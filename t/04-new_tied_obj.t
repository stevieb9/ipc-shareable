use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before $segs_before\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable';

my $ph = $mod->new(
    key => 'hash',
    create => 1,
    destroy => 1
);

my $k = tied %$ph;

is ref $k, 'IPC::Shareable', "tied() returns a proper IPC::Shareable object ok";
is exists $k->{attributes}, 1, "...and it has proper attributes ok";

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs, even those created in separate procs, cleaned up ok";

done_testing();
