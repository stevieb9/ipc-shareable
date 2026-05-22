use warnings;
use strict;

# Run this on a FreeBSD system to inspect the raw sysctl kern.ipc output
# and confirm the keys/values that sysv_info() will parse.

print "=== Raw sysctl kern.ipc output ===\n\n";
my $raw = `sysctl kern.ipc 2>/dev/null`;
print $raw;

print "\n=== Keys matched by sysv_info regex (shm* only) ===\n\n";
for my $line (split /\n/, $raw) {
    if ($line =~ /^kern\.ipc\.(shm\w+):\s*(\S+)/) {
        printf "  %-10s => %s\n", $1, $2;
    }
}

print "\n=== Via IPC::Shareable->sysv_info ===\n\n";
use lib 'lib';
use IPC::Shareable;

my $info = IPC::Shareable->sysv_info;

if (!defined $info) {
    print "sysv_info() returned undef (not running on FreeBSD?)\n";
}
else {
    for my $key (sort keys %$info) {
        printf "  %-10s => %s\n", $key, $info->{$key};
    }
}
