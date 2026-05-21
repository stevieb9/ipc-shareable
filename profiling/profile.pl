#!/usr/bin/env perl
# Profile IPC::Shareable with Devel::NYTProf.
#
# Run:
#   perl -d:NYTProf testing/profile.pl
#   nytprofhtml --open
#
# Exercises the API in patterns a reasonable Perl developer would use.

use strict;
use warnings;
use IPC::Shareable qw(:lock);

# ── Scalar with enforced locking (real-world: shared counter) ──────────────

{
    tie my $counter, 'IPC::Shareable', {
        key                    => 'PROF_SCALAR',
        create                 => 1,
        destroy                => 1,
        enforced_write_locking => 1,
    };

    $counter = 0;
    for (1 .. 10) {
        tied($counter)->lock;
        $counter++;
        tied($counter)->unlock;
    }

    tied($counter)->lock(LOCK_SH);
    my $val = $counter;    # FETCH under shared lock
    tied($counter)->unlock;
}

# ── Hash with nested data (real-world: config cache) ──────────────────────

{
    tie my %config, 'IPC::Shareable', {
        key        => 'PROF_HASH',
        create     => 1,
        destroy    => 1,
        serializer => 'json',
    };

    # Populate
    $config{host}    = 'db01.example.com';
    $config{port}    = 5432;
    $config{options} = { timeout => 30, retries => 3 };
    $config{tags}    = ['primary', 'read-write'];

    # Locked update of nested ref (correct pattern: top-level STORE)
    tied(%config)->lock;
    $config{options} = { timeout => 60, retries => 5 };
    tied(%config)->unlock;

    # Read back
    tied(%config)->lock(LOCK_SH);
    my $host = $config{host};
    my $port = $config{port};
    tied(%config)->unlock;

    # Non-blocking lock attempt
    if (tied(%config)->lock(LOCK_SH | LOCK_NB)) {
        my %copy = %config;
        tied(%config)->unlock;
    }
}

# ── Array (real-world: job queue) ─────────────────────────────────────────

{
    tie my @queue, 'IPC::Shareable', {
        key        => 'PROF_ARRAY',
        create     => 1,
        destroy    => 1,
        serializer => 'storable',
    };

    # Push jobs
    tied(@queue)->lock;
    push @queue, { id => 1, task => 'send_email',   to => 'a@example.com' };
    push @queue, { id => 2, task => 'gen_report',   type => 'monthly' };
    push @queue, { id => 3, task => 'purge_cache',  older_than => 3600 };
    tied(@queue)->unlock;

    # Pop jobs
    tied(@queue)->lock;
    while (@queue) {
        my $job = shift @queue;
    }
    tied(@queue)->unlock;

    # Push/pop without explicit locks (advisory only — fine for single-process)
    push @queue, 'fast-job-1', 'fast-job-2';
    my $first = shift @queue;
}

# ── Deeply nested structure (3-5 levels, many children) ─────────────────────

{
    tie my %deep, 'IPC::Shareable', {
        key        => 'PROF_DEEP',
        create     => 1,
        destroy    => 1,
        serializer => 'json',
    };

    # Build a 4-level nested config with ~30 child segments
    $deep{servers} = {
        web => {
            count => 4,
            hosts => [
                { name => 'web01', ip => '10.0.0.1', resources => { cpu => 8, ram => 32768, disk => { type => 'ssd', size_gb => 500 } } },
                { name => 'web02', ip => '10.0.0.2', resources => { cpu => 8, ram => 32768, disk => { type => 'ssd', size_gb => 500 } } },
                { name => 'web03', ip => '10.0.0.3', resources => { cpu => 4, ram => 16384, disk => { type => 'hdd', size_gb => 1000 } } },
                { name => 'web04', ip => '10.0.0.4', resources => { cpu => 4, ram => 16384, disk => { type => 'hdd', size_gb => 1000 } } },
            ],
            lb_config => {
                algorithm => 'round-robin',
                health_check => { interval_sec => 5, timeout_sec => 2, path => '/health' },
            },
        },
        db => {
            primary => { name => 'db-primary', ip => '10.0.1.1', pool => { min => 5, max => 20, timeout => 30 } },
            replica => [
                { name => 'db-repl1', ip => '10.0.1.2', lag_ms => 200 },
                { name => 'db-repl2', ip => '10.0.1.3', lag_ms => 350 },
            ],
            backup => { schedule => { daily => '03:00', weekly => 'Sun 04:00' }, retention_days => 30 },
        },
        cache => {
            redis => {
                instances => [
                    { host => 'redis01', port => 6379, config => { maxmemory => '4gb', eviction => 'allkeys-lru', cluster => { enabled => 1, nodes => 6 } } },
                    { host => 'redis02', port => 6379, config => { maxmemory => '4gb', eviction => 'allkeys-lru', cluster => { enabled => 1, nodes => 6 } } },
                ],
            },
        },
    };

    # Locked mutation deep in the tree
    tied(%deep)->lock;
    $deep{servers}{web}{hosts}[0]{resources}{cpu} = 16;
    tied(%deep)->unlock;

    # Locked read of nested data
    tied(%deep)->lock(LOCK_SH);
    my $algo = $deep{servers}{web}{lb_config}{algorithm};
    my $r1   = $deep{servers}{cache}{redis}{instances}[0]{host};
    tied(%deep)->unlock;

    # Non-blocking lock + bulk replace
    if (tied(%deep)->lock(LOCK_EX | LOCK_NB)) {
        $deep{servers}{web}{hosts}[1]{resources}{ram} = 65536;
        $deep{servers}{db}{primary}{pool}{max} = 50;
        tied(%deep)->unlock;
    }
}

# ── Scoped lock with coderef ───────────────────────────────────────────────

{
    tie my $token, 'IPC::Shareable', {
        key      => 'PROF_SCOPED',
        create   => 1,
        destroy  => 1,
    };

    $token = 'initial';

    tied($token)->lock(sub {
        $token = 'updated-inside-scoped-lock';
    });
}

# ── Singleton (real-world: one-instance guard) ────────────────────────────

IPC::Shareable->singleton('PROFILING_SCRIPT_LOCK_STRING');

# ── Inspect attributes ─────────────────────────────────────────────────────

{
    tie my $x, 'IPC::Shareable', {
        key      => 'PROF_ATTRS',
        create   => 1,
        destroy  => 1,
    };

    $x = { a => 1, b => 2 };
    my $attrs = tied($x)->attributes;
}

# ── System introspection ───────────────────────────────────────────────────

my $seg_count  = IPC::Shareable::seg_count();
my $sem_count  = IPC::Shareable::sem_count();
my $sysv_info  = IPC::Shareable::sysv_info();

# seg_map() requires a tied object — use a fresh tie for introspection only
{
    tie my $insp, 'IPC::Shareable', {
        key      => 'PROF_INSPECT',
        create   => 1,
        destroy  => 1,
    };
    $insp = { foo => 'bar' };
    my $seg_map = tied($insp)->seg_map();
}

# ── Manual cleanup ─────────────────────────────────────────────────────────

IPC::Shareable::clean_up_all;

print "Profiling complete.\n";
