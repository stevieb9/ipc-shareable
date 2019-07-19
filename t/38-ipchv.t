use warnings;
use strict;

use Carp;
use IPC::Shareable;
use Test::More tests => 8;

my %shareOpts = (
		 create =>       'yes',
		 exclusive =>    0,
		 mode =>         0644,
		 destroy =>      'yes',
		 );

my $awake = 0;
local $SIG{ALRM} = sub { $awake = 1 };

my $pid = fork;
defined $pid or die "Cannot fork: $!";

if ($pid == 0) {
    # child

    sleep unless $awake;
    $awake = 0;

    my $ipch = tie my %hv, 'IPC::Shareable', "data", {
        create    => 'yes',
        exclusive => 0,
        mode      => 0644,
        destroy   => 0,
    };

    for (qw(fee fie foe fum)) {
        $hv{$_} = $$;
    }

    sleep unless $awake;

#    for (qw(fee fie foe fum)) {
#        is $hv{$_}, $$, "child: HV key $_ has val $$";
#    }

    my $parent = getppid;
    $parent == 1 and die "Parent process has unexpectedly gone away";

#    for (qw(eenie meenie minie moe)) {
#        is $hv{$_}, $parent, "child: HV key $_ has val $parent (parent PID)";
#    }
} else {
    # parent

    my $ipch = tie my %hv, 'IPC::Shareable', "data", {
        create    => 1,
        exclusive => 0,
        mode      => 0666,
        size      => 1024*512,
        destroy   => 'yes',
    };

    %hv = ();

    kill ALRM => $pid;
    sleep 1;           # Allow time for child to process the signal before next ALRM comes in
    
    for (qw(eenie meenie minie moe)) {
        $hv{$_} = $$;
    }

    kill ALRM => $pid;
    waitpid($pid, 0);

    for (qw(fee fie foe fum)) {
        is $hv{$_}, $pid, "parent: HV $_ has val $pid";
    }

    for (qw(eenie meenie minie moe)) {
        is $hv{$_}, $$, "parent: HV $_ has val $$";
    }
}

#done_testing();
