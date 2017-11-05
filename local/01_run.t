use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Test::More;
use Chess::ELO::FEDA;
use File::Temp qw/ tempfile tempdir /;

#my $tempdir = tempdir("$Bin/data/elo-XXXXXXXX", CLEANUP => 1);
my $tempdir = "$Bin/data";
my $cef = Chess::ELO::FEDA->new(
               -path=>$tempdir, 
               -target=>'test.sqlite', 
               -url=>'http://feda.org/feda2k16/wp-content/uploads/2017_11.zip', 
               -callback=> sub{ my $p =shift; print $p->{'surname'}, "\n"},
               -verbose=>1
);

my $rc_d = $cef->download;
ok( $rc_d, 'download: ' . $cef->{-xls} );


my $rc_p = $cef->parse;
ok( $rc_p, 'parse xls: ' . $cef->{-target} );


done_testing;
