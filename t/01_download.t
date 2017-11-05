use strict;
use warnings;
use Test::More tests=>6;
use Test::Exception;


use_ok 'Chess::ELO::FEDA';

dies_ok sub {Chess::ELO::FEDA->new;}, "Constructor without params";
dies_ok sub {Chess::ELO::FEDA->new(-target=>'test.xls');}, "No target supported: xls";
lives_ok sub {Chess::ELO::FEDA->new(-path=>'.', -target=>'test.sqlite');}, "Constructor for SQLite";
lives_ok sub {Chess::ELO::FEDA->new(-path=>'.', -target=>'test.csv');}, "Constructor for CSV";

dies_ok sub {Chess::ELO::FEDA->new(-path=>'/a/path/invalid/' . time(), -target=>'test.sqlite');}, "Invalid path not allowed";

my $tempdir = tempdir('chess-elo-feda-XXXXXXXX', CLEANUP => 1);
my $cef = Chess::ELO::FEDA->new(-path=>$tempdir, -target=>'test.csv', -url=>'http://feda.org/feda2k16/wp-content/uploads/2017_11.zip');
$cef->download;

print $tempdir, "\n";
unlink $tempdir;
