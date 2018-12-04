package Chess::ELO::FEDA;

use strict;
use warnings;

use DBI;
use DBD::CSV;
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

=head1 DESCRIPTION

The main idea of this module consists on build a SQL format from the XLS
downloaded from the URL provided. All players information are loaded into
"elo_feda" table, according this script:

   CREATE TABLE elo_feda(
      feda_id integer primary key, 
      surname varchar(32) not null,
      name    varchar(32), 
      fed     varchar(8), 
      rating  integer, 
      games   integer, 
      birth   integer, 
      title   varchar(16), 
      flag    varchar(8)
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
for a CSV file format. An empty value means that no backend is built.

=item -url

The URL direction (http://) used by the downloader to search the ZIP file. The
main file expected into the package is the XLS

=item -verbose

0 by default. If set, shows useful debug messages

=back 
=cut

sub new {
   my $class = shift;
   my %args = @_;
   my $self = {-verbose=>0, -url=>'', -target=>'', -ext=>'', -path=>''};
   $self->{-path} = $args{-folder} if exists $args{-folder};
   $self->{-target} = $args{-target} if exists $args{-target};
   $self->{-url} = $args{-url} if exists $args{-url};
   $self->{-verbose} = $args{-verbose} if exists $args{-verbose};
   $self->{-callback} = $args{-callback} if exists $args{-callback};

   if( $self->{-target} && ($self->{-target} =~ m!(\w+)$!) ) {
      $self->{-ext} = lc( $1 );
   }
   
   if( ($self->{-ext} ne 'sqlite') && ($self->{-ext} ne 'csv') ) {
      if( $self->{-target} ) {
         die "Unsupported target: [" . $self->{-ext} . "]";
      }
      else {
         $self->{-ext} = 'NULL';
      }
   }

   unless(-d $self->{-path} ) {
      die "Invalid path: [" . $self->{-path} . "]";
   }
   bless $self, $class;
}

#-------------------------------------------------------------------------------

=method cleanup

Unlink the files dowloaded for this downloader (the XLS file)

=cut

sub cleanup {
   my $self = shift;
   if( -e $self->{-xls} ) {
      $self->{-verbose} and print "+ remove xls file: ", $self->{-xls}, "\n";
      unlink $self->{-xls};
   }
}

#-------------------------------------------------------------------------------

=method download

Download the ZIP file from the -url parameter. Extract the XLS file to the
target_folder (which must exists).

=cut

sub download {
   my $self = shift;
   my $filename = $self->{-target} || 'chess_elo_feda';
   my $target_filename = catfile($self->{-path}, $filename);
   my $zip_filename = $target_filename . '.zip';
   my $xls_filename = $target_filename . '.xls';

   ##my $response = {content=>'', status=>200, reason=>'OK'};
   my $response = HTTP::Tiny->new->get($self->{-url});
   die "GET [$self->{-url}] failed" unless $response->{success};

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

#-------------------------------------------------------------------------------

=method parse

Parse and transform the XLS input file to the proper backend, according the
-target parameter. It relies on DBD::* in order to build the file.

=cut

sub parse {
   my $self = shift;
   
   my $rc = 0;

   if( $self->{-ext} eq 'NULL' ) {
      $rc = $self->_parse_null;
   }
   elsif( $self->{-ext} eq 'sqlite' ) {
      $rc = $self->_parse_sqlite;
   }
   elsif( $self->{-ext} eq 'csv' ) {
      $rc = $self->_parse_csv;
   }
   else {
      die "Unsupported target. Not in [sqlite, csv]";
   }

   return $rc;
}

#-------------------------------------------------------------------------------

=method run

Integrates download, parse and cleanup in a single call.

=cut

sub run {
   my $self = shift;
   my $rc = 0;

   if( $self->download() ) {
      $rc = $self->parse;
      $self->cleanup;
   }

   return $rc;
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

sub _parse_null {
   my $self = shift;
   
   $self->{-verbose} and print "+ NULL target", "\n";
   my $rc = $self->_parse_abstract_dbd(undef);
   
   return $rc;
}

#-------------------------------------------------------------------------------

sub _parse_sqlite {
   my $self = shift;
   
   $self->{-dbfile} = catfile($self->{-path}, $self->{-target});
   $self->{-verbose} and print "+ DB File: ", $self->{-dbfile}, "\n";
   unlink $self->{-dbfile} if -e $self->{-dbfile};

   my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->{-dbfile}, "", "", {
                  RaiseError=>1, 
                  AutoCommit=>0
   }) or die $DBI::errstr;
   my $rc = $self->_parse_abstract_dbd($dbh);
   $dbh->disconnect;
   return $rc;
}

#-------------------------------------------------------------------------------

sub _parse_csv {
   my $self = shift;

   $self->{-dbfile} = catfile($self->{-path}, $self->{-target});
   $self->{-verbose} and print "+ DB File: ", $self->{-dbfile}, "\n";
   unlink $self->{-dbfile} if -e $self->{-dbfile};

   my $dbh = DBI->connect ("dbi:CSV:", "", "", {
               f_schema         => undef,
               f_dir            => $self->{-path},
               f_encoding       => "utf8",
               csv_eol          => "\n",
               csv_sep_char     => ",",
               csv_quote_char   => '"',
               csv_escape_char  => '"',
               csv_class        => "Text::CSV_XS",
               csv_null         => 1,
               csv_always_quote => 1,
               csv_tables       => { elo_feda => { f_file => $self->{-target} } },
               RaiseError       => 1,
               AutoCommit       => 1
   }) or die $DBI::errstr;
   my $rc = $self->_parse_abstract_dbd($dbh);
   $dbh->disconnect;
   return $rc;
}

#-------------------------------------------------------------------------------

sub _parse_abstract_dbd {
   my $self = shift;
   my $dbh = shift;
   
   $dbh and $dbh->do(qq/CREATE TABLE elo_feda(
feda_id integer primary key, 
surname varchar(32) not null,
name    varchar(32), 
fed     varchar(8), 
rating  integer, 
games   integer, 
birth   integer, 
title   varchar(16), 
flag    varchar(8)
)/ );
   $self->{-verbose} and print "+ Load XLS: ", $self->{-xls}, "\n";

   my $parser   = Spreadsheet::ParseExcel->new;
   my $workbook = $parser->parse( $self->{-xls} )
        or die $parser->error(), "\n";

   my $worksheet = $workbook->worksheet('ELO');
   my ( $row_min, $row_max ) = $worksheet->row_range();

   my $START_XLS_ROW = 4;
   my @player_keys = qw/feda_id name fed rating games birth title flag/;

   sub new_xls_player {
      my ($worksheet, $stmt, $player_keys, $callback, $start_row, $stop_row, $verbose) = @_;
      for my $row ( $start_row .. $stop_row ) {
         my %feda_player;
         for my $col_index( 0..7 ) {
            my $cell = $worksheet->get_cell($row, $col_index);
            my $value = $cell ? $cell->value : undef; 
            $feda_player{ $player_keys->[$col_index] } = $value;
         }
         
         $feda_player{name} = decode('latin1', $feda_player{name});
         
         my $name = $feda_player{name};
         my ($apellidos, $nombre) = split / *, */, $name;

         if( $apellidos && $nombre ) {
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
               $stmt and $stmt->execute(
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
            $verbose and print "DB Error: $@", "\n";   
         }
      }
   }

   my $BLOCK_TXN = 2000;
   my $i = $START_XLS_ROW;
   my $j = $i + $BLOCK_TXN - 1;
   
   my $stmt = $dbh ? 
      $dbh->prepare("insert into elo_feda (feda_id, surname, name, fed, rating, games, birth, title, flag) values (?,?,?,?,?,?,?,?,?)"):
      undef;

   do {
      new_xls_player($worksheet, $stmt, \@player_keys, $self->{-callback}, $i, $j, $self->{-verbose});
      if( $dbh && (! $dbh->{AutoCommit}) ) {
         $dbh->commit unless $dbh->{AutoCommit};
      }
      $i += $BLOCK_TXN;
      $j = ($i + $BLOCK_TXN -1) > $row_max ? $row_max : $i + $BLOCK_TXN - 1;
   } while( $i <= $row_max );

   $stmt and $stmt->finish;

   return 1;
}

#-------------------------------------------------------------------------------

1;
