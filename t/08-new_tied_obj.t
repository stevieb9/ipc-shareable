use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

my $mod = 'IPC::Shareable';

my $ph = $mod->new(
    key => 'hash',
    create => 1,
    destroy => 1
);

my $k = tied %$ph;

is ref $k, 'IPC::Shareable', "tied() returns a proper IPC::Shareable object ok";
is exists $k->{attributes}, 1, "...and it has proper attributes ok";

done_testing();
