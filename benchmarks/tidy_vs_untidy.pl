use warnings;
use strict;
use feature 'say';

use Benchmark qw(:all);
use Data::Dumper;
use IPC::Shareable;

if (@ARGV < 1) {
    print "\nNeed test count argument...\n\n";
    exit;
}

cmpthese($ARGV[0],
    {
        tidy    => \&tidy,
        untidy  => \&untidy,
    }
);

sub tidy {
    my %test_data = (
        a => {
            a => 1,
            b => 2,
            c => 3,
            d => {
                z => 26,
                y => {
                    yy => 25,
                },
            },
        }
    );

    tie my %h, 'IPC::Shareable', {create => 1, destroy => 1, tidy => 1};

    $h{a} = {a => 1, b => 2};
    $h{a} = {a => 1, b => 2, c => 3};
    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26}};
    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};
    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};

    IPC::Shareable->clean_up_all;
}

sub untidy {
    my %test_data = (
        a => {
            a => 1,
            b => 2,
            c => 3,
            d => {
                z => 26,
                y => {
                    yy => 25,
                },
            },
        }
    );

    tie my %h, 'IPC::Shareable', {create => 1, destroy => 1, tidy => 0};

    $h{a} = {a => 1, b => 2};
    $h{a} = {a => 1, b => 2, c => 3};
    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26}};
    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};
    $h{a} = {a => 1, b => 2, c => 3, d => {z => 26, y => {yy => 25}}};

    IPC::Shareable->clean_up_all;
}

__END__
        Rate   tidy untidy
tidy   197/s     --    -5%
untidy 208/s     5%     --

