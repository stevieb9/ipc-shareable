use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;

tie my %p, 'IPC::Shareable', {
    key => 'ipcp',
};

print Dumper \%p;
