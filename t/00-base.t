use warnings;
use strict;

use Data::Dumper;
use Test::More;

BEGIN {
    #if (!$ENV{CI_TESTING}) {
    #    plan skip_all => "Not on a valid CI platform...";
    #}
    use_ok('IPC::Shareable');
};

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

print "Starting with $segs_before segments\n";
is $segs_before, $segs_before, "Initial test ok";

tie my %store, 'IPC::Shareable', {key => 'async_tests', create => 1};
$store{segs} = $segs_before;


{
    my $a = tie my $x, 'IPC::Shareable';
    my $b = tie my $y, 'IPC::Shareable', { create => 1, destroy => 1 };

    is $a->{_key}, 0, "tie with no glue or options is IPC_PRIVATE ok";
    is $b->{_key}, 0, "tie with no glue but with options is IPC_PRIVATE ok";

    $a->remove;
}

IPC::Shareable::_end;

warn "Segs After: " . IPC::Shareable::ipcs() . "\n" if $ENV{PRINT_SEGS};
is IPC::Shareable::ipcs(), $segs_before + 1, "No segs left after test suite run ok";

done_testing();