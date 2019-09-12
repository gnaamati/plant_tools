#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case);
use Net::FTP;
use JSON qw(decode_json);
use Data::Dumper;
use Benchmark;
use Time::HiRes;
use HTTP::Tiny;

# Produces pangenome analysis based on clusters of orthologous genes shared by (plant) species in clade 
# by querying pre-computed Compara data from Ensembl Genomes
#
# Produces output compatible with scripts at 
# https://github.com/eead-csic-compbio/get_homologues
#
# Bruno Contreras Moreira 2019

# Ensembl Genomes
my @divisions  = qw( Plants Bacteria Fungi Vertebrates Protists Metazoa );
my $FTPURL     = 'ftp.ensemblgenomes.org'; 
my $COMPARADIR = '/pub/xxx/current/tsv/ensembl-compara/homologies';
my $FASTADIR   = '/pub/current/xxx/fasta';
my $RESTURL    = 'http://rest.ensembl.org';
my $INFOPOINT  = $RESTURL.'/info/genomes/division/';
my $TAXOPOINT  = $RESTURL.'/info/genomes/taxonomy/';

my $TRANSPOSEXE= 'perl -F\'\t\' -ane \'$F[$#F]=~s/\n//g;$r++;for(1 .. @F){$m[$r][$_]=$F[$_-1]};$mx=@F;END{for(1 .. $mx){for $t(1 .. $r){print"$m[$t][$_]\t"}print"\n"}}\'';

my $verbose    = 0;
my $division   = 'Plants';
my $seqtype    = 'protein';
my $taxonid    = ''; # NCBI Taxonomy id, Brassicaceae=3700, Asterids=71274, Poaceae=4479
my $ref_genome = ''; # should be contained in $taxonid;
my ($clusterdir,$comparadir,$fastadir,$outfolder,$out_genome,$params) = ('','','','','','');

my ($help,$sp,$sp2,$show_supported,$request,$response);
my ($filename,$dnafile,$pepfile,$seqfolder,$ext);
my ($n_core_clusters,$n_cluster_sp,$n_cluster_seqs) = (0,0,0);
my ($GOC,$WGA,$LOWCONF) = (0,0,0);
my ($request_time,$last_request_time) = (0,0);
my (@ignore_species, %ignore, %division_supported);

GetOptions(	
	"help|?"       => \$help,
	"verbose|v"    => \$verbose,
	"supported|l"  => \$show_supported,
	"division|d=s" => \$division, 
	"clade|c=s"    => \$taxonid,
	"reference|r=s"=> \$ref_genome,
	"outgroup|o=s" => \$out_genome,
	"ignore|i=s"   => \@ignore_species,
	"type|t=s"     => \$seqtype,
	"GOC|G=i"      => \$GOC,
	"WGA|W=i"      => \$WGA,
	"LC|L"         => \$LOWCONF,
	"folder|f=s"   => \$outfolder
) || help_message(); 

sub help_message {
	print "\nusage: $0 [options]\n\n".
      "-c NCBI Taxonomy clade of interest         (required, example: -c Brassicaceae or -c 3700)\n".
		"-f output folder                           (required, example: -f myfolder)\n".
		"-r reference species_name to name clusters (required, example: -r arabidopsis_thaliana)\n".
		"-l list supported species_names            (optional, example: -l)\n".
		"-d Ensembl division                        (optional, default: -d $division)\n".
		"-o outgroup species_name                   (optional, example: -o brachypodium_distachyon)\n".
		"-i ignore species_name(s)                  (optional, example: -i selaginella_moellendorffii -i ...)\n".
		"-t sequence type [protein|cdna]            (optional, default: -t protein)\n".
		"-L allow low-confidence orthologues        (optional, by default these are skipped)\n".
		"-v verbose                                 (optional, example: -v\n";

	print "\nThe following options are only available for some clades:\n\n".
		"-G min Gene Order Conservation [0:100]  (optional, example: -G 75)\n".
		"   see modules/Bio/EnsEMBL/Compara/PipeConfig/EBI/Plants/ProteinTrees_conf.pm\n".
		"   at https://github.com/Ensembl/ensembl-compara\n\n".
		"-W min Whole Genome Align score [0:100] (optional, example: -W 75)\n".
		"   see ensembl-compara/scripts/pipeline/compara_plants.xml\n".
		"   at https://github.com/Ensembl/ensembl-compara\n\n";
	print "Read about GOC and WGA at:\n".
		"https://www.ensembl.org/info/genome/compara/Ortholog_qc_manual.html\n\n";

	print "Example calls:\n\n".
		" perl $0 -c Brassicaceae -f Brassicaceae\n".
		" perl $0 -c Brassicaceae -f Brassicaceae -t cdna -o theobroma_cacao\n".
		" perl $0 -f poaceae -c 4479 -r oryza_sativa -WGA 75\n".
		exit(0);
}

if($help){ help_message() }

if($ref_genome eq ''){
   print "# ERROR: need a valid reference species_name, such as -r arabidopsis_thaliana)\n\n";
   exit;
} else {
   $clusterdir = $ref_genome;
	$clusterdir =~ s/_//g;
	if($out_genome){
		$clusterdir .= "_plus_".$out_genome;
	}
}

if($taxonid eq ''){
	print "# ERROR: need a valid NCBI Taxonomy clade, such as -c Brassicaceae or -c 3700\n\n";
	print "# Check https://www.ncbi.nlm.nih.gov/taxonomy\n";
	exit;
} else { 
	$clusterdir .= "_$taxonid\_algEnsemblCompara";
}

if($GOC){
	$params .= "_GOC$GOC";	
}

if($WGA){
	$params .= "_WGA$WGA";	
}

if($LOWCONF){
	$params .= "_LC";
}

if($division){
	if(!grep(/$division/,@divisions)){
		die "# ERROR: accepted values for division are: ".join(',',@divisions)."\n"
	} else {
		my $lcdiv = lc($division);

		$comparadir = $COMPARADIR;
		$comparadir =~ s/xxx/$lcdiv/;
		
		$fastadir   = $FASTADIR;		
		$fastadir =~ s/xxx/$lcdiv/;
	}
}

if(@ignore_species){
	foreach my $sp (@ignore_species){
		$ignore{ $sp } = 1;
	}
	printf("\n# ignored species : %d\n\n",scalar(keys(%ignore)));
}

if($seqtype ne 'protein' && $seqtype ne 'cdna'){
	die "# ERROR: accepted values for seqtype are: protein|cdna\n"
} else {
	if($seqtype eq 'protein'){ 
		$ext = '.faa';
		$seqfolder = 'pep';
	}
   else{ 
		$ext = '.fna'; 
		$seqfolder = 'cdna';
	}
}

if($outfolder){
	if(-e $outfolder){ print "\n# WARNING : folder '$outfolder' exists, files might be overwritten\n\n" }
	else{ 	 
		if(!mkdir($outfolder)){ die "# ERROR: cannot create $outfolder\n" }
	}

	# create $clusterdir with $params
	$clusterdir .= $params;
	if(!-e "$outfolder/$clusterdir"){
		if(!mkdir("$outfolder/$clusterdir")){ die "# ERROR: cannot create $outfolder/$clusterdir\n" }
	}
} else {
	print "# ERROR: need a valid output folder, such as -f Brassicaceae\n\n";
   exit;
}

if($show_supported){ print "# $0 -l \n\n" }
else {
	print "# $0 -d $division -c $taxonid -r $ref_genome -o $out_genome ".
		"-f $outfolder -t $seqtype -G $GOC -W $WGA -L $LOWCONF\n\n";
}

my $start_time = new Benchmark();

# new object for REST requests
my $http = HTTP::Tiny->new();
my $global_headers = { 'Content-Type' => 'application/json' };
my $request_count = 0; # global counter to avoid overload

## 0) check supported species in division ##################################################

$request = $INFOPOINT."Ensembl$division?";

$response = perform_rest_action( $request, $global_headers );
my $infodump = decode_json($response);

foreach $sp (@{ $infodump }) {
	if($sp->{'has_peptide_compara'}){
		$division_supported{ $sp->{'name'} } = 1;
	}	
}

# list supported species and exit
if($show_supported){

	foreach $sp (sort(keys(%division_supported))){
		print "$sp\n";
	}
	exit;
}

# check outgroup is supported
if($out_genome && !$division_supported{ $out_genome }){
	die "# ERROR: genome $out_genome is not supported\n";
}

## 1) check species in clade ##################################################################

my ($n_of_species, $cluster_id) = ( 0, '' );
my (@supported_species, @cluster_ids, %supported);
my (%incluster, %cluster, %sequence, %totalgenes, %POCP_matrix);

$request = $TAXOPOINT."$taxonid?";

$response = perform_rest_action( $request, $global_headers );
$infodump = decode_json($response);

foreach $sp (@{ $infodump }) {
   if($sp->{'name'} && $division_supported{ $sp->{'name'} }){

		next if($ignore{ $sp->{'name'} });

		# add sorted clade species except reference
		$supported{ $sp->{'name'} } = 1;
		if( $sp->{'name'} ne $ref_genome ){
			push(@supported_species, $sp->{'name'});
		}
   }
}

# check reference genome is supported 
if(!$supported{ $ref_genome }){
	die "# ERROR: cannot find $ref_genome within NCBI taxon $taxonid\n";
} else {
	unshift(@supported_species, $ref_genome);

	if($verbose){
		foreach $sp (@supported_species){
			print "# $sp\n";
		}
	}
}

printf("# supported species in NCBI taxon %s : %d\n\n", $taxonid, scalar(@supported_species));

# add outgroup if required
if($out_genome){
	push(@supported_species,$out_genome);
	$supported{ $out_genome } = 1;
	print "# outgenome: $out_genome\n";
}

$n_of_species = scalar( @supported_species );
print "# total selected species : $n_of_species\n\n";

## 2) get orthologous (plant) genes shared by selected species ####################

# columns of TSV file 
my ($gene_stable_id,$prot_stable_id,$species,$identity,$homology_type,$hom_gene_stable_id,
   $hom_prot_stable_id,$hom_species,$hom_identity,$dn,$ds,$goc_score,$wga_coverage,
	$high_confidence,$homology_id);

# iteratively get and parse TSV & FASTA files, starting with reference, to compile clusters
# of sequences made by Ensembl Compara
foreach $sp ( @supported_species ){

	# get TSV file; these files are bulky and might take some time to download
	my $stored_compara_file = download_compara_TSV_file( $comparadir, $sp );

	# uncompress on the fly and parse
	my %compara_isoform;
	open(TSV,"gzip -dc $stored_compara_file |") || die "# ERROR: cannot open $stored_compara_file\n";
	while(my $line = <TSV>){

		#ATMG00030       ATMG00030.1     arabidopsis_thaliana    52.3364 ortholog_one2many       \
		#Tp57577_TGAC_v2_gene25507       Tp57577_TGAC_v2_mRNA26377       trifolium_pratense      \
		#16.8675 NULL    NULL    NULL    NULL    0       84344678

		($gene_stable_id,$prot_stable_id,$species,$identity,$homology_type,$hom_gene_stable_id,
		$hom_prot_stable_id,$hom_species,$hom_identity,$dn,$ds,$goc_score,$wga_coverage,    
		$high_confidence,$homology_id) = split(/\t/,$line);

		next if(!$supported{ $hom_species });

		if($LOWCONF == 0 && ($high_confidence eq 'NULL' || $high_confidence == 0)){
			print "# skip $prot_stable_id,$hom_prot_stable_id due to low-confidence\n" if($verbose);
			next; 
		}

		next if($WGA && ($wga_coverage eq 'NULL' || $wga_coverage < $WGA));

		next if($GOC && ($goc_score eq 'NULL' || $goc_score < $GOC));

		if($homology_type =~ m/ortholog/) {

			# add $species protein to cluster only if not clustered yet
			if(!$incluster{ $prot_stable_id }){

				if($incluster{ $hom_prot_stable_id }){

					# use existing cluster_id from other species ortholog
					$cluster_id = $incluster{ $hom_prot_stable_id };
				} else {

					# otherwise create a new one
					$cluster_id = $prot_stable_id;
					push(@cluster_ids, $cluster_id);
				}

				# record to which cluster this protein belongs
				$incluster{ $prot_stable_id } = $cluster_id;
			
				push(@{ $cluster{ $cluster_id }{ $species } }, $prot_stable_id );

			} else {
				# set cluster for $hom_species anyway 
				$cluster_id = $incluster{ $prot_stable_id };
			}
			
			# now add $hom_species protein to previously defined cluster
         if(!$incluster{ $hom_prot_stable_id }){

				# record to which cluster this protein belongs
            $incluster{ $hom_prot_stable_id } = $cluster_id;

            push(@{ $cluster{ $cluster_id }{ $hom_species } }, $hom_prot_stable_id );
         } 

			# save isoforms used in compara
			$compara_isoform{$prot_stable_id} = 1;
		} 
	}
	close(TSV);

	# now get FASTA file and parse it, selected/longest isoforms are read
   my $stored_sequence_file = download_FASTA_file( $fastadir, "$sp/$seqfolder"  );
	my $ref_sequence = parse_isoform_FASTA_file( $stored_sequence_file, \%compara_isoform );

	# count number of genes/selected isoforms in this species
	$totalgenes{ $sp } = scalar(keys(%$ref_sequence));

	# save these sequences
	foreach $prot_stable_id (keys(%$ref_sequence)){
		$sequence{$species}{$prot_stable_id} = $ref_sequence->{$prot_stable_id};		
	}
}

# add unclustered sequences as singletons
foreach $sp (@supported_species){

	my $singletons = 0;
	
	foreach $prot_stable_id (sort keys(%{ $sequence{ $sp } })){

		next if($incluster{ $prot_stable_id }); # skip

		# create new cluster
		$cluster_id = $prot_stable_id;
		$incluster{ $prot_stable_id } = $cluster_id;

      push(@{ $cluster{ $cluster_id }{ $sp } }, $prot_stable_id );
		push(@cluster_ids, $cluster_id);

		$singletons++;
	}

	printf("# %s : sequences = %d singletons = %d\n",$sp,$totalgenes{$sp},$singletons);
}

## 3) write sequence clusters, summary text file and POCP matrix #################

# POCP=Percent Conserved Sequences (POCP) matrix 
my $POCP_matrix_file = "$outfolder/POCP.matrix$params\.tab";

my $cluster_summary_file  = "$outfolder/$clusterdir.cluster_list";

open(CLUSTER_LIST,">",$cluster_summary_file) || 
	die "# ERROR: cannot create $cluster_summary_file\n";

$n_core_clusters = 0;

foreach $cluster_id (@cluster_ids){

   if(scalar(keys(%{ $cluster{ $cluster_id } })) == $n_of_species){
		$n_core_clusters++;
	}

   # sequence cluster
   $n_cluster_sp=$n_cluster_seqs=0;
   $filename = $cluster_id;

   # for summary, in case this was run twice (cdna & prot)
   $dnafile = $filename . '.fna';
   $pepfile = $filename . '.faa';

   # write sequences and count sequences
	my (%cluster_stats,@cluster_species);
   open(CLUSTER,">","$outfolder/$clusterdir/$filename$ext") ||
      die "# ERROR: cannot create $outfolder/$clusterdir/$filename$ext\n";
   foreach $species (@supported_species){
      next if(! $cluster{ $cluster_id }{ $species } );
      $n_cluster_sp++;
      foreach $prot_stable_id (@{ $cluster{ $cluster_id }{ $species } }){
         print CLUSTER ">$prot_stable_id [$species]\n$sequence{$species}{$prot_stable_id}\n";
         $n_cluster_seqs++;
			$cluster_stats{$species}++;
      }
   }
   close(CLUSTER);

   # cluster summary 
	@cluster_species = keys(%cluster_stats);
   if(!-s "$outfolder/$clusterdir/$dnafile"){ $dnafile = 'void' }
   if(!-s "$outfolder/$clusterdir/$pepfile"){ $pepfile = 'void' }
   print CLUSTER_LIST "cluster $cluster_id size=$n_cluster_seqs taxa=$n_cluster_sp file: $dnafile aminofile: $pepfile\n";
   foreach $species (@cluster_species){
      foreach $prot_stable_id (@{ $cluster{ $cluster_id }{ $species } }){
         print CLUSTER_LIST ": $species\n";
      }
   }

	# update PCOP data
	foreach $sp (0 .. $#cluster_species-1){
		foreach $sp2 ($sp+1 .. $#cluster_species){

			# add the number of sequences in this cluster from a pair of species/taxa
			$POCP_matrix{$cluster_species[$sp]}{$cluster_species[$sp2]} += $cluster_stats{$cluster_species[$sp]};
			$POCP_matrix{$cluster_species[$sp]}{$cluster_species[$sp2]} += $cluster_stats{$cluster_species[$sp2]};

			# now in reverse order to make sure it all adds up
			$POCP_matrix{$cluster_species[$sp2]}{$cluster_species[$sp]} += $cluster_stats{$cluster_species[$sp]};
         $POCP_matrix{$cluster_species[$sp2]}{$cluster_species[$sp]} += $cluster_stats{$cluster_species[$sp2]};
		}
	}
}

close(CLUSTER_LIST);

printf("\n# number_of_clusters = %d (core = %d)\n\n",scalar(@cluster_ids),$n_core_clusters);
print "# cluster_list = $outfolder/$clusterdir.cluster_list\n";
print "# cluster_directory = $outfolder/$clusterdir\n";

# print POCP matrix
open(POCPMATRIX,">$POCP_matrix_file") || 
	die "# EXIT: cannot create $POCP_matrix_file\n";

print POCPMATRIX "genomes";
foreach $sp (0 .. $#supported_species){
	print POCPMATRIX "\t$supported_species[$sp]";
} print POCPMATRIX "\n";

foreach $sp (0 .. $#supported_species){
	print POCPMATRIX "$supported_species[$sp]";
	foreach $sp2 (0 .. $#supported_species){

		if($sp == $sp2){ print POCPMATRIX "\t100" }
		else{
			if($POCP_matrix{$supported_species[$sp]}{$supported_species[$sp2]}){
				printf(POCPMATRIX "\t%1.2f",
					(100*$POCP_matrix{$supported_species[$sp]}{$supported_species[$sp2]}) /
					($totalgenes{$supported_species[$sp]} + $totalgenes{$supported_species[$sp2]}));
			} else {	
				print POCPMATRIX "\tNA";
			}
		}
	}
	print POCPMATRIX "\n";
}
close(POCPMATRIX);

print "\n# percent_conserved_proteins_file = $POCP_matrix_file\n\n";

## 4)  write pangenome matrices in output folder ####################

# set matrix filenames and write headers
my $pangenome_matrix_file = "$outfolder/pangenome_matrix$params\.tab";
my $pangenome_gene_file   = "$outfolder/pangenome_matrix_genes$params\.tab";
my $pangenome_matrix_tr   = "$outfolder/pangenome_matrix$params\.tr.tab";
my $pangenome_gene_tr   = "$outfolder/pangenome_matrix_genes$params\.tr.tab";
my $pangenome_fasta_file  = "$outfolder/pangenome_matrix$params\.fasta";

open(PANGEMATRIX,">$pangenome_matrix_file") ||
	die "# EXIT: cannot create $pangenome_matrix_file\n";

open(PANGENEMATRIX,">$pangenome_gene_file") || 
   die "# EXIT: cannot create $pangenome_gene_file\n";

print PANGEMATRIX "source:$outfolder/$clusterdir";
foreach $cluster_id (@cluster_ids){ print PANGEMATRIX "\t$cluster_id$ext"; }
print PANGEMATRIX "\n";
  
print PANGENEMATRIX "source:$outfolder/$clusterdir";
foreach $cluster_id (@cluster_ids){ print PANGENEMATRIX "\t$cluster_id$ext"; }
print PANGENEMATRIX "\n";

open(PANGEMATRIF,">$pangenome_fasta_file") || 
	die "# EXIT: cannot create $pangenome_fasta_file\n";

foreach $species (@supported_species){

	print PANGEMATRIX "$species";
	print PANGENEMATRIX "$species";
	print PANGEMATRIF ">$species\n";

	foreach $cluster_id (@cluster_ids){

		if($cluster{ $cluster_id }{ $species }){
			printf(PANGEMATRIX "\t%d", scalar(@{ $cluster{ $cluster_id }{ $species } }));
			printf(PANGENEMATRIX "\t%s", join(',',@{ $cluster{ $cluster_id }{ $species } }) );
			print PANGEMATRIF "1";
		} else { # absent genes
			print PANGEMATRIX "\t0"; 
			print PANGENEMATRIX "\t-"; 
			print PANGEMATRIF "0";
		}
	}

	print PANGEMATRIX "\n";
	print PANGENEMATRIX "\n";
	print PANGEMATRIF "\n";
}

close(PANGEMATRIX);
close(PANGENEMATRIX);
close(PANGEMATRIF);

system("$TRANSPOSEXE $pangenome_matrix_file > $pangenome_matrix_tr");
system("$TRANSPOSEXE $pangenome_gene_file > $pangenome_gene_tr");

print "# pangenome_file = $pangenome_matrix_file tranposed = $pangenome_matrix_tr\n";
print "# pangenome_genes = $pangenome_gene_file transposed = $pangenome_gene_tr\n";
print "# pangenome_FASTA_file = $pangenome_fasta_file\n";


## 5) make genome composition analysis to simulate pangenome growth

  my ($s,$t,$t2,@pangenome,@coregenome,@softcore,$n_of_permutations,$soft_taxa); #$s = sample, $t=taxon to be added, $t2=taxon to compare
  my ($mean,$sd,$data_file,$sort,%previous_sorts,%inparalogues,%homol_registry,@sample,@clusters);
  my @tmptaxa = @taxa;
  my $n_of_taxa = scalar(@tmptaxa);

  if($include_file) # add 0 && if you wish $NOFSAMPLESREPORT samples even if using a -I include file
  {
    $NOFSAMPLESREPORT = 1;
    print "\n# genome composition report (samples=1, using sequence order implicit in -I file: $include_file)\n";
  }
  else
  {
    $n_of_permutations = sprintf("%g",factorial($n_of_taxa));
    if($n_of_permutations < $NOFSAMPLESREPORT){ $NOFSAMPLESREPORT = $n_of_permutations; }
    print "\n# genome composition report (samples=$NOFSAMPLESREPORT,permutations=$n_of_permutations,seed=$random_number_generator_seed)\n";
  }

  for($s=0;$s<$NOFSAMPLESREPORT;$s++) # random-sort the list of taxa $NOFSAMPLESREPORT times
  { 
    #if($s) # in case you wish $NOFSAMPLESREPORT samples even if using a -I include file
    if(!$include_file && $s) # reshuffle until a new permutation is obtained, conserve input order in first sample
    {
      $sort = fisher_yates_shuffle( \@tmptaxa );
      while($previous_sorts{$sort}){ $sort = fisher_yates_shuffle( \@tmptaxa ); }
      $previous_sorts{$sort} = 1;
    }
    push(@{$sample[$s]},@tmptaxa);
  }


  for($t=0;$t<$n_of_taxa;$t++){ print "# $t $taxa[$t]\n"; } print "\n";

  # 3.0.1) sample taxa in random order
  for($s=0;$s<$NOFSAMPLESREPORT;$s++)
  {
    my (%n_of_taxa_in_cluster,%n_of_homs_in_genomes,$sample);
    @tmptaxa = @{$sample[$s]};

    $sample = "## sample $s ($tmptaxa[0] | ";
    for($t=0;$t<$n_of_taxa;$t++)
    {
      $t2=0;
      while($tmptaxa[$t] ne $taxa[$t2]){ $t2++ }
      $sample .= "$t2,";

      # arbitrary trimming
      if(length($sample)>70){ $sample .= '...'; last }
    }
    $sample .= ')';
    print "$sample\n";

    # 3.0.2) calculate pan/core-genome size adding genomes one-by-one
      my $n_of_inparalogues = 0;
      foreach $cluster (@clusters)
      {
        foreach $taxon (keys(%{$orth_taxa{$cluster}}))
        {
          next if($taxon ne $tmptaxa[0]);
          $n_of_inparalogues += ($orth_taxa{$cluster}{$taxon}-1);
          last;
        }
      }
      $coregenome[$s][0] = $gindex{$tmptaxa[0]}[2] - $n_of_inparalogues;
      if($do_soft){ $softcore[$s][0] = $coregenome[$s][0] }
      $pangenome[$s][0]  = $coregenome[$s][0];
      print "# adding $tmptaxa[0]: core=$coregenome[$s][0] pan=$pangenome[$s][0]\n";

   for($t=1;$t<$n_of_taxa;$t++)
    {
      $coregenome[$s][$t] = 0;
      $pangenome[$s][$t] = $pangenome[$s][$t-1];

      # core genome
      if($doMCL || $doPARANOID || $doCOG)
      {
        CLUSTER: foreach $cluster (@clusters)
        {
          # potential core clusters must contain sequences from reference taxon $tmptaxa[0]
          # this check is done only once ($t=1)
          next if($t == 1 && !$do_soft && !$orth_taxa{$cluster}{$tmptaxa[0]});
          
          foreach $taxon (keys(%{$orth_taxa{$cluster}}))
          {
            if($taxon eq $tmptaxa[$t])
            {
              $n_of_taxa_in_cluster{$cluster}++; # taxa added starting from $t=1
              
              if($orth_taxa{$cluster}{$tmptaxa[0]} && $n_of_taxa_in_cluster{$cluster} == $t)
              {
                $coregenome[$s][$t]++;  # update core totals
                if($do_soft){ $softcore[$s][$t]++ }
              }
              elsif($do_soft) 
              {
                $soft_taxa = $n_of_taxa_in_cluster{$cluster} || 0;
                if($orth_taxa{$cluster}{$tmptaxa[0]}){ $soft_taxa++ }
                
                if($soft_taxa >= int(($t+1)*$SOFTCOREFRACTION))
                {
                  $softcore[$s][$t]++;  
                }
              }
                     
              next CLUSTER;
            }
          }
        }
        #print "# adding $tmptaxa[$t]: core=$coregenome[$s][$t] pan=$pangenome[$s][$t]\n";

		  # pan genome (unique genes) : those without hits in last added genome when compared to all previous
      for($t2=$t-1;$t2>=0;$t2--)
      {
        $label = $tmptaxa[$t].' '.$tmptaxa[$t2];
        if(!$homol_registry{$label} && ($runmode eq 'cluster' &&
            !-e get_makeHomolog_outfilename($tmptaxa[$t],$tmptaxa[$t2])))
        {
          $redo_orth = $diff_HOM_params;
          $homol_registry{$label} = 1;
        }
        elsif($runmode eq 'local')
        {
          $redo_orth = $diff_HOM_params;
        }
        else{ $redo_orth = 0 }

        print "# finding homologs between $tmptaxa[$t] and $tmptaxa[$t2]\n";
        my $ref_homol = makeHomolog($saveRAM,$tmptaxa[$t],$tmptaxa[$t2],$evalue_cutoff,
          $MIN_PERSEQID_HOM,$MIN_COVERAGE_HOM,$redo_orth);

        foreach $gene ($gindex{$tmptaxa[$t]}[0] .. $gindex{$tmptaxa[$t]}[1])
        {
          if($ref_homol->{$gene}){ $n_of_homs_in_genomes{$gene}++; }
        }
      }

		# label inparalogues in OMCL,PRND,COGS clusters to avoid over-estimating pangenome
      if($doMCL || $doPARANOID || $doCOG)
      {
        %inparalogues = ();
        foreach $cluster (@clusters)
        {
          # skip clusters with <2 $t sequences
          next if(!$orth_taxa{$cluster}{$tmptaxa[$t]} ||
            $orth_taxa{$cluster}{$tmptaxa[$t]} < 2);

          foreach $gene (@{$orthologues{$cluster}})
          {
            next if($gindex2[$gene] ne $tmptaxa[$t]);
            $inparalogues{$gene} = 1;
          }
        }
      }

      # update pan total
      foreach $gene ($gindex{$tmptaxa[$t]}[0] .. $gindex{$tmptaxa[$t]}[1])
      {
        next if($n_of_homs_in_genomes{$gene} || $inparalogues{$gene});

        $pangenome[$s][$t]++;
      }

      print "# adding $tmptaxa[$t]: core=$coregenome[$s][$t] pan=$pangenome[$s][$t]\n";
    }
  }

  # 3.0.3) print pan-genome composition stats
  $data_file = $newDIR ."/pan_genome".$pancore_mask.".tab";
  print "\n# pan-genome (number of genes, can be plotted with plot_pancore_matrix.pl)\n# file=".
    short_path($data_file,$pwd)."\n";
  print "genomes\tmean\tstddev\t|\tsamples\n";
  for($t=0;$t<$n_of_taxa;$t++)
  {
    my @data;
    for($s=0;$s<$NOFSAMPLESREPORT;$s++){ push(@data,$pangenome[$s][$t]) }
    $mean = sprintf("%1.0f",calc_mean(\@data));
    $sd = sprintf("%1.0f",calc_std_deviation(\@data));
    print "$t\t$mean\t$sd\t|\t";
    for($s=0;$s<$NOFSAMPLESREPORT;$s++){ print "$pangenome[$s][$t]\t"; } print "\n";
  }

  # 3.0.4) create input file for pan-genome composition boxplot
  open(BOXDATA,">$data_file") || die "# EXIT: cannot create $data_file\n";
  for($t=0;$t<$n_of_taxa;$t++)
  {
    $label = 'g'.($t+1);
    print BOXDATA "$label\t";
  } print BOXDATA "\n";

  for($s=0;$s<$NOFSAMPLESREPORT;$s++)
  {
    for($t=0;$t<$n_of_taxa;$t++){ print BOXDATA "$pangenome[$s][$t]\t";}
    print BOXDATA "\n";
  }
  close(BOXDATA);

  # 3.0.5) print core-genome composition stats
  $data_file = $newDIR ."/core_genome".$pancore_mask.".tab";
  print "\n# core-genome (number of genes, can be plotted with plot_pancore_matrix.pl)\n# file=".
    short_path($data_file,$pwd)."\n";
  print "genomes\tmean\tstddev\t|\tsamples\n";
  for($t=0;$t<$n_of_taxa;$t++)
  {
    my @data;
    for($s=0;$s<$NOFSAMPLESREPORT;$s++){ push(@data,$coregenome[$s][$t]) }
    $mean = sprintf("%1.0f",calc_mean(\@data));
    $sd = sprintf("%1.0f",calc_std_deviation(\@data));
    print "$t\t$mean\t$sd\t|\t";
    for($s=0;$s<$NOFSAMPLESREPORT;$s++){ print "$coregenome[$s][$t]\t"; } print "\n";
  }

  # 3.0.6) create input file for core-genome composition boxplot
  open(BOXDATA,">$data_file") || die "# EXIT : cannot create $data_file\n";
  for($t=0;$t<$n_of_taxa;$t++)
  {
    $label = 'g'.($t+1);
    print BOXDATA "$label\t";
  } print BOXDATA "\n";

  for($s=0;$s<$NOFSAMPLESREPORT;$s++)
  {
    for($t=0;$t<$n_of_taxa;$t++){ print BOXDATA "$coregenome[$s][$t]\t";}
    print BOXDATA "\n";
  }
  close(BOXDATA);


    



my $end_time = new Benchmark();
print "\n# runtime: ".timestr(timediff($end_time,$start_time),'all')."\n";

###################################################################################################

# parses a FASTA file, either pep or cdna, downloaded with download_FASTA_file
# returns a isoform=>sequence hash with the (optionally) selected or (default) longest peptide/transcript per gene
sub parse_isoform_FASTA_file {

	my ($FASTA_filename, $ref_isoforms2keep) = @_;

	my ($stable_id, $gene_stable_id, $max, $len);
	my ($iso_selected, $len_selected);
	my (%sequence, %sequence4gene);

   open(FASTA,"gzip -dc $FASTA_filename |") || die "# ERROR: cannot open $FASTA_filename\n";
   while(my $line = <FASTA>){
      #>g00297.t1 pep supercontig:Ahal2.2:FJVB01000001.1:1390275:1393444:1 gene:g00297 ...
      if($line =~ m/^>(\S+).*?gene:(\S+)/){
         $stable_id = $1; # might pep or cdna id
         $gene_stable_id = $2;
      } elsif($line =~ m/^(\S+)/){
         $sequence{ $gene_stable_id }{ $stable_id } .= $1;
      }
   }
   close(FASTA);

	foreach $gene_stable_id (keys(%sequence)){

		# work out which isoform should be kept for this gene
		($max,$iso_selected,$len_selected) = (0,'','');
		foreach $stable_id (keys(%{ $sequence{$gene_stable_id} })){

			# find longest isoform (default), note that key order is random
			$len = length($sequence{ $gene_stable_id }{ $stable_id });
			if($len > $max){ 
				$max = $len;
				$len_selected = $stable_id;
			}

			if($ref_isoforms2keep->{ $stable_id }){
				$iso_selected = $stable_id;
			}
		}

		if($iso_selected){
			$sequence4gene{ $iso_selected } = $sequence{ $gene_stable_id }{ $iso_selected };
		} elsif($len_selected){
			$sequence4gene{ $len_selected } = $sequence{ $gene_stable_id }{ $len_selected };
		} else {
			print "# ERROR: cannot select an isoform for gene $gene_stable_id\n";
		}
	}

	return \%sequence4gene;
}


# download compressed TSV file from FTP site, renames it 
# and saves it in current folder; uses FTP globals defined above
sub download_compara_TSV_file {

	my ($dir,$ref_genome) = @_;
	my ($compara_file,$stored_compara_file) = ('','');

	if(my $ftp = Net::FTP->new($FTPURL,Passive=>1,Debug =>0,Timeout=>60)){
		$ftp->login("anonymous",'-anonymous@') ||
			die "# cannot login ". $ftp->message();
		$ftp->cwd($dir) ||
		   die "# ERROR: cannot change working directory to $dir ". $ftp->message();
		$ftp->cwd($ref_genome) ||
			die "# ERROR: cannot find $ref_genome in $dir ". $ftp->message();

		# find out which file is to be downloaded and 
		# work out its final name with $ref_genome in it
		foreach my $file ( $ftp->ls() ){
			if($file =~ m/protein_default.homologies.tsv.gz/){
				$compara_file = $file;
				$stored_compara_file = $compara_file;
				$stored_compara_file =~ s/tsv.gz/$ref_genome.tsv.gz/;
				last;
			}
		}
		
		# download that TSV file
		unless(-s $stored_compara_file){
			$ftp->binary();
			my $downsize = $ftp->size($compara_file);
			$ftp->hash(\*STDOUT,$downsize/20) if($downsize);
			printf("# downloading %s (%1.1fMb) ...\n",$stored_compara_file,$downsize/(1024*1024));
			print "# [        50%       ]\n# ";
			if(!$ftp->get($compara_file)){
				die "# ERROR: failed downloading $compara_file\n";
			}

			# rename file to final name
			rename($compara_file, $stored_compara_file);
			print "# using $stored_compara_file\n\n";
		} else {
			print "# re-using $stored_compara_file\n\n";
		}
	} else { die "# ERROR: cannot connect to $FTPURL , please try later\n" }

	return $stored_compara_file;
}

# download compressed FASTA file from FTP site, and saves it in current folder; 
# uses FTP globals defined above
sub download_FASTA_file {

   my ($dir,$genome_folder) = @_;
   my ($fasta_file) = ('');

   if(my $ftp = Net::FTP->new($FTPURL,Passive=>1,Debug =>0,Timeout=>60)){
      $ftp->login("anonymous",'-anonymous@') ||
         die "# cannot login ". $ftp->message();
      $ftp->cwd($dir) ||
         die "# ERROR: cannot change working directory to $dir ". $ftp->message();
      $ftp->cwd($genome_folder) ||
         die "# ERROR: cannot find $genome_folder in $dir ". $ftp->message();

      # find out which file is to be downloaded and 
      # work out its final name
      foreach my $file ( $ftp->ls() ){
         if($file =~ m/all.fa.gz/){
            $fasta_file = $file;
            last;
         }
      }

		# download that FASTA file
      unless(-s $fasta_file){
         $ftp->binary();
         my $downsize = $ftp->size($fasta_file);
         $ftp->hash(\*STDOUT,$downsize/20) if($downsize);
         printf("# downloading %s (%1.1fMb) ...\n",$fasta_file,$downsize/(1024*1024));
         print "# [        50%       ]\n# ";
         if(!$ftp->get($fasta_file)){
            die "# ERROR: failed downloading $fasta_file\n";
         }

         print "# using $fasta_file\n\n";
      } else {
         print "# re-using $fasta_file\n\n";
      }
   } else { die "# ERROR: cannot connect to $FTPURL , please try later\n" }

   return $fasta_file;
}

# uses global $request_count
# based on examples at https://github.com/Ensembl/ensembl-rest/wiki/Example-Perl-Client
sub perform_rest_action {
	my ($url, $headers) = @_;
	$headers ||= {};
	$headers->{'Content-Type'} = 'application/json' unless exists $headers->{'Content-Type'};

	if($request_count == 15) { # check every 15
		my $current_time = Time::HiRes::time();
		my $diff = $current_time - $last_request_time;

		# if less than a second then sleep for the remainder of the second
		if($diff < 1) {
			Time::HiRes::sleep(1-$diff);
		}
		# reset
		$last_request_time = Time::HiRes::time();
		$request_count = 0;
	}

	my $response = $http->get($url, {headers => $headers});
	my $status = $response->{status};
	
	if(!$response->{success}) {
		# check for rate limit exceeded & Retry-After (lowercase due to our client)
		if(($status == 429 || $status == 599) && exists $response->{headers}->{'retry-after'}) {
			my $retry = $response->{headers}->{'retry-after'};
			Time::HiRes::sleep($retry);
			# afterr sleeping see that we re-request
			return perform_rest_action($url, $headers);
		}
		else {
			my ($status, $reason) = ($response->{status}, $response->{reason});
			die "# ERROR: failed REST request $url\n# Status code: ${status}\n# Reason: ${reason}\n# Please re-run";
		}
	}

	$request_count++;

	if(length($response->{content})) { return $response->{content} } 
	else { return '' }	
}
