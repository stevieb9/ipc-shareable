use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

tie my %hv, 'IPC::Shareable', {destroy => 1};

$hv{a} = 'foo';
is $hv{a}, 'foo', "data created and set ok";

tied(%hv)->clean_up;

is %hv, '', "data is removed after tied(\$data)->clean_up()";

done_testing();
