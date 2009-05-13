#!/usr/bin/perl

use strict;

my $root_dir;
BEGIN {
  $root_dir = $0;
  $root_dir =~ s/[^\/]*$//;
  $root_dir = "./" unless $root_dir =~ /\//;
  push @INC, $root_dir;
}

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
use ModENCODE::Parser::Chado;
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

#report directory
my $report_dir = File::Spec->rel2abs($output_dir);
#make sure $report_dir ends with '/'
$report_dir .= '/' unless $report_dir =~ /\/$/;

#what is the database for this dataset? 
my $dbname = $ini{database}{dbname};
my $dbhost = $ini{database}{host};
my $dbusername = $ini{database}{username};
my $dbpassword = $ini{database}{password};
#search path for this dataset, this is fixed by modencode chado db
my $schema = $ini{database}{pathprefix}. $unique_id . $ini{database}{pathsuffix} . ',' . $ini{database}{schema};
#build the uniquename for this dataset
my $unique_name = 'modencode_' . $unique_id;

#start read chado
print "connecting to database ...";
my $reader = new ModENCODE::Parser::Chado({
	'dbname' => $dbname,
	'host' => $dbhost,
	'username' => $dbusername,
	'password' => $dbpassword,
   });
my $experiment_id = $reader->set_schema($schema);
print "done.\n";
print "loading experiment ...";
$reader->load_experiment($experiment_id);
my $experiment = $reader->get_experiment();
print "done.\n";

my $reporter = new GEO::Reporter({config => \%ini});
my $seriesfile = $report_dir . $unique_name . '_series.txt';
my $samplefile = $report_dir . $unique_name . '_sample.txt';

my ($seriesFH, $sampleFH);
open $seriesFH, ">", $seriesfile;
open $sampleFH, ">", $samplefile;
print "generating GEO series file ...";
$reporter->chado2series($reader, $experiment, $seriesFH, $unique_name);
print "done.\n";
print "generating GEO sample file ...";
my ($raw_datafiles, $normalized_datafiles) = $reporter->chado2sample($reader, $experiment, $seriesFH, $sampleFH, $report_dir);
print "done.\n";
close $sampleFH;
close $seriesFH;

my $tarfile = $unique_name . '.tar';
my $tarballfile = $unique_name . '.tar.gz';
my $tarball_made = 0;
if ($make_tarball == 1) {
    print "making tarball for GEO submission ...\n";
    my @nr_raw_datafiles = nr(@$raw_datafiles);
    my @nr_normalized_datafiles = nr(@$normalized_datafiles);
    my @datafiles = (@nr_raw_datafiles, @nr_normalized_datafiles);
    my $metafile = $unique_name . ".soft";
    #make a tar ball at report_dir for series, sample files and all datafiles
    chdir $report_dir;
    my $dir = dirname($seriesfile);
    my $file1 = basename($seriesfile);
    my $file2 = basename($samplefile);
    my @cat = ("cat $file1 $file2 > $metafile");
    system(@cat) == 0 || die "can not cat two GEO meta files: $?";
    my @tar = ('tar', 'cf', $tarfile, $metafile);
    system(@tar) == 0 || die "can not make tar of two GEO meta files: $?";
    system("rm $metafile") == 0 || die "can not remove catenated metafile: $?";

    print "   downloading tarball provided by pipeline ...";
    my $url = $ini{tarball}{url};
    $url .= '/' unless $url =~ /\/$/;
    $url .= $unique_id . $ini{tarball}{condition};
    my $allfile = 'extracted.tgz';
    my $allfilenames = 'extracted_filenames.txt';
    my @allfilenames;
    #download flattened tarball of submission
    open my $allfh, ">" , $allfile;
    my $ua = new LWP::UserAgent;
    my $request = $ua->request(HTTP::Request->new('GET' => $url));
    $request->is_success or die "$url: $request->message";
    print $allfh $request->content();
    close $allfh;
    print "done.\n";
    #peek into tarball to list all filenames
    my @listcmd = ("tar tzf $allfile > $allfilenames");
    system(@listcmd) == 0 || die "can not list filenames in the downloaded tarball $allfile and save them into file $allfilenames";
    open my $allfilenamesfh, "<", $allfilenames;
    while (<$allfilenamesfh>) {chomp; push @allfilenames, $_;}
    close $allfilenamesfh;

    for my $datafile (@datafiles) {
	#remove subdirectory prefix, this is the filename goes into geo tarball
	my $myfile = basename($datafile);
	#replace / with _ , use it to match the filenames in downloaded tarball
	$datafile =~ s/\//_/g;
	#remove suffix of compression, such as .zip, .bz2
	my $clean_file = unzipp($datafile);
	
	my $filename_in_tarball;
	for my $filename (@allfilenames) {
	    $filename_in_tarball = $filename and last if $filename =~ /$clean_file/;
	}
	my @untar = "tar xzf $allfile $filename_in_tarball";
	system(@untar) == 0 || die "can not extract a datafile $filename_in_tarball from download tarball $allfile";
	my @mv = "mv $filename_in_tarball $myfile";
	system(@mv) == 0 || die "can not change filename $filename_in_tarball to $myfile";
	my @tar = ("tar -r --remove-files -f $tarfile $myfile");
	system(@tar) == 0 || die "can not append a datafile $filename_in_tarball from download tarball $allfile to my tarball $tarfile and then remove it (leave no garbage).";
    }
    my @tarball = ("gzip $tarfile");
    system(@tarball) == 0 || die "can not gzip the tar file $tarfile";
    my @rm = ("rm $allfile $allfilenames");
    system(@rm) == 0 || die "can not remove file $allfile $allfilenames";
    $tarball_made = 1;
    print "tarball made.\n";
}

if ($tarball_made && $send_to_geo) {
    #use ftp to send file to geo ftp site
    print "beginning to send tarball to GEO ...\n";
    my $ftp_host = $ini{ftp}{host};
    my $ftp_username = $ini{ftp}{username};
    my $ftp_password = $ini{ftp}{password};
    my $ftp = Net::FTP->new($ftp_host);
    my $success = $ftp->login($ftp_username, $ftp_password);
    die $ftp->message unless $success;
    my $success = $ftp->cwd($ini{ftp}{dir});
    die $ftp->message unless $success;
    my $success = $ftp->put($tarballfile);
    die $ftp->message unless $success;

    #send geo a email
    my $mailer = Mail::Mailer->new;
    my $submitter = $ini{submitter}{submitter};
    $mailer->open({
	From => $ini{email}{from},
	To   => $ini{email}{to},
	CC   => $ini{email}{cc},
	Subject => 'ftp upload',
		  });
    print $mailer "userid: $submitter\n";
    print $mailer "file: $tarballfile\n";
    print $mailer "modencode DCC ID for this submission: $unique_id\n";
    print $mailer "Best Regards, modencode DCC\n";
    $mailer->close;
    print "sent to GEO already!\n";
    my @rm = ("rm $tarballfile");
    system(@rm) == 0 || die "can not remove file $tarballfile";   
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
    $path =~ s/\.tgz$//;
    $path =~ s/\.tar\.gz$//;    
    $path =~ s/\.tar$//;
    $path =~ s/\.gz$//;    
    $path =~ s/\.bz2$//;
    $path =~ s/\.zip$//;
    $path =~ s/\.ZIP//;
    $path =~ s/\.Z//;
    return $path;
}

sub usage {
    my $usage = qq[$0 -unique_id <unique_submission_id> -out <output_dir> -config <config_file> [-make_tarball <0|1>] [-send_to_geo <0|1>]];
    print "Usage: $usage\n";
    print "required parameters: unique_id, out, config\n";
    print "optional yet helpful parameter: make_tarball, default is 0 for NOT archiving any raw/normalized data.\n";
    print "optional yet important parameter: send_to_geo, default is 0 for NOT sending crappy results to geo. must set both make_tarball and send_to_geo to 1 for sending submission to geo happen.\n";
    exit 2;
}
