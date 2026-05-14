use warnings;
use strict;

use Test::More;

#plan skip_all => "TEST FILE NOT READY";

use IPC::Shareable;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

{
    # exclusive duplicate

    my $opts = {
        key       => 1234,
        create    => 1,
        exclusive => 1,
        destroy   => 1,
        mode      => 0600,
        size      => 999,
    };

    my $s = tie my %opt_test => 'IPC::Shareable', $opts;
    $opt_test{a} = 1;


    is
        eval {
            my $s = tie my %opt_test => 'IPC::Shareable', $opts;
            1;
        },
        undef,
        "trying to re-create an existing memory segment fails";

    like $@, qr/ERROR:.*File exists/, "...and error message is sane";

}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
