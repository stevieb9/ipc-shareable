use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Mock::Sub;
use Test::More;

BEGIN {
    if (! $ENV{CI_TESTING}) {
        plan skip_all => "Not on a legit CI platform...";
    }
}

warn "Segs Before: " . IPC::Shareable::ipcs() . "\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable::SharedMem';

# new()
{
    # croak on no key param

    {
        my $seg;
        my $ok = eval { $seg = $mod->new; 1; };
        is $ok, undef, "new() equires a 'key' parameter with value";
        like $@, qr/new\(\) requires a 'key'/, "...and error is sane";
    }

    # croak on non-integer key

    {
        my $seg;
        my $ok = eval { $seg = $mod->new(key => 'aaaa'); 1; };
        is $ok, undef, "'key' param must be integer";
        like $@, qr/with an integer value/, "...and error is sane";
    }

    # Success: check defaults

    {
        my $seg;
        my $ok = eval { $seg = $mod->new(key => 9999); 1; };
        is $ok, 1, "segment object created ok";
        is ref $seg, 'IPC::Shareable::SharedMem', "object is of proper type ok";

        is $seg->key, 9999, "key attr set ok";
        is $seg->size, 1024, "size attr default ok";
        is $seg->flags, 512, "flags attr default ok";
        is $seg->type, undef, "type defaults to undef ok";
        like $seg->id, qr/^\d+$/, "id is an integer ok";

        is $seg->remove, 1, "segment removed ok";
    }
}

# size()
{
    # Object already instantiated warning

    {

        my $warning;
        local $SIG{__WARN__} = sub { $warning = shift; };

        my $seg = $mod->new(key => 9999);
        $seg->size(2048);
        like $warning, qr/instantiated/, "size() warns that it can't be set after obj created";
        is $seg->size, 1024, "...and it hasn't been changed ok";

        is $seg->remove, 1, "seg cleaned up ok";
    }

    # Invalid type

    {
        my $seg;
        my $ok = eval { $seg = $mod->new(key => 9999, size => 'aaaa'); 1; };
        is $ok, undef, "size() requires an integer";
        like $@, qr/size\(\) requires an integer/, "...and error is sane";
    }
}

# flags()
{
    # Object already instantiated warning

    {

        my $warning;
        local $SIG{__WARN__} = sub { $warning = shift; };

        my $seg = $mod->new(key => 9999);
        $seg->flags(1024);
        like $warning, qr/instantiated/, "flags() warns that it can't be set after obj created";
        is $seg->flags, 512, "...and it hasn't been changed ok";

        is $seg->remove, 1, "seg cleaned up ok";
    }
}

# type()
{
    # Object already instantiated warning

    {

        my $warning;
        local $SIG{__WARN__} = sub { $warning = shift; };

        my $seg = $mod->new(key => 9999, type => 'TESTING');
        $seg->type('HELLO');
        like $warning, qr/instantiated/, "type() warns that it can't be set after obj created";
        is $seg->type, 'TESTING', "...and it hasn't been changed ok";

        is $seg->remove, 1, "seg cleaned up ok";
    }
}

# id()
{
    # Object already instantiated warning

    {
        my $warning;
        local $SIG{__WARN__} = sub { $warning = shift; };

        my $seg = $mod->new(key => 9999);
        my $created_id = $seg->id;

        $seg->id(9998);

        like $warning, qr/instantiated/, "id() warns that it can't be set after obj created";
        is $seg->id, $created_id, "...and it hasn't been changed ok";

        is $seg->remove, 1, "seg cleaned up ok";
    }
}
warn "Segs After: " . IPC::Shareable::ipcs() . "\n" if $ENV{PRINT_SEGS};

done_testing();
