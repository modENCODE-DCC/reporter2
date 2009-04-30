#!/usr/bin/perl

use strict;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Response;
use HTTP::Cookies;
use File::Basename;
use File::Copy;
use File::Spec;
use Net::FTP;
use Mail::Mailer;
use Config::IniFiles;
use Getopt::Long;
use GEO::Reporter;

#parse command-line parameters
my ($unique_id, $output_dir, $config); 
my $make_tarball = 0; 
my $send_to_geo = 0;
my $option = GetOptions ("unique_id=s"     => \$unique_id,
			 "out=s"           => \$output_dir,
			 "config=s"        => \$config,
			 "make_tarball=s"  => \$make_tarball,
			 "send_to_geo=s"   => \$send_to_geo) or usage();
usage() if (!$unique_id or !$output_dir or !$config);
usage() unless -w $output_dir;
usage() unless -e $config;

#get config
my %ini;
tie %ini, 'Config::IniFiles', (-file => $config);

#validator path
my $validator_path = $ini{validator}{validator};
BEGIN {
    push @INC, $validator_path;
}
use ModENCODE::Parser::Chado;

#report directory
my $report_dir = File::Spec->rel2abs($output_dir);
#make sure $report_dir ends with '/'
$report_dir .= '/' unless $report_dir =~ /\/$/;

#what is the database for this dataset?
my $dbname = $ini{database}{name};
my $dbhost = $ini{database}{host};
my $dbusername = $ini{database}{username};
my $dbpassword = $ini{database}{password};
#search path for this dataset, this is fixed by modencode chado db
my $search_path = $dbname . "_" . $unique_id . "_data";

#build the uniquename for this dataset
my $unique_name = 'modencode_' . $unique_id;

#experiment_id is the serial number in chado experiment table
#one data one database, so experiment_id is always 1
my $experiment_id = '1';

#start read chado
my $reader = new ModENCODE::Parser::Chado({
	'dbname' => $dbname,
	'host' => $dbhost,
	'username' => $dbusername,
	'password' => $dbpassword,
	'search_path' => $search_path
   });

$reader->load_experiment($experiment_id);
my $experiment = $reader->get_experiment();
print "experiment loaded\n";

my $reporter = new GEO::Reporter({config => \%ini});
my $seriesfile = $report_dir . $unique_name . '_series.txt';
my $samplefile = $report_dir . $unique_name . '_sample.txt';

my ($seriesFH, $sampleFH);
open $seriesFH, ">", $seriesfile;
open $sampleFH, ">", $samplefile;
$reporter->chado2series($reader, $experiment, $seriesFH, $unique_name);
print "done with series\n";
my ($raw_datafiles, $normalized_datafiles) = $reporter->chado2sample($reader, $experiment, $seriesFH, $sampleFH, $report_dir);
print "done with sample\n";
close $sampleFH;
close $seriesFH;

my $metafile = $unique_id . ".soft";
my $tarfile = $unique_id . '.tar';
if ($make_tarball) {
my @nr_raw_datafiles = nr(@$raw_datafiles);
my @nr_normalized_datafiles = nr(@$normalized_datafiles);

#make a tar ball at report_dir for series, sample files and all datafiles
chdir $report_dir;
my $dir = dirname($seriesfile);
my $file1 = basename($seriesfile);
my $file2 = basename($samplefile);
my @cat = ("cat $file1 $file2 > $metafile");
system(@cat) == 0 || die "can not cate: $?";
my @tar = ('tar', 'cf', $tarfile, $metafile);
system(@tar) == 0 || die "can not make tar: $?";
system("rm $metafile") == 0 || die "can not remove metafile: $?";
my @datafiles = (@nr_raw_datafiles, @nr_normalized_datafiles);
for my $datafile (@datafiles) {
    my $path = $report_dir . $datafile;
    my $dir = dirname($path);
    my $file = basename($path);
    my ($unzipped_file, $unzipped) = unzipp($file);
    move($tarfile, $dir);
    chdir $dir;
    my @tar;
    if ($unzipped) {
	@tar = ('tar', 'rf', $tarfile, $unzipped_file);
	system(@tar) == 0 || die "can not make tar: $?";
	system("rm $unzipped_file") == 0 || die "can not remove unzipped file: $?";
    } else {
	@tar = ('tar', 'rf', $tarfile, $file);
	system(@tar) == 0 || die "can not make tar: $?";
    }
    
}
move($tarfile, $report_dir);
chdir $report_dir;
system('gzip', $tarfile) == 0 || die "can not zip the tar: $?";
}

if ($send_to_geo) {
#use ftp to send file to geo ftp site
my $ftp_host = $ini{ftp}{host};
my $ftp_username = $ini{ftp}{username};
my $ftp_password = $ini{ftp}{password};
my $ftp = Net::FTP->new($ftp_host);
my $success = $ftp->login($ftp_username, $ftp_password);
die $ftp->message unless $success;
my $success = $ftp->cwd($ini{ftp}{dir});
die $ftp->message unless $success;
my $success = $ftp->put($tarfile);
die $ftp->message unless $success;

#send geo a email
my $mailer = Mail::Mailer->new;
my $submitter = $ini{submitter}{submitter};
$mailer->open({
    From => $ini{email}{from},
    To   => $ini{email}{to},
    CC   => $ini{email}{cc},
    Subject => 'ftp upload'
});
print $mailer "userid: $submitter\n";
print $mailer "file: $tarfile\n";
print $mailer "modencode DCC ID for this submission: $unique_id\n";
print $mailer "Best Regards, modencode DCC\n";
}


sub nr {
    my @files = @_;
    my @nr_files = ();
    for my $file (@files) {
	my $already_in = 0;
	for my $nr_file (@nr_files) {
	    $already_in = 1 and last if $file eq $nr_file;
	}
	push @nr_files, $file unless $already_in;
    }
    return @nr_files;
}

sub unzipp {
    my $path = shift; #this is already a basename
    #always keep the original file
    my ($file, $dir, $suffix) = fileparse($path, qr/\.[^.]*/);
    my $unzipped = 0;
    if ($suffix eq '.tgz') {#need to ban this suffix for submission to us!!
	$unzipped = 1;
    }
    if ($suffix eq '.bz2') {#use this is good.
	$unzipped = 1;
	system("bzip2 -dk $path")	
    }
    if ($suffix eq '.zip' || $suffix eq '.ZIP' || $suffix eq '.Z') {
	$unzipped = 1;
    }
    if ($suffix eq '.gz') {
	$unzipped = 1;
	#deal with .tar.gz here
    }
    if ($suffix eq '.tar') {#need to ban this suffix for submission to us!!
	$unzipped = 1;
    }
    if ($unzipped) {
	return ($file, $unzipped);
    } else {
	return ($path, $unzipped);
    }
}

sub usage {
    my $usage = qq[$0 -unique_id <unique_submission_id> -out <output_dir> -config <config_file> [-make_tarball <0|1>] [-send_to_geo <0|1>]];
    print "Usage: $usage\n";
    print "required parameters: unique_id, out, config\n";
    print "optional yet helpful parameter: make_tarball, default is 0 for NOT archiving any raw/normalized data.\n";
    print "optional yet important parameter: send_to_geo, default is 0 for NOT sending crappy results to geo.\n";
    exit 2;
}
