use warnings;
use strict;

use IPC::Shareable;
use Test::More;

use constant BYTES => 2000000; # ~2MB

# limit
{
    my $size_ok_limit = eval {
        tie my $var, 'IPC::Shareable', {
            create  => 1,
            size    => 2_000_000_000,
            destroy => 1
        };
        1;
    };

    is $size_ok_limit, undef, "size larger than MAX croaks ok";
    like $@, qr/larger than max size/, "...and error is sane";

    if ($ENV{IPC_MEM}) {
        my $size_ok_no_limit = eval {
            tie my $var, 'IPC::Shareable', {
                limit   => 0,
                create  => 1,
                size    => 2_000_000_000,
                destroy => 1
            };
            1;
        };

        is $size_ok_no_limit, 1, "size larger than MAX succeeeds with limit=>0 ok";
    }
    else {
        warn "IPC_MEM env var not set, skipped the big memory test\n";
    }
}

{
    my $size_ok = eval {
        tie my $var, 'IPC::Shareable', {
            limit   => 0,
            size    => 999999999999,
            destroy => 1
        };
        1;
    };

    is $size_ok, undef, "We croak if size is greater than max RAM";

    if ($^O eq 'linux') {
        like $@, qr/Cannot allocate memory/, "...and error is sane";
    }
    else {
        like $@, qr/Invalid argument/, "...and error is sane";
    }
}

my $k = tie my $sv, 'IPC::Shareable', {
    create => 1,
    destroy => 1,
    size => BYTES,
};

my $seg = $k->seg;

my $id   = $seg->id;
my $size = $seg->size;

my $actual_size;

if ($^O eq 'linux') {
    my $record = `ipcs -m -i $id`;
    $actual_size = 0;

    if ($record =~ /bytes=(\d+)/s) {
        $actual_size = $1;
    }
}
else {
    $actual_size = 0;
}

is BYTES, $size, "size param is the same as the segment size";

# ipcs -i doesn't work on MacOS or FreeBSD, so skip it for now

TODO: {
    local $TODO = 'Not yet working on FreeBSD or macOS';
};

# ...and only run it on Linux systems

if ($^O eq 'linux') {
    is $size, $actual_size, "actual size in bytes ok if sending in custom size";
}

$k->clean_up_all;

done_testing();
