#!/usr/bin/perl
use strict;

my $root_dir;
BEGIN {
  $root_dir = $0;
  $root_dir =~ s/[^\/]*$//;
  $root_dir = "./" unless $root_dir =~ /\//;
  push @INC, $root_dir;
}

use Carp;
use Data::Dumper;
use Getopt::Long;
use Config::IniFiles;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Response;
use File::Temp;
use XML::Simple;

print "initializing...\n";
#default config
my $config;
$config = $root_dir . 'geoid.ini';
#get option, override default config if config parameter exists
my $option = GetOptions ("config=s" => \$config);
tie my %ini, 'Config::IniFiles', (-file => $config);
print "done.\n";

#output files
my $outdir = $ini{output}{geo};
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
print $gsefh "#submission_id project title GSE\n";
print $gsmfh "#submission_id project title GSM\n";
    my %projects = ('lieb' => 'Jason Lieb',
                   'celniker' => 'Susan Celniker',
                   'henikoff' => 'Steven Henikoff',
                   'karpen' => 'Gary Karpen',
                   'lai' => 'Eric Lai',
                   'macalpine' => 'David MacAlpine',
                   'piano' => 'Fabio Piano',
                   'snyder' => 'Michael Snyder',
                   'waterston' => 'Robert Waterston',
                   'white' => 'Kevin White');  
for my $id (@$ids) {
    #print "  GEO UID $id: downloading...";
    my $summary_url = $ini{geo}{summary_url} . "db=$ini{geo}{db}" . "&id=$id";
    my $geo_uid_file = $outdir . $id . '.xml';
    my $summaryfile = fetch($summary_url, $geo_uid_file);
    #print "done. parsing...";
    print $summaryfile, "\n";
    my $esummary = $xs->XMLin($summaryfile);
    my ($type, $title, $summary, $gse, $gsm, $samples);
    my $is_gse = 0;
    for my $item (@{$esummary->{DocSum}->{Item}}) {
	$type = $item->{content} if $item->{Name} eq 'entryType';
	$type =~ s/^\s*//; $type =~ s/\s*$//;
	if ($type eq 'GSE') {
	    $is_gse = 1 and last;
	}
    }
    
    if ($is_gse) {
	my @gsm;
	for my $item (@{$esummary->{DocSum}->{Item}}) {
	    $title = $item->{content} if $item->{Name} eq 'title';
	    $summary = $item->{content} if $item->{Name} eq 'summary';
	    $gse = $item->{content} if $item->{Name} eq 'GSE';
	    $gsm = $item->{content} if $item->{Name} eq 'GSM_L';
	    #$samples = $item->{content} if $item->{Name} eq 'Samples';
	    $samples = $item if $item->{Name} eq 'Samples';
	}
	print Dumper($samples);
	my $internal_id;
	my $project;
	for my $tmp (($title, $summary)) {
	    while (my ($k, $v) = each %projects) {
		$project = $k and last if $tmp =~ /$v/;
	    }
	}	
	for my $tmp (($title, $summary)) {
	    $internal_id = $1 and last if $tmp =~ /modENCODE[_ ]submission[_ ](\d*)?/i ;	    
	}
	$gse =~ s/^\s*//; $gse =~ s/\s*$//; $gse = 'GSE' . $gse;	
	if ($gsm ne '') {
	    @gsm = split(';', $gsm);
	    @gsm = map { $_ =~ s/^\s*//; $_ =~ s/\s*$//; 'GSM' . $_; } @gsm;
	} else {
	    @gsm = get_gsm($samples);
	}
	
	warn "I could not find DCC internal submission id for this GSE number $gse." unless $internal_id;
	$internal_id = $internal_id ? $internal_id : "Unknown id";
	print "done. write out ...";
	print $gsefh join("\t", ($internal_id, $project, $title, $gse)), "\n";
	print $gsmfh join("\t", ($internal_id, $project, $title, @gsm)), "\n";
    }
    print "done\n";
}
close $gsefh;
close $gsmfh;
print "done\n";

exit 0; 

sub fetch {
    my ($url, $outfile) = @_;
    my ($fh, $file);
    if ($outfile) {
	return $outfile if -e $outfile;
        $file = $outfile;
        open $fh, ">", $file;
    } else {
        ($fh, $file) = File::Temp::tempfile();
    }
    my $ua = new LWP::UserAgent;
    my $request = $ua->request(HTTP::Request->new('GET' => $url));
    $request->is_success or die "$url: " . $request->message;
    print $fh $request->content();
    close $fh;
    return $file;
}

sub get_gsm {
    my $item = shift;
    my @gsm;
    my $xl = $item->{Item};
    if (ref($xl) eq 'HASH') {
	my $yl = $xl->{Item};
	for my $y (@$yl) {
	    push @gsm, $y->{content} if $y->{Name} eq 'Accession';
	}	
    }
    if (ref($xl) eq 'ARRAY') {
	for my $x (@$xl) {
	    my $yl = $x->{Item};
	    for my $y (@$yl) {
		push @gsm, $y->{content} if $y->{Name} eq 'Accession';
	    }
	}
    }
    return @gsm;
}
