use warnings;
use strict;

use Carp;
use Data::Dumper;
use IPC::Shareable;
use Test::More;

my $segs_before = IPC::Shareable::shm_count();
warn "Segs Before: $segs_before\n" if $ENV{PRINT_SEGS};

# serializer: storable
{
    # scalar ref
    tie my $sv, 'IPC::Shareable', { destroy => 1 };

    my $ref = 'ref';
    $sv = \$ref;

    is $$sv, $ref, "storable: SV can be assigned a reference to another scalar";

    # array ref

    $sv = [ 0 .. 9 ];
    is ref($sv), 'ARRAY', "storable: SV contains an aref ok";

    for (0 .. 9) {
        is $sv->[$_], $_, "storable: SV aref elem $_ ok";
    }

    # hash ref

    my %check;

    my @k = map { ('a' .. 'z')[int(rand(26))] } (0 .. 9);
    my @v = map { ('A' .. 'Z')[int(rand(26))] } (0 .. 9);
    @check{@k} = @v;

    $sv = { %check };
    is ref($sv), 'HASH', "storable: SV contains an href ok";

    while (my($k, $v) = each %check) {
        is $sv->{$k}, $v, "storable: SV href key $k contains value $v ok";
    }

    # multiple refs

    tie my @av, 'IPC::Shareable';

    $av[0] = { foo => 'bar', baz => 'bash' };
    $av[1] = [ 0 .. 9 ];

    is ref($av[0]), 'HASH',  "storable: AV elem 0 is a hash";
    is ref($av[1]), 'ARRAY', "storable: AV elem 1 is an array";

    is $av[0]->{foo}, 'bar',  "storable: AV->HV contains valid value in key 'foo'";
    is $av[0]->{baz}, 'bash', "storable: AV->HV contains valid value in key 'baz'";

    for (0 .. 9) {
        is $av[1]->[$_], $_, "storable: AV[1]->[$_] == $_ ok";
    }

    tie my %hv, 'IPC::Shareable';

    for ('a' .. 'z') {
        $hv{lower}->{$_} = $_;
        $hv{upper}->{$_} = uc;
    }

    for ('a' .. 'z') {
        is $hv{lower}->{$_}, $_, "storable: HV{lower}{$_} set to $_ ok";
        is $hv{upper}->{$_}, uc $_, "storable: HV{upper}{$_} set to uppercase $_ ok";
    }

    IPC::Shareable->clean_up_all;

    # deeply nested

    tie $sv, 'IPC::Shareable', { serializer => 'storable', destroy => 1 };

    $sv->{this}->{is}->{nested}->{deeply}->[0]->[1]->[2] = 'found';

    is
        $sv->{this}->{is}->{nested}->{deeply}->[0]->[1]->[2],
        'found',
        "storable: crazy deep nested struct ok";

    IPC::Shareable->clean_up_all;
}

# serializer: json
{
    # scalar ref
    tie my $sv, 'IPC::Shareable', { serializer => 'json', destroy => 1 };

    my $ref = 'ref';
    $sv = \$ref;

    is $$sv, $ref, "json: SV can be assigned a reference to another scalar";

    # array ref

    $sv = [ 0 .. 9 ];
    is ref($sv), 'ARRAY', "json: SV contains an aref ok";

    for (0 .. 9) {
        is $sv->[$_], $_, "json: SV aref elem $_ ok";
    }

    # hash ref

    my %check;

    my @k = ('a' .. 'j');
    my @v = ('A' .. 'J');
    @check{@k} = @v;

    $sv = { %check };
    is ref($sv), 'HASH', "json: SV contains an href ok";

    for my $k (@k) {
        is $sv->{$k}, $check{$k}, "json: SV href key $k ok";
    }

    # multiple refs via array tie

    tie my @av, 'IPC::Shareable', { serializer => 'json', destroy => 1 };

    $av[0] = { foo => 'bar', baz => 'bash' };
    $av[1] = [ 0 .. 9 ];

    is ref($av[0]), 'HASH',  "json: AV elem 0 is a hash";
    is ref($av[1]), 'ARRAY', "json: AV elem 1 is an array";

    is $av[0]->{foo}, 'bar',  "json: AV->HV contains valid value in key 'foo'";
    is $av[0]->{baz}, 'bash', "json: AV->HV contains valid value in key 'baz'";

    for (0 .. 9) {
        is $av[1]->[$_], $_, "json: AV[1]->[$_] == $_ ok";
    }

    tie my %hv, 'IPC::Shareable', { serializer => 'json', destroy => 1 };

    for ('a' .. 'z') {
        $hv{lower}->{$_} = $_;
        $hv{upper}->{$_} = uc;
    }

    for ('a' .. 'z') {
        is $hv{lower}->{$_}, $_, "json: HV{lower}{$_} set to $_ ok";
        is $hv{upper}->{$_}, uc $_, "json: HV{upper}{$_} set to uppercase $_ ok";
    }

    IPC::Shareable->clean_up_all;

    # deeply nested via hash tie

    tie my %dh, 'IPC::Shareable', { serializer => 'json', destroy => 1 };

    $dh{this}{is}{nested}{deeply}[0][1][2] = 'found';

    is
        $dh{this}{is}{nested}{deeply}[0][1][2],
        'found',
        "json: crazy deep nested struct ok";

    IPC::Shareable->clean_up_all;
}

IPC::Shareable::_end;

my $segs_after = IPC::Shareable::shm_count();
warn "Segs After: $segs_after\n" if $ENV{PRINT_SEGS};
is $segs_after, $segs_before, "All segs cleaned up ok";

done_testing();
