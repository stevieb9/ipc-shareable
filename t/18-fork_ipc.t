use warnings;
use strict;

use Carp;
use IPC::Shareable;
IPC::Shareable->testing_set('IPC::Shareable');
use Test::More;
use Test::SharedFork;

use FindBin;
use lib $FindBin::Bin;
use IPCShareableTest qw(unique_glue assert_clean);

# serializer: storable
{
    my $awake = 0;
    local $SIG{ALRM} = sub { $awake = 1 };

    my $pid = fork;
    defined $pid or die "Cannot fork: $!";

    if ($pid == 0) {
        # child

        sleep unless $awake;

        tie my %h, 'IPC::Shareable', { key => unique_glue('testing25'), destroy => 0 , serializer => 'storable' };
        $h{a} = 'foo';
        exit;
    } else {
        # parent

        tie my %h, 'IPC::Shareable', {
            key     => unique_glue('testing25'),
            create  => 1,
            destroy => 1,
                    serializer => 'storable',
        };

        $h{a} = 'bar';
        is $h{a}, 'bar', "storable: in parent: parent set HV to 'bar' ok";

        kill ALRM => $pid;
        waitpid($pid, 0);

        is $h{a}, 'foo', "storable: in parent: child set HV to 'foo' ok";

        IPC::Shareable->clean_up_all;
    }
}

# serializer: json
{
    my $awake = 0;
    local $SIG{ALRM} = sub { $awake = 1 };

    my $pid = fork;
    defined $pid or die "Cannot fork: $!";

    if ($pid == 0) {
        # child

        sleep unless $awake;

        tie my %h, 'IPC::Shareable', { key => unique_glue('testing25j'), destroy => 0, serializer => 'json' };
        $h{a} = 'foo';
        exit;
    } else {
        # parent

        tie my %h, 'IPC::Shareable', {
            key        => unique_glue('testing25j'),
            create     => 1,
            destroy    => 1,
            serializer => 'json',
        };

        $h{a} = 'bar';
        is $h{a}, 'bar', "json: in parent: parent set HV to 'bar' ok";

        kill ALRM => $pid;
        waitpid($pid, 0);

        is $h{a}, 'foo', "json: in parent: child set HV to 'foo' ok";

        IPC::Shareable->clean_up_all;
    }
}

IPC::Shareable::_end;

assert_clean(unique_glue('testing25'), unique_glue('testing25j'));

done_testing();
