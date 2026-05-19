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

my $segs_before = IPC::Shareable::seg_count();
my $sems_before = IPC::Shareable::sem_count();
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

# Non-coderef passed as $code param: must croak
{
    eval { $knot->lock(LOCK_EX, 'not_a_coderef') };
    like $@, qr/must be a code ref/, "lock() croaks when non-coderef passed as \$code";
    $knot->unlock if $knot->{_lock};
}

# Coderef that throws: lock() re-throws and knot is unlocked
{
    eval { $knot->lock(LOCK_EX, sub { die "boom\n" }) };
    is $@, "boom\n", "lock() re-throws exception from coderef";
    is $knot->{_lock}, 0, "...and knot is unlocked after coderef die";
}

IPC::Shareable->clean_up_all;

is %hv, '', "hash deleted after clean_up()";

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::seg_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};

is $segs_after, $segs_before, "All segs, even those created in separate procs, cleaned up ok";
my $sems_after = IPC::Shareable::sem_count();
is $sems_after, $sems_before, "All semaphore sets cleaned up ok";

done_testing();


