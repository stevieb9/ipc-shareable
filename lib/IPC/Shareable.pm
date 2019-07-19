package IPC::Shareable;

use warnings;
use strict;

require 5.00503;

use Carp qw(croak confess carp);
use Data::Dumper;
#use IPC::Semaphore;
#use IPC::Shareable::SharedMem;
use IPC::ShareLite;

use IPC::SysV qw(
    IPC_PRIVATE
    IPC_CREAT
    IPC_EXCL
    IPC_NOWAIT
    SEM_UNDO
);
use Storable 0.6 qw(
    freeze
    thaw
);
use Scalar::Util;

our $VERSION = 0.61;

use constant {
    LOCK_SH     => 1,
    LOCK_EX     => 2,
    LOCK_NB     => 4,
    LOCK_UN     => 8,

    DEBUGGING   => ($ENV{SHAREABLE_DEBUG} or 0),
    SHM_BUFSIZ  =>  65536,
    SEM_MARKER  =>  0,
    SHM_EXISTS  =>  1,
};

require Exporter;
our @ISA = 'Exporter';
our @EXPORT_OK = qw(LOCK_EX LOCK_SH LOCK_NB LOCK_UN);
our %EXPORT_TAGS = (
    all     => [qw( LOCK_EX LOCK_SH LOCK_NB LOCK_UN )],
    lock    => [qw( LOCK_EX LOCK_SH LOCK_NB LOCK_UN )],
    flock   => [qw( LOCK_EX LOCK_SH LOCK_NB LOCK_UN )],
);
Exporter::export_ok_tags('all', 'lock', 'flock');

# Locking scheme copied from IPC::ShareLite -- ltl
my %semop_args = (
    (LOCK_EX),
    [
        1, 0, 0,                        # wait for readers to finish
        2, 0, 0,                        # wait for writers to finish
        2, 1, SEM_UNDO,                 # assert write lock
    ],
    (LOCK_EX|LOCK_NB),
    [
        1, 0, IPC_NOWAIT,               # wait for readers to finish
        2, 0, IPC_NOWAIT,               # wait for writers to finish
        2, 1, (SEM_UNDO | IPC_NOWAIT),  # assert write lock
    ],
    (LOCK_EX|LOCK_UN),
    [
        2, -1, (SEM_UNDO | IPC_NOWAIT),
    ],

    (LOCK_SH),
    [
        2, 0, 0,                        # wait for writers to finish
        1, 1, SEM_UNDO,                 # assert shared read lock
    ],
    (LOCK_SH|LOCK_NB),
    [
        2, 0, IPC_NOWAIT,               # wait for writers to finish
        1, 1, (SEM_UNDO | IPC_NOWAIT),  # assert shared read lock
    ],
    (LOCK_SH|LOCK_UN),
    [
        1, -1, (SEM_UNDO | IPC_NOWAIT), # remove shared read lock
    ],
);

my %default_options = (
    key       => IPC_PRIVATE,
    create    => 0,
    exclusive => 0,
    destroy   => 0,
    mode      => 0666,
    size      => SHM_BUFSIZ,
);

my %global_register;
my %process_register;

sub _trace;
sub _debug;

# --- "Magic" methods
sub TIESCALAR {
    _trace @_                                                    if DEBUGGING;
    return _tie('SCALAR', @_);
}
sub TIEARRAY {
    _trace @_                                                    if DEBUGGING;
    return _tie('ARRAY', @_);
}
sub TIEHASH {
    _trace @_                                                    if DEBUGGING;
    return _tie('HASH', @_);
}
sub STORE {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    $knot->{_data} = _thaw($knot->{_shm}) unless ($knot->{_lock});

    if ($knot->{_data_type} eq 'HASH') {
        my $key = shift;
        my $val = shift;
        _mg_tie($knot, $val) if _need_tie($val);
        $knot->{_data}->{$key} = $val;
    }
    elsif ($knot->{_data_type} eq 'ARRAY') {
        my $i   = shift;
        my $val = shift;
        _mg_tie($knot, $val) if _need_tie($val);
        $knot->{_data}->[$i] = $val;
    }
    elsif ($knot->{_data_type} eq 'SCALAR') {
        my $val = shift;
        _mg_tie($knot, $val) if _need_tie($val);
        $knot->{_data} = \$val;
    }
    else {
        croak "Variables of type $knot->{type} not supported";
    }

    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!\n";
        }
    }
    return 1;
}
sub FETCH {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    my $sid = $knot->{_shm}->shmid;

    $global_register{$sid} ||= $knot;

    my $data;
    if ($knot->{_lock} || $knot->{_iterating}) {
        $knot->{_iterating} = 0; # In case we break out
        $data = $knot->{_data};
    } else {
        $data = _thaw($knot->{_shm});
        $knot->{_data} = $data;
    }

    my $val;

    if ($knot->{_data_type} eq 'HASH') {
        if (defined $data) {
            my $key = shift;
            $val = $data->{$key};
        } else {
            return;
        }
    }
    elsif ($knot->{_data_type} eq 'ARRAY') {
        if (defined $data) {
            my $i = shift;
            $val = $data->[$i];
        } else {
            return;
        }
    }
    elsif ($knot->{_data_type} eq 'SCALAR') {
        if (defined $data) {
            $val = $$data;
        } else {
            return;
        }
    }
    else {
        croak "Variables of type $knot->{type} not supported";
    }

    if (my $inner = _is_kid($val)) {
        my $s = $inner->{_shm};
        $inner->{_data} = _thaw($s);
    }
    return $val;

}
sub CLEAR {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    if ($knot->{_data_type} eq 'HASH') {
        $knot->{_data} = { };
    }
    elsif ($knot->{_data_type} eq 'ARRAY') {
        $knot->{_data} = [ ];
    }

    else {
        croak "Attempt to clear non-aggegrate";
    }

    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
}
sub DELETE {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;
    my $key  = shift;

    $knot->{_data} = _thaw($knot->{_shm}) unless $knot->{_lock};
    my $val = delete $knot->{_data}->{$key};
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }

    return $val;
}
sub EXISTS {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;
    my $key  = shift;

    $knot->{_data} = _thaw($knot->{_shm}) unless $knot->{_lock};
    return exists $knot->{_data}->{$key};
}
sub FIRSTKEY {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;
    my $key  = shift;

    _debug "setting hash iterator on", $knot->{_shm}->id         if DEBUGGING;
    $knot->{_iterating} = 1;
    $knot->{_data} = _thaw($knot->{_shm}) unless $knot->{_lock};
    my $reset = keys %{$knot->{_data}};
    my $first = each %{$knot->{_data}};
    return $first;
}
sub NEXTKEY {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    # caveat emptor if hash was changed by another process
    my $next = each %{$knot->{_data}};
    if (not defined $next) {
        _debug "resetting hash iterator on", $knot->{_shm}->id   if DEBUGGING;
        $knot->{_iterating} = 0;
        return;
    } else {
        $knot->{_iterating} = 1;
        return $next;
    }
}
sub EXTEND {
    _trace @_                                                    if DEBUGGING;
    #XXX Noop
}
sub PUSH {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    $global_register{$knot->{_shm}->shmid} ||= $knot;
    $knot->{_data} = _thaw($knot->{_shm}, $knot->{_data}) unless $knot->{_lock};

    push @{$knot->{_data}}, @_;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        };
    }
}
sub POP {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    $knot->{_data} = _thaw($knot->{_shm}, $knot->{_data}) unless $knot->{_lock};

    my $val = pop @{$knot->{_data}};
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $val;
}
sub SHIFT {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    $knot->{_data} = _thaw($knot->{_shm}, $knot->{_data}) unless $knot->{_lock};
    my $val = shift @{$knot->{_data}};
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $val;
}
sub UNSHIFT {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    $knot->{_data} = _thaw($knot->{_shm}, $knot->{_data}) unless $knot->{_lock};
    my $val = unshift @{$knot->{_data}}, @_;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $val;
}
sub SPLICE {
    _trace @_                                                    if DEBUGGING;
    my($knot, $off, $n, @av) = @_;

    $knot->{_data} = _thaw($knot->{_shm}, $knot->{_data}) unless $knot->{_lock};
    my @val = splice @{$knot->{_data}}, $off, $n, @av;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return @val;
}
sub FETCHSIZE {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    $knot->{_data} = _thaw($knot->{_shm}) unless $knot->{_lock};
    return scalar(@{$knot->{_data}});
}
sub STORESIZE {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;
    my $n    = shift;

    $knot->{_data} = _thaw($knot->{_shm}) unless $knot->{_lock};
    $#{$knot->{_data}} = $n - 1;
    if ($knot->{_lock} & LOCK_EX) {
        $knot->{_was_changed} = 1;
    } else {
        if (! defined _freeze($knot->{_shm}, $knot->{_data})){
            croak "Could not write to shared memory: $!";
        }
    }
    return $n;
}

# --- Public methods

sub clean_up {
    _trace @_                                                    if DEBUGGING;
    my $class = shift;

    for my $seg (values %process_register) {
        next unless $seg->{attributes}->{owner} == $$;
        remove($seg);
    }
}
sub clean_up_all {
    _trace @_                                                    if DEBUGGING;
    my $class = shift;

    for my $seg (values %global_register) {
        remove($seg);
    }
}
sub remove {
    _trace @_                                                    if DEBUGGING;
    my $knot = shift;

    my $seg = $knot->{_shm};
    my $id = $seg->shmid;

    IPC::ShareLite::destroy_share($seg->{share}, 1);

    delete $process_register{$id};
    delete $global_register{$id};
}

END {
    _trace @_                                                    if DEBUGGING;
    for my $seg (values %process_register) {
        next unless $seg->{attributes}->{destroy};
        next unless $seg->{attributes}->{owner} == $$;
        remove($seg);
    }
}

# --- Private methods below
sub _freeze {
    _trace @_                                                    if DEBUGGING;
    my $seg  = shift;
    my $water = shift;

    my $ice = freeze $water;
    # Could be a large string.  No need to copy it.  substr more efficient
    substr $ice, 0, 0, 'IPC::Shareable';

    _debug "writing to shm segment ", $seg->id, ": ", $ice         if DEBUGGING;
    if (length($ice) > $seg->size) {
        croak "Length of shared data exceeds shared segment size";
    }
    $seg->store($ice);
}
sub _thaw {
    _trace @_                                                    if DEBUGGING;

    my $seg = shift;

    my $ice;
    my $fetch_ok = eval {
        $ice = $seg->fetch;
        1;
    };

    return undef if ! defined $ice || ! $fetch_ok;

    _debug "read from shm segment ", $seg->id, ": ", $ice          if DEBUGGING;

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
sub _tie {
    _trace @_                                                    if DEBUGGING;
    my $type  = shift;
    my $class = shift;
    my $opts  = _parse_args(@_);

    my $key      = _shm_key($opts);
    my $flags    = _shm_flags($opts);

    my $knot = bless {
        key          => $key,
        _iterating   => 0,
        _lock        => 0,
        _was_changed => 0,
        _data_type   => $type,
        attributes   => {%$opts},
    }, $class;

    my %seg_opts = (
        -key       => $key,
        -create    => $opts->{create},
        -destroy   => $opts->{destroy},
        -persist   => 1,
        -exclusive => $opts->{exclusive},
        -mode      => $opts->{mode},
        -flags     => $flags,
        -size      => $opts->{size},
        -data_type => $type,
    );

    my $seg = IPC::ShareLite->new(%seg_opts);

    if (! defined $seg){
        croak "ERROR: Could not create shared memory segment: $!\n";
    };

    $knot->{_shm} = $seg;
    $knot->{_data} = _thaw($seg);

    _debug "IPC::Shareable instance created:", $knot               if DEBUGGING;

    my $sid = $knot->{_shm}->shmid;

    $global_register{$sid} ||= $knot;
    $process_register{$sid} ||= $knot;

    return bless $knot;
}
sub _parse_args {
    _trace @_                                                    if DEBUGGING;
    my($proto, $opts) = @_;

    $proto = defined $proto ? $proto :  0;
    $opts  = defined $opts  ? $opts  : { %default_options };

    if (ref $proto eq 'HASH') {
        $opts = $proto;
    }
    else {
        $opts->{key} = $proto;
    }
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
    _debug "options are", $opts                                  if DEBUGGING;
    return $opts;
}
sub _shm_key {
    _trace @_                                                    if DEBUGGING;
    my $hv = shift;
    my $val = ($hv->{key} or '');

    if ($val eq '') {
        return IPC_PRIVATE;
    }
    elsif ($val =~ /^\d+$/) {
        return $val;
    }
    else {
        # XXX This only uses the first four characters
        $val = pack   'A4', $val;
        $val = unpack 'i', $val;
        return $val;
    }
}
sub _shm_flags {
    # --- Parses the anonymous hash passed to constructors; returns a list
    # --- of args suitable for passing to shmget
    _trace @_                                                    if DEBUGGING;
    my $hv = shift;
    my $flags = 0;

#    $flags |= IPC_CREAT if $hv->{create};
#    $flags |= IPC_EXCL  if $hv->{exclusive};
#    $flags |= ($hv->{mode} or 0666);

    return $flags;
}
sub _mg_tie {
    _trace @_                                                    if DEBUGGING;
    my $parent = shift;
    my $val = shift;

    # XXX How to generate a unique id ?
    my $key;
    if ($parent->{key} == IPC_PRIVATE) {
        $key = IPC_PRIVATE;
    } else {
        $key = int(rand(1_000_000));
    }

    my %opts = (
        %{$parent->{attributes}},
        key       => $key,
        exclusive => 1,
        create    => 1,
        magic     => 1,
    );

    # XXX I wish I didn't have to take a copy of data here and copy it back in
    # XXX Also, have to peek inside potential objects to see their implementation
    my $child;
    my $type = Scalar::Util::reftype( $val ) || '';

    if ($type eq "HASH") {
        my %copy = %$val;
        $child = tie %$val, 'IPC::Shareable', $key, { %opts };
        croak "Could not create inner tie" if ! $child;
        %$val = %copy;
    }
    elsif ($type eq "ARRAY") {
        my @copy = @$val;
        $child = tie @$val, 'IPC::Shareable', $key, { %opts };
        croak "Could not create inner tie" if ! $child;
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
sub _is_kid {
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
    my $val = shift;

    my $type = Scalar::Util::reftype( $val );
    return unless $type;

    if ($type eq "HASH") {
        return !(tied %$val);
    }
    elsif ($type eq "ARRAY") {
        return !(tied @$val);
    }
    elsif ($type eq "SCALAR") {
        return !(tied $$val);
    }

    return;
}

sub _trace {
    require Carp;
    require Data::Dumper;
    my $caller = '    ' . (caller(1))[3] . " called with:\n";
    my $i = -1;
    my @msg = map {
        ++$i;
        my $obj;
        if (ref eq 'IPC::Shareable') {
            '        ' . "\$_[$i] = $_: shmid: $_->{_shm}->{_id}; " .
                Data::Dumper->Dump([ $_->{attributes} ], [ 'opts' ]);
        } else {
            '        ' . Data::Dumper->Dump( [ $_ ] => [ "\_[$i]" ]);
        }
    }  @_;
    Carp::carp "IPC::Shareable ($$) debug:\n", $caller, @msg;
}
sub _debug {
    require Carp;
    require Data::Dumper;
    local $Data::Dumper::Terse = 1;
    my $caller = '    ' . (caller(1))[3] . " tells us that:\n";
    my @msg = map {
        my $obj;
        if (ref eq 'IPC::Shareable') {
            '        ' . "$_: shmid: $_->{_shm}->{_id}; " .
                Data::Dumper->Dump([ $_->{attributes} ], [ 'opts' ]);
        }
        else {
            '        ' . Data::Dumper::Dumper($_);
        }
    }  @_;
    Carp::carp "IPC::Shareable ($$) debug:\n", $caller, @msg;
};

1;

__END__

=head1 NAME

IPC::Shareable - share Perl variables between processes

=head1 SYNOPSIS

 use IPC::Shareable (':lock');
 tie SCALAR, 'IPC::Shareable', GLUE, OPTIONS;
 tie ARRAY,  'IPC::Shareable', GLUE, OPTIONS;
 tie HASH,   'IPC::Shareable', GLUE, OPTIONS;

 (tied VARIABLE)->shlock;
 (tied VARIABLE)->shunlock;

 (tied VARIABLE)->shlock(LOCK_SH|LOCK_NB)
        or print "resource unavailable\n";

 (tied VARIABLE)->remove;

 IPC::Shareable->clean_up;
 IPC::Shareable->clean_up_all;

=head1 CONVENTIONS

The occurrence of a number in square brackets, as in [N], in the text
of this document refers to a numbered note in the L</NOTES>.

=head1 DESCRIPTION

IPC::Shareable allows you to tie a variable to shared memory making it
easy to share the contents of that variable with other Perl processes.
Scalars, arrays, and hashes can be tied.  The variable being tied may
contain arbitrarily complex data structures - including references to
arrays, hashes of hashes, etc.

The association between variables in distinct processes is provided by
GLUE.  This is an integer number or 4 character string[1] that serves
as a common identifier for data across process space.  Hence the
statement

 tie $scalar, 'IPC::Shareable', 'data';

in program one and the statement

 tie $variable, 'IPC::Shareable', 'data';

in program two will bind $scalar in program one and $variable in
program two.

There is no pre-set limit to the number of processes that can bind to
data; nor is there a pre-set limit to the complexity of the underlying
data of the tied variables[2].  The amount of data that can be shared
within a single bound variable is limited by the system's maximum size
for a shared memory segment (the exact value is system-dependent).

The bound data structures are all linearized (using Raphael Manfredi's
Storable module) before being slurped into shared memory.  Upon
retrieval, the original format of the data structure is recovered.
Semaphore flags can be used for locking data between competing processes.

=head1 OPTIONS

Options are specified by passing a reference to a hash as the fourth
argument to the tie() function that enchants a variable.
Alternatively you can pass a reference to a hash as the third
argument; IPC::Shareable will then look at the field named B<key> in
this hash for the value of GLUE.  So,

 tie $variable, 'IPC::Shareable', 'data', \%options;

is equivalent to

 tie $variable, 'IPC::Shareable', { key => 'data', ... };

Boolean option values can be specified using a value that evaluates to
either true or false in the Perl sense.

NOTE: Earlier versions allowed you to use the word B<yes> for true and
the word B<no> for false, but support for this "feature" is being
removed.  B<yes> will still act as true (since it is true, in the Perl
sense), but use of the word B<no> now emits an (optional) warning and
then converts to a false value.  This warning will become mandatory in a
future release and then at some later date the use of B<no> will
stop working altogether.

The following fields are recognized in the options hash.

=over 4

=item B<key>

The B<key> field is used to determine the GLUE when using the
three-argument form of the call to tie().  This argument is then, in
turn, used as the KEY argument in subsequent calls to shmget() and
semget().

The default value is IPC_PRIVATE, meaning that your variables cannot
be shared with other processes.

=item B<create>

B<create> is used to control whether calls to tie() create new shared
memory segments or not.  If B<create> is set to a true value,
IPC::Shareable will create a new binding associated with GLUE as
needed.  If B<create> is false, IPC::Shareable will not attempt to
create a new shared memory segment associated with GLUE.  In this
case, a shared memory segment associated with GLUE must already exist
or the call to tie() will fail and return undef.  The default is
false.

=item B<exclusive>

If B<exclusive> field is set to a true value, calls to tie() will fail
(returning undef) if a data binding associated with GLUE already
exists.  If set to a false value, calls to tie() will succeed even if
a shared memory segment associated with GLUE already exists.  The
default is false

=item B<mode>

The I<mode> argument is an octal number specifying the access
permissions when a new data binding is being created.  These access
permission are the same as file access permissions in that 0666 is
world readable, 0600 is readable only by the effective UID of the
process creating the shared variable, etc.  The default is 0666 (world
readable and writable).

=item B<destroy>

If set to a true value, the shared memory segment underlying the data
binding will be removed when the process calling tie() exits
(gracefully)[3].  Use this option with care.  In particular
you should not use this option in a program that will fork
after binding the data.  On the other hand, shared memory is
a finite resource and should be released if it is not needed.
The default is false

=item B<size>

This field may be used to specify the size of the shared memory
segment allocated.  The default is IPC::Shareable::SHM_BUFSIZ().

=back

Default values for options are

 key       => IPC_PRIVATE,
 create    => 0,
 exclusive => 0,
 destroy   => 0,
 mode      => 0,
 size      => IPC::Shareable::SHM_BUFSIZ(),

=head1 LOCKING

IPC::Shareable provides methods to implement application-level
advisory locking of the shared data structures.  These methods are
called shlock() and shunlock().  To use them you must first get the
object underlying the tied variable, either by saving the return
value of the original call to tie() or by using the built-in tied()
function.

To lock a variable, do this:

 $knot = tie $sv, 'IPC::Shareable', $glue, { %options };
 ...
 $knot->shlock;

or equivalently

 tie($scalar, 'IPC::Shareable', $glue, { %options });
 (tied $scalar)->shlock;

This will place an exclusive lock on the data of $scalar.  You can
also get shared locks or attempt to get a lock without blocking.
IPC::Shareable makes the constants LOCK_EX, LOCK_SH, LOCK_UN, and
LOCK_NB exportable to your address space with the export tags
C<:lock>, C<:flock>, or C<:all>.  The values should be the same as
the standard C<flock> option arguments.

 if ( (tied $scalar)->shlock(LOCK_SH|LOCK_NB) ) {
        print "The value is $scalar\n";
        (tied $scalar)->shunlock;
 } else {
        print "Another process has an exlusive lock.\n";
 }


If no argument is provided to C<shlock>, it defaults to LOCK_EX.  To
unlock a variable do this:

 $knot->shunlock;

or

 (tied $scalar)->shunlock;

or

 $knot->shlock(LOCK_UN);        # Same as calling shunlock

There are some pitfalls regarding locking and signals about which you
should make yourself aware; these are discussed in L</NOTES>.

If you use the advisory locking, IPC::Shareable assumes that you know
what you are doing and attempts some optimizations.  When you obtain
a lock, either exclusive or shared, a fetch and thaw of the data is
performed.  No additional fetch/thaw operations are performed until
you release the lock and access the bound variable again.  During the
time that the lock is kept, all accesses are perfomed on the copy in
program memory.  If other processes do not honor the lock, and update
the shared memory region unfairly, the process with the lock will not be in
sync.  In other words, IPC::Shareable does not enforce the lock
for you.

A similar optimization is done if you obtain an exclusive lock.
Updates to the shared memory region will be postponed until you
release the lock (or downgrade to a shared lock).

Use of locking can significantly improve performance for operations
such as iterating over an array, retrieving a list from a slice or
doing a slice assignment.

=head1 REFERENCES

When a reference to a non-tied scalar, hash, or array is assigned to a
tie()d variable, IPC::Shareable will attempt to tie() the thingy being
referenced[4].  This allows disparate processes to see changes to not
only the top-level variable, but also changes to nested data.  This
feature is intended to be transparent to the application, but there
are some caveats to be aware of.

First of all, IPC::Shareable does not (yet) guarantee that the ids
shared memory segments allocated automagically are unique.  The more
automagical tie()ing that happens, the greater the chance of a
collision.

Secondly, since a new shared memory segment is created for each thingy
being referenced, the liberal use of references could cause the system
to approach its limit for the total number of shared memory segments
allowed.

=head1 OBJECTS

IPC::Shareable implements tie()ing objects to shared memory too.
Since an object is just a reference, the same principles (and caveats)
apply to tie()ing objects as other reference types.

=head1 DESTRUCTION

perl(1) will destroy the object underlying a tied variable when then
tied variable goes out of scope.  Unfortunately for IPC::Shareable,
this may not be desirable: other processes may still need a handle on
the relevant shared memory segment.  IPC::Shareable therefore provides
an interface to allow the application to control the timing of removal
of shared memory segments.  The interface consists of three methods -
remove(), clean_up(), and clean_up_all() - and the B<destroy> option
to tie().

=over 4

=item B<destroy option>

As described in L</OPTIONS>, specifying the B<destroy> option when
tie()ing a variable coerces IPC::Shareable to remove the underlying
shared memory segment when the process calling tie() exits gracefully.
Note that any related shared memory segments created automagically by
the use of references will also be removed.

=item B<remove()>

 (tied $var)->remove;

Calling remove() on the object underlying a tie()d variable removes
the associated shared memory segment.  The segment is removed
irrespective of whether it has the B<destroy> option set or not and
irrespective of whether the calling process created the segment.

=item B<clean_up()>

 IPC::Shareable->clean_up;

This is a class method that provokes IPC::Shareable to remove all
shared memory segments created by the process.  Segments not created
by the calling process are not removed.

=item B<clean_up_all()>

 IPC::Shareable->clean_up_all;

This is a class method that provokes IPC::Shareable to remove all
shared memory segments encountered by the process.  Segments are
removed even if they were not created by the calling process.

=back

=head1 EXAMPLES

In a file called B<server>:

 #!/usr/bin/perl -w
 use strict;
 use IPC::Shareable;
 my $glue = 'data';
 my %options = (
     create    => 1,
     exclusive => 0,
     mode      => 0644,
     destroy   => 1,
 );
 my %colours;
 tie %colours, 'IPC::Shareable', $glue, { %options } or
     die "server: tie failed\n";
 %colours = (
     red => [
         'fire truck',
         'leaves in the fall',
     ],
     blue => [
         'sky',
         'police cars',
     ],
 );
 ((print "server: there are 2 colours\n"), sleep 5)
     while scalar keys %colours == 2;
 print "server: here are all my colours:\n";
 foreach my $c (keys %colours) {
     print "server: these are $c: ",
         join(', ', @{$colours{$c}}), "\n";
 }
 exit;

In a file called B<client>

 #!/usr/bin/perl -w
 use strict;
 use IPC::Shareable;
 my $glue = 'data';
 my %options = (
     create    => 0,
     exclusive => 0,
     mode      => 0644,
     destroy   => 0,
     );
 my %colours;
 tie %colours, 'IPC::Shareable', $glue, { %options } or
     die "client: tie failed\n";
 foreach my $c (keys %colours) {
     print "client: these are $c: ",
         join(', ', @{$colours{$c}}), "\n";
 }
 delete $colours{'red'};
 exit;

And here is the output (the sleep commands in the command line prevent
the output from being interrupted by shell prompts):

 bash$ ( ./server & ) ; sleep 10 ; ./client ; sleep 10
 server: there are 2 colours
 server: there are 2 colours
 server: there are 2 colours
 client: these are blue: sky, police cars
 client: these are red: fire truck, leaves in the fall
 server: here are all my colours:
 server: these are blue: sky, police cars

=head1 RETURN VALUES

Calls to tie() that try to implement IPC::Shareable will return true
if successful, I<undef> otherwise.  The value returned is an instance
of the IPC::Shareable class.

=head1 AUTHOR

Benjamin Sugars <bsugars@canoe.ca>

=head1 NOTES

=head2 Footnotes from the above sections

=over 4

=item 1

If GLUE is longer than 4 characters, only the 4 most significant
characters are used.  These characters are turned into integers by
unpack()ing them.  If GLUE is less than 4 characters, it is space
padded.

=item 2

IPC::Shareable provides no pre-set limits, but the system does.
Namely, there are limits on the number of shared memory segments that
can be allocated and the total amount of memory usable by shared
memory.

=item 3

If the process has been smoked by an untrapped signal, the binding
will remain in shared memory.  If you're cautious, you might try

 $SIG{INT} = \&catch_int;
 sub catch_int {
     die;
 }
 ...
 tie $variable, IPC::Shareable, 'data', { 'destroy' => 'Yes!' };

which will at least clean up after your user hits CTRL-C because
IPC::Shareable's END method will be called.  Or, maybe you'd like to
leave the binding in shared memory, so subsequent process can recover
the data...

=item 4

This behaviour is markedly different from previous versions of
IPC::Shareable.  Older versions would sometimes tie() referenced
thingies, and sometimes not.  The new approach is more reliable (I
think) and predictable (certainly) but uses more shared memory
segments.

=back

=head2 General Notes

=over 4

=item o

When using shlock() to lock a variable, be careful to guard against
signals.  Under normal circumstances, IPC::Shareable's END method
unlocks any locked variables when the process exits.  However, if an
untrapped signal is received while a process holds an exclusive lock,
DESTROY will not be called and the lock may be maintained even though
the process has exited.  If this scares you, you might be better off
implementing your own locking methods.

One advantage of using C<flock> on some known file instead of the
locking implemented with semaphores in IPC::Shareable is that when a
process dies, it automatically releases any locks.  This only happens
with IPC::Shareable if the process dies gracefully.  The alternative
is to attempt to account for every possible calamitous ending for your
process (robust signal handling in Perl is a source of much debate,
though it usually works just fine) or to become familiar with your
system's tools for removing shared memory and semaphores.  This
concern should be balanced against the significant performance
improvements you can gain for larger data structures by using the
locking mechanism implemented in IPC::Shareable.

=item o

There is a program called ipcs(1/8) (and ipcrm(1/8)) that is
available on at least Solaris and Linux that might be useful for
cleaning moribund shared memory segments or semaphore sets produced
by bugs in either IPC::Shareable or applications using it.

=item o

This version of IPC::Shareable does not understand the format of
shared memory segments created by versions prior to 0.60.  If you try
to tie to such segments, you will get an error.  The only work around
is to clear the shared memory segments and start with a fresh set.

=item o

Iterating over a hash causes a special optimization if you have not
obtained a lock (it is better to obtain a read (or write) lock before
iterating over a hash tied to Shareable, but we attempt this
optimization if you do not).  The fetch/thaw operation is performed
when the first key is accessed.  Subsequent key and and value
accesses are done without accessing shared memory.  Doing an
assignment to the hash or fetching another value between key
accesses causes the hash to be replaced from shared memory.  The
state of the iterator in this case is not defined by the Perl
documentation.  Caveat Emptor.

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

=head1 BUGS

Certainly; this is beta software. When you discover an anomaly, send
an email to me at bsugars@canoe.ca.

=head1 SEE ALSO

perl(1), perltie(1), Storable(3), shmget(2), ipcs(1), ipcrm(1)
and other SysV IPC man pages.

=cut

