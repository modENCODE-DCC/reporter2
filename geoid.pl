#!/usr/bin/perl
use strict;

my $root_dir;
BEGIN {
  $root_dir = $0;
  $root_dir =~ s/[^\/]*$//;
  $root_dir = "./" unless $root_dir =~ /\//;
  #push @INC, $root_dir;
}

use Data::Dumper;
use Config::IniFiles;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Response;
use File::Temp;
use XML::Simple;

print "initializing...\n";

#get config
print "get config ...";
my $config = $root_dir . 'geoid.ini';
tie my %ini, 'Config::IniFiles', (-file => $config);
print "done.\n";

#output files
my $gsefile = $ini{output}{gse};
my $gsmfile = $ini{output}{gsm};

#get xml result from entrez search
print "download entrez esearch results ...";
my $search_url = $ini{geo}{search_url} . "db=$ini{geo}{db}" . "&term=$ini{geo}{term}" . "[$ini{geo}{field}]" . "&retmax=$ini{geo}{retmax}" ;
my $searchfile = fetch($search_url);
print "done.\n";

#parse the xml file to get entrez UID for submissions
print "parsing esearch result xml file ...";
my $xs = new XML::Simple;
my $esearch = $xs->XMLin($searchfile);
my $ids = $esearch->{IdList}->{Id};
print "done.\n";

#use entrez esummary with input UID to fetch summary
print "download and parse esummary xml file for GEO UIDs ...\n";
my $xs = new XML::Simple;
open my $gsefh, ">", $gsefile;
open my $gsmfh, ">", $gsmfile;
print $gsefh "#submission_id GSE\n";
print $gsmfh "#submission_id GSM\n";
for my $id (@$ids) {
    print "  GEO UID $id: downloading...";
    my $summary_url = $ini{geo}{summary_url} . "db=$ini{geo}{db}" . "&id=$id";
    my $summaryfile = fetch($summary_url);
    print "done. parsing...";
    my $esummary = $xs->XMLin($summaryfile);
    my ($type, $summary, $gse, $gsm);
    my $is_gse = 0;
    for my $item (@{$esummary->{DocSum}->{Item}}) {
	$type = $item->{content} if $item->{Name} eq 'entryType';
	$type =~ s/^\s*//; $type =~ s/\s*$//;
	if ($type eq 'GSE') {
	    $is_gse = 1 and last;
	}
    }
    if ($is_gse) {
	for my $item (@{$esummary->{DocSum}->{Item}}) {	    
	    $summary = $item->{content} if $item->{Name} eq 'summary';
	    $gse = $item->{content} if $item->{Name} eq 'GSE';
	    $gsm = $item->{content} if $item->{Name} eq 'GSM_L';
	}
	$summary =~ /modENCODE_submission_(\d*)?/i;
	my $internal_id = $1;
	my @gsm = split(';', $gsm);
	@gsm = map { $_ =~ s/^\s*//; $_ =~ s/\s*$//; $_; } @gsm;
	print "done. write out ...";
	print $gsefh $internal_id, "\t", $gse, "\n";
	print $gsmfh $internal_id, "\t", join("\t", @gsm), "\n";
    }
    print "done\n";
}
close $gsefh;
close $gsmfh;
print "done\n";

exit 0; 


sub fetch {
    my $url = shift;
    my ($fh, $file) = File::Temp::tempfile();    
    my $ua = new LWP::UserAgent;
    my $request = $ua->request(HTTP::Request->new('GET' => $url));
    $request->is_success or die "$search_url: " . $request->message;
    print $fh $request->content();
    close $fh;
    return $file;
}


