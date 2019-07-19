#!/usr/bin/env perl
use warnings;
use strict;

use Benchmark qw(:all) ;
use IPC::Shareable;
use Sereal qw(encode_sereal decode_sereal looks_like_sereal);
use Storable qw(freeze thaw);

if (@ARGV < 1){
    print "\n Need test count argument...\n\n";
    exit;
}

my $timethis = 1;
my $timethese = 0;
my $cmpthese = 0;

if ($timethis) {
    #timethis($ARGV[0], \&storable);
    timethis($ARGV[0], \&sereal);
}

if ($timethese) {
    timethese($ARGV[0],
        {
            'sereal' => \&sereal,
            'store ' => \&storable,
        },
    );
}

if ($cmpthese) {
    cmpthese($ARGV[0],
        {
            'sereal' => \&sereal,
            'store ' => \&storable,
        },
    );
}

sub default {
     return {
        a => 1,
        b => 2,
        c => [qw(1 2 3)],
        d => {z => 26, y => 25},
    };
}

sub sereal {
    my $base_data = default();

    tie my %hash, 'IPC::Shareable', 'sere', {
        create  => 1,
        destroy => 1
    };

    %hash = %$base_data;

    $hash{struct} = {a => [qw(b c d)]};

    tied(%hash)->clean_up_all;

}
sub storable {
    my $base_data = default();

    tie my %hash, 'IPC::Shareable', 'stor', {
        create  => 1,
        destroy => 1
    };

    %hash = %$base_data;

    $hash{struct} = {a => [qw(b c d)]};

    tied(%hash)->clean_up_all;
}

__END__

Benchmark: timing 3000000 iterations of sereal, store ...
    sereal: 12 wallclock secs (13.11 usr +  0.00 sys = 13.11 CPU) @ 228832.95/s (n=3000000)
    store : 32 wallclock secs (31.02 usr +  0.00 sys = 31.02 CPU) @ 96711.80/s (n=3000000)
           Rate store  sereal
store  105374/s     --   -55%
sereal 231660/s   120%     --

# timethis (0.61)
timethis 30000: 53 wallclock secs (31.66 usr + 21.34 sys = 53.00 CPU) @ 566.04/s (n=30000)

# timethis (sereal)
timethis 30000: 56 wallclock secs (30.35 usr + 25.87 sys = 56.22 CPU) @ 533.62/s (n=30000)


### full tests ###

# perl -v
# This is perl 5, version 30, subversion 0 (v5.30.0) built for x86_64-linux

### 0.61 (on dev VPS)

# perl -MIPC::Shareable -E 'say $IPC::Shareable::VERSION'
# 0.61

timethis 30000: 76 wallclock secs (42.98 usr + 32.38 sys = 75.36 CPU) @ 398.09/s (n=30000)
timethis 30000: 75 wallclock secs (42.60 usr + 32.07 sys = 74.67 CPU) @ 401.77/s (n=30000)
timethis 30000: 74 wallclock secs (41.18 usr + 31.66 sys = 72.84 CPU) @ 411.86/s (n=30000)
timethis 30000: 77 wallclock secs (43.81 usr + 32.36 sys = 76.17 CPU) @ 393.86/s (n=30000)

### 0.99_02 (on dev VPS)

# perl -MIPC::Shareable -E 'say $IPC::Shareable::VERSION'
# 0.99_02

timethis 30000: 22 wallclock secs (17.17 usr +  4.82 sys = 21.99 CPU) @ 1364.26/s (n=30000)
timethis 30000: 23 wallclock secs (17.20 usr +  4.61 sys = 21.81 CPU) @ 1375.52/s (n=30000)
timethis 30000: 23 wallclock secs (17.07 usr +  4.97 sys = 22.04 CPU) @ 1361.16/s (n=30000)
timethis 30000: 22 wallclock secs (17.00 usr +  5.07 sys = 22.07 CPU) @ 1359.31/s (n=30000)


