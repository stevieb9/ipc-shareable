use warnings;
use strict;

use Carp;
use IPC::Shareable;
use Test::More;

my $sv;

my $awake = 0;
local $SIG{ALRM} = sub { $awake = 1 };

# locking

my $pid = fork;
defined $pid or die "Cannot fork: $!\n";

if ($pid == 0) {
    # child

    sleep unless $awake;
    tie($sv, 'IPC::Shareable', { key => 'data', destroy => 0 });

    for (0 .. 99) {
        (tied $sv)->shlock;
        ++$sv;
        (tied $sv)->shunlock;
    }
#    is $sv, 200, "in child: locked and set SV to 200";
    exit;

} else {
    # parent

    tie($sv, 'IPC::Shareable', data => { create => 'yes', destroy => 'yes' })
        or die "parent process can't tie \$sv";
    $sv = 0;
    kill ALRM => $pid;
    for (0 .. 99) {
        (tied $sv)->shlock;
        ++$sv;
        (tied $sv)->shunlock;
    }
    waitpid($pid, 0);
    is $sv, 200, "in parent: locked and updated SV to 200";
}

done_testing();
