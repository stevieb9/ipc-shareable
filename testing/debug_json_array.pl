#!/usr/bin/env perl
use warnings;
use strict;
use IPC::Shareable;
use Data::Dumper;

# Patch FETCHSIZE to trace the failure
{
    no warnings "redefine";
    *IPC::Shareable::FETCHSIZE = sub {
        my $knot = shift;
        $knot->{_data} = $knot->_decode($knot->seg) unless ($knot->{_lock});
        if (!defined $knot->{_data}) {
            my $id  = $knot->seg->id;
            my $key = $knot->seg->key;
            printf "FETCHSIZE: _data UNDEF, seg id=%s key=%s\n", $id//"undef", $key//"undef";
            my $buf = "";
            my $ok = shmread($id, $buf, 0, 65536);
            printf "  direct shmread: ok=%s errno='%s' first40='%s'\n",
                $ok // "undef", $!, substr($buf, 0, 40);
        }
        return scalar(@{$knot->{_data} // []});
    };
}

tie my %j_hash, 'IPC::Shareable', {
    create => 1, destroy => 1, serializer => 'json'
};

$j_hash{c} = [qw(1 2 3)];

# Check what the tied data looks like internally right after storing
my $parent_knot = tied(%j_hash);
my $child_ref   = $parent_knot->{_data}{c};

if (my $inner = IPC::Shareable::_is_child($child_ref)) {
    printf "Child seg id at STORE time: %s  key=%s\n",
        $inner->seg->id, $inner->seg->key;
    printf "Child _data at STORE time: %s\n", Dumper($inner->{_data});
} else {
    print "No child found after store - child_ref=$child_ref\n";
}

print "\nFetching \$j_hash{c}...\n";
my $fetched = $j_hash{c};
printf "fetched ref type: %s\n", ref($fetched) // "undef";

if (my $inner = IPC::Shareable::_is_child($fetched)) {
    printf "Child seg id at FETCH time: %s  key=%s\n",
        $inner->seg->id, $inner->seg->key;
    printf "Child _data at FETCH time: %s\n", Dumper($inner->{_data});
}

print "\nCalling scalar(\@{\$fetched})...\n";
my $size = scalar(@$fetched);
printf "size = %d\n", $size;
