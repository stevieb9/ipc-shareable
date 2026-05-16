#!/usr/bin/env perl
use warnings;
use strict;

use Benchmark qw(timethis timediff timestr);
use Time::HiRes qw(time);
use IPC::Shareable;

# tidy => 1 (default): before writing a nested ref to an existing key,
# remove the old child segment first (_reset_segment). Clean, but costs
# an extra shmctl(IPC_RMID) + semctl(IPC_RMID) per overwrite.
#
# tidy => 0: skip segment cleanup on overwrite. Faster, but orphan segments
# accumulate for every nested-ref overwrite in a long-running process.
#
# Because tidy => 0 leaks one child segment per overwrite, and macOS limits
# processes to kern.sysv.shmseg segments (default 32), the two approaches
# cannot share a cmpthese loop. We time them sequentially, flushing between.

my $ITERS   = @ARGV ? int($ARGV[0]) : 1000;

# How many iterations are safe for the tidy=0 run before we hit the
# per-process segment ceiling (shmseg=32). Each iteration creates 2 child
# segments (one hash, one array) and never frees them. Starting with ~4
# already in use (2 shm + 2 sem for the parent), we have ~14 safe iterations;
# cap at 12 to be conservative and then scale the reported time.
my $MAX_UNTIDY = 12;
my $UNTIDY_ITERS = ($ITERS > $MAX_UNTIDY) ? $MAX_UNTIDY : $ITERS;

printf "Benchmark: tidy=1 for %d iters, tidy=0 for %d iters (segment-leak constrained)\n\n",
    $ITERS, $UNTIDY_ITERS;

# ---- tidy => 1 -------------------------------------------------------
{
    my %h;
    tie %h, 'IPC::Shareable', {
        key     => 'bench_tidy',
        create  => 1,
        destroy => 1,
        tidy    => 1,
    };

    # Seed so first loop iteration is an overwrite (not first-create)
    $h{nested} = { a => 1, b => 2 };
    $h{list}   = [ 1, 2, 3 ];

    my $t0 = time;
    for (1 .. $ITERS) {
        $h{nested} = { x => int(rand 1000), y => int(rand 1000) };
        my $v = $h{nested}{x};
        $h{list} = [ 1..5 ];
        my $f = $h{list}[0];
    }
    my $elapsed = time - $t0;

    printf "tidy=1  : %d iters in %.4fs  (%.2f us/iter)\n",
        $ITERS, $elapsed, ($elapsed / $ITERS) * 1e6;

    IPC::Shareable->clean_up_all;
}

# ---- tidy => 0 -------------------------------------------------------
{
    my %h;
    tie %h, 'IPC::Shareable', {
        key     => 'bench_untidy',
        create  => 1,
        destroy => 1,
        tidy    => 0,
    };

    $h{nested} = { a => 1, b => 2 };
    $h{list}   = [ 1, 2, 3 ];

    my $t0 = time;
    for (1 .. $UNTIDY_ITERS) {
        $h{nested} = { x => int(rand 1000), y => int(rand 1000) };
        my $v = $h{nested}{x};
        $h{list} = [ 1..5 ];
        my $f = $h{list}[0];
    }
    my $elapsed = time - $t0;

    my $per_iter  = $elapsed / $UNTIDY_ITERS;
    my $projected = $per_iter * $ITERS;

    printf "tidy=0  : %d iters in %.4fs  (%.2f us/iter)  [projected %d iters: %.4fs]\n",
        $UNTIDY_ITERS, $elapsed, $per_iter * 1e6, $ITERS, $projected;
    printf "Note: tidy=0 leaks 2 child segments per overwrite; capped at %d iters to stay\n",
        $MAX_UNTIDY;
    print  "      within kern.sysv.shmseg limit. Projected time assumes linear scaling.\n";

    IPC::Shareable->clean_up_all;
}

