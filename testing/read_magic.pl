use warnings;
use strict;

use Data::Dumper;
use Storable qw(freeze thaw read_magic);

my %data = (a => 1, b => 2);

my $ice = freeze(\%data);

print Dumper $ice;

my $x = read_magic($ice);

print Dumper $x;


