use warnings;
use strict;
use feature 'say';

use Data::Dumper;
use IPC::Shareable;

$Data::Dumper::Sortkeys = 1;

tie my %hash, 'IPC::Shareable', {
    key     => 'SPAWN TEST',
    destroy => 1
};

$hash{phase1}{phase3}{add} = "Added by phase3";
$hash{phase2}{testing}{phase3} = "Added by phase3";
$hash{phase3}{unspawn} = 'z';

print "\nPHASE 3 - unspawn\n\n";

print "Displaying aggregated in-memory hash\n";
print Dumper \%hash;

tied(%hash)->unspawn('SPAWN TEST', 1);

IPC::Shareable::clean_up_all;
IPC::Shareable::_end;

my $segs = IPC::Shareable::ipcs;
print "\nEnding with $segs segments\n";