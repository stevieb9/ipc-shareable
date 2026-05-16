use warnings;
use strict;

use IPC::Shareable;
use Test::More;

# Determine the shm segment limit for this platform.
# On macOS, kern.sysv.shmseg gives a per-process limit (typically 32).
# On Linux, kernel.shmmni is a system-wide limit (typically 4096).
# We can only run this test if the limit is low enough to exhaust safely.

my $limit;

{

    if ($^O eq 'darwin') {
        my $out = `sysctl kern.sysv.shmseg 2>/dev/null`;
        $limit = ($out =~ /(\d+)/) ? $1 : undef;
    }
    elsif ($^O eq 'linux') {
        if (open my $fh, '<', '/proc/sys/kernel/shmmni') {
            chomp($limit = <$fh>);
        }
    }

    if (! defined $limit) {
        plan skip_all => "Cannot determine shm segment limit on this platform ($^O)";
    }
    elsif ($limit > 500) {
        plan skip_all =>
            "shm segment limit ($limit) is too high to exhaust safely in a test (macOS shmseg=32 expected)";
    }
}

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable';

my $knot = tie my %hv, $mod, {
    create  => 1,
    key     => 1234,
    destroy => 1,
    size    => 1_048_576,   # large enough that kernel slot limit is hit first
};

my $ok = eval {
    for my $i (1 .. $limit + 1) {
        # Each unique key creates one child segment.  No delete, so segments
        # accumulate until the kernel shm slot limit is reached.
        $hv{$i} = {val => $i};
    }
    1;
};

# print $@;

is $ok, undef, "If we try to use all available shm slots, we croak()";
like $@, qr/No space left on device/, "...and error is sane";

IPC::Shareable->clean_up_all;

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
