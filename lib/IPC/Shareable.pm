package IPC::Shareable;

use warnings;
use strict;

require 5.00503;

use Carp qw(croak confess carp);
use Config;
use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use IPC::Semaphore;
use IPC::Shareable::SharedMem;
use IPC::SysV qw(
    IPC_PRIVATE
    IPC_CREAT
    IPC_EXCL
    IPC_NOWAIT
    IPC_RMID
    IPC_STAT
    SEM_UNDO
);
use JSON qw(-convert_blessed_universally);
use Scalar::Util;
use String::CRC32;
use Storable 0.6 qw(freeze thaw);

our $VERSION = '1.14_06';

use constant {
    # Locking

    LOCK_SH               => 1,
    LOCK_EX               => 2,
    LOCK_NB               => 4,
    LOCK_UN               => 8,

    # SHM parameters

    SHM_BUFSIZ            => 65536,
    SHMMAX_BYTES          => 1073741824, # 1 GB
    SHM_EXISTS            => 1,

    # Semaphore slots

    SEM_MARKER            => 0,
    SEM_READERS           => 1,
    SEM_WRITERS           => 2,
    SEM_PROTECTED         => 3,

    # Perl sends in a double as opposed to an integer to shmat(), and on some
    # systems, this causes the IPC system to round down to the maximum integer
    # size of 0x80000000 we correct that when generating keys with CRC32

    MAX_KEY_INT_SIZE      => 0x80000000,

    # Number of times we'll check for existing segs

    EXCLUSIVE_CHECK_LIMIT => 10,

    # Struct types

    TYPE_HASH             => 0,
    TYPE_ARRAY            => 1,
    TYPE_SCALAR           => 2,
};

require Exporter;
our @ISA = 'Exporter';
our @EXPORT_OK = qw(LOCK_EX LOCK_SH LOCK_NB LOCK_UN SEM_MARKER SEM_READERS SEM_WRITERS SEM_PROTECTED);
our %EXPORT_TAGS = (
    all     => [qw( LOCK_EX LOCK_SH LOCK_NB LOCK_UN )],
    lock    => [qw( LOCK_EX LOCK_SH LOCK_NB LOCK_UN )],
    flock   => [qw( LOCK_EX LOCK_SH LOCK_NB LOCK_UN )],
);
Exporter::export_ok_tags('all', 'lock', 'flock');

# Locking scheme copied from IPC::ShareLite

my %semop_args = (
    (LOCK_EX),
    [
        SEM_READERS, 0, 0,                        # Wait for readers to finish
        SEM_WRITERS, 0, 0,                        # Wait for writers to finish
        SEM_WRITERS, 1, SEM_UNDO,                 # Assert write lock
    ],
    (LOCK_EX|LOCK_NB),
    [
        SEM_READERS, 0, IPC_NOWAIT,               # Wait for readers to finish
        SEM_WRITERS, 0, IPC_NOWAIT,               # Wait for writers to finish
        SEM_WRITERS, 1, (SEM_UNDO | IPC_NOWAIT),  # Assert write lock
    ],
    (LOCK_EX|LOCK_UN),
    [
        SEM_WRITERS, -1, (SEM_UNDO | IPC_NOWAIT),
    ],
    (LOCK_SH),
    [
        SEM_WRITERS, 0, 0,                        # Wait for writers to finish
        SEM_READERS, 1, SEM_UNDO,                 # Assert shared read lock
    ],
    (LOCK_SH|LOCK_NB),
    [
        SEM_WRITERS, 0, IPC_NOWAIT,               # Wait for writers to finish
        SEM_READERS, 1, (SEM_UNDO | IPC_NOWAIT),  # Assert shared read lock
    ],
    (LOCK_SH|LOCK_UN),
    [
        SEM_READERS, -1, (SEM_UNDO | IPC_NOWAIT), # Remove shared read lock
    ],
);

my %default_options = (
    key                => IPC_PRIVATE,
    create             => 0,
    exclusive          => 0,
    destroy            => 0,
    mode               => 0666,
    size               => SHM_BUFSIZ,
    protected          => 0,
    limit              => 1,
    graceful           => 0,
    warn               => 0,
    tidy               => 1,
    serializer         => 'json',
    enforced_locking   => 1,
    violated_lock_warn => 0,
);

# Seed the random number generator

srand();

my %global_register;
my %process_register;
my %used_ids;

sub _trace;
sub _debug;

# --- "Magic" methods
sub TIESCALAR {
    return _tie('SCALAR', @_);
}
sub TIEARRAY {
    return _tie('ARRAY', @_);
}
sub TIEHASH {
    return _tie('HASH', @_);
}
sub STORE {
    my $knot = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg) unless ($knot->{_lock});

    if ($knot->{_type_int} == TYPE_HASH) {
        my ($key, $val) = @_;
        # If $val is a reference, we need to create a new segment
        _magic_tie($knot, $val, $key) if ref($val) && $knot->_need_tie($val, $key);
        $knot->{_data}{$key} = $val;
    }
    elsif ($knot->{_type_int} == TYPE_ARRAY) {
        my ($i, $val) = @_;
        _magic_tie($knot, $val, $i) if ref($val) && $knot->_need_tie($val, $i);
        $knot->{_data}[$i] = $val;
    }
    elsif ($knot->{_type_int} == TYPE_SCALAR) {
        my ($val) = @_;
        _magic_tie($knot, $val) if ref($val) && $knot->_need_tie($val);
        $knot->{_data} = \$val;
    }

    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!\n";
        }
    }

    return 1;
}
sub FETCH {
    my $knot = shift;

    my $data;
    if ($knot->{_lock}) {
        $data = $knot->{_data};
    }
    else {
        $data = $knot->_decode($knot->seg);
        $knot->{_data} = $data;
    }

    my $val;

    if ($knot->{_type_int} == TYPE_HASH) {
        my $key = shift;
        $val = $data->{$key};
    }
    elsif ($knot->{_type_int} == TYPE_ARRAY) {
        my $i = shift;
        $val = $data->[$i];
    }
    elsif ($knot->{_type_int} == TYPE_SCALAR) {
        if (defined $data) {
            $val = $$data;
        }
        else {
            return;
        }
    }

    if (ref($val) && (my $inner = _is_child($val))) {
        # Register the inner knot so clean_up_all() can find it even when it
        # was created in a forked child process

        if (! exists $global_register{$inner->seg->id}) {
            $global_register{$inner->seg->id} = $inner;
        }

        my $s = $inner->seg;
        $inner->{_data} = $knot->_decode($s);
    }
    return $val;

}
sub CLEAR {
    my $knot = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg) unless $knot->{_lock};

    if ($knot->{_type_int} == TYPE_HASH) {
        # Remove any child segments before discarding the data
        for my $val (values %{ $knot->{_data} }) {
            if (ref($val) && (my $child = _is_child($val))) {
                $child->remove;
            }
        }
        $knot->{_data} = { };
    }
    elsif ($knot->{_type_int} == TYPE_ARRAY) {
        # Remove any child segments before discarding the data
        for my $val (@{ $knot->{_data} }) {
            if (ref($val) && (my $child = _is_child($val))) {
                $child->remove;
            }
        }
        $knot->{_data} = [ ];
    }

    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
}
sub DELETE {
    my $knot = shift;
    my $key  = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg) unless $knot->{_lock};
    my $val = delete $knot->{_data}->{$key};

    # Remove the child segment if the deleted value was a nested tied ref

    if (ref($val) && (my $child = _is_child($val))) {
        $child->remove;
    }

    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }

    return $val;
}
sub EXISTS {
    my $knot = shift;
    my $key  = shift;

    $knot->{_data} = $knot->_decode($knot->seg) unless $knot->{_lock};
    return exists $knot->{_data}->{$key};
}
sub FIRSTKEY {
    my $knot = shift;

    $knot->{_data} = $knot->_decode($knot->seg) unless $knot->{_lock};

    $knot->{_hkey_list} = [ keys %{$knot->{_data}} ];

    return $knot->NEXTKEY;
}
sub NEXTKEY {
    my ($knot, $last_key_accessed) = @_;

    # We don't use ordered hashes, so we don't need to use
    # the last key accessed parameter

    # Caveat emptor if hash was changed by another process

    return shift @{$knot->{_hkey_list}};
}
sub EXTEND {
    #XXX Noop
}
sub PUSH {
    my $knot = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg, $knot->{_data}) unless $knot->{_lock};

    push @{$knot->{_data}}, @_;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        };
    }
}
sub POP {
    my $knot = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg, $knot->{_data}) unless $knot->{_lock};

    my $val = pop @{$knot->{_data}};
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $val;
}
sub SHIFT {
    my $knot = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg, $knot->{_data}) unless $knot->{_lock};
    my $val = shift @{$knot->{_data}};
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $val;
}
sub UNSHIFT {
    my $knot = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg, $knot->{_data}) unless $knot->{_lock};
    my $val = unshift @{$knot->{_data}}, @_;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $val;
}
sub SPLICE {
    my($knot, $off, $n, @av) = @_;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg, $knot->{_data}) unless $knot->{_lock};
    my @val = splice @{$knot->{_data}}, $off, $n, @av;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return @val;
}
sub FETCHSIZE {
    my $knot = shift;

    $knot->{_data} = $knot->_decode($knot->seg) unless $knot->{_lock};
    return scalar(@{$knot->{_data}});
}
sub STORESIZE {
    my $knot = shift;
    my $n    = shift;

    return if ! _write_permitted($knot);

    $knot->{_data} = $knot->_decode($knot->seg) unless $knot->{_lock};
    $#{$knot->{_data}} = $n - 1;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    }
    else {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $n;
}

# --- Public methods

sub new {
    my ($class, %opts) = @_;

    my $type = $opts{var} || 'HASH';

    if ($type eq 'HASH') {
        my $k = tie my %h, 'IPC::Shareable', \%opts;
        return \%h;
    }
    if ($type eq 'ARRAY') {
        my $k = tie my @a, 'IPC::Shareable', \%opts;
        return \@a;
    }
    if ($type eq 'SCALAR') {
        my $k = tie my $s, 'IPC::Shareable', \%opts;
        return \$s;
    }
}
sub global_register {
    return \%global_register;
}
sub process_register {
    return \%process_register;
}

sub attributes {
    my ($knot, $attr) = @_;

    if (defined $attr) {
        return $knot->{attributes}{$attr};
    }
    else {
        return $knot->{attributes};
    }
}
sub shm_count {
    my $count = 0;

    for my $line (`ipcs -m`) {
        # BSD/macOS format: m <shmid> <key> ...
        # Linux format:     <key> <shmid> ...
        $count++ if $line =~ /^\s*m\s+\d+\s+\S+/;
        $count++ if $line =~ /^\s*(?:0x[0-9a-fA-F]+|\d+)\s+\d+\s+\S+/;
    }

    return $count;
}
sub sem_count {
    my $count = 0;

    for my $line (`ipcs -s`) {
        # BSD/macOS format: s <semid> <key> ...
        # Linux format:     <key> <semid> ...
        $count++ if $line =~ /^\s*s\s+\d+\s+\S+/;
        $count++ if $line =~ /^\s*(?:0x[0-9a-fA-F]+|\d+)\s+\d+\s+\S+/;
    }

    return $count;
}
sub shm_segments {
    shift if ref($_[0]) || (defined $_[0] && !ref($_[0]) && UNIVERSAL::isa($_[0], __PACKAGE__));

    my ($filter_key) = @_;

    my $filter_int = _key_str_to_int($filter_key) if defined $filter_key;

    my %segments;

    for my $line (`ipcs -m`) {
        my ($id, $raw_key);

        # BSD/macOS format: m <shmid> <key> ...
        if ($line =~ /^\s*m\s+(\d+)\s+(\S+)/) {
            ($id, $raw_key) = ($1, $2);
        }
        # Linux format: <key> <shmid> ...
        elsif ($line =~ /^\s*(\S+)\s+(\d+)\s+\S+/) {
            ($raw_key, $id) = ($1, $2);
        }
        else {
            next;
        }

        my $key_int = $raw_key =~ /^0x[0-9a-fA-F]+$/
            ? hex($raw_key)
            : $raw_key =~ /^\d+$/
                ? int($raw_key)
                : next;

        my $hex_key = sprintf('0x%08x', $key_int);

        next if $key_int == 0;  # IPC_PRIVATE segments can't be found by key

        # Get segment size via IPC_STAT
        my $stat_buf = '';
        shmctl($id, IPC_STAT, $stat_buf) or next;

        my ($segsz) = $^O eq 'linux'
            ? ( $Config{longsize} == 8
                    ? unpack('x[48] Q', $stat_buf)   # 64-bit Linux
                    : unpack('x[36] L', $stat_buf) ) # 32-bit Linux
            : ( $^O eq 'freebsd' && $Config{longsize} == 8
                    ? unpack('x[32] Q', $stat_buf)   # 64-bit FreeBSD (key_t=long=8, ipc_perm=32)
                    : unpack('x[24] Q', $stat_buf) );# macOS/32-bit BSD

        next unless $segsz;

        my $data = '';
        shmread($id, $data, 0, $segsz) or next;

        # Strip trailing null bytes
        $data =~ s/\x00+$//;

        # Skip segments not owned by IPC::Shareable (all our segments
        # are prefixed with the literal string 'IPC::Shareable')
        next unless substr($data, 0, 14) eq 'IPC::Shareable';

        my $json_part  = substr($data, 14);
        my @child_keys = ($json_part =~ /"child_key_hex":"([^"]+)"/g);

        $segments{$hex_key} = {
            child_keys    => \@child_keys,
            content       => $data,
            local_process => (exists $process_register{$id} ? 1 : 0),
            known         => (exists $global_register{$id}  ? 1 : 0),
        };
    }

    if (defined $filter_int) {
        # Walk the segment tree starting from the root whose key matches
        # $filter_int, collecting it and all its descendants.  Use integer
        # comparison so that hex formatting differences (zero-padding, case)
        # between ipcs(1) output and child_key_hex values don't matter.
        my %int_to_hex = map { hex($_) => $_ } keys %segments;
        my (%related, @queue);
        push @queue, $filter_int;
        while (my $k_int = shift @queue) {
            my $k_hex = $int_to_hex{$k_int} // next;
            next if $related{$k_hex}++;
            push @queue, map { hex($_) } @{ $segments{$k_hex}{child_keys} };
        }
        %segments = map { $_ => $segments{$_} } keys %related;
    }

    return \%segments;
}
sub unknown_segments {
    shift if ref $_[0]; # Allow for object or class method call

    my $segs = shm_segments();

    return grep { !$segs->{$_}{known} } keys %$segs;
}
sub _seg_data_summary {
    my ($knot) = @_;

    my $data  = $knot->{_data};
    my $rtype = Scalar::Util::reftype($data) // '';

    if ($rtype eq 'SCALAR') {
        my $v = $$data;
        return defined $v ? qq("$v") : '(undef)';
    }

    if ($rtype eq 'HASH') {
        my @parts;
        for my $k (sort keys %$data) {
            my $v = $data->{$k};
            if (ref $v) {
                my $vt    = Scalar::Util::reftype($v) // '';
                my $child = $vt eq 'HASH'   ? tied(%$v)
                          : $vt eq 'ARRAY'  ? tied(@$v)
                          : $vt eq 'SCALAR' ? tied($$v)
                          : undef;
                push @parts, $child && $child->{_key_hex}
                    ? qq($k => <child: $child->{_key_hex}>)
                    : "$k => <ref>";
            }
            else {
                push @parts, defined $v ? qq($k => "$v") : "$k => (undef)";
            }
        }
        return @parts ? '{ ' . join(', ', @parts) . ' }' : '{}';
    }

    if ($rtype eq 'ARRAY') {
        my @parts;
        for my $v (@$data) {
            if (ref $v) {
                my $vt    = Scalar::Util::reftype($v) // '';
                my $child = $vt eq 'HASH'   ? tied(%$v)
                          : $vt eq 'ARRAY'  ? tied(@$v)
                          : $vt eq 'SCALAR' ? tied($$v)
                          : undef;
                push @parts, $child && $child->{_key_hex}
                    ? "<child: $child->{_key_hex}>"
                    : '<ref>';
            }
            else {
                push @parts, defined $v ? qq("$v") : '(undef)';
            }
        }
        return '[' . join(', ', @parts) . ']';
    }

    return '(unknown type)';
}
sub seg_map {
    croak "seg_map() must be called as an object method" unless ref $_[0];
    my $knot_filter = shift;

    my $segs = shm_segments();

    # Build hex_key -> OS segment ID from ipcs output
    my %id_by_hex;
    for my $line (`ipcs -m`) {
        my ($id, $raw_key);
        if    ($line =~ /^\s*m\s+(\d+)\s+(\S+)/)    { ($id, $raw_key) = ($1, $2) }
        elsif ($line =~ /^\s*(\S+)\s+(\d+)\s+\S+/)  { ($raw_key, $id) = ($1, $2) }
        else  { next }

        my $key_int = $raw_key =~ /^0x[0-9a-fA-F]+$/ ? hex($raw_key)
                    : $raw_key =~ /^\d+$/             ? int($raw_key)
                    : next;
        $id_by_hex{ sprintf('0x%08x', $key_int) } = $id;
    }

    # Build hex_key -> knot from global_register (keyed by seg_id)
    my %knot_by_hex;
    for my $id (keys %global_register) {
        my $knot = $global_register{$id};
        my $hex  = $knot->{_key_hex};
        $knot_by_hex{$hex} = $knot if defined $hex;
    }

    # Supplement child_keys from global_register for Storable segments.
    # shm_segments() only extracts child_key_hex from JSON segment content;
    # for Storable we walk each knot's _data looking for tied child references.
    my %extra_child_keys;   # hex_key -> [ child_hex, ... ]
    for my $hex (keys %knot_by_hex) {
        my $knot  = $knot_by_hex{$hex};
        my $data  = $knot->{_data};
        my $rtype = Scalar::Util::reftype($data) // '';

        my @vals = $rtype eq 'HASH'  ? values %$data
                 : $rtype eq 'ARRAY' ? @$data
                 : ();

        for my $v (@vals) {
            next unless ref($v);
            my $vtype = Scalar::Util::reftype($v) // '';
            my $child_knot;
            if    ($vtype eq 'HASH')   { $child_knot = tied(%$v) }
            elsif ($vtype eq 'ARRAY')  { $child_knot = tied(@$v) }
            elsif ($vtype eq 'SCALAR') { $child_knot = tied($$v) }
            next unless $child_knot && $child_knot->{_key_hex};
            push @{ $extra_child_keys{$hex} }, $child_knot->{_key_hex};
        }
    }

    # If called as an object method, restrict output to just that knot's tree
    # by BFS through both child_keys (JSON) and extra_child_keys (Storable).
    if ($knot_filter && $knot_filter->{_key_hex}) {
        my $root_hex = $knot_filter->{_key_hex};
        my (%in_tree, @queue);
        push @queue, $root_hex;
        while (my $h = shift @queue) {
            next if $in_tree{$h}++;
            push @queue, @{ $segs->{$h}{child_keys}   // [] };
            push @queue, @{ $extra_child_keys{$h}     // [] };
        }
        %$segs = map { $_ => $segs->{$_} } grep { $in_tree{$_} } keys %$segs;
    }

    # Identify root segments (not a child of any other segment)
    my %is_child;
    for my $hex (keys %$segs) {
        $is_child{$_}++ for @{ $segs->{$hex}{child_keys} };
    }
    for my $hex (keys %extra_child_keys) {
        next unless exists $segs->{$hex};
        $is_child{$_}++ for @{ $extra_child_keys{$hex} };
    }
    my @roots = sort grep { !$is_child{$_} } keys %$segs;

    my @lines;
    push @lines, 'IPC::Shareable Segment Map';
    push @lines, '=' x 26;

    if (!@roots) {
        push @lines, '';
        push @lines, '  (no IPC::Shareable segments found)';
        return join("\n", @lines) . "\n";
    }

    my $render;
    $render = sub {
        my ($hex, $depth) = @_;
        my $indent = '  ' x $depth;
        my $seg    = $segs->{$hex} // {};

        my @tags;
        push @tags, $seg->{known} ? 'known' : 'unknown';
        push @tags, 'owner' if $seg->{local_process};
        my $tag_str = '[' . join(', ', @tags) . ']';

        my $seg_id = $id_by_hex{$hex} // '?';

        # Read semaphore slot values and ID; for segments not in
        # global_register attach with nsems=0 (avoids EINVAL on existing sets)
        my ($sem_str, $content_str);
        my $sem = $knot_by_hex{$hex}
            ? $knot_by_hex{$hex}->sem
            : IPC::Semaphore->new(hex($hex), 0, 0);

        if (defined $sem) {
            my $sem_id    = $sem->id                    // '?';
            my $marker    = $sem->getval(SEM_MARKER)    // '?';
            my $readers   = $sem->getval(SEM_READERS)   // '?';
            my $writers   = $sem->getval(SEM_WRITERS)   // '?';
            my $protected = $sem->getval(SEM_PROTECTED) // '?';
            # Continuation indent: one tab (8 spaces) from the left margin
            my $cont = ' ' x 8;
            $sem_str = join("\n",
                "sem_id: $sem_id",
                "${cont}1: SEM_MARKER=$marker",
                "${cont}2: READERS=$readers",
                "${cont}3: WRITERS=$writers",
                "${cont}4: PROTECTED=$protected",
            );
        }
        else {
            $sem_str = '(not accessible)';
        }

        $content_str = $knot_by_hex{$hex}
            ? _seg_data_summary($knot_by_hex{$hex})
            : '(not accessible - segment not tied in this process)';

        # Merge child keys from shm_segments() and from global_register walk
        my %seen_child;
        my @child_keys = grep { !$seen_child{$_}++ } (
            @{ $seg->{child_keys} // [] },
            @{ $extra_child_keys{$hex} // [] },
        );
        my $children = @child_keys ? join(', ', @child_keys) : '(none)';

        push @lines, '';
        push @lines, "${indent}${tag_str}  key: ${hex}  seg_id: ${seg_id}";
        push @lines, "${indent}  Semaphores: ${sem_str}";
        push @lines, "${indent}  Children:   ${children}";
        push @lines, "${indent}  Content:    ${content_str}";

        $render->($_, $depth + 1) for @child_keys;
    };

    $render->($_, 0) for @roots;

    push @lines, '';
    return join("\n", @lines) . "\n";
}
sub sysv_info {
    shift; # Discard invocant (object ref or class name)
    my %opts     = @_;
    my $proc_dir = delete $opts{_proc_dir} // '/proc/sys/kernel';

    my %info;

    if ($^O eq 'darwin') {
        my $out = `sysctl kern.sysv 2>/dev/null`;
        for my $line (split /\n/, $out) {
            if ($line =~ /^kern\.sysv\.(\w+):\s*(\S+)/) {
                $info{$1} = $2;
            }
        }
    }
    elsif ($^O eq 'linux') {
        for my $key (qw(shmmax shmmin shmmni shmall)) {
            my $file = "$proc_dir/$key";
            if (open my $fh, '<', $file) {
                chomp(my $val = <$fh>);
                $info{$key} = $val;
            }
        }
    }

    return %info ? \%info : undef;
}
sub lock {
    my $knot = shift;

    my ($flags, $code);

    if (scalar @_ == 2) {
        ($flags, $code) = @_;
    }

    if (defined $_[0]) {
        if (ref $_[0] eq 'CODE') {
            $code = shift;
        }
        else {
            $flags = shift;
        }
    }

    if (defined $code && ref $code ne 'CODE') {
        croak "\$code param to lock() must be a code ref"
    }

    $flags = LOCK_EX if ! defined $flags;

    return $knot->unlock if ($flags & LOCK_UN);

    return 1 if ($knot->{_lock} & $flags);

    # If they have a different lock than they want, release it first

    $knot->unlock if ($knot->{_lock});

    my $sem = $knot->sem;
    my $lock_success = $sem->op(@{ $semop_args{$flags} });

    if ($lock_success) {
        $knot->{_lock} = $flags;
        $knot->{_data} = $knot->_decode($knot->seg);
    }

    if ($flags == LOCK_EX && $lock_success) {
        if ($code) {
            my $ok = eval { $code->(); 1 };
            my $err = $@;
            $knot->unlock;
            die $err if ! $ok;
            return 1;
        }
    }
    return $lock_success;
}
sub unlock {
    my $knot = shift;

    return 1 unless $knot->{_lock};

    if ($knot->{_was_changed}) {
        if (! defined $knot->_encode($knot->seg, $knot->{_data})){
            croak "Could not write to shared memory: $!\n";
        }
        $knot->{_was_changed} = 0;
    }

    my $sem = $knot->sem;
    my $flags = $knot->{_lock} | LOCK_UN;

    $flags ^= LOCK_NB if ($flags & LOCK_NB);

    if (! $sem->op(@{ $semop_args{$flags} })) {
        croak "Could not release semaphore lock: $!\n";
    }

    $knot->{_lock} = 0;

    1;
}
*shlock = \&lock;
*shunlock = \&unlock;

sub clean_up {
    my $class = shift;

    for my $id (keys %process_register) {
        my $s = $process_register{$id};
        next unless $s->attributes('owner') == $$;
        next if $s->attributes('protected');
        remove($s);
    }
}
sub clean_up_all {
    my $class = shift;

    my $global_register = __PACKAGE__->global_register;

    for my $id (keys %$global_register) {
        my $s = $global_register->{$id};
        next if $s->attributes('protected');
        remove($s);
    }
}
sub clean_up_protected {
    my ($knot, $protect_key);

    if (scalar @_ == 2) {
        ($knot, $protect_key) = @_;
    }
    if (scalar @_ == 1) {
        ($protect_key) = @_;
    }

    if (! defined $protect_key) {
        croak "clean_up_protected() requires a \$protect_key param";
    }

    if ($protect_key !~ /^\d+$/) {
        croak
            "clean_up_protected() \$protect_key must be an integer. You sent $protect_key";
    }

    my $global_register = __PACKAGE__->global_register;

    for my $id (keys %$global_register) {
        my $s = $global_register->{$id};
        my $stored_key = $s->attributes('protected');

        if ($stored_key && $stored_key == $protect_key) {
            remove($s);
        }
    }
}
sub remove {
    my ($knot, $key) = @_;

    # If a key is passed, remove that specific segment by key rather than
    # via an existing tied object

    if (defined $key) {
        $key = $knot->_shm_key($key);
        my $id = shmget($key, 0, 0);

        if (! defined $id) {
            warn "remove(): shmget failed for key $key: $!";
            return;
        }

        if (! shmctl($id, IPC_RMID, 0)) {
            warn "Couldn't remove shm segment $id: $!";
        }
        else {
            delete $process_register{$id};
            delete $global_register{$id};
        }

        # Remove the associated semaphore set (same key, attach-only with nsems=0)

        my $sem = IPC::Semaphore->new($key, 0, 0);
        if (defined $sem) {
            $sem->remove or warn "Couldn't remove semaphore set for key $key: $!";
        }

        return;
    }

    # Standard object based removal

    my $seg = $knot->seg;
    my $id = $seg->id;

    my $seg_removed = 0;

    if (! $seg->remove) {
        warn "Couldn't remove shm segment $id: $!";
    }
    else {
        $seg_removed = 1;
    }

    # Semaphore cleanup

    my $sem = $knot->sem;

    my $sem_removed = 0;
    my $sem_remove_status = $sem->remove;

    if ($sem_remove_status != 1 && $sem_remove_status ne '0 but true') {
        warn "Couldn't remove semaphore set $id: $!";
    }
    else {
        $sem_removed = 1;
    }

    # If the segment or semaphore couldn't be cleaned up, we need to
    # keep state

    if ($seg_removed && $sem_removed) {
        delete $process_register{$id};
        delete $global_register{$id};
    }
}
sub seg {
    my ($knot) = @_;
    return $knot->{_shm} if defined $knot->{_shm};
}
sub sem {
    my ($knot) = @_;
    return $knot->{_sem} if defined $knot->{_sem};
}
sub singleton {

    # If called with IPC::Shareable::singleton() as opposed to
    # IPC::Shareable->singleton(), the class isn't sent in. Check
    # for this and fix it if necessary

    if (! defined $_[0] || $_[0] ne __PACKAGE__) {
        unshift @_, __PACKAGE__;
    }

    my ($class, $glue, $warn) = @_;

    if (! defined $glue) {
        croak "singleton() requires a GLUE parameter";
    }

    $warn = 0 if ! defined $warn;

    tie my $lock, 'IPC::Shareable', {
        key         => $glue,
        create      => 1,
        exclusive   => 1,
        graceful    => 1,
        destroy     => 1,
        warn        => $warn
    };

    return $$;
}
sub uuid {
    my ($knot) = @_;

    if (! defined $knot->{_uuid}) {
        $knot->{_uuid} = md5_hex(rand());
    }

    return $knot->{_uuid};
}
END {
    _end();
}

# --- Private methods below

sub _write_permitted {
    my ($knot) = @_;

    return 1 unless $knot->attributes('enforced_locking');

    # If this knot itself holds LOCK_EX it is the owner of the lock and is
    # permitted to write.

    return 1 if $knot->{_lock} & LOCK_EX;

    my $sem = $knot->sem;

    # Semaphore index 2 is the write-lock counter; it is 1 when any other knot
    # holds LOCK_EX (set via SEM_UNDO so it auto-releases on process exit).

    # Block if any process holds LOCK_EX

    if ($sem->getval(SEM_WRITERS) > 0) {
        if ($knot->attributes('violated_lock_warn')) {
            my $uuid   = $knot->uuid;
            my $seg_id = $knot->seg->id;
            warn "Object with UUID $uuid attempted write to segment ID "
                . "$seg_id which is exclusively locked (enforced locking enabled)";
        }

        return 0;
    }

    # Block if any process holds LOCK_SH (active readers present)

    if ($sem->getval(SEM_READERS) > 0) {
        if ($knot->attributes('violated_lock_warn')) {
            my $uuid   = $knot->uuid;
            my $seg_id = $knot->seg->id;
            warn "Object with UUID $uuid attempted write to segment ID "
                . "$seg_id which has active readers (enforced locking enabled)";
        }

        return 0;
    }

    return 1;
}

# Encoding/Decoding

sub _encode {
    my ($knot, $seg, $data) = @_;

    my $serializer = $knot->attributes('serializer');

    if ($serializer eq 'storable') {
        return _freeze($seg, $data);
    }

    return _encode_json($seg, $data);
}
sub _decode {
    my ($knot, $seg) = @_;

    my $serializer = $knot->attributes('serializer');

    my $data = $serializer eq 'storable'
        ? _thaw($seg)
        : _decode_json($seg, $knot);

    return $data if defined $data;

    # Empty/never-written segment — return appropriate empty default so that
    # aggregate tie methods (FETCHSIZE, PUSH, CLEAR, etc.) can deref safely.
    return [] if $knot->{_type_int} == TYPE_ARRAY;
    return {} if $knot->{_type_int} == TYPE_HASH;
    return undef;
}
sub _encode_json {
    my $seg  = shift;
    my $data = shift;

    my $json = encode_json _encode_json_prepare($data);

    substr $json, 0, 0, 'IPC::Shareable';

    if (length($json) > $seg->size) {
        croak "Length of shared data exceeds shared segment size";
    }

    $seg->shmwrite($json);
}
sub _encode_json_prepare {
    my ($data) = @_;

    my $type = Scalar::Util::reftype($data) or return $data;

    # Replace direct IPC::Shareable child segments with __ics__ markers.
    # All nested refs are tied children — no recursion needed; each child
    # segment encodes its own children independently. We have to do this because
    # JSON can't store blessed objects

    if ($type eq 'HASH') {
        my %result;
        for my $key (keys %$data) {
            my $val   = $data->{$key};
            my $inner = ref($val) && _is_child($val);
            $result{$key} = $inner
                ? { '__ics__' => { type => $inner->{_type}, child_key => $inner->{_key}, child_key_hex => sprintf('0x%08x', $inner->{_key}) } }
                : $val;
        }
        return \%result;
    }

    if ($type eq 'ARRAY') {
        return [
            map {
                my $inner = ref($_) && _is_child($_);
                $inner
                    ? { '__ics__' => { type => $inner->{_type}, child_key => $inner->{_key}, child_key_hex => sprintf('0x%08x', $inner->{_key}) } }
                    : $_
            } @$data
        ];
    }

    if ($type eq 'SCALAR' || $type eq 'REF') {
        my $val   = $$data;
        my $inner = ref($val) && _is_child($val);
        return $inner
            ? { '__ics__' => { type => $inner->{_type}, child_key => $inner->{_key}, child_key_hex => sprintf('0x%08x', $inner->{_key}) } }
            : { '__sv__' => $val };
    }

    return $data;
}
sub _decode_json {
    my ($seg, $knot) = @_;

    my $json = $seg->data;

    return if ! $json;

    # The return of shmread() is the actual size of the defined size of the
    # shared memory segment. Even if the return equates to an empty string
    # (which it will if it contains no data), there will always be a length().
    # Therefore, we must see if we've tagged this data as a valid structure,
    # or else decode will fail

    my $tag = substr $json, 0, 14, '';

    if ($tag eq 'IPC::Shareable') {
        my $data = decode_json $json;

        if (! defined($data)){
            croak "Munged shared memory segment (size exceeded?)";
        }

        _decode_json_restore($data, $knot) if defined $knot && index($json, '"__ics__"') >= 0;

        # Unwrap scalar-tie values encoded as { '__sv__' => val } or { '__ics__' => {...} }
        if (defined $knot && $knot->{_type_int} == TYPE_SCALAR && ref($data) eq 'HASH') {
            if (exists $data->{'__ics__'}) {
                my $prev     = $knot->{_data};
                my $prev_val = (defined $prev && ref($prev)) ? $$prev : undef;
                my $resolved = _decode_json_resolve($data->{'__ics__'}, $prev_val, $knot);
                return \$resolved;
            }
            if (exists $data->{'__sv__'}) {
                my $val = $data->{'__sv__'};
                return \$val;
            }
        }

        return $data;
    } else {
        return;
    }
}
sub _decode_json_restore {
    my ($data, $knot) = @_;

    my $type = Scalar::Util::reftype($data) or return;

    # Reuse existing tied child refs from previous decode where possible.
    # This avoids a shmget+semget system call pair for each child on every
    # decode cycle — only the first attach per segment incurs that cost.

    my $prev = $knot->{_data};

    if ($type eq 'HASH') {
        for my $key (keys %$data) {
            next unless ref($data->{$key}) eq 'HASH' && exists $data->{$key}{'__ics__'};
            $data->{$key} = _decode_json_resolve(
                $data->{$key}{'__ics__'},
                ref($prev) eq 'HASH' ? $prev->{$key} : undef,
                $knot,
            );
        }
    }
    elsif ($type eq 'ARRAY') {
        for my $i (0 .. $#$data) {
            next unless ref($data->[$i]) eq 'HASH' && exists $data->[$i]{'__ics__'};
            $data->[$i] = _decode_json_resolve(
                $data->[$i]{'__ics__'},
                ref($prev) eq 'ARRAY' && $i <= $#$prev ? $prev->[$i] : undef,
                $knot,
            );
        }
    }
}
sub _decode_json_resolve {
    my ($info, $existing, $knot) = @_;

    if (defined $existing) {
        my $inner = ref($existing) && _is_child($existing);
        return $existing if $inner && $inner->{_key} == $info->{child_key};
    }

    return _decode_json_reattach($info, $knot);
}
sub _decode_json_reattach {
    my ($info, $knot) = @_;

    my %opts = (
        %{ $knot->attributes },
        key       => $info->{child_key},
        exclusive => 0,
        create    => 0,
        magic     => 1,
    );

    if ($info->{type} eq 'HASH') {
        my %h;
        tie %h, 'IPC::Shareable', \%opts;
        return \%h;
    }
    elsif ($info->{type} eq 'ARRAY') {
        my @a;
        tie @a, 'IPC::Shareable', \%opts;
        return \@a;
    }
    elsif ($info->{type} eq 'SCALAR') {
        my $s;
        tie $s, 'IPC::Shareable', \%opts;
        return \$s;
    }
}
sub _freeze {
    my $seg  = shift;
    my $water = shift;

    my $ice = freeze $water;
    substr $ice, 0, 0, 'IPC::Shareable';

    if (length($ice) > $seg->size) {
        croak "Length of shared data exceeds shared segment size";
    }

    $seg->shmwrite($ice);
}
sub _thaw {
    my $seg = shift;

    my $ice = $seg->shmread;

    return if ! $ice;

    my $tag = substr $ice, 0, 14, '';

    if ($tag eq 'IPC::Shareable') {
        my $water = thaw $ice;
        if (! defined($water)){
            croak "Munged shared memory segment (size exceeded?)";
        }
        return $water;
    } else {
        return;
    }
}

# Data management
sub _tie {
    my ($type, $class, $key_str, $opts);

    if (scalar @_ == 4) {
        # Legacy API allowed a string scalar key
        ($type, $class, $key_str, $opts) = @_;
        $opts->{key} = $key_str;
    }
    else {
        ($type, $class, $opts) = @_;
    }

    $opts  = _parse_args($opts);

    my $knot = bless { attributes => $opts }, $class;

    $knot->uuid;

    my $key      = $knot->_shm_key;
    my $flags    = $knot->_shm_flags;
    my $shm_size = $knot->attributes('size');

    if ($knot->attributes('limit') && $shm_size > SHMMAX_BYTES) {
        croak
            "Shared memory segment size '$shm_size' is larger than max size of " .
            SHMMAX_BYTES;
    }

    my $seg;

    if ($knot->attributes('graceful')) {
        my $exclusive = eval {
            $seg = IPC::Shareable::SharedMem->new(
                key   => $key,
                size  => $shm_size,
                flags => $flags,
                mode  => $knot->attributes('mode'),
                type  => $type,
            );
            1;
        };

        if (! defined $exclusive) {
            if ($knot->attributes('warn')) {
                my $key = lc(sprintf("0x%X", $knot->_shm_key));

                warn "Process ID $$ exited due to exclusive shared memory collision at segment/semaphore key '$key'\n";
            }
            exit(0);
        }
    }
    else {
        $seg = IPC::Shareable::SharedMem->new(
            key   => $key,
            size  => $shm_size,
            flags => $flags,
            mode  => $knot->attributes('mode'),
            type  => $type,
        );
    }

    if (! defined $seg) {
        if ($! =~ /Cannot allocate memory/) {
            croak "\nERROR: Could not create shared memory segment: $!\n\n" .
                  "Are you using too large a segment size, or spawning too many segments?";
        }

        if ($! =~ /No space left on device/) {
            croak "\nERROR: Could not create shared memory segment: $!\n\n" .
                "Are you spawning too many segments (in a loop perhaps)?";
        }

        if (! $knot->attributes('create')) {
            confess "ERROR: Could not acquire shared memory segment... 'create' ".
                  "option is not set, and the segment hasn't been created " .
                  "yet:\n\n $!";
        }
        elsif ($knot->attributes('create') && $knot->attributes('exclusive')){
            croak "ERROR: Could not create shared memory segment. 'create' " .
                  "and 'exclusive' are set. Does the segment already exist? " .
                  "\n\n$!";
        }
        else {
            croak "ERROR: Could not create shared memory segment.\n\n$!";
        }
    }

    # Try to attach to an existing semaphore set first using nsems=0, which
    # avoids EINVAL on macOS/BSD when the existing set has fewer slots than
    # the requested count. If the set does not exist yet, fall through to
    # create a new 4-slot set (SEM_MARKER=0, SEM_PROTECTED=1, shared/write
    # lock counters=2/3).
    my $sem = IPC::Semaphore->new($key, 0, $seg->flags & 0777)
           // IPC::Semaphore->new($key, 4, $seg->flags);

    if (! defined $sem){
        croak "Could not create semaphore set: $!\n";
    }

    if (! $sem->op(@{ $semop_args{(LOCK_SH)} }) ) {
        croak "Could not obtain semaphore set lock: $!\n";
    }

    %$knot = (
        %$knot,
        _hkey_list          => undef,
        _key                => $key,
        _key_hex            => $seg->key_hex,
        _lock               => 0,
        _shm                => $seg,
        _sem                => $sem,
        _type               => $type,
        _type_int           => $type eq 'HASH' ? TYPE_HASH : $type eq 'ARRAY' ? TYPE_ARRAY : TYPE_SCALAR,
        _was_changed        => 0,
    );

    my $serializer = $knot->attributes('serializer');

    if ($serializer eq 'json') {
        my $data;
        my $decoded_ok = eval { $data = $knot->_decode($seg); 1 };

        if (! $decoded_ok) {
            # JSON decode threw — the segment may contain legacy Storable data.
            # Try Storable; if it succeeds, silently switch this session over
            # and warn the caller so they know to migrate.
            my $storable_data;
            my $thaw_ok = eval { $storable_data = _thaw($seg); 1 };

            if ($thaw_ok && defined $storable_data) {
                carp sprintf(
                    "IPC::Shareable: segment 0x%08x contains Storable-encoded data; "
                  . "switching serializer to 'storable' for this session. "
                  . "Re-create the segment to migrate it to JSON.",
                    $key
                );
                $knot->{attributes}{serializer} = 'storable';
                $knot->{_data} = $storable_data;
            }
            else {
                die $@;
            }
        }
        else {
            $knot->{_data} = $data;
        }
    }
    else {
        $knot->{_data} = _thaw($seg);
    }

    # Register unconditionally so any process that attaches to an existing
    # segment (create=>0, re-attach, cross-process) is also tracked for
    # clean_up_all(). Previously only new segments were registered here,
    # requiring the Dumper hack in global_register() to catch the rest.

    if (! exists $global_register{$knot->seg->id}) {
        $global_register{$knot->seg->id} = $knot;
    }

    if ($sem->getval(SEM_MARKER) != SHM_EXISTS) {

        $process_register{$knot->seg->id} ||= $knot;

        $sem->setval(SEM_PROTECTED, $knot->attributes('protected'));

        if (! $sem->setval(SEM_MARKER, SHM_EXISTS)){
            croak "Couldn't set semaphore during object creation: $!";
        }
    }
    else {
        # Segment already existed — restore the protected attribute from the
        # semaphore so that clean_up_all() in this process correctly skips it
        # even when the caller did not explicitly pass protected => N.
        my $stored_protected = $sem->getval(SEM_PROTECTED);
        $knot->{attributes}{protected} = $stored_protected
            if defined $stored_protected && $stored_protected != 0;
    }

    $sem->op(@{ $semop_args{(LOCK_SH|LOCK_UN)} });

    return $knot;
}
sub _magic_tie {
    my ($parent, $val, $identifier) = @_;

    my $key;

    if ($parent->{_key} == IPC_PRIVATE && $parent->attributes('serializer') ne 'json') {
        $key = IPC_PRIVATE;
    }
    else {
        $key = _shm_key_rand();
    }

    # The individual options in the hash override any pre-set options that are
    # being inherited from the parent

    my %opts = (
        %{ $parent->attributes },
        key       => $key,
        exclusive => 1,
        create    => 1,
        magic     => 1,
    );

    # XXX I wish I didn't have to take a copy of data here and copy it back in
    # XXX Also, have to peek inside potential objects to see their implementation

    my $child;
    my $type = Scalar::Util::reftype($val) || '';

    if ($type eq "HASH") {
        my %copy = %$val;
        $child = tie %$val, 'IPC::Shareable', $key, { %opts };
        croak "Could not create inner tie" if ! $child;

        _reset_segment($parent, $identifier) if $opts{tidy};

        %$val = %copy;
    }
    elsif ($type eq "ARRAY") {
        my @copy = @$val;
        $child = tie @$val, 'IPC::Shareable', $key, { %opts };
        croak "Could not create inner tie" if ! $child;

        _reset_segment($parent, $identifier) if $opts{tidy};

        @$val = @copy;
    }
    elsif ($type eq "SCALAR") {
        my $copy = $$val;
        $child = tie $$val, 'IPC::Shareable', $key, { %opts };
        croak "Could not create inner tie" if ! $child;

        $$val = $copy;
    }
    else {
        croak "Variables of type $type not implemented";
    }

    return $child;
}
sub _is_child {
    my $data = shift or return;

    my $type = Scalar::Util::reftype( $data );
    return unless $type;

    my $obj;

    if ($type eq "HASH") {
        $obj = tied %$data;
    }
    elsif ($type eq "ARRAY") {
        $obj = tied @$data;
    }
    elsif ($type eq "SCALAR") {
        $obj = tied $$data;
    }

    if (ref $obj eq 'IPC::Shareable') {
        return $obj;
    }

    return;
}
sub _need_tie {
    my ($knot, $val, $identifier) = @_;

    my $type = Scalar::Util::reftype($val);
    return 0 if ! $type;

    my $need_tie;

    if ($type eq "HASH") {
        $need_tie = !(tied %$val);
    }
    elsif ($type eq "ARRAY") {
        $need_tie = !(tied @$val);
    }
    elsif ($type eq "SCALAR") {
        $need_tie = !(tied $$val);
    }

    return $need_tie ? 1 : 0;
}

# Segment operations
sub _key_str_to_int {
    # Convert any key format (hex string, decimal integer string, or arbitrary
    # text) to a 32-bit integer using the same algorithm as _shm_key(), but
    # without the %used_ids side effect. Safe to call any number of times.
    my ($key_str) = @_;

    return hex($key_str)    if $key_str =~ /^0x[0-9a-fA-F]+$/i;
    return $key_str + 0     if $key_str =~ /^\d+$/;

    my $int = crc32($key_str);
    $int -= MAX_KEY_INT_SIZE if $int > MAX_KEY_INT_SIZE;
    return $int;
}
sub _shm_key {
    # Generates a 32-bit CRC on the key string. The $key_str parameter is used
    # for testing only, for purposes of testing various key strings

    my ($knot, $key_str) = @_;

    $key_str //= ($knot->attributes('key') || '');

    my $key;

    if ($key_str eq '') {
        $key = IPC_PRIVATE;
    }
    elsif ($key_str =~ /^0x[0-9a-fA-F]+$/i) {
        # User specified an explicit hex string key (e.g. '0xDEADBEEF'); use the
        # bit pattern as-is so the segment key seen by ipcs(1) matches exactly.
        $key = hex($key_str);
        $used_ids{$key}++;
        return $key;
    }
    elsif ($key_str =~ /^\d+$/) {
        # User specified an explicit decimal integer key; use it as-is.
        $key = $key_str;
        $used_ids{$key}++;
        return $key;
    }
    else {
        # String key: compute a 32-bit CRC and apply overflow correction so the
        # result fits in a signed 32-bit key_t.
        $key = crc32($key_str);
    }

    $used_ids{$key}++;

    if ($key > MAX_KEY_INT_SIZE) {
        $key = $key - MAX_KEY_INT_SIZE;

        if ($key == 0) {
            croak "We've calculated a key which equals 0. This is a fatal error";
        }
    }

    return $key;
}
sub _shm_key_rand {
    my $key;

    # Unfortunatly, the only way I know how to check if a segment exists is
    # to actually create it. We must do that here, then remove it just to
    # ensure the slot is available

    my $verified_exclusive = 0;

    my $check_count = 0;

    while (! $verified_exclusive && $check_count < EXCLUSIVE_CHECK_LIMIT) {
        $check_count++;

        $key = _shm_key_rand_int();

        next if $used_ids{$key};

        my $flags;
        $flags |= IPC_CREAT;
        $flags |= IPC_EXCL;

        my $seg;

        my $shm_slot_available = eval {
            $seg = IPC::Shareable::SharedMem->new(
                key     => $key,
                size    => 1,
                flags   => $flags,
            );
            1;
        };

        if ($shm_slot_available) {
            $verified_exclusive = 1;
            $seg->remove if $seg;
        }
    }

    if (! $verified_exclusive) {
        croak
            "_shm_key_rand() can't get an available key after $check_count tries";
    }

    $used_ids{$key}++;

    return $key;
}
sub _shm_key_rand_int {
    return int(rand(1_000_000));
}
sub _shm_flags {
    # Parses the anonymous hash passed to constructors; returns a list
    # of args suitable for passing to shmget

    my ($knot) = @_;

    my $flags = 0;

    $flags |= IPC_CREAT if $knot->attributes('create');
    $flags |= IPC_EXCL  if $knot->attributes('exclusive');

    return $flags;
}
sub _reset_segment {
    my ($parent, $id) = @_;

    my $parent_type = Scalar::Util::reftype($parent->{_data}) || '';

    if ($parent_type eq 'HASH') {
        my $data = $parent->{_data};
        if (exists $data->{$id}) {
            my $child_type = Scalar::Util::reftype($data->{$id}) || '';
            if ($child_type eq 'HASH' && tied %{ $data->{$id} }) {
                (tied %{ $parent->{_data}{$id} })->remove;
            }
            elsif ($child_type eq 'ARRAY' && tied @{ $data->{$id} }) {
                (tied @{ $parent->{_data}{$id} })->remove;
            }
        }
    }
    elsif ($parent_type eq 'ARRAY') {
        my $data = $parent->{_data};
        if (exists $data->[$id]) {
            my $child_type = Scalar::Util::reftype($data->[$id]) || '';
            if ($child_type eq 'HASH' && tied %{ $data->[$id] }) {
                (tied %{ $parent->{_data}[$id] })->remove;
            }
            elsif ($child_type eq 'ARRAY' && tied @{ $data->[$id] }) {
                (tied @{ $parent->{_data}[$id] })->remove;
            }
        }
    }
}

# Misc
sub _parse_args {
    my ($opts) = @_;

    $opts  = defined $opts  ? $opts  : { %default_options };

    for my $k (keys %default_options) {
        if (not defined $opts->{$k}) {
            $opts->{$k} = $default_options{$k};
        }
        elsif ($opts->{$k} eq 'no') {
            if ($^W) {
                require Carp;
                Carp::carp("Use of `no' in IPC::Shareable args is obsolete");
            }

            $opts->{$k} = 0;
        }
    }
    $opts->{owner} = ($opts->{owner} or $$);
    $opts->{magic} = ($opts->{magic} or 0);
    return $opts;
}
sub _end {
    for my $s (values %process_register) {
        eval { unlock($s) };
        next if $s->attributes('protected');
        next if ! $s->attributes('destroy');
        next if $s->attributes('owner') != $$;
        eval { remove($s) };
    }
}

sub _placeholder {}

1;

__END__

=head1 NAME

IPC::Shareable - Use shared memory backed variables across processes

=for html
<a href="https://github.com/stevieb9/ipc-shareable/actions"><img src="https://github.com/stevieb9/ipc-shareable/workflows/CI/badge.svg"/></a>
<a href='https://coveralls.io/github/stevieb9/ipc-shareable?branch=master'><img src='https://coveralls.io/repos/stevieb9/ipc-shareable/badge.svg?branch=master&service=github' alt='Coverage Status' /></a>


=head1 SYNOPSIS

    use IPC::Shareable qw(:lock);

    tie my %hash,   'IPC::Shareable', OPTIONS;
    tie my @array,  'IPC::Shareable', OPTIONS;
    tie my $scalar, 'IPC::Shareable', OPTIONS;

    # Get SYSV shared memory specifications of the system (if available)

    my $href = IPC::Shareable::sysv_info();

    # Lock, make changes, unlock

    tied(VARIABLE)->lock;
        # Do something with the variable
    tied(VARIABLE)->unlock;

    # Non-blocking lock attempt

    tied(VARIABLE)->lock(LOCK_SH|LOCK_NB)
        or print "Resource unavailable\n";

    # Lock with a code reference, which will auto-unlock when the block finishes

    tied(VARIABLE->lock(sub { print "hello!\n"; });

    # Get the shared memory segment and semaphore objects directly

    my $segment   = tied(VARIABLE)->seg;
    my $semaphore = tied(VARIABLE)->sem;

    # Remove the shared memory segment and semaphore directly

    tied(VARIABLE)->remove;

    # Manual cleanup procedures

    IPC::Shareable::clean_up;
    IPC::Shareable::clean_up_all;
    IPC::Shareable::clean_up_protected;

    # Ensure only one instance of a script can be run at any time

    IPC::Shareable->singleton('UNIQUE SCRIPT LOCK STRING');

    # Get the actual IPC::Shareable tied object you can make method calls on
    # instead of using the tied object like the examples above

    my $knot = tied(VARIABLE); # Dereference first if using a tied reference

    # ...or get the knot at inception

    my $knot = tie my VARIABLE, 'IPC::Shareable', OPTIONS;
    my $sysv_info_href = $knot->sysv_info;

=head1 DESCRIPTION

IPC::Shareable allows you to tie a variable to shared memory making it
easy to share the contents of that variable with other Perl processes and
scripts.

Scalars, arrays, hashes and even objects can be tied. The variable being
tied may contain arbitrarily complex data structures - including references to
arrays, hashes of hashes, etc.

B<Note>: When using nested data structures, each nested structure utilizes an
additional shared memory segment. The entire structure is not squashed into a
single segment. See L</DATA AND SEGMENT MAPPING> for details.

The association between variables in distinct processes is provided by
GLUE (aka "key").  This is any arbitrary string or integer that serves as a
common identifier for data across process space.  Hence the statement:

    tie my %hash, 'IPC::Shareable', { key => 'GLUE STRING', create => 1 };

...in program one and the statement

    tie my %thing, 'IPC::Shareable', { key => 'GLUE STRING' };

...in program two will create and bind C<%hash> the shared memory in program
one and bind it to C<%thing> in program two.

There is no pre-set limit to the number of processes that can bind to
data; nor is there a pre-set limit to the complexity of the underlying
data of the tied variables.  The amount of data that can be shared
within a single bound variable is limited by the system's maximum size
for a shared memory segment (the exact value is system-dependent).

The bound data structures are all linearized (using Raphael Manfredi's
L<JSON> module or optionally L<Storable>) before being slurped into shared
memory.  Upon retrieval, the original format of the data structure is recovered.
Semaphore flags can be used for locking data between competing processes.

=head1 OPTIONS

a.k.a "attributes"

Options are specified by passing a reference to a hash as the third argument to
the C<tie()> function that enchants a variable. We also call these "Attributes"

The following fields are recognized in the options hash:

=head2 key

B<key> is the GLUE that is a direct reference to the shared memory segment
that's to be tied to the variable.

If this option is missing, we'll default to using C<IPC_PRIVATE>. This
default key will not allow sharing of the variable between processes.

The key can be specified as:

=over 4

=item * A text string (internally, a 32-bit CRC of the string is used as the key)

=item * A hex string (e.g. C<'0xDEADBEEF'>), used as-is as the integer key

=item * An integer (e.g. C<1234>), used as-is as the integer key

=back

Default: B<IPC_PRIVATE>

=head2 create

B<create> is used to control whether the process creates a new shared
memory segment or not.  If B<create> is set to a true value,
L<IPC::Shareable> will create a new binding associated with GLUE as
needed.  If B<create> is false, L<IPC::Shareable> will not attempt to
create a new shared memory segment associated with GLUE.  In this
case, a shared memory segment associated with GLUE must already exist
or we'll C<croak()>.

Defult: B<false>

=head2 exclusive

If B<exclusive> field is set to a true value, we will C<croak()> if the data
binding associated with GLUE already exists.  If set to a false value, calls to
C<tie()> will succeed even if a shared memory segment associated with GLUE
already exists.

See L</graceful> for a silent, non-exception exit if a second process attempts
to obtain an in-use C<exclusive> segment.

Default: B<false>

=head2 graceful

If B<exclusive> is set to a true value, we normally C<croak()> if a second
process attempts to obtain the same shared memory segment. Set B<graceful>
to true and we'll C<exit> silently and gracefully. This option does nothing
if C<exclusive> isn't set.

Useful for ensuring only a single process is running at a time.

Default: B<false>

=head2 warn

When set to a true value, B<graceful> will output a warning if there are
process collisions.

Default: B<false>

=head2 mode

The B<mode> argument is an octal number specifying the access
permissions when a new data binding is being created.  These access
permission are the same as file access permissions in that C<0666> is
world readable and writable, C<0600> is readable only by the effective UID of
the process creating the shared variable, etc.

Default: B<0666> (world readable and writeable)

=head2 size

This field may be used to specify the size of the shared memory segment
allocated.

B<Note>: Each nested data structure requires a new shared memory segment. The
C<size> attribute is applied to the first, and all subsequent segments created,
and does not reflect the overall size of memory to be used.

The maximum size we allow by default is ~1GB. See the L</limit> option to
override this default.

Default: C<IPC::Shareable::SHM_BUFSIZ()> (ie. B<65536>)

=head2 protected

If set, the C<clean_up()> and C<clean_up_all()> routines will not remove the
segments or semaphores related to the tied object.

Set this to a non-zero integer. The integer is persisted in the segment's
associated semaphore set, so any process that later attaches to the same
segment via C<< create => 0 >> will automatically have this attribute restored;
it does not need to pass C<< protected >> explicitly. This means
C<clean_up_all()> in that process will also honour the protection.

The integer acts as a group key: all segments (including nested children)
created under the same protected parent share the same value, so a single call
to C<clean_up_protected($key)> removes the entire group.

To clean up protected objects, call
C<< (tied %object)->clean_up_protected(integer) >>, where 'integer' is the
value you set the C<protected> option to. You can call this cleanup routine in
the script you created the segment, or anywhere else, at any time.

The protect key is limited to values accepted by the system's semaphore
implementation (typically 0-32767; 0 means unprotected).

Default: B<0>

=head2 limit

This field will allow you to set a segment size larger than the default maximum
which is 1,073,741,824 bytes (approximately 1 GB). If set, we will
C<croak()> if a size specified is larger than the maximum. If it's set to a
false value, we'll C<croak()> if you send in a size larger than the total
system RAM.

Default: B<true>

=head2 enforced_locking

This attribute will allow you to enforce locks that you set, instead of them
being simply advisory.

Use with C<violated_lock_warn> to emit a warning when a lock collision has
occurred.

Default: B<true>

=head2 violated_lock_warn

When C<enforced_locking> is enabled, and this attribute is set to true, we will
emit a warning when an exclusive lock collision has occurred. The warning will
include the UUID of the object that caused the violation, and the segment ID
that the violation occurred against.

Default: B<false>

=head2 destroy

If set to a true value, the shared memory segment underlying the data
binding will be removed when the process that initialized the shared memory
segment exits (gracefully)[1].

Only those memory segments that were created by the current process will be
removed.

Use this option with care. In particular you should not use this option in a
program that will fork after binding the data.  On the other hand, shared memory
is a finite resource and should be released if it is not needed.

B<NOTE>: If the segment was created with its L</protected> attribute set,
it will not be removed upon program completion, even if C<destroy> is set.

Default: B<false>

=head2 tidy

For long running processes, set this to a true value to clean up unneeded
segments from nested data structures. Comes with a slight 2% performance hit.

Default: B<true>

=head2 serializer

By default, we use L<JSON> as the data serializer when writing to or
reading from the shared memory segments we create. For cross-platform and
cross-language interoperability this is the recommended choice. Alternatively,
you can use L<Storable> for richer data type support (e.g. blessed objects).

Send in either C<json> or C<storable> as the value to use the respective
serializer.

Default: B<json>

=head2 Default Option Values

Default values for options are:

    key                 => IPC_PRIVATE, # 0
    create              => 0,
    exclusive           => 0,
    mode                => 0666,
    size                => IPC::Shareable::SHM_BUFSIZ(), # 65536
    protected           => 0,
    limit               => 1,
    destroy             => 0,
    graceful            => 0,
    warn                => 0,
    tidy                => 1,
    serializer          => 'json',
    enforced_locking    => 1,
    violated_lock_warn  => 0,


=head1 METHODS

=head2 new

This C<new()> call is not necessary and is a simple wrapper around C<tie()>. It
is capable only of returning a tied hash reference object.

Instantiates and returns a reference to a hash backed by shared memory.

    my $href = IPC::Shareable->new(key => "testing", create => 1);

    $href=>{a} = 1;

    # Call tied() on the dereferenced variable to access object methods
    # and information

    tied(%$href)->shm_count;

Parameters:

Hash, Optional: See the L</OPTIONS> section for a list of all available options.
Most often, you'll want to send in the B<key> and B<create> options.

It is possible to get a reference to an array or scalar as well. Simply send in
either C<< var = > 'ARRAY' >> or C<< var => 'SCALAR' >> to do so.

Return: A reference to a hash (or array or scalar) which is backed by shared
memory.

=head2 uuid

Returns the UUID of the object.

=head2 singleton($glue, $warn)

Class method that ensures that only a single instance of a script can be run
at any given time.

Parameters:

    $glue

Mandatory, String: The key/glue that identifies the shared memory segment.

    $warn

Optional, Bool: Send in a true value to have subsequent processes throw a
warning that there's been a shared memory violation and that it will exit.

Default: B<false>

B<Note>: See L<Script::Singleton|https://metacpan.org/pod/Script::Singleton>.
That library implements C<singleton> for a script with a simple C<use> line.

=head2 shm_count

Returns the number of instantiated shared memory segments that currently exist
on the system. This isn't precise; it simply does a C<wc -l> line count on your
system's C<ipcs -m> call. It is guaranteed though to produce reliable results.

Return: Integer

=head2 sem_count

Returns the number of semaphore sets that currently exist on the system, by
parsing C<ipcs -s>. Since each L<IPC::Shareable> segment is associated with
exactly one semaphore set (same SysV key), this count moves in lockstep with
L</shm_count> when segments are created and destroyed cleanly.

Return: Integer

=head2 shm_segments($key)

    my $ipc_shareable_segments = IPC::Shareable->shm_segments;

    # Filtered to one variable's segments only
    my $segs = IPC::Shareable->shm_segments('my_key');
    my $segs = IPC::Shareable->shm_segments('0xDEADBEEF');

Class/object method. Scans all existing shared memory segments on the system
and returns a hash reference mapping the hex key string (e.g. C<'0xdeadbeef'>)
to the raw literal contents of that segment. Only loads segments that were
created by L<IPC::Shareable>.

Segments created with C<IPC_PRIVATE> (key C<0x00000000>) are skipped because
they cannot be looked up by key.

Parameters:

    $key

Optional, String or Int: If sent in, we will restrict the result to only the
segments related to the variable the C<$key> reflects. Without this parameter,
all L<IPC::Shareable> segments on the system are returned.

Return: Hash reference where each key is the SHM key in hex format.

Field descriptions:

B<known>: C<1> if this segment is currently tied in the calling process,
C<0> if not. A value of C<0> includes segments legitimately persisted by
another process (C<destroy =E<gt> 0>), not just crashed leftovers. See
L</unknown_segments> for important caveats.

B<local_process>: C<1> if created by the same process this method is being run,
and C<0> if not.

B<content>: The actual raw content of the shared memory segment.

B<child_keys>: Nested data structures each require their own segment. Keys
within this array reference map to child segments.

Here's an example data structure, and what the return value of C<shm_segments>
would look like for it using the JSON serializer. Note that the top-level
structure is a hash, and it contains two nested hashes (keys 'c; and 'd'), which
are each stored in their own segments. It also has two scalar values (keys 'a'
and 'b'), which are stored in the top-level segment.

    # Actual data

    {
        a => 1,
        b => 'hello',
        c => {
            x => 10,
            y => 20,
        },
        d => {
            p => 'foo',
            q => 'bar',
        },
    }

    # Call return (JSON content strings will be on one line; separated for
    # clarity)

    {
        '0x2abc0001' => {
            known           => 1,
            local_process   => 1
            content         => 'IPC::Shareable{
                "a": 1,
                "b": "hello",
                "c": {
                    "__ics__": {
                        "child_key_hex": "0x000e1b1d",
                        "child_key":     "924445",
                        "type":          "HASH"
                    }
                },
                "d": {
                    "__ics__": {
                        "child_key_hex": "0x000097af",
                        "child_key":     "38831",
                        "type":          "HASH"
                    }
                }
            }',
            child_keys      => [
                '0x000e1b1d',
                '0x000097af'
            ],
        },
        '0x000e1b1d' => {
            known           => 1,
            local_process   => 1
            content         => 'IPC::Shareable{"y":20,"x":10}',
            child_keys      => [],
        },
        '0x000097af' => {
            known           => 1,
            local_process   => 1
            content         => 'IPC::Shareable{"p":"foo","q":"bar"}',
            child_keys      => [],
        }
    }

=head2 unknown_segments

    my @unknown_keys = IPC::Shareable->unknown_segments;

    # or

    my @unknown_keys = $knot->unknown_segments;

Class/object method. Returns a list of hex key strings (e.g. C<'0xdeadbeef'>)
for all shared memory segments that were created by L<IPC::Shareable> but are
not currently tied in the calling process.

B<Important>: this method has no way to distinguish between a segment that was
left behind by a crashed process and one that is legitimately persisted by
another running process (C<destroy =E<gt> 0>). Both will appear in the returned
list. Only call C<remove> on entries you are certain belong to your own
application and are no longer in use.

Return: List of hex key strings.

    my @unknown = IPC::Shareable->unknown_segments;

    for my $key (@unknown) {
        print "Unknown segment: $key\n";
        IPC::Shareable->remove($key);
    }

=head2 seg_map

    # Show all IPC::Shareable segments visible on the system
    print IPC::Shareable->seg_map;

    # Show only the segment tree rooted at this object
    print $knot->seg_map;
    print tied(%hash)->seg_map;

When called as a B<class method>, returns a human-readable string showing all
L<IPC::Shareable> shared memory segments visible on the current system,
organised as a tree (root segments at the top, nested children indented below
their parent).

When called as an B<object method>, the output is filtered to just the segment
tree rooted at that object (the segment itself plus any nested children).

For each segment the output includes:

=over 4

=item * The hex key and OS segment ID

=item * Status tags: C<known> (tied in this process) or C<unknown>, and
C<owner> if this process created the segment

=item * Semaphore information: OS semaphore ID (C<sem_id>), C<SEM_MARKER>,
read-lock counter, write-lock counter, and C<PROTECTED> (the integer stored
in C<SEM_PROTECTED>)

=item * The list of child segment hex keys, or C<(none)>

=item * The segment's current content. Reference values that are child segments
are shown as C<< <child: 0xHEX> >> rather than being recursed into.
Segments not tied in this process show C<(not accessible)>.

=back

Example output:

    IPC::Shareable Segment Map
    ==========================

    [known, owner]  key: 0x0000cafe  seg_id: 12345678
      Semaphores: sem_id: 98765
              1: SEM_MARKER=1
              2: READERS=0
              3: WRITERS=0
              4: PROTECTED=42
      Children:   0x0001beef
      Content:    { nested => <child: 0x0001beef> }

      [known, owner]  key: 0x0001beef  seg_id: 23456789
        Semaphores: sem_id: 98766
                1: SEM_MARKER=1
                2: READERS=0
                3: WRITERS=0
                4: PROTECTED=42
        Children:   (none)
        Content:    { x => "1", y => "2" }

=head2 sysv_info

    my $sysv_info = IPC::Shareable->sysv_info;

    print "Max segment size: $sysv_info->{shmmax}\n";
    print "Max segments (system): $sysv_info->{shmmni}\n";

Class method. Returns a hash reference containing the kernel's SysV shared
memory configuration parameters for the current platform.

Returns C<undef> if the platform is not supported or no data could be read.

On macOS, reads from C<sysctl kern.sysv>. Example return value:

    {
        shmmax => 4194304,   # Maximum size of a single segment (bytes)
        shmmin => 1,         # Minimum size of a single segment (bytes)
        shmmni => 32,        # Maximum number of segments system-wide
        shmseg => 8,         # Maximum number of segments per process
        shmall => 1024,      # Maximum total shared memory (pages)
    }

On Linux, reads from C</proc/sys/kernel/>. Example return value:

    {
        shmmax => 18446744073692774399,  # Maximum size of a single segment (bytes)
        shmmin => 1,                     # Minimum size of a single segment (bytes)
        shmmni => 4096,                  # Maximum number of segments system-wide
        shmall => 18446744073692774399,  # Maximum total shared memory (pages)
    }

Note: Linux has no per-process segment limit (C<shmseg>); only the system-wide
C<shmmni> applies.

Return: Hash reference, or C<undef> if the platform is not supported or no data could be read.

=head2 lock($flags, $code)

Parameters:

    $flags

Optional, Integer: See C<flock()> system call for lock flag combinations. If
this parameter is emitted, we default to C<LOCK_EX>, an exclusive blocking
lock.

    $code

Optional, Code reference: If this parameter is sent in, and an exclusive lock
is asked for, we will set the lock, execute the subroutine, and then call
C<unlock()> on the segment.

Obtains a lock on the shared memory. C<$flags> specifies the type
of lock to acquire.  If C<$flags> is not specified, an exclusive
read/write lock is obtained.  Acceptable values for C<$flags> are
the same as for the C<flock()> system call.

Returns C<true> on success, and C<undef> on error. For non-blocking calls
(see below), the method returns C<0> if it would have blocked.

B<Note>: Although the C<$flags> and C<$code> parameters appear positional, you
can send in C<$code> without sending in any C<$flags>. When this occurs,
C<$flags> will automatically be set to C<LOCK_EX>.

Obtain an exclusive lock like this:

        tied(%var)->lock(LOCK_EX); # Same as default

Only one process can hold an exclusive lock on the shared memory at a given
time.

Obtain a shared (read) lock:

        tied(%var)->lock(LOCK_SH);

Multiple processes can hold a shared (read) lock at a given time.  If a process
attempts to obtain an exclusive lock while one or more processes hold
shared locks, it will be blocked until they have all finished.

Either of the locks may be specified as non-blocking:

        tied(%var)->lock( LOCK_EX|LOCK_NB );
        tied(%var)->lock( LOCK_SH|LOCK_NB );

A non-blocking lock request will return C<0> if it would have had to
wait to obtain the lock.

Note that these locks are advisory (just like flock), meaning that
all cooperating processes must coordinate their accesses to shared memory
using these calls in order for locking to work.  See the C<flock()> call for
details.

Locks are inherited through forks, which means that two processes actually
can possess an exclusive lock at the same time. Don't do that.

The constants C<LOCK_EX>, C<LOCK_SH>, C<LOCK_NB>, and C<LOCK_UN> are available
for import using any of the following export tags:

        use IPC::Shareable qw(:lock);
        use IPC::Shareable qw(:flock);
        use IPC::Shareable qw(:all);

Or, just use the flock constants available in the Fcntl module.

See L</LOCKING> for further details.

=head2 unlock

Removes a lock. Takes no parameters, returns C<true> on success.

This is equivalent of calling C<shlock(LOCK_UN)>.

See L</LOCKING> for further details.

=head2 seg

Called on either the tied variable or the tie object, returns the shared
memory segment object currently in use.

See L<IPC::Shareable::SharedMem> documentation for details.

=head2 sem

Called on either the tied variable or the tie object, returns the semaphore
object related to the memory segment currently in use.

=head2 attributes

Retrieves the list of attributes that drive the L<IPC::Shareable> object.

Parameters:

    $attribute

Optional, String: The name of the attribute. If sent in, we'll return the value
of this specific attribute. Returns C<undef> if the attribute isn't found.

Attributes are the C<OPTIONS> that were used to create the object.

Returns: A hash reference of all attributes if C<$attributes> isn't sent in, the
value of the specific attribute if it is.

=head2 global_register

Returns a hash reference of hashes of all in-use shared memory segments across
all processes. The key is the memory segment ID, and the value is the segment
and semaphore objects.

=head2 process_register

Returns a hash reference of hashes of all in-use shared memory segments created
by the calling process. The key is the memory segment ID, and the value is the
segment and semaphore objects.

=head1 LOCKING

IPC::Shareable provides methods to implement application-level advisory and
enforced locking of the shared data structures.  These methods are C<lock()> and
C<unlock()>. To use them you must first get the object underlying the tied
variable, either by saving the return value of the original call to C<tie()> or
by using the built-in C<tied()> function.

=head2 Lock and unlock

To lock and subsequently unlock a variable, do this:

    my $knot = tie my %hash, 'IPC::Shareable', { %options };

    $knot->lock;
    $hash{a} = 'foo';
    $knot->unlock;

or equivalently, if you've decided to throw away the return of C<tie()>:

    tie my %hash, 'IPC::Shareable', { %options };

    tied(%hash)->lock;
    $hash{a} = 'foo';
    tied(%hash)->unlock;

This will place an exclusive lock on the data of C<%hash>.  You can
also get shared locks or attempt to get a lock without blocking.

L<IPC::Shareable> makes the constants C<LOCK_EX>, C<LOCK_SH>, C<LOCK_UN>, and
C<LOCK_NB> exportable to your address space with the export tags C<:lock>,
C<:flock>, or C<:all>. The values should be the same as the standard C<flock>
option arguments.

    if (tied(%hash)->lock(LOCK_SH|LOCK_NB)){
        print "The value is $hash{a}\n";
        tied(%hash)->unlock;
    } else {
        print "Another process has an exclusive lock.\n";
    }

If no argument is provided to C<lock>, it defaults to C<LOCK_EX>.

=head2 Enforced write locking

By default, the C<enforced_locking> is set to true, which means that if a tied
variable sets a C<LOCK_EX>, all writes from all other processes will fail,
regardless of whether the other processes opted in to check locking.

=head3 violated_lock_warn Option

Disabled by default, this is an attribute you set on object instantiation. If
set to C<< true >> and another object has a C<LOCK_EX> in place during a write
operation, a warning will be emitted by any process that attempts to write to
a locked segment.

=head3 Important notes

Note that in the background, we perform lock optimization when reading and
writing to the shared storage even if the advisory locks aren't being used.

Using the advisory locks can speed up processes that are doing several writes/
reads at the same time.

When using C<lock()> to lock a variable, be careful to guard against
signals.  Under normal circumstances, C<IPC::Shareable>'s C<END> method
unlocks any locked variables when the process exits.  However, if an
untrapped signal is received while a process holds a lock, C<END> will
not be called.

This is I<not> a deadlock risk: all semaphore lock operations in
C<IPC::Shareable> use the C<SEM_UNDO> flag, which causes the kernel to
automatically reverse any semaphore operations when the process exits,
regardless of the cause of death (including C<SIGKILL> and hardware
faults). Other processes waiting for the lock will be unblocked.

=head1 DESTRUCTION

perl(1) will destroy the object underlying a tied variable when then
tied variable goes out of scope.  Unfortunately for L<IPC::Shareable>,
this may not be desirable: other processes may still need a handle on
the relevant shared memory segment.

L<IPC::Shareable> therefore provides several options to control the timing of
removal of shared memory segments.

=head2 destroy Option

As described in L</OPTIONS>, specifying the B<destroy> option when
C<tie()>ing a variable coerces L<IPC::Shareable> to remove the underlying
shared memory segment when the process calling C<tie()> exits gracefully.

B<NOTE>: The destruction is handled in an C<END> block. Only those memory
segments that are tied to the current process will be removed.

B<NOTE>: If the segment was created with its L</protected> attribute set,
it will not be removed in the C<END> block, even if C<destroy> is set.

B<NOTE>: The C<END> block only runs on a I<clean> exit (normal program
end, C<die>, or C<exit>). It does B<not> run for untrapped signals
(C<SIGTERM>, C<SIGINT>, etc.) or for C<SIGKILL>. If your process may be
terminated by a signal and you want C<destroy> cleanup to run, install
signal handlers that call C<exit>:

    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { exit };

This causes the C<END> block to fire on those signals. C<SIGKILL> cannot
be caught; any segments left behind by it can be recovered with
C<IPC::Shareable-E<gt>clean_up_all>.

B<NOTE>: Advisory locks (C<lock()>/C<unlock()>) are I<always> released
automatically when a process dies, even on C<SIGKILL>, because the
underlying semaphore operations use C<SEM_UNDO>. Lock release is
therefore not a concern; only shared memory I<segment> data requires
the signal handler precaution above.

=head2 remove($key)

Parameters:

    $key

Optional, see L</key> for valid values. Preferably, an integer or a hex string
prefixed with C<0x>.

B<Note>: If the C<$key> parameter is sent in, we will delete that segment only
and return immediately thereafter.

    tied($var)->remove;

    # or

    $knot->remove;

    # Remove a specific segment by key (can remove non C<IPC::Shareable>
    segments). If key is sent in, the caller can be the module or the object.

    IPC::Shareable->remove('0xdeadbeef');   # hex string
    IPC::Shareable->remove(0xdeadbeef);     # hex integer
    IPC::Shareable->remove(1234);           # integer
    tied($var)->remove('Test');             # string

Calling C<remove()> on the object underlying a C<tie()>d variable removes
the associated shared memory segments.  The segment is removed
irrespective of whether it has the B<destroy> option set or not and
irrespective of whether the calling process created the segment.

=head2 clean_up

    IPC::Shareable->clean_up;

    # or

    tied($var)->clean_up;

    # or

    $knot->clean_up;

This is a class method that provokes L<IPC::Shareable> to remove all
shared memory segments created by the process.  Segments not created
by the calling process are not removed.

This method will not clean up segments created with the C<protected> option.

=head2 clean_up_all

    IPC::Shareable->clean_up_all;

    # or

    tied($var)->clean_up_all;

    # or

    $knot->clean_up_all

This is a class method that provokes L<IPC::Shareable> to remove all
shared memory segments encountered by the process.  Segments are
removed even if they were not created by the calling process.

This method will not clean up segments created with the C<protected> option.

=head2 clean_up_protected($protect_key)

If a segment is created with the C<protected> option, it, nor its children will
be removed during calls of C<clean_up()> or C<clean_up_all()>.

When setting L</protected>, you specified a lock key integer. When calling this
method, you must send that integer in as a parameter so we know which segments
to clean up.

Because the protect key is stored in the segment's semaphore set, any process
that attached to the segment (even without passing C<< protected >> on tie)
will have had its in-process attribute populated automatically. You can
therefore call C<clean_up_protected()> from any process that has attached to
the segment, not only from the one that created it.

    my $protect_key = 93432;

    IPC::Shareable->clean_up_protected($protect_key);

    # or

    tied($var)->clean_up_protected($protect_key);

    # or

    $knot->clean_up_protected($protect_key)

Parameters:

    $protect_key

Mandatory, Integer: The integer protect key you assigned with the C<protected>
option

=head1 RETURN VALUES

Calls to C<tie()> that try to implement L<IPC::Shareable> will return an
instance of C<IPC::Shareable> on success, and C<undef> otherwise.

=head1 DATA AND SEGMENT MAPPING

For simple data (none of the values are references), a single segment is used
throughout. However, with nested data, each value that is a reference is stored
in its own, separate shared memory segment (the key is auto-generated).

Consider a three-level hash:

    $h{a}{b}{c} = 1;

This creates three segments:

    Root segment  (SysV key 0xABCD)
      stored data: { a => <pointer to child key=11111> }
                              |
                              v
              Child segment  (SysV key 11111)
                stored data: { b => <pointer to grandchild key=22222> }
                                          |
                                          v
                        Grandchild segment  (SysV key 22222)
                          stored data: { c => 1 }

Each segment only knows about its direct children. The chain is followed
lazily, one level at a time, as you C<FETCH> down into the structure. (See the
L<shm_segments()|/shm_segments($key)> documentation to gather this structure within code).

When you replace a child with a new reference where the previous value was
also a reference, a new segment is created and the new data is stored there.
If C<tidy> is enabled (default), the old segment is automatically removed.

When a value that is a reference is deleted from the data, the memory segment
that held that data is automatically cleaned up and freed.

=head2 Storable

The child knot object (which holds _key, _type, etc.) is frozen in-place
inside the parent's serialized byte blob. On thaw, the child knot is
reconstructed from those bytes and re-attached to the existing child segment.

=head2 JSON

JSON can't serialize blessed objects, so each child pointer is written as an
explicit marker:

    { "__ics__" => { type => "HASH", child_key => 11111, child_key_hex => "0x00002b67" } }

The raw JSON in the root segment looks like:

    {"a":{"__ics__":{"type":"HASH","child_key":11111,"child_key_hex":"0x00002b67"}}}

The raw JSON in the child segment (key 11111) looks like:

    {"b":{"__ics__":{"type":"HASH","child_key":22222,"child_key_hex":"0x000056ce"}}}

Finally, the value in the child is not a reference, so it's stored as literal
data:

    {"c": 1}

On decode, any C<__ics__> marker is spotted and a tie with C<create =Egt 0> is
used to re-attach to the existing child segment by that key; no new segment is
created, it simply reconnects.

=head1 AUTHOR

Benjamin Sugars <bsugars@canoe.ca>

=head1 MAINTAINED BY

Steve Bertrand <steveb@cpan.org>

=head1 NOTES

=head2 General Notes

=over 4

=item o

There is a program called C<ipcs>(1/8) (and C<ipcrm>(1/8)) that is
available on at least Solaris and Linux that might be useful for
cleaning moribund shared memory segments or semaphore sets produced
by bugs in either L<IPC::Shareable> or applications using it.

Examples:

    # List all semaphores and memory segments in use on the system

    ipcs -a

    # List all memory segments and semaphores along with each one's associated process ID

    ipcs -ap

    # List just the shared memory segments

    ipcs -m

    # List the details of an individual memory segment

    ipcs -i 12345678

    # Remove *all* semaphores and memory segments

    ipcrm -a

=item o

This version of L<IPC::Shareable> does not understand the format of
shared memory segments created by versions prior to C<0.60>.  If you try
to tie to such segments, you will get an error.  The only work around
is to clear the shared memory segments and start with a fresh set.

=item o

Iterating over a hash causes a special optimization if you have not
obtained a lock (it is better to obtain a read (or write) lock before
iterating over a hash tied to L<IPC::Shareable>, but we attempt this
optimization if you do not).

For tied hashes, the C<fetch>/C<thaw> operation is performed
when the first key is accessed.  Subsequent key and and value
accesses are done without accessing shared memory.  Doing an
assignment to the hash or fetching another value between key
accesses causes the hash to be replaced from shared memory. The
state of the iterator in this case is not defined by the Perl
documentation. Caveat Emptor.

=back

=head1 CREDITS

Thanks to all those with comments or bug fixes, especially

    Maurice Aubrey      <maurice@hevanet.com>
    Stephane Bortzmeyer <bortzmeyer@pasteur.fr>
    Doug MacEachern     <dougm@telebusiness.co.nz>
    Robert Emmery       <roberte@netscape.com>
    Mohammed J. Kabir   <kabir@intevo.com>
    Terry Ewing         <terry@intevo.com>
    Tim Fries           <timf@dicecorp.com>
    Joe Thomas          <jthomas@women.com>
    Paul Makepeace      <Paul.Makepeace@realprogrammers.com>
    Raphael Manfredi    <Raphael_Manfredi@pobox.com>
    Lee Lindley         <Lee.Lindley@bigfoot.com>
    Dave Rolsky         <autarch@urth.org>
    Steve Bertrand      <steveb@cpan.org>

=head1 SEE ALSO

L<perltie>, L<Storable>, C<shmget>, C<ipcs>, C<ipcrm> and other SysV IPC manual
pages.
