use warnings;
use strict;

use Carp;
use Data::Dumper;
use IPC::Shareable;
use Test::More;
use Test::SharedFork;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my $sv;

#my $awake = 0;
#local $SIG{ALRM} = sub { $awake = 1 };
#
## locking
#
#my $pid = fork;
#defined $pid or die "Cannot fork: $!\n";
#
#if ($pid == 0) {
#    # child
#
#    sleep unless $awake;
#    tie($sv, 'IPC::Shareable', 'TEST', { destroy => 0 });
#
#    for (0 .. 99) {
#        (tied $sv)->lock;
#        ++$sv;
#        (tied $sv)->unlock;
#    }
#    is $sv, 100, "in child: locked and set SV to 100";
#    exit;
#
#} else {
#    # parent
#
#    tie($sv, 'IPC::Shareable', 'TEST', { create => 1, destroy => 1 })
#        or die "parent process can't tie \$sv";
#    $sv = 0;
#    kill ALRM => $pid;
#    waitpid($pid, 0);
#    for (0 .. 99) {
#        (tied $sv)->lock;
#        ++$sv;
#        (tied $sv)->unlock;
#    }
#    is $sv, 200, "in parent: locked and updated SV to 200";
#}

# Advisory locking
{
    my $k1 = tie my %h1, 'IPC::Shareable', { key => 'TEST1', create => 1, destroy => 1 };
    my $k2 = tie my %h2, 'IPC::Shareable', { key => 'TEST1', create => 1, destroy => 1 };

    $h1{a} = {b => 1};

    is_deeply {%h1}, {a => {b => 1}}, "h1 - initial value set";
    is_deeply {%h2}, {a => {b => 1}}, "h2 - sees h1's initial value via same key";

    # Correct pattern for modifying nested data while locked: use a top-level
    # STORE on the parent hash, NOT $h1{a}->{b} = 3.
    #
    # Using a top-level STORE ($h1{a} = ...) sets _was_changed = 1 on k1 and
    # properly replaces the child segment via _magic_tie / _reset_segment.
    $k1->lock;

    $h1{a} = {b => 3};   # top-level STORE: sets k1->{_was_changed} = 1
    $k1->unlock;          # writes {a => {b => 3}} back to shared memory

    is_deeply {%h1}, {a => {b => 3}}, "h1 - locked STORE written back on unlock";
    is_deeply {%h2}, {a => {b => 3}}, "h2 - sees h1's change after unlock";

    # Without enforced_locking, a knot that does NOT call lock() bypasses the
    # semaphore and writes directly -- purely cooperative/advisory locking.
    $k1->lock;
    $h2{a} = {c => 10};  # k2 never locked: writes directly, no error
    $k1->unlock;

    #is_deeply {%h2}, {a => {b => 3}}, "h2 - back to pre-unlock of h1 data";
}

# enforced_locking w/o warn: k2 attempting a write while k1 holds LOCK_EX must croak
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key              => 'TEST2',
        create           => 1,
        destroy          => 1,
        enforced_locking => 1,
    };
    my $k2 = tie my %h2, 'IPC::Shareable', {
        key              => 'TEST2',
        enforced_locking => 1,
    };

    $h1{a} = 1;
    is $h1{a}, 1, "enforced_locking - initial value set";

    $k1->lock;

    # k1 (the lock holder) can still write freely
    $h1{a} = 2;
    is $h1{a}, 2, "enforced_locking - lock holder can write while locked";

    # k2 must croak because k1 holds LOCK_EX and k2 has enforced_locking on
#    eval { $h2{a} = 99 };
#    like $@, qr/exclusively locked/, "enforced_locking - k2 STORE croaks while k1 holds LOCK_EX";

    $h2{a} = 99;

    $k1->unlock;

    # after unlock, k2 can write freely again
    is $h2{a}, 2, "enforced_locking - after k1 unlock, h2 set properly";
    $h2{a} = 3;
    is $h2{a}, 3, "enforced_locking - k2 can write after k1 unlocks";
}

# enforced_locking with warn: k2 attempting a write while k1 holds LOCK_EX must croak
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key                => 'TEST2',
        create             => 1,
        destroy            => 1,
        enforced_locking   => 1,
    };
    my $k2 = tie my %h2, 'IPC::Shareable', {
        key                 => 'TEST2',
        enforced_locking    => 1,
        violated_lock_warn  => 1,
    };

    $h1{a} = 1;
    is $h1{a}, 1, "enforced_locking with warn - initial value set";

    $k1->lock;

    # k1 (the lock holder) can still write freely
    $h1{a} = 2;
    is $h1{a}, 2, "enforced_locking with warn - lock holder can write while locked";

    local $SIG{__WARN__} = sub {
        my $w = shift;
        my $uuid = $k2->uuid;
        my $seg_id = $k2->seg->id;

        like $w, qr/$uuid/, "With enforced_locking and violated_lock_warn, UUID in warning ok";
        like $w, qr/$seg_id/, "With enforced_locking and violated_lock_warn, seg ID in warning ok";
    };

    $h2{a} = 99;

    $k1->unlock;

    # after unlock, k2 can write freely again
    is $h2{a}, 2, "enforced_locking with warn - after k1 unlock, h2 set properly";
    $h2{a} = 3;
    is $h2{a}, 3, "enforced_locking with warn - k2 can write after k1 unlocks";
}

# LOCK_EX + CLEAR on a hash: _was_changed deferred write
{
    my $k = tie my %h, 'IPC::Shareable', { key => 'T3', create => 1, destroy => 1 };
    $h{a} = 1;
    $h{b} = 2;
    $k->lock(IPC::Shareable::LOCK_EX);
    %h = ();
    is $k->{_was_changed}, 1, "LOCK_EX CLEAR: _was_changed set while locked";
    $k->unlock;
    is keys(%h), 0, "LOCK_EX CLEAR: hash empty after unlock";
}

# LOCK_EX + DELETE on a hash: _was_changed deferred write
{
    my $k = tie my %h, 'IPC::Shareable', { key => 'T4', create => 1, destroy => 1 };
    $h{x} = 10;
    $h{y} = 20;
    $k->lock(IPC::Shareable::LOCK_EX);
    delete $h{x};
    is $k->{_was_changed}, 1, "LOCK_EX DELETE: _was_changed set while locked";
    $k->unlock;
    is exists($h{x}), '', "LOCK_EX DELETE: key removed after unlock";
    is $h{y}, 20,          "LOCK_EX DELETE: other key intact after unlock";
}

# LOCK_EX + array mutation ops: PUSH, POP, SHIFT, UNSHIFT, SPLICE
{
    my $k = tie my @a, 'IPC::Shareable', { key => 'T5', create => 1, destroy => 1 };
    @a = (1, 2, 3);

    $k->lock(IPC::Shareable::LOCK_EX);

    push @a, 4;
    is $k->{_was_changed}, 1, "LOCK_EX PUSH: _was_changed set";
    $k->{_was_changed} = 0;

    my $p = pop @a;
    is $p, 4,               "LOCK_EX POP: returns correct value";
    is $k->{_was_changed}, 1, "LOCK_EX POP: _was_changed set";
    $k->{_was_changed} = 0;

    my $s = shift @a;
    is $s, 1,               "LOCK_EX SHIFT: returns correct value";
    is $k->{_was_changed}, 1, "LOCK_EX SHIFT: _was_changed set";
    $k->{_was_changed} = 0;

    unshift @a, 9;
    is $k->{_was_changed}, 1, "LOCK_EX UNSHIFT: _was_changed set";
    $k->{_was_changed} = 0;

    my @gone = splice @a, 0, 1, 99;
    is $gone[0], 9,          "LOCK_EX SPLICE: spliced-out value correct";
    is $k->{_was_changed}, 1, "LOCK_EX SPLICE: _was_changed set";

    $k->unlock;
    is $a[0], 99, "LOCK_EX array ops: all changes written back on unlock";
}

# LOCK_SH: hash read ops skip _decode when already locked (EXISTS, FIRSTKEY)
{
    my $k = tie my %h, 'IPC::Shareable', { key => 'T6', create => 1, destroy => 1 };
    $h{a} = 1;
    $k->lock(IPC::Shareable::LOCK_SH);
    ok  exists($h{a}), "LOCK_SH EXISTS: returns true for existing key (uses cached _data)";
    ok !exists($h{z}), "LOCK_SH EXISTS: returns false for missing key (uses cached _data)";
    my @keys = keys %h;
    is scalar(@keys), 1, "LOCK_SH FIRSTKEY: keys() returns correct count while locked";
    $k->unlock;
}

# LOCK_SH: array FETCHSIZE skips _decode when already locked
{
    my $k = tie my @a, 'IPC::Shareable', { key => 'T7', create => 1, destroy => 1};
    @a = (1, 2, 3);
    $k->lock(IPC::Shareable::LOCK_SH);
    is scalar(@a), 3, "LOCK_SH FETCHSIZE: scalar(\@array) correct while locked (uses cached _data)";
    $k->unlock;
}

# LOCK_EX + STORESIZE ($#array = N): _was_changed deferred write
{
    my $k = tie my @a, 'IPC::Shareable', { key => 'T8', create => 1, destroy => 1 };
    @a = (1, 2, 3, 4, 5);
    $k->lock(IPC::Shareable::LOCK_EX);
    $#a = 1;
    is $k->{_was_changed}, 1, "LOCK_EX STORESIZE: _was_changed set while locked";
    $k->unlock;
    is scalar(@a), 2, "LOCK_EX STORESIZE: array truncated after unlock";
}

# enforced_locking: array write ops blocked when another knot holds LOCK_EX
{
    my $k1 = tie my @a1, 'IPC::Shareable', {
        key => 'T9', create => 1, destroy => 1, enforced_locking => 1 };
    my $k2 = tie my @a2, 'IPC::Shareable', {
        key => 'T9', enforced_locking => 1 };

    @a1 = (1, 2, 3);
    $k1->lock(IPC::Shareable::LOCK_EX);

    push    @a2, 99;
    is scalar(@a2), 3, "enforced_locking PUSH: blocked when k1 holds LOCK_EX";

    pop     @a2;
    is scalar(@a2), 3, "enforced_locking POP: blocked when k1 holds LOCK_EX";

    shift   @a2;
    is $a2[0], 1, "enforced_locking SHIFT: blocked when k1 holds LOCK_EX";

    unshift @a2, 0;
    is $a2[0], 1, "enforced_locking UNSHIFT: blocked when k1 holds LOCK_EX";

    splice  @a2, 0, 1;
    is scalar(@a2), 3, "enforced_locking SPLICE: blocked when k1 holds LOCK_EX";

    $#a2 = 0;
    is scalar(@a2), 3, "enforced_locking STORESIZE: blocked when k1 holds LOCK_EX";

    $k1->unlock;
}

# enforced_locking: hash CLEAR and DELETE blocked when another knot holds LOCK_EX
{
    my $k1 = tie my %h1, 'IPC::Shareable', {
        key => 'TA', create => 1, destroy => 1, enforced_locking => 1 };
    my $k2 = tie my %h2, 'IPC::Shareable', {
        key => 'TA', enforced_locking => 1 };

    $h1{a} = 1;
    $h1{b} = 2;
    $k1->lock(IPC::Shareable::LOCK_EX);

    delete $h2{a};
    ok exists($h2{a}), "enforced_locking DELETE: blocked when k1 holds LOCK_EX";

    %h2 = ();
    is $h2{a}, 1, "enforced_locking CLEAR: blocked when k1 holds LOCK_EX";

    $k1->unlock;
}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
