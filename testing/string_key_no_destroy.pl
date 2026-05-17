use warnings;
use strict;
use feature 'say';

use IPC::Shareable;

my $string_key = 'mykey';

say "--- Step 1: create segment with string key '$string_key' ---";
tie my %h, 'IPC::Shareable', { key => $string_key, create => 1, destroy => 0 };

$h{foo} = 'bar';
$h{count} = 42;

my $seg     = (tied %h)->seg;
my $hex_key = sprintf("0x%08x", $seg->key);
my $seg_id  = $seg->id;

say "String key  : $string_key";
say "Hex key     : $hex_key  (this is what ipcs -m shows)";
say "Segment id  : $seg_id";
say "";

say "--- Step 2: re-attach to the same segment using the hex key ---";
tie my %h2, 'IPC::Shareable', { key => $hex_key, create => 0, destroy => 0 };

say "foo   => $h2{foo}";
say "count => $h2{count}";
say "";

say "Both keys resolve to the same segment: "
    . ( (tied %h)->seg->id == (tied %h2)->seg->id ? "YES" : "NO" );
say "";
say "Segments live: " . IPC::Shareable::shm_count();
say "Clean up with: ipcrm -m $seg_id";
