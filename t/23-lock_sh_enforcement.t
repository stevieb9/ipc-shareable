use warnings;
use strict;

use IPC::Shareable qw(:lock SEM_READERS SEM_WRITERS);
use Test::More;

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

# --- LOCK_SH blocks writes from other knots (enforced_locking) ---
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key              => 'SLCK1',
        create           => 1,
        destroy          => 1,
        enforced_locking => 1,
    };
    my $k2 = tie my %h2, 'IPC::Shareable', {
        key              => 'SLCK1',
        enforced_locking => 1,
    };

    $h1{a} = 10;
    is $h1{a}, 10, "LOCK_SH enforcement - initial value set ok";

    # k1 acquires a shared read lock
    $k1->lock(LOCK_SH);
    is $k1->sem->getval(SEM_READERS), 1, "LOCK_SH enforcement - reader count is 1 after LOCK_SH";
    is $k1->sem->getval(SEM_WRITERS), 0, "LOCK_SH enforcement - write lock is 0 after LOCK_SH";

    # k2 attempts a write while k1 holds LOCK_SH -- must be blocked
    my $result = $h2{a} = 99;
    is $h1{a}, 10, "LOCK_SH enforcement - k2 write blocked while k1 holds LOCK_SH";

    $k1->unlock;
    is $k1->sem->getval(SEM_READERS), 0, "LOCK_SH enforcement - reader count is 0 after unlock";

    # After k1 releases LOCK_SH, k2 can write freely
    $h2{a} = 99;
    is $h2{a}, 99, "LOCK_SH enforcement - k2 write succeeds after k1 releases LOCK_SH";
}

# --- LOCK_SH holder itself cannot write (must upgrade to LOCK_EX) ---
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key              => 'SLCK2',
        create           => 1,
        destroy          => 1,
        enforced_locking => 1,
    };

    $h1{a} = 10;
    is $h1{a}, 10, "LOCK_SH self-write - initial value set ok";

    $k1->lock(LOCK_SH);

    # k1 holds LOCK_SH and tries to write itself -- must be blocked
    $h1{a} = 99;
    is $h1{a}, 10, "LOCK_SH self-write - write blocked while holding own LOCK_SH";

    $k1->unlock;

    # After upgrading to LOCK_EX, write succeeds
    $k1->lock(LOCK_EX);
    $h1{a} = 99;
    $k1->unlock;
    is $h1{a}, 99, "LOCK_SH self-write - write succeeds after upgrading to LOCK_EX";
}

# --- violated_lock_warn fires with 'active readers' message ---
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key              => 'SLCK3',
        create           => 1,
        destroy          => 1,
        enforced_locking => 1,
    };
    my $k2 = tie my %h2, 'IPC::Shareable', {
        key                => 'SLCK3',
        enforced_locking   => 1,
        violated_lock_warn => 1,
    };

    $h1{a} = 10;

    $k1->lock(LOCK_SH);

    my $warned = 0;
    local $SIG{__WARN__} = sub {
        my $w = shift;
        my $uuid   = $k2->uuid;
        my $seg_id = $k2->seg->id;

        like $w, qr/active readers/, "violated_lock_warn - message mentions 'active readers'";
        like $w, qr/$uuid/,          "violated_lock_warn - message contains UUID";
        like $w, qr/$seg_id/,        "violated_lock_warn - message contains segment ID";
        $warned++;
    };

    $h2{a} = 99;

    is $warned, 1, "violated_lock_warn - warning fired exactly once";

    $k1->unlock;

    # After unlock warning should not fire again
    {
        local $SIG{__WARN__} = sub { fail "violated_lock_warn - unexpected warning after unlock: $_[0]" };
        $h2{a} = 99;
    }
    is $h2{a}, 99, "violated_lock_warn - write succeeds after readers gone";
}

# --- LOCK_EX blocking still works (regression) ---
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key              => 'SLCK4',
        create           => 1,
        destroy          => 1,
        enforced_locking => 1,
    };
    my $k2 = tie my %h2, 'IPC::Shareable', {
        key              => 'SLCK4',
        enforced_locking => 1,
    };

    $h1{a} = 10;

    $k1->lock(LOCK_EX);

    $h2{a} = 99;
    is $h1{a}, 10, "LOCK_EX regression - k2 write blocked while k1 holds LOCK_EX";

    $k1->unlock;

    $h2{a} = 99;
    is $h2{a}, 99, "LOCK_EX regression - k2 write succeeds after k1 unlocks";
}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing;
