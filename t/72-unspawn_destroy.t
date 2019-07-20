use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

tie my %h, 'IPC::Shareable', {
    key       => 'aaaa',
    destroy   => 1,
    mode      => 0666,
};

is $h{t70}->[1], 5, "hash element ok";

IPC::Shareable->unspawn('aaaa', 1);

is %h, '', "hash deleted after calling unspawn() with destroy => 1";

done_testing();