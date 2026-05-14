use strict;
use warnings;

use Data::Dumper;
use Test::More;
use IPC::Shareable;

warn "Segs Before: " . IPC::Shareable::ipcs() . "\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable';

my $knot = tie my %hv, $mod, {
    create     => 1,
    key        => 1234,
    destroy    => 1,
};

my $seg = $knot->seg;
my $stats = $seg->stats;

my @stat_list = IPC::Shareable::SharedMem::_stat_list();

for (@stat_list) {
    my $data = $seg->stat->$_;

    like $data, qr/^\d+$/, "$_ segment stat returned an integer properly";

    is $data, $stats->{$_}, "stats() and stat $_ method data lines up ok";
}


#print Dumper $stats;
#print Dumper $knot;
#print Dumper $seg;

IPC::Shareable->clean_up_all;

is % hv, '', "hash deleted after clean_up()";

IPC::Shareable::_end;
warn "Segs After: " . IPC::Shareable::ipcs() . "\n" if $ENV{PRINT_SEGS};

done_testing();


