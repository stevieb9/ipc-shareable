#!/usr/bin/env perl
use warnings;
use strict;

# Benchmark: publishing a whole nested data structure two ways --
#
#   (a) VERBATIM  - pre-serialize it yourself (JSON) and store the string in a
#                   single segment via a scalar tie; decode it yourself on read.
#   (b) FAN-OUT   - a native nested hash tie, which spreads the structure across
#                   one shared-memory segment (plus one semaphore set) per
#                   nested reference.
#
# Reports IPC resource usage and store/read wall-time. Verbatim trades per-key
# shared-update granularity for far fewer IPC resources and lower per-op cost.
#
# Usage: perl benchmarks/verbatim_vs_fanout.pl [count] [width] [depth]
#   count > 0 : run each variant exactly that many times
#   count < 0 : run each variant for that many CPU-seconds (default -3)

use Benchmark qw(cmpthese);
use IPC::Shareable;
use JSON qw(encode_json decode_json);
use Storable qw(dclone);

my $count = $ARGV[0] || -3;
my $width = $ARGV[1] || 12;    # keys per level
my $depth = $ARGV[2] || 2;     # nesting levels

# A nested structure: $width keys at each of $depth levels; leaves are strings.
sub build {
    my ($w, $d) = @_;
    return {
        map { ("k$_" => $d > 1 ? build($w, $d - 1) : "leaf-value-$_") } 1 .. $w
    };
}
my $struct = build($width, $depth);

# Materialize a tied structure into a plain copy -- forces FETCH on every node,
# the realistic "read the whole thing back" cost for the fan-out tie.
sub deep_copy {
    my ($v) = @_;
    my $r = ref $v;
    return { map { ($_ => deep_copy($v->{$_})) } keys %$v } if $r eq 'HASH';
    return [ map { deep_copy($_) } @$v ]                    if $r eq 'ARRAY';
    return $v;
}

my $SIZE = 1 << 20;   # 1 MB, ample for the serialized blob
my $reg  = IPC::Shareable->global_register;

# ---- IPC resource usage (counted once) -----------------------------------

my $before_v = scalar keys %$reg;
tie my $sv, 'IPC::Shareable', { key => 'bench-verbatim', create => 1, destroy => 1, size => $SIZE };
$sv = encode_json($struct);
my $segs_v = (scalar keys %$reg) - $before_v;

my $before_f = scalar keys %$reg;
tie my %hf, 'IPC::Shareable', { key => 'bench-fanout', create => 1, destroy => 1, size => $SIZE };
%hf = %{ dclone($struct) };
my $segs_f = (scalar keys %$reg) - $before_f;

printf "\nStructure: width=%d depth=%d  (%d leaf values, blob %d bytes)\n",
    $width, $depth, $width ** $depth, length(encode_json($struct));
print "IPC resources (each segment also carries one semaphore set):\n";
printf "  verbatim scalar : %4d segment(s)\n", $segs_v;
printf "  native fan-out  : %4d segment(s)\n", $segs_f;
printf "  => %.0fx fewer segments (and semaphore sets) with verbatim\n\n",
    $segs_f / ($segs_v || 1);

# ---- timing --------------------------------------------------------------

print "STORE the whole structure:\n";
cmpthese($count, {
    verbatim => sub { $sv = encode_json($struct); },
    fanout   => sub { %hf = %{ dclone($struct) }; },
});

print "\nREAD back the whole structure:\n";
cmpthese($count, {
    verbatim => sub { my $d = decode_json($sv); },
    fanout   => sub { my $d = deep_copy(\%hf); },
});

print "\nNote: the fan-out tie also supports per-key shared updates and "
    . "sub-structure locking,\nwhich the single verbatim segment does not. "
    . "Choose per use case.\n\n";
