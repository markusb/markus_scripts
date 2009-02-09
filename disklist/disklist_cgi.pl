#!/usr/bin/perl -w
#
# check_disk.pl
#
# create a disk map and check all disk connections
#
 
use strict;
use DBI;
use CGI qw/:standard/;
use CGI::Carp qw(fatalsToBrowser);
 
my $cgi = new CGI;
my $dbfile = "/work/git/markus_scripts/disklist/disklist.sqlite";
my $dbh;
my $partid;
my $host="";
my $debugtable="";
 
sub init_db {
  my $rc;
  $dbh = DBI->connect("dbi:SQLite2:dbname=$dbfile","","")
    or die "Error connecting to db file $dbfile";
}
 
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
 
sub db_getsingle {
  my $sql = shift;
 
  return (db_getval($sql))[0];
}
 
sub db_getlist {
  my $sql = shift;
  my $sth = $dbh->prepare($sql);
  $sth->execute();
  my @rows;
  while ( my @row = $sth->fetchrow_array ) {
    push @rows,@row;
  }
  return @rows;
}
 
sub print_sql {
  my $sql = shift;
  my $sth = $dbh->prepare($sql);
  $sth->execute();
  print "SQL: $sql\n";
  while ( my @row = $sth->fetchrow_array ) {
    print "@row\n";
  }
}
 
print header;
print start_html('Disklist - AIX Server Disk/LUN Inventory')."\n";
 
print "<style type=\"text/css\">";
print "table { border = 1px solid #000000; padding: 5px; border-collapse: collapse; }";
print "</style>\n";
 
init_db();
 
print h1("Disklist - AIX Server Disk/LUN Inventory")."\n";
print "<p>Last Update: ".db_getsingle("SELECT contents FROM vars WHERE name='update'");
$host=$cgi->param("host");
$debugtable=$cgi->param("debugtable");
#print "<p>Selected: ".$cgi->param("host")."\n";
#print "<table>\n"; print "<tr valign=top><td>";
print "<table border=1>\n";
foreach my $sys (db_getlist("SELECT DISTINCT system FROM partitions;")) {
  print "<tr><td colspan=20>$sys</td></tr>\n";
  print "<tr align=center>\n";
  foreach my $h (db_getlist("SELECT hostname FROM partitions WHERE state='Running' AND system='$sys';")) {
    print "<td><a href=".url()."?host=$h>$h</a></td>\n";
  }
  print "</tr>";
}
print "</table>\n";
 
if ($host ne "") {
print "<p><table border=1 width=100%>\n";
$partid = db_getsingle("SELECT DISTINCT lpar_id FROM scsimap WHERE lpar_names='$host';");
my $lparenv = db_getsingle("SELECT lparenv FROM partitions WHERE hostname='$host';");
my $partid_h = sprintf("0x%08x",$partid);
print "<tr><td colspan=9><p style=\"font-size: large;\"><b>$host ($partid-$lparenv)</b></td>";
 
print "<tr><th colspan=2>lpar</th><th colspan=4>vio</th><th colspan=2>disk controller</th>\n";
print "<tr><th>hdisk</th><th>path/slot-lun</th>\n";
print "<th>vio</th><th>vhost/slot-lun</th><th>vtd</th><th>hdisk</th>\n";
print "<th>ctrl-lun</th><th>description</th>\n";
print "</tr>";
 
foreach my $vg (db_getlist("SELECT DISTINCT vg FROM hdisk WHERE hostname='$host';")) {
  print "<tr><td><b>$vg</b></td>";
  my $hdisk_last;
  foreach my $hdisk (db_getlist("SELECT DISTINCT hdisk FROM hdisk WHERE hostname='$host' AND vg='$vg';")) {
    my $size = db_getsingle("SELECT size FROM hdisk WHERE hostname='$host' AND hdisk='$hdisk';");
    $size = sprintf("%.0fG",$size/1000);
 
#    my @rows = db_getlist("SELECT parent,connid FROM paths WHERE hostname='$host' AND hdisk='$hdisk';");
    my $h = $dbh->prepare("SELECT parent,connid,state FROM paths WHERE hostname='$host' AND hdisk='$hdisk';");
    $h->execute();
#    print "SQL: $sql\n";
    while ( my @row = $h->fetchrow_array ) {
      my ($parent,$connid,$pstate) = @row;
#      print "<tr><td colspan=9>$parent,$connid,$pstate $host $hdisk</td></tr>\n";
#    while (my ($parent,$connid)=pop @rows) {
#      my ($parent,$pstate) = db_getval("SELECT parent,state FROM paths WHERE hostname='$host' AND hdisk='$hdisk' AND connid='$connid';");
#      my $pstate = db_getval("SELECT state FROM paths WHERE hostname='$host' AND hdisk='$hdisk' AND parent='$parent' AND connid='$connid';");
      my $pslot = db_getsingle("SELECT pslot FROM paths WHERE hostname='$host' AND hdisk='$hdisk' AND parent='$parent';");
      if ($parent =~ /vscsi.*/) {
        # vio-attached disk
        my $pstate = db_getsingle("SELECT state FROM paths WHERE hostname='$host' AND hdisk='$hdisk' AND parent='$parent';");
        my $vslot = db_getsingle("SELECT DISTINCT rp_slot FROM scsimap WHERE slot='$pslot' AND lpar_names='$host';");
        my $vioname = db_getsingle("SELECT DISTINCT rp_name FROM scsimap WHERE slot='$pslot' AND lpar_names='$host';");
        my $vhost = db_getsingle("SELECT vhost FROM viomap WHERE vioname='$vioname' AND partid='$partid' AND slot='$vslot';");
        my $lun = db_getsingle("SELECT lun FROM paths WHERE hostname='$host' AND hdisk='$hdisk' AND parent='$parent';");
        my ($vtd,$vhdisk) = db_getval("SELECT vtd,hdisk FROM viomap WHERE vioname='$vioname' AND lun='$lun' AND vhost='$vhost';");
        my $vhdesc = db_getsingle("SELECT desc FROM hdisk WHERE hostname='$vioname' AND hdisk='$vhdisk';");
        my $vdctrl = db_getsingle("SELECT loc FROM hdisk WHERE hostname='$vioname' AND hdisk='$vhdisk';");
        my $vdlun = $vdctrl; $vdlun =~ s/^.*-L//; $vdlun =~ s/0+$//; $vdlun = hex($vdlun);
        $vdctrl =~ s/^.*-W.*(\w{4})-L.*$/$1/; # get last 4 digits from controller serial num
        print "<tr>";
        if ($hdisk_last eq $hdisk) {
          print "<td></td>";
        } else {
          print "<td>$hdisk $size</td>";
        }
        print "<td>$parent / $pslot-$lun</td>";
        print "<td>$vioname</td>";
        print "<td>$vhost / $vslot-$lun</td>";
        if ($vhdisk =~ /^hdisk/) {
          # Backing device is lun/hdisk
          print "<td>$vtd</td>";
          print "<td>$vhdisk</td>";
          print "<td>$vdctrl-$vdlun</td>";
          print "<td>$vhdesc</td>";
          print "</tr>\n";
          if ($hdisk_last eq $hdisk) {
            # checks & warnings
          }
        } else {
          # Backing device is not hdisk, must be logical volume
          print "<td colspan=2>$vtd</td><td colspan=2>Logical volume</td>";
        }
      } else {
        # directly attached disk
        my $lun = db_getsingle("SELECT lun FROM paths WHERE hostname='$host' AND hdisk='$hdisk' AND parent='$parent';");
        my $desc = db_getsingle("SELECT desc FROM hdisk WHERE hostname='$host' AND hdisk='$hdisk';");
        my $ctrl = db_getsingle("SELECT loc FROM hdisk WHERE hostname='$host' AND hdisk='$hdisk';");
        $ctrl =~ s/^.*-W.*(\w{4})-L.*$/$1/; # get last 4 digits from controller serial num
        $ctrl =~ s/U.*(\w{4}-P\d+-[CT]\d+).*$/$1/; # get last 4 digits from controller serial num
        $connid =~ s/0+$//; $connid =~ s/.*(\w{4},.*)/$1/;
        print "<tr>";
        if ($hdisk_last eq $hdisk) {
          print "<td></td>";
        } else {
          print "<td>$hdisk $size</td>";
        }
        print "<td>$parent / $pslot-$lun ($connid)</td>";
        if ($hdisk_last ne $hdisk) {
          if ($lparenv eq "vioserver") {
            # on a vio server - find where the disk is mapped
            my ($vtd,$vhost,$vslot,$vlun) = db_getval("SELECT vtd,vhost,slot,lun FROM viomap WHERE vioname='$host' AND hdisk='$hdisk';");
            if ($vtd) {
              my ($lpar_names,$pslot) = db_getval("SELECT lpar_names,slot FROM scsimap WHERE rp_slot='$vslot';");
              my $phdisk = db_getsingle("SELECT hdisk FROM paths WHERE hostname='$lpar_names' AND pslot='$pslot' AND lun='$vlun';");
              print "<td colspan=4>$vtd -> $lpar_names($vhost-$vlun):$phdisk</td>";
            } else {
              print "<td colspan=4>not mapped</td>";
            }
          } else {
            print "<td colspan=4>No vio - direct attach</td>";
          }
        } else {
          print "<td colspan=4></td>";
        }
        print "<td>$ctrl-$lun</td><td>$desc</td></tr>";
        if ($hdisk_last eq $hdisk) {
          # checks & warnings
        }
      }
      if ($pstate ne "Enabled") {
        print "<tr><td colspan=9><b>Path: '$hdisk $parent $connid' $pstate</b></td></tr>\n";
      }
      $hdisk_last=$hdisk;
    }
  }
}
print "</table>";
}
 

print "<form action=\"".url()."\"\n><p>Display raw debug data: \n";
print "<input type=hidden name=host value=\"$host\">\n";
if ($debugtable) {
  print "<input type=checkbox name=debugtable value=\"1\" checked>\n";
} else {
  print "<input type=checkbox name=debugtable value=\"1\">\n";
}
print "<input type=submit value=Submit>\n";
print "</form>\n";
if ($debugtable) {
print "<p><table border=1><tr><td><pre>\n";
#print_sql ("SELECT * FROM scsimap WHERE lpar_names='$host';");
#print_sql ("SELECT * FROM viomap;");
print_sql ("SELECT * FROM viomap WHERE partid='$partid';");
print_sql ("SELECT * FROM hdisk WHERE hostname='$host';");
print_sql ("SELECT * FROM paths WHERE hostname='$host';");
print_sql ("SELECT hdisk FROM paths WHERE slot='84' AND hostname='ziggy' AND lun='1';");
print "</pre></td></tr></table>\n";
}
print end_html."\n";
