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

my $segs_before = IPC::Shareable::ipcs();
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

{
    my $k1 = tie my %h1, 'IPC::Shareable', { key => 'TEST1', create => 1, destroy => 1 };
    my $k2 = tie my %h2, 'IPC::Shareable', { key => 'TEST1', create => 1, destroy => 1 };

    $h1{a} = {b => 1};

    is_deeply {%h1}, {a => {b => 1}}, "h1 - initial value set";
    is_deeply {%h2}, {a => {b => 1}}, "h2 - sees h1's initial value via same key";

    # Correct pattern for modifying nested data while locked: use a top-level
    # STORE on the parent hash, NOT $h1{a}->{b} = 3.
    #
    # $h1{a}->{b} = 3 while locked calls STORE on the child segment's knot, not
    # on k1. k1's _was_changed flag is never set, so unlock() skips _encode and
    # the modification is never written back to shared memory. Additionally,
    # Storable preserves the IPC::Shareable tie across freeze/thaw, so after
    # lock() decodes the segment _data->{a} is still a tied hash reference.
    # If another knot writes to the same key while k1 is locked (without calling
    # lock() itself -- see below), its _reset_segment removes the underlying
    # child segment that k1's _data->{a} still points to, causing it to read as
    # {}.
    #
    # Using a top-level STORE ($h1{a} = ...) sets _was_changed = 1 on k1 and
    # properly replaces the child segment via _magic_tie / _reset_segment.
    $k1->lock;

    $h1{a} = {b => 3};   # top-level STORE: sets k1->{_was_changed} = 1
    $h2{a} = {c => 10};

    print Dumper \%h2;
    $k1->unlock;          # writes {a => {b => 3}} back to shared memory

    is_deeply {%h1}, {a => {b => 3}}, "h1 - locked STORE written back on unlock";
    is_deeply {%h2}, {a => {b => 3}}, "h2 - sees h1's change after unlock";


    print Dumper \%h1;
    print Dumper \%h2;
    # IPC::Shareable uses cooperative (advisory) locking via SysV semaphores.
    # A knot that does NOT call lock() bypasses the semaphore and writes
    # directly, regardless of whether another knot holds the lock.
    # For true mutual exclusion both k1 AND k2 must call lock()/unlock() around
    # their critical sections. In a forked scenario, $k2->lock would block here
    # until k1 releases the semaphore.
}
IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
