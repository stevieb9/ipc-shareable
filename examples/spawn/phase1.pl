use warnings;
use strict;
use feature 'say';

use Data::Dumper;
use IPC::Shareable;

my $segs = IPC::Shareable::ipcs;
print "\nStarting with $segs segments\n";

tie my %hash, 'IPC::Shareable', {
    key     => 'SPAWN TEST',
    create  => 1,
};

print "\nPHASE 1 - spawn\n\n";

$hash{phase1}{spawn} = 'a';

tied(%hash)->spawn;