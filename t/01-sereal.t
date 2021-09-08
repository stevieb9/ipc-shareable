use warnings;
use strict;

use Data::Dumper;
use Test::More;
use Devel::Trace::Subs qw(trace_dump);

use IPC::Shareable;
my $k_s = tie my %s, 'IPC::Shareable', {
    key        => 'storable',
    create     => 1,
    destroy    => 1,
    serializer => 'storable',
};

my $k_j = tie my %j, 'IPC::Shareable', {
    key        => 'json1',
    create     => 1,
    destroy    => 1,
    serializer => 'json',
};

#my $k_e = tie my %e, 'IPC::Shareable', {
#    key        => 'sereal1',
#    create     => 1,
#    destroy    => 1,
#    serializer => 'sereal',
#};
#


$s{s} = {a => 1};
$j{j} = {a => 1};
#$e{e} = {a => 1};

$s{s}->{a} = 99;
$j{j}->{a} = 99;
#$e{e}->{a} = 99;

#trace_dump(want => 'flow');


print Dumper \%s;
print Dumper \%j;
#print Dumper \%e;


done_testing();
