use warnings;
use strict;

use Data::Dumper;
use IPC::Shareable;
use Test::More;

# deprecated string key param
{
    my $ok = eval {
        tie my $sv, 'IPC::Shareable', 'TEST', {create => 1, destroy => 1};
        1;
    };

    is $ok, 1, "IPC::Shareable accepts old string way of sending in key";
    is $@, '', "...and no error message was set";
}


# shm key matches object key
{
    tie my $sv, 'IPC::Shareable', 'TEST', {create => 1, destroy => 1};
    is((tied $sv)->seg->key, (tied $sv)->seg->key, "Object key matches segment key ok");
}

# three letter caps
{
    my $k = tie my $sv, 'IPC::Shareable', {key => 'TES', create => 1, destroy => 1};

    is $k->{attributes}{key}, 'TES', "attr key is TES ok";
    is $k->seg->key, 3952665712, "three letter attr key is  ok";
}

# four letter caps
{
    my $k = tie my $sv, 'IPC::Shareable', {key => 'TEST', create => 1, destroy => 1};

    is $k->{attributes}{key}, 'TEST', "attr key is TEST ok";
    is $k->seg->key, 4008350648, "four letter attr key is ok";
}

# three letter lower case
{
    my $k = tie my $sv, 'IPC::Shareable', {key => 'tes', create => 1, destroy => 1};

    is $k->{attributes}{key}, 'tes', "3 letter lower case key is tes ok";
    is $k->seg->key, 2101323514, "3 letter lower case attr key is ok";
}

# six letter
{
    my $k = tie my $sv, 'IPC::Shareable', {key => 'tested', create => 1, destroy => 1};

    is $k->{attributes}{key}, 'tested', "six letter attr key is tested ok";
    is $k->seg->key, 142926612, "six letter attr key is ok";
}

# filenames
{
    my %key_hash = (
        'test/this.pl'          => 2780677640,
        'test/this.plx'         => 2191663991,
        'test/that.pl'          => 135968112,
        'test/testing/this.pl'  => 1718888502,
    );

    for (keys %key_hash) {

        my $k = tie my $sv, 'IPC::Shareable', {key => $_, create => 1, destroy => 1};

        is $k->attributes('key'), $_, "$_ as key is the proper attribute ok";

        my $key = $k->seg->key;
        is $key, $key_hash{$_}, "...and key $_ converted to '$key' ok";

        $k->clean_up_all;
    }
}

done_testing();
