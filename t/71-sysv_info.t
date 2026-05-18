use warnings;
use strict;

use File::Temp qw(tempdir);
use IPC::Shareable;
use Test::More;

my $segs_before = IPC::Shareable::shm_count();
my $sems_before = IPC::Shareable::sem_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

# sysv_info() - class method
{
    my $info = IPC::Shareable->sysv_info;

    if ($^O eq 'darwin' || $^O eq 'linux') {
        isnt $info, undef, "sysv_info() returns a value on $^O";
        is ref $info, 'HASH', "...and it's a hash ref";

        # shmmax, shmmni, shmall are always present on both platforms
        for my $key (qw(shmmax shmmni shmall)) {
            ok exists $info->{$key}, "...key '$key' exists";
            like $info->{$key}, qr/^\d+$/, "...'$key' is an integer ($info->{$key})";
        }

        if ($^O eq 'darwin') {
            # shmmin and shmseg come from sysctl and are always present on macOS
            for my $key (qw(shmmin shmseg)) {
                ok exists $info->{$key}, "...key '$key' exists on macOS";
                like $info->{$key}, qr/^\d+$/, "...'$key' is an integer ($info->{$key})";
            }
        }
        elsif ($^O eq 'linux') {
            # shmmin is a kernel compile-time constant; not always exposed via procfs
            if (exists $info->{shmmin}) {
                like $info->{shmmin}, qr/^\d+$/, "...'shmmin' is an integer if present ($info->{shmmin})";
            }
            else {
                pass "...'shmmin' not available via procfs on this kernel (ok)";
            }
        }
    }
    else {
        is $info, undef, "sysv_info() returns undef on unsupported platform ($^O)";
    }
}

# sysv_info() - object method
{
    my $knot = tie my %hv, 'IPC::Shareable', { create => 1, destroy => 1 , serializer => 'storable' };

    my $info = $knot->sysv_info;

    if ($^O eq 'darwin' || $^O eq 'linux') {
        isnt $info, undef, "sysv_info() called as object method returns a value";
        is ref $info, 'HASH', "...and it's a hash ref";

        for my $key (qw(shmmax shmmni shmall)) {
            ok exists $info->{$key}, "...key '$key' exists";
        }
    }
    else {
        is $info, undef, "sysv_info() returns undef on unsupported platform ($^O)";
    }

    IPC::Shareable->clean_up_all;
}

# sysv_info() - class method and object method return identical data
{
    my $knot = tie my %hv, 'IPC::Shareable', { create => 1, destroy => 1 , serializer => 'storable' };

    if ($^O eq 'darwin' || $^O eq 'linux') {
        my $class_info  = IPC::Shareable->sysv_info;
        my $object_info = $knot->sysv_info;

        is_deeply $class_info, $object_info,
            "Class method and object method return identical data";
    }

    IPC::Shareable->clean_up_all;
}

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";
my $sems_after = IPC::Shareable::sem_count();
is $sems_after, $sems_before, "All semaphore sets cleaned up ok";

# -----------------------------------------------------------------------
# Linux branch - mocked via _proc_dir and local $^O
# -----------------------------------------------------------------------

{
    my $tmpdir = tempdir(CLEANUP => 1);

    for my $key (qw(shmmax shmmin shmmni shmall)) {
        open my $fh, '>', "$tmpdir/$key" or die "Cannot create $tmpdir/$key: $!";
        print $fh "65536\n";
        close $fh;
    }

    my $info;
    {
        local $^O = 'linux';
        $info = IPC::Shareable->sysv_info(_proc_dir => $tmpdir);
    }

    isnt $info, undef,
        "linux branch (mocked): sysv_info() returns a defined value";
    is ref($info), 'HASH',
        "linux branch (mocked): return value is a hash ref";

    for my $key (qw(shmmax shmmin shmmni shmall)) {
        is $info->{$key}, '65536',
            "linux branch (mocked): '$key' reads value from fake proc file";
    }
}

done_testing();
