#!/usr/bin/perl

use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use IPC::SysV qw(IPC_CREAT IPC_RMID);
use JSON qw(decode_json);

# -----------------------------------------------------------------------
# Section 1: Raw segments written directly via shmget/shmwrite
# -----------------------------------------------------------------------

my @raw_keys = (0x1EAD0001, 0x1EAD0002, 0x1EAD0003);
my @raw_ids;

for my $key (@raw_keys) {
    my $hex = sprintf '0x%08x', $key;
    my $id  = shmget($key, 1024, IPC_CREAT | 0666) or die "shmget($hex): $!";
    shmwrite($id, "Value for key: $hex", 0, 1024)  or die "shmwrite: $!";
    push @raw_ids, $id;
}

# -----------------------------------------------------------------------
# Section 2: IPC::Shareable segments - Storable (default) serializer
# -----------------------------------------------------------------------

tie my $storable_scalar, 'IPC::Shareable', { key => '0x1EAD0010', create => 1, destroy => 0 };
$storable_scalar = 'Value for key: 0x1ead0010';

tie my %storable_hash, 'IPC::Shareable', { key => '0x1EAD0020', create => 1, destroy => 0 };
$storable_hash{msg} = 'Value for key: 0x1ead0020';

# -----------------------------------------------------------------------
# Section 3: IPC::Shareable segments - JSON serializer
# -----------------------------------------------------------------------

tie my %json_hash1, 'IPC::Shareable', { key => '0x1EAD0030', create => 1, destroy => 0, serializer => 'json' };
$json_hash1{msg} = 'Value for key: 0x1ead0030';

tie my %json_hash2, 'IPC::Shareable', { key => '0x1EAD0040', create => 1, destroy => 0, serializer => 'json' };
$json_hash2{msg} = 'Value for key: 0x1ead0040';

tie my %json_nested, 'IPC::Shareable', { key => '0x1EAD0050', create => 1, destroy => 0, serializer => 'json' };
$json_nested{name}    = 'ipc-shareable';
$json_nested{version} = '1.14';
$json_nested{authors} = ['Steve Bertrand'];
$json_nested{meta}    = {
    platform => $^O,
    features => {
        serializers => ['storable', 'json'],
        locking     => 1,
    },
};

# -----------------------------------------------------------------------
# Dump everything shm_segments() sees
# -----------------------------------------------------------------------

my $segs = IPC::Shareable->shm_segments;

print Dumper($segs);

# -----------------------------------------------------------------------
# Decoded view: strip IPC::Shareable prefix and parse JSON segments
# -----------------------------------------------------------------------

print "--- Decoded JSON segments ---\n";
for my $hex_key (sort keys %$segs) {
    my $raw = $segs->{$hex_key}{content};
    if ($raw =~ /^IPC::Shareable(\{.*)$/s) {
        my $decoded = eval { decode_json($1) };
        if ($decoded) {
            printf "%s (local=%d global=%d) => %s",
                $hex_key,
                $segs->{$hex_key}{local_process},
                $segs->{$hex_key}{orphaned},
                Dumper($decoded);
        }
    }
}

# -----------------------------------------------------------------------
# Clean up
# -----------------------------------------------------------------------

shmctl($_, IPC_RMID, 0) for @raw_ids;

(tied $storable_scalar)->remove;
(tied %storable_hash)->remove;
(tied %json_hash1)->remove;
(tied %json_hash2)->remove;
(tied %json_nested)->remove;
