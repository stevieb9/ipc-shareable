use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

my $protect_lock = 292;

tie my %p, 'IPC::Shareable', {
    key     => 'protected',
    create  => 1,
    destroy => 1,
    protected => $protect_lock,
};

tie my %u, 'IPC::Shareable', {
    key     => 'unprotected',
    create  => 1,
    destroy => 1,
};

$p{one}{two} = 1;
$u{one}{two} = 1;

print Dumper \%p;
print Dumper \%u;

done_testing();
