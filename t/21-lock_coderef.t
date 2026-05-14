use strict;
use warnings;

use Data::Dumper;
use Test::More;
use IPC::Shareable;

use constant {
    LOCK_SH => 1,
    LOCK_EX => 2,
    LOCK_NB => 4,
};

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable';

my $knot = tie my %hv, $mod, {
    create     => 1,
    key        => 1234,
    destroy    => 1,
};

# Only cref param
{
    my $x = 0;
    my $ret = $knot->lock(sub { $x+=5; });

    is $x, 5, "lock() with only a cref param works properly";
    is $ret, 1, "...and return value is ok";
    is $knot->{_lock}, 0, "...and knot is unlocked";
}

# Both params (LOCK_EX)
{
    my $x = 0;
    my $ret = $knot->lock(LOCK_EX, sub { $x+=10; });

    is $x, 10, "lock() with LOCK_EX, and cref param works properly";
    is $ret, 1, "...and return value is ok";
    is $knot->{_lock}, 0, "...and knot is unlocked";
}

# Both params (LOCK_NB)
{
    my $x = 0;
    my $ret = $knot->lock(LOCK_SH|LOCK_NB, sub { $x+=10; });

    is $x, 0, "lock() with LOCK_NB, and cref don't run cref ok";
    is $ret, 1, "...and return value is ok";
    is $knot->{_lock}, LOCK_SH|LOCK_NB, "...and knot remained locked";

    $knot->unlock;
    is $knot->{_lock}, 0, "...and knot is unlocked after running unlock()";

}

IPC::Shareable->clean_up_all;

is %hv, '', "hash deleted after clean_up()";

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};

is $segs_after, $segs_before, "All segs, even those created in separate procs, cleaned up ok";

done_testing();


