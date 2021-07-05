use warnings;
use strict;

use IPC::Shareable;
use Test::Exception;
use Test::More;

my $k = tie my $sv, 'IPC::Shareable', {
    create => 1,
    destroy => 1,
    size => 1,
};

throws_ok
    { $sv = "more than one byte"; } qr/exceeds shared segment size/,
    "We croak if we exceed the segment size";

(tied $sv)->clean_up_all;

done_testing();
