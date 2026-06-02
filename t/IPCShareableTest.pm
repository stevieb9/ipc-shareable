package IPCShareableTest;

use warnings;
use strict;

use Carp qw(croak);
use Exporter qw(import);
use Test::More;

use IPC::Shareable;
use IPC::Semaphore;

our @EXPORT_OK = qw(assert_clean assert_clean_process live_seg_count tree_seg_count unique_glue);

# A token that is unique to this process and stable across fork() (it is
# computed once, at load time, before any test forks). Embedding it in every
# glue string gives each test run its own System V IPC keyspace, so concurrent
# runs on the same host -- eg. a CPAN smoker testing many perls against the
# same release at once -- can no longer collide on the same shared memory
# segment or semaphore set. See evaluation.md for the failure analysis.

our $TOKEN = sprintf '%d-%d', $$, int(rand(1_000_000));

# Assert that every shared memory segment AND semaphore set belonging to the
# given run-scoped glue(s) has been cleaned up. Unlike the old global
# seg_count()/sem_count() comparison, this only inspects resources keyed to
# this run, so it is immune to unrelated IPC activity elsewhere on the host.

sub assert_clean {
    my (@glues) = @_;

    if (! @glues) {
        croak "assert_clean() requires at least one glue string";
    }

    my (@seg_leaks, @sem_leaks);

    for my $glue (@glues) {
        push @seg_leaks, $glue if tree_seg_count($glue) > 0;
        push @sem_leaks, $glue if _sem_exists($glue);
    }

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    is scalar(@seg_leaks), 0, "all of this run's shm segments cleaned up ok"
        or diag "leaked shm segments for glue(s): @seg_leaks";

    is scalar(@sem_leaks), 0, "all of this run's semaphore sets cleaned up ok"
        or diag "leaked semaphore sets for glue(s): @sem_leaks";
}

# Process-scoped end-of-test cleanup assertion. Verifies that THIS process has
# released every IPC::Shareable segment it created, via the module's own global
# register. Immune to IPC activity from other processes (other smokers, or
# parallel `prove -j` siblings), unlike the old global seg_count()/sem_count()
# before/after comparison. One assertion: semaphore sets are created and
# removed in lockstep with their segment, so an empty register implies none
# leaked. NB: only tracks resources created through the normal tie/new path; a
# test that pokes IPC::Shareable::SharedMem (or raw shm) directly should scope
# its own check to the keys it used instead.

sub assert_clean_process {
    my ($label) = @_;

    $label = "this process cleaned up all its IPC::Shareable segments"
        if ! defined $label;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    is live_seg_count(), 0, $label;
}

# Count of IPC::Shareable segments currently live and owned by THIS process
# (a tied structure's root plus its nested-reference children), via the
# module's own global register. Process-scoped, so it is immune to unrelated
# IPC activity from other processes -- and unlike tree_seg_count() it works for
# every serializer, including the binary 'storable' format whose child links
# shm_segments() cannot parse back out of segment content.

sub live_seg_count {
    return scalar keys %{ IPC::Shareable->global_register };
}

# Number of live IPC::Shareable segments in this glue's segment tree (the root
# plus any nested-reference child segments), as seen in the OS at the key
# level. Used by assert_clean() to confirm real cleanup. Note: only the JSON
# serializer records child links in a form shm_segments() can follow, so for
# measuring a live storable structure's size use live_seg_count() instead.

sub tree_seg_count {
    my ($glue) = @_;

    if (! defined $glue) {
        croak "tree_seg_count() requires a \$glue param";
    }

    my $segs = IPC::Shareable::shm_segments($glue);

    return scalar keys %$segs;
}

# Turn a human-readable base name into a glue string that is unique to this
# process. Deterministic within a process: unique_glue('foo') always returns
# the same string, in both the parent and any forked child, so both sides of a
# fork tie to the same key.

sub unique_glue {
    my ($base) = @_;

    if (! defined $base) {
        croak "unique_glue() requires a \$base param";
    }

    return "${base}-${TOKEN}";
}

sub _sem_exists {
    my ($glue) = @_;

    if (! defined $glue) {
        croak "_sem_exists() requires a \$glue param";
    }

    my $key = IPC::Shareable::_key_str_to_int($glue);

    # Attach-only (nsems => 0, flags => 0): returns an object if a semaphore
    # set already exists for this key, undef otherwise. This is the same probe
    # IPC::Shareable itself uses when removing a set.

    my $sem = IPC::Semaphore->new($key, 0, 0);

    return defined $sem ? 1 : 0;
}

1;
