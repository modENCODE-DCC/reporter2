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

my $validator_path;
BEGIN {
    $validator_path = "/home/zheng/validator";
    push @INC, $validator_path;
}

#replace with your own validator dir 
#use lib $validator_path;

use ModENCODE::Parser::Chado;
use GEO::Reporter;

#use AE::Reporter;

#my $experiment_id = $ARGV[0];
#where does the raw data stored?
my $report_dir = File::Spec->rel2abs($ARGV[0]);

#what is the database/schema name for this dataset?
my $dbname = $ARGV[1];

#waht is the uniquename for this dataset? this can be the serial number of the dataset
my $unique_id = 'modencode_' . $ARGV[2];

#print $report_dir;
#print $dbname;
my $experiment_id = '1';
#my $report_dir = '/home/zheng/data';

#is this a new submission?
my $newsubmission = 1;
my $username = 'zheng';
my $passwd = 'weigaocn';

#my $dbname = 'modencode_chado';
#my $host = 'heartbroken.lbl.gov';
#my $username = 'db_public';
#my $passwd = 'ir84#4nm';

#my $dbname = 'modencode2';
#my $dbname = 'NA_MES4FLAG_EEMB';
my $host = 'localhost';
my $dbusername = 'zheng';
my $dbpasswd = 'weigaocn';



my $reader = new ModENCODE::Parser::Chado({
	'dbname' => $dbname,
	'host' => $host,
	'username' => $dbusername,
	'password' => $dbpasswd,
   });

if (!$experiment_id) {
    #print out all experiment id
} else {
    #check whether experiment id is valid
}

$reader->load_experiment($experiment_id);
my $experiment = $reader->get_experiment();
print "experiment loaded\n";

my $reporter = new GEO::Reporter();

#make sure $report_dir ends with '/'
$report_dir .= '/' unless $report_dir =~ /\/$/;


my $seriesfile = $report_dir . $unique_id . '_series.txt';
my $samplefile = $report_dir . $unique_id . '_sample.txt';

my ($seriesFH, $sampleFH);
open $seriesFH, ">", $seriesfile;
open $sampleFH, ">", $samplefile;
$reporter->chado2series($reader, $experiment, $seriesFH, $unique_id);
print "done with series\n";
my ($raw_datafiles, $normalized_datafiles) = $reporter->chado2sample($reader, $experiment, $seriesFH, $sampleFH, $report_dir);
print "done with sample\n";
close $sampleFH;
close $seriesFH;

my @nr_raw_datafiles = nr(@$raw_datafiles);
my @nr_normalized_datafiles = nr(@$normalized_datafiles);

#make a tar ball at report_dir for series, sample files and all datafiles
my $metafile = $unique_id . ".soft";
my $tarfile = $unique_id . '.tar';
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

#submit to GEO using web deposit
#ditched because we use supplementary files instead of data_table
#my $submit_url = 'http://www.ncbi.nlm.nih.gov/geo/submission/depslip.cgi';
#my $submitter = new LWP::UserAgent;
#$submitter->cookie_jar({});
#$submitter->credentials('http://www.ncbi.nlm.nih.gov/', 'geo/submission/depslip.cgi', $username, $passwd);
#my $subtype = $newsubmission ? 'new' : 'update';
#my $request = POST($submit_url,
#		   Content_Type => 'form-data',
#		   Content => [state => '2',
#			       subtype => $subtype,
#			       filename => [$tarballfile],
#			       release_immed_date => 'on',]);
#my $response = $submitter->request($request);
#die $response->message unless $response->is_success;


#use ftp to send file to geo ftp site
my $ftp_host = 'ftp-private.ncbi.nlm.nih.gov';
my $ftp_username = 'geo';
my $ftp_password = 'do_not_know_yet';
my $ftp = Net::FTP->new($ftp_host);
my $success = $ftp->login($ftp_username, $ftp_password);
die $ftp->message unless $success;
my $success = $ftp->cwd('raw');
die $ftp->message unless $success;
my $success = $ftp->put($tarfile);
die $ftp->message unless $success;

#send geo a email
my $mailer = Mail::Mailer->new;
my $submitter = 'modencode';
$mailer->open({
    From => 'help@modencode.org',
    To   => 'geo@ncbi.nlm.nih.gov',
    CC   => 'zhengzha2000@gmail.com',
    Subject => 'ftp upload'
});
print $mailer "userid: $submitter\n";
print $mailer "file: $tarfile\n";
print $mailer "modencode DCC ID for this submission: $unique_id\n";
print $mailer "Best Regards, modencode DCC\n";




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
