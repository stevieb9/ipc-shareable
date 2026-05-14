use strict;
use warnings;

use Data::Dumper;
use Test::More;
use IPC::Shareable;

#BEGIN {
#    if (! $ENV{CI_TESTING}) {
#        plan skip_all => "Not on a legit CI platform...";
#    }
#}

my $segs_before = IPC::Shareable::ipcs();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

my $mod = 'IPC::Shareable';

# serializer: storable
{
    my $knot = tie my %hv, $mod, {
        create     => 1,
        key        => 1234,
        destroy    => 1,
        # serializer => 'json',
        #    persist => 1
    };

    my %check;
    my (@k, @v, %used);

    for (0 .. 9) {
        my $n;

        do {
            $n = int(rand(26));
        } while (exists $used{$n});

        $used{$n} ++;

        push @k, ('a' .. 'z')[$n];
        push @v, ('A' .. 'Z')[$n];
    }
    @check{@k} = @v;

    while (my ($k, $v) = each %check) {
        $hv{$k} = $v;
    }

    is keys(%hv), 10, "hv has proper number of keys";

    while (my ($k, $v) = each %check) {
        is $hv{$k}, $v, "check hash $k matches hv val $v";
    }

    # --- EXISTS

    $hv{there} = undef;
    is exists($hv{there}), 1, "exists() works ok";
    is defined($hv{there}), '', "defined with undef val ok";

    # --- DELETE
    $hv{there}->{here} = 'yes';
    is $hv{there}->{here}, 'yes', "hv there is ok";
    $hv{there}->{here} = 'no';
    is $hv{there}->{here}, 'no', "hv there is ok again";

    $hv{there} = 'yes';
    is $hv{there}, 'yes', "hv there is ok";
    is defined($hv{there}), 1, "defined with val ok";
    $hv{there} = 'no';
    is $hv{there}, 'no', "hv there is ok again";
    delete $hv{there};

    is exists($hv{there}), '', "delete removes hash key and value";

    # --- CLEAR
    %hv = ();

    is keys(%hv), 0, "clearing a hash works ok";
    #is exists($hv{__ipc}), 1, "__ipc__ key still exists";


    IPC::Shareable->clean_up_all;

    is % hv, '', "hash deleted after clean_up()";
}

# serializer: json
{
    my $knot = tie my %hv, $mod, {
        create     => 1,
        key        => 1234,
        destroy    => 1,
        serializer => 'json',
        #    persist => 1
    };

    my %check;
    my (@k, @v, %used);

    for (0 .. 9) {
        my $n;

        do {
            $n = int(rand(26));
        } while (exists $used{$n});

        $used{$n} ++;

        push @k, ('a' .. 'z')[$n];
        push @v, ('A' .. 'Z')[$n];
    }
    @check{@k} = @v;

    while (my ($k, $v) = each %check) {
        $hv{$k} = $v;
    }

    is keys(%hv), 10, "json: hv has proper number of keys";

    while (my ($k, $v) = each %check) {
        is $hv{$k}, $v, "json: check hash $k matches hv val $v";
    }

    # --- EXISTS

    $hv{there} = undef;
    is exists($hv{there}), 1, "json: exists() works ok";
    is defined($hv{there}), '', "json: defined with undef val ok";

    # --- DELETE
    $hv{there}->{here} = 'yes';
    is $hv{there}->{here}, 'yes', "json: hv there is ok";
    $hv{there}->{here} = 'no';
    is $hv{there}->{here}, 'no', "json: hv there is ok again";

    $hv{there} = 'yes';
    is $hv{there}, 'yes', "json: hv there is ok";
    is defined($hv{there}), 1, "json: defined with val ok";
    $hv{there} = 'no';
    is $hv{there}, 'no', "json: hv there is ok again";
    delete $hv{there};

    is exists($hv{there}), '', "json: delete removes hash key and value";

    # --- CLEAR
    %hv = ();

    is keys(%hv), 0, "json: clearing a hash works ok";
    #is exists($hv{__ipc}), 1, "__ipc__ key still exists";

    IPC::Shareable->clean_up_all;

    is % hv, '', "hash deleted after clean_up()";
}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::ipcs();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();


