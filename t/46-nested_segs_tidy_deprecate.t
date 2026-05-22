use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

# Prove that the 'tidy' attribute is now a no-op.
#
# Since STORE calls _remove_child() on the old value before _magic_tie()
# creates the new child, the old child's shm segment and semaphore are already
# removed from the kernel.  _reset_segment() (gated by tidy) runs after
# _remove_child(), finds the same already-removed segment via its lingering
# Perl tie, and attempts a redundant removal that only produces a warning.
#
# tidy=>0 and tidy=>1 should therefore produce identical segment counts
# and identical final data.

my $segs_before = IPC::Shareable::seg_count();
my $sems_before = IPC::Shareable::sem_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my @test_data = (
    [ 1, 2, 3, [ 26, [ 30, 31 ] ] ],
);
my %test_data = (
    a => {
        a => 1, b => 2, c => 3,
        d => { z => 26, y => { yy => 25 } },
    },
);

# Recursively dereference tied IPC::Shareable refs into plain Perl structures.
sub untie_deep {
    my ($val) = @_;
    my $type = Scalar::Util::reftype($val) or return $val;

    if ($type eq 'HASH') {
        my %copy;
        for my $k (keys %$val) {
            $copy{$k} = untie_deep($val->{$k});
        }
        return \%copy;
    }
    elsif ($type eq 'ARRAY') {
        return [ map { untie_deep($_) } @$val ];
    }
    elsif ($type eq 'SCALAR') {
        return \ untie_deep($$val);
    }
    return $val;
}

my (%counts_tidy_off, %counts_tidy_on, %data_off, %data_on);

for my $tidy (0, 1) {
    my $counts = $tidy ? \%counts_tidy_on : \%counts_tidy_off;
    my $data   = $tidy ? \%data_on       : \%data_off;

    # Array
    {
        tie my @a, 'IPC::Shareable', {
            create     => 1,
            destroy    => 1,
            tidy       => $tidy,
            serializer => 'storable',
        };

        my $initial = seg_count();
        $counts->{arr_initial} = $initial;

        $a[0] = [3];
        $counts->{arr_first} = seg_count();

        $a[0] = [1, 2];
        $counts->{arr_overwrite_flat} = seg_count();

        $a[0] = [1, 2, 3];
        $counts->{arr_overwrite_flat2} = seg_count();

        $a[0] = [1, 2, 3, [26, [30, 31]]];
        $counts->{arr_nested} = seg_count();

        # Deep-copy before cleanup destroys the segments
        $data->{arr} = untie_deep([@a]);

        IPC::Shareable->clean_up_all;
    }

    # Hash
    {
        tie my %h, 'IPC::Shareable', {
            create     => 1,
            destroy    => 1,
            tidy       => $tidy,
            serializer => 'storable',
        };

        my $initial = seg_count();
        $counts->{hash_initial} = $initial;

        $h{a} = {a => 1};
        $counts->{hash_first} = seg_count();

        $h{a} = {a => 1, b => 2};
        $counts->{hash_overwrite_flat} = seg_count();

        $h{a} = {a => 1, b => 2, c => 3};
        $counts->{hash_overwrite_flat2} = seg_count();

        $h{a} = {a => 1, b => 2, c => 3, d => {z => 26}};
        $counts->{hash_nested1} = seg_count();

        $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};
        $counts->{hash_nested2} = seg_count();

        $data->{hash} = untie_deep({ %h });

        IPC::Shareable->clean_up_all;
    }
}

# -- Every segment count must be identical regardless of tidy --

subtest 'array segment counts identical' => sub {
    for my $key (sort keys %counts_tidy_off) {
        next unless $key =~ /^arr_/;
        is $counts_tidy_on{$key}, $counts_tidy_off{$key},
            "tidy=0 and tidy=1 match for $key";
    }
};

subtest 'hash segment counts identical' => sub {
    for my $key (sort keys %counts_tidy_off) {
        next unless $key =~ /^hash_/;
        is $counts_tidy_on{$key}, $counts_tidy_off{$key},
            "tidy=0 and tidy=1 match for $key";
    }
};

# -- Final stored data must be identical regardless of tidy --

subtest 'array data identical' => sub {
    is_deeply $data_on{arr}, $data_off{arr},
        'tidy=0 and tidy=1 produce identical array data';
    is_deeply $data_on{arr}, \@test_data,
        '...and matches expected test data';
};

subtest 'hash data identical' => sub {
    is_deeply $data_on{hash}, $data_off{hash},
        'tidy=0 and tidy=1 produce identical hash data';
    is_deeply $data_on{hash}, \%test_data,
        '...and matches expected test data';
};

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::seg_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";
my $sems_after = IPC::Shareable::sem_count();
is $sems_after, $sems_before, "All semaphore sets cleaned up ok";

done_testing;

sub seg_count {
    my $count = `ipcs -m | wc -l`;
    chomp $count;
    $count =~ s/\s+//g;
    return $count;
}
