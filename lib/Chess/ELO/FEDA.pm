package Chess::ELO::FEDA;

use strict;
use warnings;

use DBI;
use DBD::SQLite;
use File::Spec::Functions;
use HTTP::Tiny;
use IO::Uncompress::Unzip qw/$UnzipError/;
use Spreadsheet::ParseExcel;
use Encode qw/decode/;

# ABSTRACT: Download FEDA ELO (L<http://www.feda.org>) into differents backends (SQLite)

=head1 SYNOPSIS

   my $elo = Chess::ELO::FEDA->new(
      -url      => 'http://feda.org/feda2k16/wp-content/uploads/2017_11.zip'
      -folder   => './elo/feda',
      -target   => '2017_11.sqlite',
      -callback => sub { my $player = shift; },
      -verbose  => 1
   );

=method new (%OPTS)

Constructor. It accepts a hash with these options:

=over 4

=item -callback

This callback sub will be called on each record found. It receives a hash
reference with the player data: feda_id, surname, name, fed, rating, games, 
birth, title, flag

=item -folder

Working folder of the overall process. It is not created if it doesn't exists.

=item -target

Target file where the parser stores the ELO information. According the file
extension, it selects the proper backend: .sqlite for SQLite dabase or .csv
for a CSV file format.

=item -url

The URL direction (http://) used by the downloader to search the ZIP file. The
main file expected into the package is the XLS

=item -verbose

0 by default. If set, shows useful debug messages

=back 
=cut

#-------------------------------------------------------------------------------

sub new {
   my $class = shift;
   my %args = @_;
   my $self = {-verbose=>0, -url=>'', -target=>'', -ext=>'', -path=>''};
   $self->{-path} = $args{-path} if exists $args{-path};
   $self->{-target} = $args{-target} if exists $args{-target};
   $self->{-url} = $args{-url} if exists $args{-url};
   $self->{-verbose} = $args{-verbose} if exists $args{-verbose};
   $self->{-callback} = $args{-callback} if exists $args{-callback};

   if( $self->{-target} =~ m!(\w+)$! ) {
      $self->{-ext} = lc( $1 );
   }
   
   if( ($self->{-ext} ne 'sqlite') && ($self->{-ext} ne 'csv') ) {
      die "Unsupported target: [" . $self->{-ext} . "]";
   }

   unless(-d $self->{-path} ) {
      die "Invalid path: [" . $self->{-path} . "]";
   }
   bless $self, $class;
}

=method cleanup

Unlink the files dowloaded for this downloader

=cut

#-------------------------------------------------------------------------------

sub cleanup {

}

#-------------------------------------------------------------------------------

=method download

Download the ZIP file from the -url parameter. Extract the XLS file to the
target_folder (which must exists)

=cut

#-------------------------------------------------------------------------------

sub download {
   my $self = shift;
   
   my $response = HTTP::Tiny->new->get($self->{-url});
   die "GET [$self->{-url}] failed" unless $response->{success};

   my $target_filename = catfile($self->{-path}, $self->{-target});
   my $zip_filename = $target_filename . '.zip';
   my $xls_filename = $target_filename . '.xls';
   if( length $response->{content} ) {
      open my $fhz, ">", $zip_filename or die "Cannot open file: $zip_filename";
      binmode $fhz;
      print $fhz $response->{content} ;
      close $fhz;
   }
   print "+ Download: ", $zip_filename, " => [", $response->{status}, "]: ", $response->{reason}, "\n" if $self->{-verbose};
   $self->_extract_file_from_zip($xls_filename, $zip_filename, qr!\.xls$!i);
   unlink $zip_filename;
   print "+ Unzip: ", $xls_filename, "\n" if $self->{-verbose};
   $self->{-xls} = $xls_filename;
   return (-e $self->{-xls}) ? 1 : 0;
}


=method parse

Parse and transform the XLS input file to the proper backend, according the
-target parameter.

=cut

#-------------------------------------------------------------------------------

sub parse {
   my $self = shift;
   if( $self->{-ext} eq 'sqlite' ) {
      $self->_parse_sqlite();
   }

}

=method run

Integrates download, parse and cleanup in a single call.

=cut

#-------------------------------------------------------------------------------

sub run {

}

#-------------------------------------------------------------------------------

sub _extract_file_from_zip {
   my ($self, $xlsfile, $zipfile, $regexpr_file_to_extract) = @_;
   my $u = new IO::Uncompress::Unzip $zipfile or die "Cannot open $zipfile: $UnzipError";
   my $filename = undef;

   for( my $status = 1; $status > 0; $status = $u->nextStream() )
   {
      my $name = $u->getHeaderInfo()->{Name};   
      next unless $name =~ $regexpr_file_to_extract;
      
      my $buff;
      open my $fh, '>', $xlsfile or die "Couldn't write to $name: $!";
      binmode $fh;
      while( ($status = $u->read($buff)) > 0 ) {
         syswrite $fh, $buff;
      }
      close $fh;
      $filename = $name;
      last;
   }
 
    return ($filename) ? $xlsfile . "/$filename" : undef;
}

#-------------------------------------------------------------------------------

sub _parse_sqlite {
   my $self = shift;
   
   my $sqlite_file = catfile($self->{-path}, $self->{-target});
   my $dbh = DBI->connect("dbi:SQLite:dbname=$sqlite_file","","", {RaiseError=>1, AutoCommit=>0});

   $dbh->do(qq/DROP TABLE IF EXISTS elo_feda/);
   $dbh->do(qq/CREATE TABLE elo_feda(
feda_id number(9) primary key, 
surname varchar(32) not null,
name    varchar(32), 
fed     varchar(8), 
rating  number(4) default 0, 
games   number(4) default 0, 
birth   number(4), 
title   varchar(16), 
flag    varchar(8)
)/ );
   print "+ Load XLS: ", $self->{-xls}, "\n";

   my $parser   = Spreadsheet::ParseExcel->new;
   my $workbook = $parser->parse( $self->{-xls} )
        or die $parser->error(), "\n";

   my $worksheet = $workbook->worksheet('ELO');
   my ( $row_min, $row_max ) = $worksheet->row_range();

   my $START_XLS_ROW = 4;
   my @player_keys = qw/feda_id name fed rating games birth title flag/;

   sub new_xls_player {
      my ($worksheet, $stmt, $player_keys, $callback, $start_row, $stop_row) = @_;
      for my $row ( $start_row .. $stop_row ) {
         my %feda_player;
         map {
               my $cell = $worksheet->get_cell($row,$_);
               my $value = $cell ? $cell->value : undef; 
               $feda_player{ $player_keys->[$_] } = $value;
         } 0..7;
         
         ##next if $feda_player{fed} ne 'CNT';
         
         $feda_player{name} = decode('latin1', $feda_player{name});
         
         my $handled = 0;
         my $name = $feda_player{name};
         my ($apellidos, $nombre) = split / *, */, $name;

         if( $apellidos && $nombre ) {
               $handled = 1;
               $feda_player{surname} = $apellidos;
               $feda_player{name}    = $nombre;
         }
         elsif( index($name, '.') >= 0 ) {
               ($apellidos, $nombre) = split / *\. */, $name;
               $feda_player{surname} = $apellidos;
               $feda_player{name}    = $nombre;
         }
         elsif( $apellidos ) {
               $feda_player{surname} = $apellidos;
               $feda_player{name}    = '***';
         }
         eval {
               $stmt->execute(
                        $feda_player{feda_id},
                        $feda_player{surname},
                        $feda_player{name},
                        $feda_player{fed},
                        $feda_player{rating},
                        $feda_player{games},
                        $feda_player{birth},
                        $feda_player{title},
                        $feda_player{flag}
               );
               $callback and $callback->(\%feda_player);
               
         };
         if($@) {
               print "ERROR: $@";
               print Dumper(\%feda_player), "\n";
               die "DB ERROR";
         }
      }
   }

   my $BLOCK_TXN = 2000;
   my $i = $START_XLS_ROW;
   my $j = $i + $BLOCK_TXN - 1;
   
   my $stmt = $dbh->prepare("insert into elo_feda (feda_id, surname, name, fed, rating, games, birth, title, flag) values (?,?,?,?,?,?,?,?,?)");
   do {
      #print $i, " / ", $row_max, "\n";
      new_xls_player($worksheet, $stmt, \@player_keys, $self->{-callback}, $i, $j);
      $dbh->commit;
      $i += $BLOCK_TXN;
      $j = ($i + $BLOCK_TXN -1) > $row_max ? $row_max : $i + $BLOCK_TXN - 1;
   } while( $i <= $row_max );

   $stmt->finish;
   $dbh->disconnect;

}

#-------------------------------------------------------------------------------


sub _parse_csv {
   my $self = shift;
   die "Unsupported";
}

#-------------------------------------------------------------------------------

1;
