use warnings;
use strict;

use IPC::SysV qw(IPC_RMID);
use Mock::Sub;
use Test::More;

#plan skip_all => "TEST FILE NOT READY";

use IPC::Shareable;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

{
    # exclusive duplicate

    my $opts = {
        key       => 1234,
        create    => 1,
        exclusive => 1,
        destroy   => 1,
        mode      => 0600,
        size      => 999,
    };

    my $s = tie my %opt_test => 'IPC::Shareable', $opts;
    $opt_test{a} = 1;


    is
        eval {
            my $s = tie my %opt_test => 'IPC::Shareable', $opts;
            1;
        },
        undef,
        "trying to re-create an existing memory segment fails";

    like $@, qr/ERROR:.*File exists/, "...and error message is sane";

}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

# _decode_json: croaks when decode_json returns undef (mocked)
{
    tie my %h, 'IPC::Shareable', { create => 1, destroy => 1, serializer => 'json' };
    $h{a} = 1;  # write something so the segment has the IPC::Shareable tag

    # Use local typeglob override instead of Mock::Sub to avoid prototype mismatch
    # warnings (decode_json carries a ($) prototype).
    local *IPC::Shareable::decode_json = sub { return undef };

    is eval { my $x = $h{a}; 1 }, undef,
        "_decode_json: croaks when decode_json returns undef";
    like $@, qr/Munged shared memory segment/,
        "_decode_json: error message mentions munged segment";
}

# _tie: limit check — croaks when size > SHMMAX_BYTES and limit => 1
{
    is
        eval { tie my %h, 'IPC::Shareable', { create => 1, destroy => 1, size => 2_000_000_000, limit => 1 }; 1 },
        undef,
        "_tie limit: croaks when size exceeds SHMMAX_BYTES";
    like $@, qr/larger than max size/,
        "_tie limit: error message mentions max size";
}

# _tie: fallthrough croak when SharedMem->new returns undef (create => 1, not exclusive)
{
    my $mock = Mock::Sub->new;
    my $shm_mock = $mock->mock('IPC::Shareable::SharedMem::new', return_value => undef);

    is
        eval { tie my %h, 'IPC::Shareable', { create => 1, destroy => 1 }; 1 },
        undef,
        "_tie: croaks when SharedMem->new returns undef";
    like $@, qr/Could not create shared memory segment/,
        "_tie: error message mentions shared memory segment";
}

# _tie: "Could not create semaphore set" when IPC::Semaphore->new returns undef
{
    my $key     = '0x1B0BFFF2';
    my $key_int = hex($key);

    {
        my $mock = Mock::Sub->new;
        my $sem_mock = $mock->mock('IPC::Semaphore::new', return_value => undef);

        is
            eval { tie my %h, 'IPC::Shareable', { key => $key, create => 1, destroy => 0 }; 1 },
            undef,
            "_tie: croaks when IPC::Semaphore->new returns undef";
        like $@, qr/Could not create semaphore set/,
            "_tie: error message mentions semaphore set";
    }

    # The shm segment was created before IPC::Semaphore->new failed, so it
    # is not in any register.  Clean it up manually to keep the shm count clean.
    my $leaked_id = shmget($key_int, 0, 0);
    shmctl($leaked_id, IPC_RMID, 0) if defined $leaked_id;
}

# _thaw: croaks when Storable::thaw returns undef (munged segment)
{
    tie my $sv, 'IPC::Shareable', { create => 1, destroy => 1 };
    $sv = 'hello';   # write so the segment carries the IPC::Shareable tag

    {
        my $mock      = Mock::Sub->new;
        my $thaw_mock = $mock->mock('IPC::Shareable::thaw', return_value => undef);

        is eval { my $x = $sv; 1 }, undef,
            "_thaw: croaks when Storable::thaw returns undef";
        like $@, qr/Munged shared memory segment/,
            "_thaw: error message mentions munged segment";
    }
}

# _tie: croaks with OOM message when SharedMem->new fails with ENOMEM
{
    local *IPC::Shareable::SharedMem::new = sub {
        $! = 12;   # ENOMEM
        return undef;
    };

    is eval { tie my %h, 'IPC::Shareable', { create => 1, destroy => 1 }; 1 }, undef,
        "_tie: croaks when SharedMem->new fails with ENOMEM";
    like $@, qr/spawning too many segments/,
        "_tie: OOM error message references segment spawning";
}

# _tie: croaks when create+exclusive set but SharedMem->new returns undef
# (SharedMem::new normally croaks itself for File exists; this tests the _tie fallthrough)
{
    local *IPC::Shareable::SharedMem::new = sub {
        $! = 17;   # EEXIST
        return undef;
    };

    is eval { tie my %h, 'IPC::Shareable', { create => 1, exclusive => 1, destroy => 1 }; 1 }, undef,
        "_tie: croaks when create+exclusive set and SharedMem->new returns undef";
    like $@, qr/exclusive.*are set|Does the segment already exist/,
        "_tie: create+exclusive error message correct";
}

# _tie: croaks when sem->op fails for the initial LOCK_SH
{
    my $key     = '0x1B0BFFF5';
    my $key_int = hex($key);

    {
        my $mock    = Mock::Sub->new;
        my $op_mock = $mock->mock('IPC::Semaphore::op', return_value => 0);

        is eval { tie my %h, 'IPC::Shareable', { key => $key, create => 1, destroy => 0 }; 1 }, undef,
            "_tie: croaks when sem->op fails for initial LOCK_SH";
        like $@, qr/Could not obtain semaphore set lock/,
            "_tie: semaphore op failure error message correct";
    }

    # SharedMem and the semaphore set were created before op failed — clean up manually.
    my $leaked_id = shmget($key_int, 0, 0);
    shmctl($leaked_id, IPC_RMID, 0) if defined $leaked_id;
    my $leaked_sem = IPC::Semaphore->new($key_int, 0, 0);
    $leaked_sem->remove if defined $leaked_sem;
}

# _tie: croaks when sem->setval fails during initialization
{
    my $key     = '0x1B0BFFF6';
    my $key_int = hex($key);

    {
        my $mock        = Mock::Sub->new;
        my $setval_mock = $mock->mock('IPC::Semaphore::setval', return_value => 0);

        is eval { tie my %h, 'IPC::Shareable', { key => $key, create => 1, destroy => 0 }; 1 }, undef,
            "_tie: croaks when sem->setval fails during initialization";
        like $@, qr/Couldn't set semaphore during object creation/,
            "_tie: setval failure error message correct";
    }

    # Clean up the leaked shm segment and semaphore set.
    my $leaked_id = shmget($key_int, 0, 0);
    shmctl($leaked_id, IPC_RMID, 0) if defined $leaked_id;
    my $leaked_sem = IPC::Semaphore->new($key_int, 0, 0);
    $leaked_sem->remove if defined $leaked_sem;
}

done_testing();
