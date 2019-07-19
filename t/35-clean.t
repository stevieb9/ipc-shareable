use warnings;
use strict;

use Carp;
use IPC::Shareable;
use IPC::Shareable::SharedMem;
use Test::More;

sub check_fail {
    # --- shmread should barf if the segment has really been cleaned
    my $id = shift;
    my $data = '';
    eval { shmread($id, $data, 0, 6) or die "$!" };
    return scalar($@ =~ /Invalid/ or $@ =~ /removed/);
}

# remove()

my $s = tie my $sv, 'IPC::Shareable', { destroy => 0 };
$sv = 'foobar';
is $sv, 'foobar', "SV set and value is 'foobar'";

#TODO: update the following after we've got proper methods

# XXX Don't do the following: it's not part of the interface!

my $id = $s->{_shm}->id;
$s->remove;
is check_fail($id), 1, "seg id $id removed after remove() ok";

my $awake = 0;
local $SIG{ALRM} = sub { $awake = 1 };

# remove(), clean_up(), clean_up_all()

my $pid = fork;
defined $pid or die "Cannot fork : $!";

if ($pid == 0) {
    # child
    sleep unless $awake;
    my $s = tie($sv, 'IPC::Shareable', 'hash', { destroy => 0 });
    $sv = 'baz';
#    is $sv, 'baz', "SV initialized and set to 'baz' ok";

    my $data = '';
    my $id = $s->{_shm}->id;

    IPC::Shareable->clean_up();

    shmread($id, $data, 0, length('IPC::Shareable'));

#    is $data, 'IPC::Shareable', "SV doesn't get wiped if in a different proc w/clean_up()";

    $s->remove;
#    is check_fail($id), 1, "after remove(), all is well ok in child";

    tie($sv, 'IPC::Shareable', 'kids', { create => 'yes', destroy => 0 });
    $sv = 'the kid was here';
#    is $sv, 'the kid was here', "child set SV ok before exit";
    exit;

} else {
    # parent

    my $s = tie($sv, 'IPC::Shareable', 'hash', { create => 'yes', destroy => 0 });
    kill ALRM => $pid;
    my $id = $s->{_shm}->id;
    waitpid($pid, 0);

    is check_fail($id), 1, "ID cleaned up in parent";
}

$s = tie($sv, 'IPC::Shareable', 'kids', { destroy => 0 });
$id = $s->{_shm}->id;

is $sv, 'the kid was here', "in parent: SV set in child ok";

IPC::Shareable->clean_up_all;
is check_fail($id), 1, "all mem segments destroyed with cleanup_all()";

done_testing();
