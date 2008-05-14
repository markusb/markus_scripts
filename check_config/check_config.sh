#!/bin/ksh
#
# ssh_check_config
#
# this script checks various parameters and settings of devices and tunables.
#
# It displays warnings if the parameters are not set as recommended.
# If run with -a (apply) it will set all parameters to the recommended value.
#
CMDNAME=$(basename $0)
CMDPATH=$0
LOG=/var/log/${CMDNAME%.sh}.log
SSHOPTS="-o LogLevel=Quiet -o StrictHostKeyChecking=no -o BatchMode=yes"
SSHID="$HOME/.ssh/id_rsa_1024_aixnim"
SSHCMD="/usr/bin/ssh -i $SSHID $SSHOPTS"
SCPCMD="/usr/bin/scp -i $SSHID -q $SSHOPTS"
DATESTAMP=$(date +'%Y%m%d-%H%M%S')
NIMHOST=zsv0508s
HOSTLIST=$(awk '/^[0-9]/{if ($1 != "127.0.0.1") print $2}' /etc/hosts)
WARNING=0
ERROR=0
REMWARN=0
REMCOUNT=0
 
usage () {
  echo "Usage: $CMDNAME [-r] [-a] [-v] [ -g | -r <hostname>]"
  echo "       -a         apply the settings"
  echo "       -v         verbose, print details"
  echo "       -q         quiet, print summary only"
  echo "       -g         global, run on all hosts in /etc/hosts"
  echo "       -r <host>  run on <host>"
  echo "       -t         print messages formatted for tivoli"
}
 
# determine if we are on a VIO
if [ -x /usr/ios/cli/ioscli ]
then
  VIO=true
fi
 
# echo with datestamp
echodate () {
  echo "$(date +'%d.%m.%Y %H:%M:%S') $*"
}
 
# echo if verbose is set
echov () {
  if [ -n "$VERBOSE" ]
  then
    echo "Info: $*"
  fi
}
 
# echo if quiet is not set
echoq () {
  if [ -z "$QUIET" ]
  then
    echo "$*"
  fi
}
 
# check if a disk has a pvid
# check that there is a udid
check_pvid () {
  PVID=$(lsattr -El $1 -a pvid -Fvalue)
  if [ "$PVID" == "none" ]
  then
    if [ -n "$APPLY" ]
    then
      echo "$1: Assigning pvid ... \c"
      chdev -l $1 -a pv=yes
    else
      echoq "Warning: $1 has no PVID"
      let "WARNING = $WARNING + 1"
    fi
  fi
 
  UDID=$(odmget -q "name=$1 and attribute=unique_id" CuAt | awk -F'"' '/value/{print $2}')
  if [ -n "$UDID" ]
  then
    echov "$1: udid = \"$UDID\""
  else
    echoq "$1: No udid found in ODM"
  fi
}
 
# check a odm default value
check_odm_deflt () {
  echov "Checking ODM default for $2 on $1, should be $3"
  VAL=$(odmget -q "uniquetype=$1 and attribute=$2" PdAt | awk -F'"' '/deflt/{print $2}')
  if [ -n "$VAL" ]
  then
    if [ "$VAL" -ne "$3" ]
    then
      if [ -n "$APPLY" ]
      then
        echo "$1: Setting $2 to $3 ... "
        echo "PdAt:\n\tdeflt=$3" | odmchange -o PdAt -q "uniquetype=$1 and attribute=$2"
      else
        echoq "$1: Warning: $2 is $VAL, should be $3"
        let "WARNING = $WARNING + 1"
      fi
    else
      echov "$1-$2: OK ($3)"
    fi
  else
    echov "Can not find uniquetype=$1 attribute=$2 in PdAt"
  fi
}
 
# check the odm defaults for disks
check_disk_odm () {
  echov "Checking disk defaults"
  # HDS MPIO disks
  check_odm_deflt disk/fcp/htcuspmpio queue_depth 10
  check_odm_deflt disk/fcp/htc9900mpio queue_depth 10
  # HDS HDLM disks
  check_odm_deflt disk/node/dlmfdrv queue_depth 10
  check_odm_deflt disk/node/Hitachi queue_depth 10
}
 
# check an attribute
set_check_attr () {
  # $1 device name
  # $2 attribute name
  # $3 desired value
  # $4 comment
  if [ -z "$(lsattr -El$1 | grep $2)" ]
  then
    echov "$1: Attribute $2 does not exist."
    return
  fi
  VAL=$(lsattr -El$1 -a $2 -Fvalue)
  if [ "$(lsattr -El$1 -a $2 -Fuser_settable)" == "False" ]
  then
    echov "$1: Attribute $2 can not be changed"
    return
  fi
  if [ "$VAL" != "$3" ]
  then
    if [ -n "$APPLY" ]
    then
      echo "$1: Setting $2 to $3 ... \c"
      chdev -l $1 -a $2=$3 -P
      NEEDBOOT=true
    else
      echoq "Warning: $1: $2 is $VAL, should be $3 ($4)"
      let "WARNING = $WARNING + 1"
    fi
  else
    echov "$1: OK $2 is $3"
  fi
}
 
# check a tuning value
set_check_tune () {
  VAL=$($1 -o $2 | awk -F'= ' '{print $2}')
  if [ "$VAL" != "$3" ]
  then
    if [ -n "$APPLY" ]
    then
      echo "$1: Setting $2 to $3 ... \c"
      $1 -p -o $2=$3
    else
      echoq "Warning: $1: $2 is $VAL, should be $3"
      let "WARNING = $WARNING + 1"
    fi
  else
    echov "$1: OK $2 is $3"
  fi
}
 
#
# check something, contains hardcoded defaults
#
set_check_mpiopath () {
  if [ -z "$(lspath -l $1 -p $2)" ]
  then
    echov "$1: Path $2 does not exist."
    return
  fi
  VAL=$(lspath -A -l$1 -p$2 -Fvalue -apriority)
  if [ "$VAL" != "$3" ]
  then
    if [ -n "$APPLY" ]
    then
      echo "$1: Setting path priority $2 to $3 ... \c"
      chpath -l $1 -p $2 -apriority=$3 -P
    else
      echoq "Warning: $1: path priority for $2 is $VAL, should be $3"
      let "WARNING = $WARNING + 1"
    fi
  else
    echov "$1: OK $2 path priority is $3"
  fi
}
 
check_mpiopath () {
  P1=$(lspath -l $1 -Fparent | sort | head -1)
  P2=$(lspath -l $1 -Fparent | sort | tail -1)
  DNUM=${1#hdisk}
  let "DNUM = $DNUM % 2"
  case $DNUM in
    0) PA1=$P1; PA2=$P2;;
    1) PA1=$P2; PA2=$P1;;
  esac
  set_check_mpiopath $1 $PA1 1
  set_check_mpiopath $1 $PA2 2
}
 
check_disk_vscsi () {
  echov "Checking virtual disk $1 (subclass vscsi)"
  set_check_attr $1 queue_depth 10 vscsi
  set_check_attr $1 hcheck_interval 30 vscsi
  set_check_attr $1 hcheck_mode nonactive vscsi
  check_mpiopath $1
}
 
check_disk_fcp () {
  echov "Checking fcs disk $1 (subclass fcp)"
  DTYPE=$(odmget -q "name=$1" CuDv | awk -F'["/]' '/PdDvLn/{print $4}')
  QD=""
  case $DTYPE in
    hsv200) QD=8;;
    xp12kmpio) QD=2;;
    *) echo "Warning: $1: No queue_depth defined for disk type $DTYPE !"
  esac
  if [ -n "$QD" ]
  then
    set_check_attr $1 queue_depth $QD $DTYPE
  fi
#  set_check_attr $1 reserve_policy no_reserve
}
 
check_disk_scsi () {
  echov "Checking scsi disk $1 (subclass scsi)"
  set_check_attr $1 queue_depth 2 scsi
}
 
check_disk_node () {
  echov "Checking hdlm disk $1 (subclass node)"
  set_check_attr $1 queue_depth 10 hdlm
  set_check_attr $1 reserve_lock no
  check_pvid $1
}
 
check_driver_fscsi () {
  echov "Checking fscsi driver $1"
  set_check_attr $1 fc_err_recov fast_fail fscsi
  set_check_attr $1 dyntrk yes fscsi
 
}
 
#
# loop among disks and drivers to check attributes
#
check_disk () {
  for DISK in $(lsdev -cdisk -Fname -SAvailable)
  do
    case $(lsdev -l$DISK -Fsubclass)
    in
      vscsi) check_disk_vscsi $DISK;;
      fcp) check_disk_fcp $DISK;;
      scsi) check_disk_scsi $DISK;;
      node) check_disk_node $DISK;;
      *) echoq "Warning: $DISK: don't know how to check this disk !";;
    esac
  done
  for DRV in $(lsdev -cdriver -Fname)
  do
    case $DRV
    in
      fscsi*) check_driver_fscsi $DRV;;
      fcnet*) ;;
      iscsi*) ;;
      scsi*) ;;
      hdlm*) ;;
      *) echoq "Warning: $DRV: don't know how to check this driver !"
         let "WARNING = $WARNING + 1" ;;
    esac
  done
  for DISK in $(lsdev -cdisk -Fname -SDefined)
  do
    if [ -n "$APPLY" ]
    then
      echo "Removing $DISK"
      rmdev -dl $DISK
    else
      echoq "Warning: $DISK has status Defined, should it be removed ?"
      let "WARNING = $WARNING + 1"
    fi
  done
}
 
check_path () {
  echov "Checking disk paths"
  lspath -F "name status path_id parent connection" | grep -v Enabled |\
  while read name status path_id parent connection
  do
    echo "Error: $name: Path $status ($path_id $parent $connection)"
    let "ERROR = $ERROR + 1"
    if [ "$status" == "Missing" -a -n "$APPLY" ]
    then
      echo "Info: Removing Missing Path $path_id $parent $connection"
      rmpath -dw $connection
    fi
    if [ "$status" == "Defined" -a -n "$APPLY" ]
    then
      echo "Info: Starting Missing Path $path_id $parent $connection"
      mkpath -l $connection
    fi
  done
}
 
check_net_parm () {
  echov "Check network tuning parameters"
  set_check_tune no tcp_recvspace 65535
  set_check_tune no tcp_sendspace 65535
  set_check_tune no udp_recvspace 65535
  set_check_tune no udp_sendspace 32767
  echov "Check for double default gateway"
  NUMROUTES=$(lsattr -El inet0 | grep "^route " | wc -l)
  if [ $NUMROUTES -gt 1 ]
  then
    echo "Warning: Multiple static routes defined"
    lsattr -El inet0 | grep "^route "
    echo "chdev -l inet0 -a 'delroute=net,,0,192.168.221.79' && savebase"
    let "WARNING = $WARNING + 1"
  fi
}
 
check_vm_parm () {
  echov "Verifying vm tuning options"
  set_check_tune vmo lru_file_repage 0
}
 
check_adapter_ent () {
  echov "Checking adapter $1"
  set_check_attr $1 media_speed toto
}
 
check_adapter () {
  for ADAPT in $(lsdev -cadapter -Fname)
  do
    case $ADAPT in
      ent*) ;; #check_adapter_ent $ADAPT;;
      fcs*) ;;
      scsi*) ;;
      vscsi*) ;;
      sisscsia*) ;;
      vsa*) ;;
      vhost*) ;;
      ide0) ;;
      usbhc*) ;;
      *) echoq "Warning: $ADAPT: don't know how to check this adapter";;
    esac
  done
}
 
run_remotely () {
  let "REMCOUNT = $REMCOUNT + 1"
  $SCPCMD $0 $REMOTEH:/tmp
  if ! $SSHCMD $REMOTEH /tmp/$CMDNAME $APPLY $VERBOSE $QUIET
  then
    let "REMWARN = $REMWARN + 1"
  fi
}
 
#
# Parse the commandline
#
while getopts "qgvar:h" flag
do
  case $flag in
     a) APPLY=-a;;
     v) VERBOSE=-v;;
     q) QUIET=-q;;
     g) GLOBAL=-g;;
     r) REMOTEH=$OPTARG;;
     *) usage; exit 1;;
  esac
done
 
#
# execute remotely if appropriate
#
if [ -n "$REMOTEH" -o -n "$GLOBAL" ]
then
  if [ -n "$GLOBAL" -a -n "$APPLY" ]
  then
    echo "Ignoring -a flag for global execution - too dangerous"
    APPLY=""
  fi
  if [ -n "$REMOTEH" ]
  then
    HOSTLIST="$REMOTEH"
  fi
  for REMOTEH in $HOSTLIST
  do
    run_remotely $REMOTEH
  done
  if [ -n "$GLOBAL" -a "$REMWARN" -gt "0" ]
  then
    echo "$REMCOUNT hosts checked, $REMWARN hosts with warnings."
    exit 1
  fi
  exit 0
fi
 
#if ! tty -s
#then
#  exec >>$LOG 2>&1
#fi
 
check_disk
check_disk_odm
check_path
if [ -z "$VIO" ]
then
  check_net_parm
  check_vm_parm
  check_adapter
fi
 
if [ "$WARNING" -gt 0 -o "$ERROR" -gt "0" ]
then
  if [ "$WARNING" -gt 0 ]
  then
    echo "Warning: $(hostname): $WARNING Warnings found !"
  fi
  if [ "$ERROR" -gt 0 ]
  then
    echo "Error: $(hostname): $ERROR Errors found !"
  fi
else
  echo "Info: $(hostname): OK"
fi
 
if [ -n "$NEEDBOOT" ]
then
  echo "Info: Please reboot to activate the new settings"
fi
 
if [ "$WARNING" -gt 0 ]
then
  exit 1
fi

