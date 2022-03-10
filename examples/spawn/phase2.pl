use warnings;
use strict;
use feature 'say';

use Data::Dumper;
use IPC::Shareable;

my $segs = IPC::Shareable::ipcs;

print "\nPHASE 2 - update\n\n";

print "Begin testing with $segs segments\n";

tie my %hash, 'IPC::Shareable', {
    key => 'SPAWN TEST'
};

$hash{phase2}{testing}{a} = [1, 2, 3];
$hash{phase2}{testing}{b} = {a => 1, b => 2};

$segs = IPC::Shareable::ipcs;
print "End testing with $segs segments\n";