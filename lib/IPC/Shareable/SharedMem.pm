package IPC::Shareable::SharedMem;

use warnings;
use strict;

use Carp qw(carp croak confess);
use IPC::SysV qw(IPC_CREAT IPC_RMID);

our $VERSION = '1.14';

use constant {
    DEBUGGING           => ($ENV{SHM_DEBUG} || 0),
    DEFAULT_SEG_SIZE    => 1024,
};

sub new {
    my ($class, %params) = @_;

    my $self = bless {}, $class;

    if (! defined $params{key} || $params{key} !~ /^\d+$/) {
        croak "new() requires a 'key' parameter with an integer value";
    }

    $self->key($params{key});
    $self->size($params{size} || DEFAULT_SEG_SIZE);

    $self->mode($params{mode} || 0666);
    $self->flags(($params{flags} || IPC_CREAT) | $self->mode);

    $self->type($params{type});

    my $id = shmget($self->key, $self->size, $self->flags);

    defined $id or do {
        if ($! =~ /File exists/){
            my $key = $self->key;
            croak "\nERROR: IPC::Shareable::SharedMem: shmget $key: $!\n\n" .
                  "Are you using exclusive, but trying to create multiple " .
                  "instances?\n\n";
        }
        return undef;
    };

    $self->id($id);

    return $self;
}
sub id {
    my ($self, $id) = @_;

    if (defined $id) {
        if ($self->{id}) {
            warn "Can't set id() after object already instantiated";
            return $self->{id};
        }
        $self->{id} = $id;
    }
    return $self->{id};
}
sub key {
    my ($self, $key) = @_;

    if (defined $key) {
        if ($self->id) {
            croak "Can't set the 'key' attribute after object is already established";
        }

        $self->{key} = $key;
    }

    return $self->{key};
}
sub flags {
    my ($self, $flags) = @_;

    if (defined $flags) {
        if ($self->id) {
            warn "Can't set flags() after object already instantiated";
            return $self->{flags};
        }

        $self->{flags} = $flags;
    }
    return $self->{flags};
}
sub mode {
    my ($self, $mode) = @_;

    if (defined $mode) {
        if ($self->id) {
            warn "Can't set mode() after object already instantiated";
            return $self->{mode};
        }

        $self->{mode} = $mode;
    }

    return $self->{mode};
}
sub size {
    my ($self, $size) = @_;

    if (defined $size) {
        if ($self->id) {
            warn "Can't set size() after object already instantiated";
            return $self->{size};
        }
        if ($size !~ /^\d+$/) {
            croak "size() requires an integer as parameter";
        }

        $self->{size} = $size;
    }
    return $self->{size};
}
sub type {
    my ($self, $type) = @_;

    if (defined $type) {
        if ($self->id) {
            warn "Can't set type() after object already instantiated";
            return $self->{type};
        }

        $self->{type} = $type;
    }

    return $self->{type};
}
sub shmread {
    my ($self) = @_;

    my $data = '';
    shmread($self->id, $data, 0, $self->size) or return;

    # Remove \x{0} after end of string
    $data =~ s/\x00+//;

    return $data;
}
sub shmwrite {
    my($self, $data) = @_;
    return shmwrite($self->id, $data, 0, $self->size);
}
sub remove {
    my ($self) = @_;
    my $os_return_value = shmctl($self->id, IPC_RMID, 0);

    return $os_return_value eq '0 but true' ? 1 : 0;
}

1;

=head1 NAME

IPC::Shareable::SharedMem - Allows access to a shared memory segment via an
object oriented interface.

=head1 DESCRIPTION

This module provides object oriented access to a shared memory segment. Although
it can be used standalone, it was designed for use specifically within the
L<< IPC::Shareable >> library.

=for html
<a href="https://github.com/stevieb9/ipc-shareable/actions"><img src="https://github.com/stevieb9/ipc-shareable/workflows/CI/badge.svg"/></a>
<a href='https://coveralls.io/github/stevieb9/ipc-shareable?branch=master'><img src='https://coveralls.io/repos/stevieb9/ipc-shareable/badge.svg?branch=master&service=github' alt='Coverage Status' /></a>

=head1 SYNOPSIS

=head1 METHODS

=head2 new(%params)

Instantiates and returns an object that represents a shared memory segment.

Parameters (must be in key => value pairs):

=head3 key

I<< Mandatory, Integer >>: An integer that references the shared memory segment.

If this option is missing, we'll default to using C<IPC_PRIVATE>. This default
key will not allow sharing of the variable between processes.

I<Default>: C<IPC_PRIVATE>.

=head3 size

I<Optional, Integer>: An integer representing the size in bytes of the
shared memory segment. The maximum is Operating System independent.

I<Default>: 1024

=head3 flags

I<Optional, Bitwise Mask>: A bitwise mask of options logically OR'd together
with any or all of C<IPC_CREAT> (create segment if it doesn't exist),
C<IPC_EXCL> (exclusive access; if the segment already exists,
we'll C<croak>) and C<IPC_RDONLY> (create a read only segment).

See L<IPC::SysV> for further details.

I<Default>: C<IPC_CREAT> (ie. C<512>).

=head3 mode

I<Optional, Octal Integer>: An octal number representing the access permissions
for the shared memory segment. Exactly the same as a Unix file system
permissions.

I<Default>: 0666 (User RW, Group RW, World RW).

=head3 type

I<Optional, String>: The type of data that will be stored in the shared memory
segment. L<IPC::Shareable> uses C<SCALAR>, C<ARRAY> or C<HASH>.

=head2 id

Sets/gets the identification number that references the shared memory segment.

A warning will be thrown if you try to set the ID after the object is already
instantiated, and no change will occur.

=head2 key

Sets/gets the key used to identify the shared memory segment.

Setting this attribute should only be done internally. If it is sent in after
the object is already associated with a shared memory segment, we will C<croak>.

See L</key> for further details.

=head2 size

Sets/gets the size of the shared memory segment in bytes. See L</size> for
further details.

A warning will be thrown if you try to set the size after the object is already
instantiated, and no change will occur.

=head2 flags

Sets/gets the flags that the segment will be created with. See L</flags> for
details.

A warning will be thrown if you try to set the flags after the object is already
instantiated, and no change will occur.

=head2 mode

Sets/gets the access permissions. See L</mode> for further details.

A warning will be thrown if you try to set the mode after the object is already
instantiated, and no change will occur.

=head2 type

Sets/gets the type of data that will be contained in the shared memory segment.
See L</type> for details.

A warning will be thrown if you try to set the type after the object is already
instantiated, and no change will occur.

=head2 shmread

Returns the data stored in the shared memory segment.

I<Return>: The data if any is stored, empty string if no data has been stored
yet, and C<undef> if a failure to read occurs.

=head2 shmwrite($data)

Stores the serialized data to the shared memory segment.

Parameters:

    $data

I<Mandatory, String>: Typically, the a serialized data structure.

I<Return>: True on success, false on failure.

=head2 remove

Removes the shared memory segment and returns the resources to the system.

I<Return>: True (C<1>) on success, false (C<0>) on failure.

=head1 AUTHOR

Ben Sugars (bsugars@canoe.ca)

=head1 MAINTAINED BY

Steve Bertrand <steveb@cpan.org>

=head1 SEE ALSO

L<IPC::Shareable>, L<IPC::Shareable::SharedMem> L<IPC::ShareLite>
