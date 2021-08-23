use warnings;
use strict;

use Data::Dumper;
use Test::More;

use IPC::Shareable;

my $k_e = tie my %e, 'IPC::Shareable', {
    key        => 'sereal1',
    create     => 1,
    destroy    => 1,
    serializer => 'sereal',
};

my $k_j = tie my %j, 'IPC::Shareable', {
    key        => 'json1',
    create     => 1,
    destroy    => 1,
    serializer => 'json',
};

#my $k_s = tie my %s, 'IPC::Shareable', {
#    key        => 'storable',
#    create     => 1,
#    destroy    => 1,
#    serializer => 'storable',
#};


#$j{j} = "test";
$e{e} = "test";

#print Dumper \%j;
#print Dumper \%e;

done_testing();
