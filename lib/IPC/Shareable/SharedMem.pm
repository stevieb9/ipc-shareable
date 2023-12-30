package IPC::Shareable::SharedMem;

use warnings;
use strict;

use Carp qw(carp croak confess);
use IPC::SysV qw(IPC_RMID);

our $VERSION = '1.14';

use constant DEBUGGING => ($ENV{SHM_DEBUG} or 0);

my $default_size = 1024;

sub default_size {
    my $class = shift;
    $default_size = shift if @_;
    return $default_size;
}

sub new {
    my ($class, $key, $size, $flags, $type) = @_;

    defined $key or do {
        confess "usage: IPC::SharedMem->new(KEY, [ SIZE,  [ FLAGS ] ])";
    };

    $size  ||= $default_size;
    $flags ||= 0;

    my $id = shmget($key, $size, $flags);

    defined $id or do {
        if ($! =~ /File exists/){
            croak "\nERROR: IPC::Shareable::SharedMem: shmget $key: $!\n\n" .
                  "Are you using exclusive, but trying to create multiple " .
                  "instances?\n\n";
        }
        return undef;
    };

    my $sh = {
        _id    => $id,
        _key   => $key,
        _size  => $size,
        _flags => $flags,
        _type  => $type,
    };

    return bless $sh => $class;
}
sub id {
    my $self = shift;

    $self->{_id} = shift if @_;
    return $self->{_id};
}
sub key {
    my $self = shift;

    $self->{_key} = shift if @_;
    return $self->{_key};
}
sub flags {
    my $self = shift;

    $self->{_flags} = shift if @_;
    return $self->{_flags};
}
sub size {
    my $self = shift;

    $self->{_size} = shift if @_;
    return $self->{_size};
}
sub type {
    my $self = shift;

    $self->{_type} = shift if @_;
    return $self->{_type};
}
sub shmwrite {
    my($self, $data) = @_;
    return shmwrite($self->{_id}, $data, 0, $self->{_size});
}
sub shmread {
    my $self = shift;

    my $data = '';
    shmread($self->{_id}, $data, 0, $self->{_size}) or return;
    return $data;
}
sub remove {
    my $to_remove = shift;

    my $id;

    if (ref $to_remove eq __PACKAGE__){
        $id = $to_remove->{_id};
    }

    my $arg = 0;

    my $ret = shmctl($id, IPC_RMID, $arg);
    return $ret;
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

=head2 new($key, $size, $flags, $type)

Instantiates and returns an object that represents a shared memory segment.

Parameters:

    $key

I<< Mandatory, Integer >>: An integer that references the shared memory segment.

If this option is missing, we'll default to using C<IPC_PRIVATE>. This default
key will not allow sharing of the variable between processes.

I<Default>: C<IPC_PRIVATE>.

    $size

I<Optional, Integer>: An integer representing the size in bytes of the
shared memory segment. The maximum is Operating System independent.

I<Default>: 1024

    $flags

I<Optional, Bitwise Mask>: A bitwise mask of options logically OR'd together
with any or all of C<IPC_CREAT> (create segment if it doesn't exist),
C<IPC_EXCL> (exclusive access; if the segment already exists,
we'll C<croak>) and C<IPC_RDONLY> (create a read only segment).

See L<IPC::SysV> for further details.

I<Default>: C<IPC_CREAT> (ie. C<512>).

    $type

I<Optional, String>: The type of data that will be stored in the shared memory
segment. Must be one of C<SCALAR>, C<ARRAY> or C<HASH>.


=head1 AUTHOR

Ben Sugars (bsugars@canoe.ca)

=head1 MAINTAINED BY

Steve Bertrand <steveb@cpan.org>

=head1 SEE ALSO

L<IPC::Shareable>, L<IPC::ShareLite>
