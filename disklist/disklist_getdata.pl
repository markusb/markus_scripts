#!/usr/bin/perl -w
#
# disklist_getdata.pl
#
# fetch all disk related data from the involved hosts into a sqlite database
#
# the companion script disklist_cgi.pl analyzed the data and displays
# reports in html.
#
# Changes:
# 14.05.08  Markus Baertschi
#           Initial version
 
# Define perl modules used
use strict;
use DBI;
use Getopt::Std;
use Time::localtime;
 
# Define global vars, analyze command line
my $starttime = time();
my $dbfile = "/tmp/disklist.sqlite";
my $dbh;
my %args;
getopts("hvdqD:f:p:",\%args);
 
# print only if verbose flag -v on
sub printv {
  if ($args{"v"}) {
    print @_;
  }
}
 
# don't print if quiet flag -q on
sub printq {
  if (! $args{"q"}) {
    print @_;
  }
}
 
# Create a table in database if it does not yet exist
sub check_create_table {
  my $tname = shift;
  my $tdef = shift;
 
  if (db_getsingle("SELECT name FROM sqlite_master WHERE type='table' and name='$tname'")) {
    printv "Table $tname exists, leaving alone\n";
  } else {
    printv "Creating table $tname\n";
    $dbh->do("CREATE TABLE $tname ($tdef);") or die "Error creating table $tname (\"$tdef\")";;
  }
}
 
# Initialize database, drop/recreate table(s)
sub init_db {
  printq "Initializing database file $dbfile\n";
  $dbh = DBI->connect("dbi:SQLite2:dbname=$dbfile","","")
    or die "Error connecting to db file $dbfile";
 
  if ($args{"D"}) {
    printq "Dropping table ".$args{"D"}."\n";
    $dbh->do("DROP TABLE ".$args{"D"}.";") or die "Error dropping table ".$args{"D"}."\n";
  }
  check_create_table("vars","name TEXT, contents TEXT");
  check_create_table("hdisk","hostname TEXT, hdisk TEXT, pvid TEXT, lun TEXT, vg TEXT, size TEXT, state TEXT, loc TEXT, desc TEXT");
  check_create_table("paths","hostname TEXT, hdisk TEXT, pathid TEXT, parent TEXT, connid TEXT, lun TEXT, ploc TEXT, pslot TEXT, state TEXT");
  check_create_table("partitions","hostname TEXT, partname TEXT, partid TEXT, system TEXT, hmc TEXT, state TEXT, lparenv");
  check_create_table("viomap","vioname TEXT, partid TEXT, hdisk TEXT, vtd TEXT, vhost TEXT, lun TEXT, slot TEXT, loc TEXT, ploc TEXT");
  check_create_table("scsimap","system TEXT, lpar_id TEXT,lpar_names TEXT,slot TEXT,atype TEXT,rp_id TEXT,rp_name TEXT,rp_slot TEXT,rp_port TEXT");
}
 
# get hdisk information from host
sub fill_db_hdisk {
  my $hostname = shift;
  my $cmd;
  printq "Fetching hdisk data from $hostname\n";
  $dbh->do("DELETE FROM hdisk WHERE hostname='$hostname';") or die "Error deleting rows from hdisk table\n";
  open(SHELL,"ssh $hostname lspv |") or die "Error running lspv";
  while(<SHELL>) {
    chop;
    my ($hdisk,$pvid,$vg,$dummy)=split(/\s+/,$_,4);
    printv "hdisk: $hostname - $hdisk - $pvid\n";
    $dbh->do("INSERT INTO hdisk (hostname,hdisk,pvid,vg) VALUES('$hostname','$hdisk','$pvid','$vg');") or die "Error updating table";
  }
  close(SHELL);
  open(SHELL,"ssh $hostname lsdev -cdisk |") or die "Error running lsdev";
  while(<SHELL>) {
    chop;
    my ($hdisk,$state,$loc,$desc)=split(/\s+/,$_,4);
    printv "hdisk: $hostname - $hdisk - $state\n";
    $dbh->do("UPDATE hdisk SET state='$state' WHERE hdisk='$hdisk' AND hostname='$hostname';") or die "Error updating table";
  }
  close(SHELL);
  $cmd = "ssh $hostname ".'\'for D in $(lsdev -cdisk -Fname); do echo "$D \c"; bootinfo -s $D; done\' |';
  open(SHELL,$cmd) or die "Error running lspv";
  while(<SHELL>) {
    chop;
    my ($hdisk,$size)=split(/\s+/,$_,2);
    printv "hdisk: $hostname - $hdisk - $size\n";
    $dbh->do("UPDATE hdisk SET size='$size' WHERE hdisk='$hdisk' AND hostname='$hostname';") or die "Error updating table";
  }
  close(SHELL);
  $cmd = "ssh $hostname ".'\'for D in $(lsdev -cdisk -Fname); do lscfg -l "$D"; done\' |';
  open(SHELL,$cmd) or die "Error running lspv";
  while(<SHELL>) {
    chop;
    my ($dummy,$hdisk,$loc,$desc)=split(/\s+/,$_,4);
    my $lun = $loc;
    $lun =~ s/^.*-L8*//; $lun =~ s/0*$//; $lun=hex($lun);
    printv "hdisk: $hostname - $hdisk - $loc - $lun - $desc\n";
    $dbh->do("UPDATE hdisk SET loc='$loc',desc='$desc',lun='$lun' WHERE hdisk='$hdisk' AND hostname='$hostname';") or die "Error updating table";
  }
  close(SHELL);
}
 
# Isolate slot information from location string
sub slot_from_loc {
  my $loc = shift;
 
  my $slot = $loc;
  $slot =~ s/.*-[PC]//;
  $slot =~ s/-T.*//;
 
  return $slot;
}
 
# Fetch path information from host
sub fill_db_paths {
  my $hostname = shift;
  my %ploc;
  printq "Fetching path information from $hostname\n";
  $dbh->do("BEGIN TRANSACTION;") or die "Error starting transaction for paths table\n";
  $dbh->do("DELETE FROM paths WHERE hostname='$hostname';") or die "Error deleting rows from paths table\n";
  open(SHELL,"ssh $hostname lspath -F name:status:path_id:parent:connection |") or die "Error running lspath";
  while(<SHELL>) {
    chop;
    my ($hdisk,$state,$pathid,$parent,$conn)=split(/:/,$_);
    if (!$ploc{$parent}) {
      $ploc{$parent} = `ssh $hostname lscfg -l $parent | awk '{print \$2}'`;
      chop $ploc{$parent};
    }
    my $pslot = slot_from_loc($ploc{$parent});
    $pslot =~ s/.*-[PC]//;
    $pslot =~ s/-T.*//;
    my $lun = $conn; $lun =~ s/^8//; $lun =~ s/0+$//; $lun =~ s/.*,//; $lun=hex($lun);
    printv "paths: $hostname - $hdisk - $parent - $lun\n";
    $dbh->do("INSERT INTO paths VALUES('$hostname','$hdisk','$pathid','$parent','$conn','$lun','$ploc{$parent}','$pslot','$state');") or die "Error updating table";
  }
  close(SHELL);
  $dbh->do("END TRANSACTION;") or die "Error starting transaction for paths table\n";
}
 
sub fill_db_viomap {
  my $vio = shift;
  printq "Creating vio map list ($vio)\n";
  $dbh->do("DELETE FROM viomap WHERE vioname='$vio';") or die "Error deleting rows from viomap table\n";
  open(SHELL,"ssh $vio /usr/ios/cli/ioscli lsmap -all |") or die "Error running lspath";
  my ($vhost,$loc,$partid,$vtd,$lun,$hdisk,$slot);
  while(<SHELL>) {
    chop;
    if (/^vhost/) { ($vhost,$loc,$partid) = split(/\s+/,$_,3); $slot=slot_from_loc($loc); $partid=hex($partid)}
    if (/^VTD/) { $vtd = (split(/\s+/,$_,2))[1]; }
    if (/^LUN/) { $lun = (split(/\s+/,$_,2))[1]; $lun =~ s/0x8//; $lun =~ s/0+$//; $lun=hex($lun)}
    if (/^Backing/) { $hdisk = (split(/\s+/,$_,3))[2]; }
    if (/^Physloc/) {
      my $ploc = (split(/\s+/,$_,2))[1];
      printv "viomap: $vio - $partid - $hdisk - $vtd - $vhost\n";
      $dbh->do("INSERT INTO viomap VALUES('$vio','$partid','$hdisk','$vtd','$vhost','$lun','$slot','$loc','$ploc');") or die "Error updating table";
    }
  }
  close(SHELL);
}
 
# Fetch partition and scsi mapping info from hmc
sub fill_db_hmc {
  my $uhmc = shift;
  my $sysid = shift;
  my $hmc = $uhmc; $hmc =~ s/^.*@//;
  printq "Fetching data for $sysid from hmc $hmc\n";
  $dbh->do("DELETE FROM partitions WHERE system='$sysid';") or die "Error deleting rows from partitions table\n";
  my ($vhost,$loc,$partid,$vtd,$lun,$hdisk);
  my (%profiles,%lpar_names);
  open(SHELL,"ssh $uhmc lssyscfg -r lpar -m $sysid -F name,lpar_id,default_profile,state,lpar_env |") or die "Error ssh to hmc";
  while(<SHELL>) {
    chop;
    my ($lpar_name,$lpar_id,$default_profile,$state,$lparenv) = split(/\,/,$_,5);
    $profiles{$lpar_id}=$default_profile;
    $lpar_names{$lpar_id}=$lpar_name;
    my $hostname=$lpar_name; $hostname =~ s/[\d\s]*-\s*//; # remove partition-id from lpar_name
    if ($state eq "Running") {
      printv "partitions $hostname - $lpar_name\n";
      $dbh->do("INSERT INTO partitions VALUES('$hostname','$lpar_name','$lpar_id','$sysid','$hmc','$state','$lparenv');") or die "Error updating table";
    }
  }
  close(SHELL);
  $dbh->do("DELETE FROM scsimap WHERE system='$sysid';") or die "Error deleting rows from partitions table\n";
  foreach my $lpar_id (keys %profiles) {
    open(SHELL,"ssh operator\@$hmc lssyscfg -r prof -m $sysid --filter 'lpar_ids=$lpar_id' -F name,lpar_name,virtual_scsi_adapters |") or die "Error ssh to hmc";
    while(<SHELL>) {
      chop;
      my ($prof_name,$part_name,$scsi_defs) = split(/\,/,$_,3);
      if ($prof_name eq $profiles{$lpar_id}) {
        $scsi_defs=~s/\"//g;
        foreach my $scsi_ad (split(/\,/,$scsi_defs)) {
          my ($slot,$atype,$rp_id,$rp_name,$rp_slot,$rp_port) = split(/\//,$scsi_ad,6);
          if ($slot ne "none") {
            printv "scsimap $lpar_names{$lpar_id} - $lpar_id\n";
            $dbh->do("INSERT INTO scsimap VALUES('$sysid','$lpar_id','$lpar_names{$lpar_id}','$slot','$atype','$rp_id','$rp_name','$rp_slot','$rp_port');") or die "Error updating table";
          }
        }
      }
    }
    close(SHELL);
  }
}
 
# run a select on the db and return the result
sub db_select {
  my $sql = shift;
  my $sth = $dbh->prepare($sql);
  $sth->execute();
  my @rows;
  while ( my @row = $sth->fetchrow_array ) {
    push @rows,@row;
  }
  return @rows;
}
 
# run a select on the db and return the 1st result row
sub db_getval {
  my $sql = shift;
  my $sth = $dbh->prepare($sql);
  $sth->execute();
  my @rows;
  while ( my @row = $sth->fetchrow_array ) {
    return @row;
  }
  return "";
}
 
# run a select on the db and return the 1st item
sub db_getsingle {
  my $sql = shift;
 
  return (db_getval($sql))[0];
}
 
# run a select on the db and print the result
sub print_sql {
  my $sql = shift;
  my $sth = $dbh->prepare($sql);
  $sth->execute();
  print "SQL: $sql\n";
  while ( my @row = $sth->fetchrow_array ) {
    print "@row\n";
  }
}
 
sub update_host {
  my $host = shift;
 
  printq "Refreshing data for lpar/host $host\n";
  fill_db_hdisk($host);
  fill_db_paths($host);
  if (db_getsingle("SELECT lparenv FROM partitions WHERE hostname='$host'") eq "vioserver") {
    fill_db_viomap($host);
  }
}
 
# print help information
sub usage {
  print "disklist_getdata.pl [-f <dbfile>] [-p <lpar>] [<user>@<hmc1>:<system1>,<system2>,..] [<user>@<hmc2>:<system4>,<system5>,..]\n";
  print "                    -f <dbfile>    name of the database to write/update\n";
  print "                    -p <lpar>      name of a lpar to refresh\n";
  print "                    -v             verbose\n";
  print "                    -d             debug\n";
  print "                    -q             quiet\n";
}
 
# process h and f flags
if ($args{"h"}) { usage(); exit; }
if ($args{"f"}) {
  $dbfile = $args{"f"};
}
 
printq "disklist_getdata.pl: Fetching data for disk inventory\n";
init_db();
 
if ($args{"p"}) {
  # process p flag: update single partition
  update_host($args{"p"});
} else {
  if (@ARGV==0) {
    print "Error: Insufficient arguments\n";
    print "hmc or lpar required\n";
    usage();
    exit 1;
  }
  # process all hosts on a system
  # update all hmc data
  foreach my $hmcarg (@ARGV) {
    my $hmc = $hmcarg; $hmc =~ s/:.*//;
    my $sysall = $hmcarg; $sysall =~ s/.*://;
    foreach my $sys (split(/\,/,$sysall)) {
      print fill_db_hmc($hmc,$sys);
    }
  }
  # update all host data
  foreach my $host (db_select("SELECT hostname FROM partitions WHERE state='Running';")) {
    update_host($host);
  }
}
# Update datestamp in database
my $t = localtime();
my $ds = sprintf "%02d.%02d.%02d\n",$t->mday,$t->mon+1,$t->year+1900;
my $ts = sprintf "%02d:%02d:%02d\n",$t->hour,$t->min,$t->sec;
$dbh->do("REPLACE INTO vars VALUES('update','$ds $ts');") or die "Error updating table";
 
# Print closing remarks
printq "Disk inventory saved to sqlite database $dbfile\n";
my $runtime=time()-$starttime;
printq sprintf "Runtime %i:%02i\n",$runtime/60,$runtime%60;
 
