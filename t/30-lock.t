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

    (tied $sv)->lock;
    for (0 .. 99) {
        ++$sv;
    }
    (tied $sv)->unlock;
    
    exit;

} else {
    # parent

    tie($sv, 'IPC::Shareable', data => { create => 'yes', destroy => 'yes' })
        or die "parent process can't tie \$sv";
    $sv = 0;
    kill ALRM => $pid;

    (tied $sv)->lock;

    for (0 .. 99) {
           ++$sv;
    }
    (tied $sv)->unlock;
    is $sv, 100, "in parent: locked and updated SV to 100";
    waitpid($pid, 0);
    is $sv, 200, "in parent: locked and updated SV to 200";
}

done_testing();
