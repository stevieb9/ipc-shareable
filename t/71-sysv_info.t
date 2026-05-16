use warnings;
use strict;

use IPC::Shareable;
use Test::More;

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

# sysv_info() - class method
{
    my $info = IPC::Shareable->sysv_info;

    if ($^O eq 'darwin' || $^O eq 'linux') {
        isnt $info, undef, "sysv_info() returns a value on $^O";
        is ref $info, 'HASH', "...and it's a hash ref";

        for my $key (qw(shmmax shmmin shmmni shmall)) {
            ok exists $info->{$key}, "...key '$key' exists";
            like $info->{$key}, qr/^\d+$/, "...'$key' is an integer ($info->{$key})";
        }

        if ($^O eq 'darwin') {
            ok exists $info->{shmseg}, "...key 'shmseg' exists on macOS";
            like $info->{shmseg}, qr/^\d+$/, "...'shmseg' is an integer ($info->{shmseg})";
        }
    }
    else {
        is $info, undef, "sysv_info() returns undef on unsupported platform ($^O)";
    }
}

# sysv_info() - object method
{
    my $knot = tie my %hv, 'IPC::Shareable', { create => 1, destroy => 1 };

    my $info = $knot->sysv_info;

    if ($^O eq 'darwin' || $^O eq 'linux') {
        isnt $info, undef, "sysv_info() called as object method returns a value";
        is ref $info, 'HASH', "...and it's a hash ref";

        for my $key (qw(shmmax shmmin shmmni shmall)) {
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
    my $knot = tie my %hv, 'IPC::Shareable', { create => 1, destroy => 1 };

    if ($^O eq 'darwin' || $^O eq 'linux') {
        my $class_info  = IPC::Shareable->sysv_info;
        my $object_info = $knot->sysv_info;

        is_deeply $class_info, $object_info,
            "Class method and object method return identical data";
    }

    IPC::Shareable->clean_up_all;
}

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
