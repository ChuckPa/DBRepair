#!/bin/bash
#########################################################################
# Database Repair Utility for Plex Media Server.                        #
# Maintainer: ChuckPa                                                   #
# Version:    v1.12.01                                                  #
# Date:       21-Oct-2025                                               #
#########################################################################

# Version for display purposes
Version="v1.12.01"

# Have the databases passed integrity checks
CheckedDB=0

# By default,  we cannot start/stop PMS
HaveStartStop=0
StartCommand=""
StopCommand=""

# By default, require root privilege
RootRequired=1

# By default, Errors are fatal.
IgnoreErrors=0

# By default, Duplicate view states not Removed
RemoveDuplicates=0

# Keep track of how many times the user's hit enter with no command (implied EOF)
NullCommands=0

# Default TMP dir for most hosts
TMPDIR="/tmp"
SYSTMP="/tmp"

# Global variable - main database
CPPL=com.plexapp.plugins.library

# Initial timestamp
TimeStamp="$(date "+%Y-%m-%d_%H.%M.%S")"

# Initialize global runtime variables
ManualConfig=0
CheckedDB=0
Damaged=0
DbPageSize=0
Fail=0
HaveStartStop=0
HostType=""
LOG_TOOL="echo"
ShowMenu=1
Exit=0
Scripted=0
HaveStartStop=0

# On all hosts except Mac
PIDOF="pidof"
STATFMT="-c"
STATBYTES="%s"
STATPERMS="%a"

# On all hosts except QNAP
DFFLAGS="-m"

# If LC_ALL is null,  default to C
[ "$LC_ALL" = "" ] && export LC_ALL=C

# Check Restart
[ "$DBRepairRestartedAfterUpdate" = "" ] && DBRepairRestartedAfterUpdate=0

# Universal output function
Output() {
  if [ $Scripted -gt 0 ]; then
    echo \[$(date "+%Y-%m-%d %H.%M.%S")\] "$@"
  else
    echo "$@"
  fi
  # $LOG_TOOL \[$(date "+%Y-%m-%d %H.%M.%S")\] "$@"
}

# Write to Repair Tool log
WriteLog() {

  # Write given message into tool log file with TimeStamp
  echo "$(date "+%Y-%m-%d %H.%M.%S") - $*" >> "$LOGFILE"
  return 0
}

# Check given database file integrity
CheckDB() {

  # Confirm the DB exists
  [ ! -f "$1" ] && Output "ERROR: $1 does not exist." && return 1

  # Now check database for corruption
  Result="$("$PLEX_SQLITE" "$1" "PRAGMA integrity_check(1)")"
  if [ "$Result" = "ok" ]; then
    return 0
  else
     SQLerror="$(echo $Result | sed -e 's/.*code //')"
    return 1
  fi

}

# Check all databases
CheckDatabases() {

  # Arg1 = calling function
  # Arg2 = 'force' if present

  # Check each of the databases.   If all pass, set the 'CheckedDB' flag
  # Only force recheck if flag given

  # Check if not checked or forced
  NeedCheck=0
  [ $CheckedDB -eq 0 ] &&  NeedCheck=1
  [ $CheckedDB -eq 1 ] && [ "$2" = "force" ] && NeedCheck=1

  # Do we need to check
  if [ $NeedCheck -eq 1 ]; then

    # Clear Damaged flag
    Damaged=0
    CheckedDB=0

    # Info
    Output "Checking the PMS databases"

    # Check main DB
    if CheckDB $CPPL.db ; then
      Output "Check complete.  PMS main database is OK."
      WriteLog "$1"" - Check $CPPL.db - PASS"
    else
      Output "Check complete.  PMS main database is damaged."
      WriteLog "$1"" - Check $CPPL.db - FAIL ($SQLerror)"
      Damaged=1
    fi

    # Check blobs DB
    if CheckDB $CPPL.blobs.db ; then
      Output "Check complete.  PMS blobs database is OK."
      WriteLog "$1"" - Check $CPPL.blobs.db - PASS"

    else
      Output "Check complete.  PMS blobs database is damaged."
      WriteLog "$1"" - Check $CPPL.blobs.db - FAIL ($SQLerror)"
      Damaged=1
    fi

    # Yes, we've now checked it
    CheckedDB=1
  fi

  [ $Damaged -eq 0 ] && CheckedDB=1

  # return status
  return $Damaged
}

# Return list of database backup dates for consideration in replace action
GetDates(){

  Dates=""
  Tempfile="/tmp/DBRepairTool.$$.tmp"
  touch "$Tempfile"

  for i in $(find . -maxdepth 1 -name 'com.plexapp.plugins.library.db-????-??-??' | sort -r)
  do
    # echo Date - "${i//[^.]*db-/}"
    Date="$(echo $i | sed -e 's/.*.db-//')"

    # Only add if companion blobs DB exists
    [ -e $CPPL.blobs.db-$Date ] && echo $Date >> "$Tempfile"

  done

  # Reload dates in sorted order
  Dates="$(sort -r <$Tempfile)"

  # Remove tempfile
  rm -f "$Tempfile"

  # Give results
  echo $Dates
  return
}

# Non-fatal SQLite error code check
SQLiteOK() {

  # Global error variable
  SQLerror=0

  # Quick exit- known OK
  [ $1 -eq 0 ] && return 0

  # Put list of acceptable error codes here
  Codes="19 28"

  # By default assume the given code is an error
  CodeError=1

  for i in $Codes
  do
    if [ $i -eq $1 ]; then
      CodeError=0
      SQLerror=$i
      break
    fi
  done
  return $CodeError
}

# Perform a space check
# Store space available versus space needed in variables
# Return FAIL if needed GE available
# Arg 1, if provided, is multiplier
FreeSpaceAvailable() {

  Multiplier=3
  [ "$1" != "" ] && Multiplier=$1

  # Available space where DB resides
  SpaceAvailable=$(df $DFFLAGS "$DBDIR" | tail -1 | awk '{print $4}')

  # Get size of DB and blobs, Minimally needing sum of both
  LibSize="$(stat $STATFMT $STATBYTES "${DBDIR}/$CPPL.db")"
  BlobsSize="$(stat $STATFMT $STATBYTES "${DBDIR}/$CPPL.blobs.db")"
  SpaceNeeded=$((LibSize + BlobsSize))

  # Compute need (minimum $Multiplier existing; current, backup, temp and room to write new)
  SpaceNeeded=$(($SpaceNeeded * $Multiplier))
  SpaceNeeded=$(($SpaceNeeded / 1000000))

  # If need < available, all good
  [ $SpaceNeeded -lt $SpaceAvailable ] && return 0

  # Too close to call, fail
  return 1
}

# Perform the actual copying for MakeBackup()
DoBackup() {

  if [ -e $2 ]; then
    cp -p "$2" "$3"
    Result=$?
    if [ $Result -ne 0 ]; then
      Output "Error $Result while backing up '$2'.  Cannot continue."
      WriteLog "$1 - MakeBackup $2 - FAIL"

      # Remove partial copied file and return
      rm -f "$3"
      return 1
    else
      WriteLog "$1 - MakeBackup $2 - PASS"
      return 0
    fi
  fi
}

# Make a backup of the current database files and tag with TimeStamp
MakeBackups() {

  Output "Backup current databases with '-BACKUP-$TimeStamp' timestamp."

  for i in "db" "db-wal" "db-shm" "blobs.db" "blobs.db-wal" "blobs.db-shm"
  do
    DoBackup "$1" "${CPPL}.${i}" "$DBTMP/${CPPL}.${i}-BACKUP-$TimeStamp"
    Result=$?
  done

  return $Result

}

ConfirmYesNo() {

  Answer=""
  while [ "$Answer" != "Y" ] && [ "$Answer" != "N" ]
  do
    if [ $Scripted -eq 1 ]; then
      Answer=Y
    else
      printf "%s (Y/N) ? " "$1"
      read Input

      # EOF = No
      case "$Input" in
        YES|YE|Y|yes|ye|y)
          Answer=Y
          ;;
        NO|N|no|n)
          Answer=N
          ;;
        *)
          Answer=""
          ;;
      esac
    fi

    # Unrecognized
    if [ "$Answer" != "Y" ] && [ "$Answer" != "N" ]; then
      echo \"$Input\" was not a valid reply.  Please try again.
      continue
    fi
  done

  if [ "$Answer" = "Y" ]; then
    # Confirmed Yes
    return 0
  else
    return 1
  fi
}

# Restore previously saved DB from given TimeStamp
RestoreSaved() {

  T="$1"

  for i in "db" "db-wal" "db-shm" "blobs.db" "blobs.db-wal" "blobs.db-shm"
  do
    [ -e "${CPPL}.${i}" ] && rm -f "${CPPL}.${i}"
    [ -e "$DBTMP/${CPPL}.${i}-BACKUP-$T" ] && mv "$DBTMP/${CPPL}.${i}-BACKUP-$T" "${CPPL}.${i}"
  done
}

# Return only the digits in the given version string
VersionDigits() {
  local ver
  ver=$(echo "$1" | tr -d [v\.] )
  echo $ver
}

# Get the size of the given DB in MB
GetSize() {

  Size=$(stat $STATFMT $STATBYTES "$1")
  Size=$(expr $Size / 1048576)
  [ $Size -eq 0 ] && Size=1
  echo $Size
}

# Extract specified value from override file if it exists (Null if not)
GetOverride() {

    Retval=""

    # Don't know if we have pushd so do it long hand
    CurrDir="$(pwd)"

    # Find the metadata dir if customized
    if [ -e /etc/systemd/system/plexmediaserver.service.d ]; then

      # Get there
      cd /etc/systemd/system/plexmediaserver.service.d

      # Glob up all 'conf files' found
      ConfFile="$(find override.conf local.conf *.conf 2>/dev/null | head -1)"

      # If there is one, search it
      if [ "$ConfFile" != "" ]; then
        Retval="$(grep "$1" $ConfFile | head -1 | sed -e "s/.*${1}=//" | tr -d \" | tr -d \')"
      fi

    fi

    # Go back to where we were
    cd "$CurrDir"

    # What did we find
    echo "$Retval"
}

# Determine which host we are running on and set variables
HostConfig() {

  # On all hosts except Mac/FreeBSD
  PIDOF="pidof"
  STATFMT="-c"
  STATBYTES="%s"
  STATPERMS="%a"

  # On all hosts except QNAP
  DFFLAGS="-m"

  # Manual Config
  if [ $ManualConfig -eq 1 ]; then

    CACHEDIR="$DBDIR/../../Cache/PhotoTranscoder"
    LOGFILE="$DBDIR/DBRepair.log"
    HostType="MANUAL"
    return 0
  fi

  # Synology (DSM 7)
  if [ -d /var/packages/PlexMediaServer ] && \
     [ -d "/var/packages/PlexMediaServer/shares/PlexMediaServer/AppData/Plex Media Server" ]; then

    # Where is the software
    PKGDIR="/var/packages/PlexMediaServer/target"
    PLEX_SQLITE="$PKGDIR/Plex SQLite"
    LOG_TOOL="logger"

    # Where is the data
    AppSuppDir="/var/packages/PlexMediaServer/shares/PlexMediaServer/AppData"
    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
    PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
    LOGFILE="$DBDIR/DBRepair.log"
    TMPDIR="$AppSuppDir/Plex Media Server/tmp"
    SYSTMP="$TMPDIR"

    # We are done
    HostType="Synology (DSM 7)"

    # We do have start/stop as root
    HaveStartStop=1
    StartCommand="/usr/syno/bin/synopkg start PlexMediaServer"
    StopCommand="/usr/syno/bin/synopkg stop PlexMediaServer"
    return 0

  # Synology (DSM 6)
  elif [ -d "/var/packages/Plex Media Server" ] && \
       [ -f "/usr/syno/sbin/synoshare" ]; then

    # Where is the software
    PKGDIR="/var/packages/Plex Media Server/target"
    PLEX_SQLITE="$PKGDIR/Plex SQLite"
    LOG_TOOL="logger"

    # Get shared folder path
    AppSuppDir="$(synoshare --get Plex | grep Path | awk -F\[ '{print $2}' | awk -F\] '{print $1}')"

    # Where is the data
    AppSuppDir="$AppSuppDir/Library/Application Support"
    if [ -d "$AppSuppDir/Plex Media Server" ]; then

      DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
      PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
      LOGFILE="$DBDIR/DBRepair.log"
      TMPDIR="$AppSuppDir/Plex Media Server/tmp"
      SYSTMP="$TMPDIR"

      HostType="Synology (DSM 6)"

      # We do have start/stop as root
      HaveStartStop=1
      StartCommand="/usr/syno/bin/synopkg start PlexMediaServer"
      StopCommand="/usr/syno/bin/synopkg stop PlexMediaServer"
      return 0
    fi


  # QNAP (QTS & QuTS)
  elif [ -f /etc/config/qpkg.conf ]; then

    # Where is the software
    PKGDIR="$(getcfg -f /etc/config/qpkg.conf PlexMediaServer Install_path)"
    PLEX_SQLITE="$PKGDIR/Plex SQLite"
    LOG_TOOL="/sbin/log_tool -t 0 -a"

    # Where is the data
    AppSuppDir="$PKGDIR/Library"
    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
    PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
    LOGFILE="$DBDIR/DBRepair.log"
    TMPDIR="$AppSuppDir/tmp"
    SYSTMP="$TMPDIR"

    # Start/Stop
    if [ -e /etc/init.d/plex.sh ]; then
      HaveStartStop=1
      StartCommand="/etc/init.d/plex.sh start"
      StopCommand="/etc/init.d/plex.sh stop"
    fi

    # Use custom DFFLAGS (force POSIX mode)
    DFFLAGS="-Pm"

    HostType="QNAP"
    return 0

  # SNAP host (check before standard)
  elif [ -d "/var/snap/plexmediaserver/common/Library/Application Support/Plex Media Server" ]; then

    # Where things are
    PLEX_SQLITE="/snap/plexmediaserver/current/Plex SQLite"
    AppSuppDir="/var/snap/plexmediaserver/common/Library/Application Support"
    CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
    PID_FILE="$AppSuppDir/plexmediaserver.pid"
    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    LOGFILE="$DBDIR/DBRepair.log"
    LOG_TOOL="logger"
    TMPDIR="/var/snap/plexmediaserver/common/tmp"
    SYSTMP="$TMPDIR"

    HaveStartStop=1
    StartCommand="snap start plexmediaserver"
    StopCommand="snap stop plexmediaserver"

    HostType="SNAP"
    return 0

  # Standard configuration Linux host
  elif [ -f /etc/os-release ]          && \
       [ -d /usr/lib/plexmediaserver ] && \
       [ -d /var/lib/plexmediaserver ]; then

    # Where is the software
    PKGDIR="/usr/lib/plexmediaserver"
    PLEX_SQLITE="$PKGDIR/Plex SQLite"
    LOG_TOOL="logger"

    # Where is the data
    AppSuppDir="/var/lib/plexmediaserver/Library/Application Support"
    # DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    # PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"

    # Find the metadata dir if customized
    if [ -e /etc/systemd/system/plexmediaserver.service.d ]; then

      # Get custom AppSuppDir if specified
      NewSuppDir="$(GetOverride PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR)"

      if [ -d "$NewSuppDir" ]; then
          AppSuppDir="$NewSuppDir"
      else
          Output "Given application support directory override specified does not exist: '$NewSuppDir'. Ignoring."
      fi
    fi

    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
    PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
    LOGFILE="$DBDIR/DBRepair.log"

    HostType="$(grep ^PRETTY_NAME= /etc/os-release | sed -e 's/PRETTY_NAME=//' | sed -e 's/"//g')"

    HaveStartStop=1
    StartCommand="systemctl start plexmediaserver"
    StopCommand="systemctl stop plexmediaserver"
    TMPDIR="/tmp"
    SYSTMP="$TMPDIR"
    return 0

  # Netgear ReadyNAS
  elif [ -e /etc/os-release ] && [ "$(cat /etc/os-release | grep ReadyNASOS)" != "" ]; then

    # Find PMS
    if [ "$(echo /apps/plexmediaserver*)" != "/apps/plexmediaserver*" ]; then

      PKGDIR="$(echo /apps/plexmediaserver*)"

      # Where is the code
      PLEX_SQLITE="$PKGDIR/Binaries/Plex SQLite"
      AppSuppDir="$PKGDIR/MediaLibrary"
      PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
      DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
      LOGFILE="$DBDIR/DBRepair.log"
      LOG_TOOL="logger"
      TMPDIR="$PKGDIR/temp"
      SYSTMP="$TMPDIR"

      HaveStartStop=1
      StartCommand="systemctl start fvapp-plexmediaserver"
      StopCommand="systemctl stop fvapp-plexmediaserver"

      HostType="Netgear ReadyNAS"
      return 0
    fi

  # ASUSTOR
  elif [ -f /etc/nas.conf ] && grep ASUSTOR /etc/nas.conf >/dev/null && \
       [ -d "/volume1/Plex/Library/Plex Media Server" ];  then

    # Where are things
    PLEX_SQLITE="/volume1/.@plugins/AppCentral/plexmediaserver/Plex SQLite"
    AppSuppDir="/volume1/Plex/Library"
    PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
    LOGFILE="$DBDIR/DBRepair.log"
    LOG_TOOL="logger"
    TMPDIR="/tmp"
    SYSTMP="$TMPDIR"

    HostType="ASUSTOR"
    return 0


  # Apple Mac
  elif [ -d "/Applications/Plex Media Server.app" ] && \
       [ -d "$HOME/Library/Application Support/Plex Media Server" ]; then

    # Where is the software
    PLEX_SQLITE="/Applications/Plex Media Server.app/Contents/MacOS/Plex SQLite"
    AppSuppDir="$HOME/Library/Application Support"
    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    CACHEDIR="$HOME/Library/Caches/PlexMediaServer/PhotoTranscoder"
    LOGFILE="$DBDIR/DBRepair.log"
    LOG_TOOL="logger"
    TMPDIR="/tmp"
    SYSTMP="$TMPDIR"

    # MacOS uses pgrep and uses different stat options
    PIDOF="pgrep"
    STATFMT="-f"
    STATBYTES="%z"
    STATPERMS="%A"

    # Root not required on MacOS.  PMS runs as username.
    RootRequired=0

    # You can set haptic to 0 for silence.
    HaveStartStop=1
    StartCommand=startMacPMS
    StopCommand=stopMacPMS
    HapticOkay=1

    HostType="Mac"
    return 0

 # FreeBSD 14+
  elif [ -e /etc/os-release ] && [ "$(cat /etc/os-release | grep FreeBSD)" != "" ]; then

    # Load functions for interacting with FreeBSD RC System
    . /etc/rc.subr

    # Find PMS
    PLEXPKG=$(pkg info | grep plexmediaserver | awk '{print $1}')

    if [ "x$PLEXPKG" != "x" ]; then # Plex ports package is installed
      BsdRcFile=$(pkg list $PLEXPKG | grep "/usr/local/etc/rc.d")
      BsdService=$(basename $BsdRcFile)
      # FreeBSD Ports has two packages for Plex - determine which one is installed
      BsdPlexPass="$(pkg info $PLEXPKG | grep ^Name | awk '{print $3}' | sed -e 's/plexmediaserver//')"

      # Load FreeBSD RC configuration for Plex
      load_rc_config $BsdService

      # Use FreeBSD RC configuration to set paths
      if [ "x$plexmediaserver_plexpass_support_path" != "x" ]; then
        DBDIR="${plexmediaserver_plexpass_support_path}/Plex Media Server/Plug-in Support/Databases"
        CACHEDIR="${plexmediaserver_plexpass_support_path}/Plex Media Server/Cache"
      elif [ "x$plexmediaserver_support_path" != "x" ]; then
        DBDIR="${plexmediaserver_support_path}/Plex Media Server/Plug-in Support/Databases"
        CACHEDIR="${plexmediaserver_support_path}/Plex Media Server/Cache"
      else
        # System is using default Ports package configuration paths
        DBDIR="/usr/local/plexdata${BsdPlexPass}/Plex Media Server/Plug-in Support/Databases"
        CACHEDIR="/usr/local/plexdata${BsdPlexPass}/Plex Media Server/Cache"
      fi

      # Where is the software
      AppSuppDir=$(dirname `pkg list $PLEXPKG | grep Plex_Media_Server`)
      PLEX_SQLITE="${AppSuppDir}/Plex SQLite"
      LOGFILE="$DBDIR/DBRepair.log"
      LOG_TOOL="logger"
      TMPDIR="/tmp"
      SYSTMP="$TMPDIR"
    else
      Output "Plex Media Server FreeBSD PKG is not installed!"
      Fail=1
      return 1
    fi

    # FreeBSD uses pgrep and uses different stat options
    PIDOF="pgrep"
    STATFMT="-f"
    STATBYTES="%z"
    STATPERMS="%Lp"

    # User 'plex' exists on FreeBSD, but the tool may not be run as that service account.
    RootRequired=1

    HaveStartStop=1
    StartCommand="/usr/sbin/service ${BsdService} start"
    StopCommand="/usr/sbin/service ${BsdService} stop"

    HostType="FreeBSD"
    return 0

  # Western Digital (OS5)
  elif [ -f /etc/system.conf ] && [ -d /mnt/HD/HD_a2/Nas_Prog/plexmediaserver ] && \
       grep "Western Digital Corp" /etc/system.conf >/dev/null; then

    # Where things are
    PLEX_SQLITE="/mnt/HD/HD_a2/Nas_Prog/plexmediaserver/binaries/Plex SQLite"
    AppSuppDir="$(echo /mnt/HD/HD*/Nas_Prog/plex_conf)"
    PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
    DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
    CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
    LOGFILE="$DBDIR/DBRepair.log"
    LOG_TOOL="logger"
    TMPDIR="$(dirname $AppSuppDir)/plexmediaserver/tmp_transcoding"
    SYSTMP="$TMPDIR"
    HostType="Western Digital"
    return 0


  # -  Docker cgroup v1 & v2
  # -  Podman (libpod)
  # -  Kubernetes (and TrueNAS platforms)
  elif [ "$(grep docker /proc/1/cgroup | wc -l)" -gt 0 ] || [ "$(grep 0::/ /proc/1/cgroup)" = "0::/" ] ||
       [ "$(grep libpod /proc/1/cgroup | wc -l)" -gt 0 ] || [ "$(grep kube /proc/1/cgroup | wc -l)" -gt 0 ]; then

    TMPDIR="/tmp"
    SYSTMP="/tmp"

    # HOTIO Plex image structure is non-standard (contains symlink which breaks detection)
    if [ -n "$(grep -irslm 1 hotio /etc/s6-overlay/s6-rc.d)" ]; then
      PLEX_SQLITE=$(find /app/bin/usr/lib/plexmediaserver /app/usr/lib/plexmediaserver /usr/lib/plexmediaserver -maxdepth 0 -type d -print -quit 2>/dev/null); PLEX_SQLITE="$PLEX_SQLITE/Plex SQLite"
      AppSuppDir="/config"
      PID_FILE="$AppSuppDir/plexmediaserver.pid"
      DBDIR="$AppSuppDir/Plug-in Support/Databases"
      CACHEDIR="$AppSuppDir/Cache/PhotoTranscoder"
      LOGFILE="$DBDIR/DBRepair.log"
      LOG_TOOL="logger"

      if [ -d "/run/service/plex" ] || [ -d "/run/service/service-plex" ]; then
        SERVICE_PATH=$([ -d "/run/service/plex" ] && echo "/run/service/plex" || [ -d "/run/service/service-plex" ] && echo "/run/service/service-plex")
        HaveStartStop=1
        StartCommand="s6-svc -u $SERVICE_PATH"
        StopCommand="s6-svc -d $SERVICE_PATH"
      fi

      HostType="HOTIO"
      return 0

    # Docker (All main image variants except binhex and hotio)
    elif [ -d "/config/Library/Application Support" ]; then

      PLEX_SQLITE="/usr/lib/plexmediaserver/Plex SQLite"
      AppSuppDir="/config/Library/Application Support"
      PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
      DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"

      LOGFILE="$DBDIR/DBRepair.log"
      LOG_TOOL="logger"

      # Miscellaneous start/stop methods
      if [ -d "/var/run/service/svc-plex" ]; then
        HaveStartStop=1
        StartCommand="s6-svc -u /var/run/service/svc-plex"
        StopCommand="s6-svc -d /var/run/service/svc-plex"
      fi

      if [ -d "/run/service/svc-plex" ]; then
        HaveStartStop=1
        StartCommand="s6-svc -u /run/service/svc-plex"
        StopCommand="s6-svc -d /run/service/svc-plex"
      fi

      if [ -d "/var/run/s6/services/plex" ]; then
        HaveStartStop=1
        StartCommand="s6-svc -u /var/run/s6/services/plex"
        StopCommand="s6-svc -d /var/run/s6/services/plex"
      fi

      HostType="Docker"
      return 0

    # BINHEX Plex image
    elif [ -e /etc/os-release ] &&  grep "IMAGE_ID=archlinux" /etc/os-release  1>/dev/null  && \
         [ -e /home/nobody/start.sh ] &&  grep PLEX_MEDIA /home/nobody/start.sh 1> /dev/null ; then

      PLEX_SQLITE="/usr/lib/plexmediaserver/Plex SQLite"
      AppSuppDir="/config"
      PID_FILE="$AppSuppDir/Plex Media Server/plexmediaserver.pid"
      DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
      LOGFILE="$DBDIR/DBRepair.log"
      LOG_TOOL="logger"

      if grep rpcinterface /etc/supervisord.conf > /dev/null; then
        HaveStartStop=1
        StartCommand="supervisorctl start start-script"
        StopCommand="supervisorctl stop start-script"
      fi

      HostType="BINHEX"
      return 0

    fi

  # Last chance to identify this host
  elif [ -e /etc/os-release ]; then

    # Arch Linux (must check for native Arch after binhex)
    if [ "$(grep -E '=arch|="arch"' /etc/os-release)" != "" ] && \
       [ -d /usr/lib/plexmediaserver ] && \
       [ -d /var/lib/plex ]; then

      # Where is the software
      PKGDIR="/usr/lib/plexmediaserver"
      PLEX_SQLITE="$PKGDIR/Plex SQLite"
      LOG_TOOL="logger"

      # Where is the data
      AppSuppDir="/var/lib/plex"

      # Find the metadata dir if customized
      if [ -e /etc/systemd/system/plexmediaserver.service.d ]; then

        # Get custom AppSuppDir if specified
        NewSuppDir="$(GetOverride PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR)"

        if [ "$NewSuppDir" != "" ]; then
          if [ -d "$NewSuppDir" ]; then
            AppSuppDir="$NewSuppDir"
          else
            Output "Given application support directory override specified does not exist: '$NewSuppDir'. Ignoring."
          fi
        fi
      fi

      DBDIR="$AppSuppDir/Plex Media Server/Plug-in Support/Databases"
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
      LOGFILE="$DBDIR/DBRepair.log"
      LOG_TOOL="logger"
      TMPDIR="/tmp"
      SYSTMP="/tmp"
      HostType="$(grep PRETTY_NAME /etc/os-release | sed -e 's/^.*="//' | tr -d \" )"

      HaveStartStop=1
      StartCommand="systemctl start plexmediaserver"
      StopCommand="systemctl stop plexmediaserver"
      return 0
    fi
  fi


  # Unknown / currently unsupported host
  return 1
}

# Simple function to set variables
SetLast() {
  LastName="$1"
  LastTimestamp="$2"
  return 0
}

##### INDEX
DoIndex() {

    # Clear flag
    Damaged=0
    Fail=0
    # Check databases before Indexing if not previously checked
    if ! CheckDatabases "Reindex" ; then
      Damaged=1
      CheckedDB=1
      Fail=1
      [ $IgnoreErrors -eq 1 ] && Fail=0
    fi


    # If damaged, exit
    if [ $Damaged -eq 1 ]; then
      Output "Databases are damaged. Reindex operation not available.  Please repair or replace first."
      return
    fi

    # Databases are OK,  Make a backup
    Output "Backing up of databases"
    MakeBackups "Reindex"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if [ $Result -eq 0 ]; then
      WriteLog "Reindex - MakeBackup - PASS"
    else
      Output "Error making backups.  Cannot continue."
      WriteLog "Reindex - MakeBackup - FAIL ($Result)"
      Fail=1
      return
    fi

    # Databases are OK,  Start reindexing
    Output "Reindexing main database"
    "$PLEX_SQLITE" $CPPL.db 'REINDEX;'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if SQLiteOK $Result; then
      Output "Reindexing main database successful."
      WriteLog "Reindex - Reindex: $CPPL.db - PASS"
    else
      Output "Reindexing main database failed. Error code $Result from Plex SQLite"
      WriteLog "Reindex - Reindex: $CPPL.db - FAIL ($Result)"
      Fail=1
    fi

    Output "Reindexing blobs database"
    "$PLEX_SQLITE" $CPPL.blobs.db 'REINDEX;'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if SQLiteOK $Result; then
      Output "Reindexing blobs database successful."
      WriteLog "Reindex - Reindex: $CPPL.blobs.db - PASS"
    else
      Output "Reindexing blobs database failed. Error code $Result from Plex SQLite"
      WriteLog "Reindex - Reindex: $CPPL.blobs.db - FAIL ($Result)"
      Fail=1
    fi

    Output "Reindex complete."

    if [ $Fail -eq 0 ]; then
      SetLast "Reindex" "$TimeStamp"
      WriteLog "Reindex - PASS"
    else
      RestoreSaved "$TimeStamp"
      WriteLog "Reindex - FAIL"
    fi

    return $Fail

}

##### UNDO
DoUndo(){
      # Confirm there is something to undo
    if [ "$LastTimestamp" != "" ]; then

      # Educate user
      echo ""
      echo "'Undo' restores the databases to the state prior to the last SUCCESSFUL action."
      echo "If any action fails before it completes,   that action is automatically undone for you."
      echo "Be advised:  Undo restores the databases to their state PRIOR TO the last action of 'Vacuum', 'Reindex', or 'Replace'"
      echo "WARNING:  Once Undo completes,  there will be nothing more to Undo untl another successful action is completed"
      echo ""

      if ConfirmYesNo "Undo '$LastName' performed at timestamp '$LastTimestamp' ? "; then

        Output "Undoing $LastName ($LastTimestamp)"
        for j in "db" "db-wal" "db-shm" "blobs.db" "blobs.db-wal" "blobs.db-shm"
        do
        [ -e "$TMPDIR/$CPPL.$j-BACKUP-$LastTimestamp" ] && mv -f "$TMPDIR/$CPPL.$j-BACKUP-$LastTimestamp" $CPPL.$j
        done

        Output "Undo complete."
        WriteLog "Undo    - Undo ${LastName}, TimeStamp $LastTimestamp"
        SetLast "Undo" ""
      fi

    else
      Output "Nothing to undo."
      WriteLog "Undo    - Nothing to Undo."
    fi

}

##### DoSetPageSize
DoSetPageSize() {

  # If DBREPAIR_PAGESIZE variable exists, validate it.
  [ "$DBREPAIR_PAGESIZE" = "" ] && return

  # Is it a valid positive integer ?
  if [ "$DBREPAIR_PAGESIZE" != "$(echo "$DBREPAIR_PAGESIZE" | sed 's/[^0-9]*//g')" ]; then
    WriteLog "SetPageSize - ERROR: DBREPAIR_PAGESIZE is not a valid integer. Ignoring '$DBREPAIR_PAGESIZE'"
    Output "ERROR: DBREPAIR_PAGESIZE is not a valid integer. Ignoring '$DBREPAIR_PAGESIZE'"
    return
  fi

  # Make certain it's a multiple of 1024 and gt 0
  DbPageSize=$DBREPAIR_PAGESIZE
  [ $DbPageSize -le 0 ] && return

  if [ $(expr $DbPageSize % 1024) -ne 0 ]; then

    DbPageSize=$(expr $DBREPAIR_PAGESIZE + 1023)
    DbPageSize=$(expr $DbPageSize / 1024)
    DbPageSize=$(expr $DbPageSize \* 1024)

    WriteLog "DoSetPageSize - ERROR: DBREPAIR_PAGESIZE ($DBREPAIR_PAGESIZE) not a multiple of 1024. New value = $DbPageSize."
    Output   "WARNING: DBREPAIR_PAGESIZE ($DBREPAIR_PAGESIZE) not a multiple of 1024. New value = $DbPageSize."
  fi

  # Must be compliant
  if [ $DbPageSize -gt 65536 ]; then
    Output   "WARNING:  DBREPAIR_PAGESIZE ($DbPageSize) too large.  Reducing to 65536."
    WriteLog "SetPageSize - DBREPAIR_PAGESIZE ($DbPageSize) too large. Reducing."
    DbPageSize=65536
  fi

  # Confirm a valid power of two.
  IsPowTwo=0
  for i in 1024 2048 4096 8192 16384 32768 65536
  do
    [ $i -eq $DbPageSize ] && IsPowTwo=1 && break
  done

  if [ $IsPowTwo -eq 0 ] && [ $DbPageSize -lt 65536 ]; then
    for i in 1024 2048 4096 8192 16384 32768 65536
    do
      if [ $i -gt $DbPageSize ]; then
        Output "ERROR: DBREPAIR_SIZE ($DbPageSize) not a power of 2 between 1024 and 65536. Value selected = $i."
        WriteLog "SetPageSize - DBREPAIR_PAGESIZE ($DbPageSize) not a power of 2. New value selected = $i"
        DbPageSize=$i
        IsPowTwo=1
      fi
      [ $IsPowTwo -eq 1 ] && break
    done
  fi

  Output "Setting Plex SQLite page size ($DbPageSize)"
  WriteLog  "SetPageSize - Setting Plex SQLite page_size: $DbPageSize"


# Create DB with desired page size
"$PLEX_SQLITE" "$1" "PRAGMA page_size=${DbPageSize}; VACUUM;"

}

##### DoRepair
DoRepair() {


    Damaged=0
    Fail=0

    # Verify DBs are here
    if [ ! -e $CPPL.db ]; then
      Output "No main Plex database exists to repair. Exiting."
      WriteLog "Repair  - No main database - FAIL"
      Fail=1
      return 1
    fi

    # Check size
    Size=$(stat $STATFMT $STATBYTES $CPPL.db)

    # Exit if not valid
    if [ $Size -lt 300000 ]; then
      Output "Main database is too small/truncated, repair is not possible.  Please try restoring a backup. "
      WriteLog "Repair  - Main databse too small - FAIL"
      Fail=1
      return 1
    fi

    # Continue
    Output "Exporting current databases using timestamp: $TimeStamp"
    Fail=0

    # Attempt to export main db to SQL file (Step 1)
    Output "Exporting Main DB"
    "$PLEX_SQLITE" $CPPL.db  ".output '$TMPDIR/library.plexapp.sql-$TimeStamp'" .dump
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite while exporting $CPPL.db"
      Output "Could not successfully export the main database to repair it.  Please try restoring a backup."
      WriteLog "Repair  - Cannot recover main database to '$TMPDIR/library.plexapp.sql-$TimeStamp' - FAIL ($Result)"
      Fail=1
      return 1
    fi

    # Attempt to export blobs db to SQL file
    Output "Exporting Blobs DB"
    "$PLEX_SQLITE" $CPPL.blobs.db  ".output '$TMPDIR/blobs.plexapp.sql-$TimeStamp'" .dump
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite while exporting $CPPL.blobs.db"
      Output "Could not successfully export the blobs database to repair it.  Please try restoring a backup."
      WriteLog "Repair  - Cannot recover blobs database to '$TMPDIR/blobs.plexapp.sql-$TimeStamp' - FAIL ($Result)"
      Fail=1
      return 1
    fi

    # Edit the .SQL files if all OK
    if [ $Fail -eq 0 ]; then

      # Edit
      sed -i -e 's/ROLLBACK;/COMMIT;/' "$TMPDIR/library.plexapp.sql-$TimeStamp"
      sed -i -e 's/ROLLBACK;/COMMIT;/' "$TMPDIR/blobs.plexapp.sql-$TimeStamp"
    fi

    # Inform user
    Output "Successfully exported the main and blobs databases."
    WriteLog "Repair  - Export databases - PASS"

    # Library and blobs successfully exported, create new
    Output "Start importing into new databases."
    Output "Importing Main DB."
    DoSetPageSize "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"
    "$PLEX_SQLITE" "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp" < "$TMPDIR/library.plexapp.sql-$TimeStamp"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result ; then
      Output "Error $Result from Plex SQLite while importing from '$TMPDIR/library.plexapp.sql-$TimeStamp'"
      WriteLog "Repair  - Cannot import main database from '$TMPDIR/library.plexapp.sql-$TimeStamp' - FAIL ($Result)"
      Output "Cannot continue."
      Fail=1
      return 1
    fi

    Output "Importing Blobs DB."
    DoSetPageSize "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp"
    "$PLEX_SQLITE" "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp" < "$TMPDIR/blobs.plexapp.sql-$TimeStamp"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result ; then
      Output "Error $Result from Plex SQLite while importing from '$TMPDIR/blobs.plexapp.sql-$TimeStamp'"
      WriteLog "Repair  - Cannot import blobs database from '$TMPDIR/blobs.plexapp.sql-$TimeStamp' - FAIL ($Result)"
      Output "Cannot continue."
      Fail=1
      return 1
    fi

    # Made it to here, now verify
    Output "Successfully imported databases."
    WriteLog "Repair  - Import - PASS"

    # Verify databases are intact and pass testing
    Output "Verifying databases integrity after importing."

    # Check main DB
    if CheckDB "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp" ; then
      SizeStart=$(GetSize "$CPPL.db")
      SizeFinish=$(GetSize "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp")
      Output "Verification complete.  PMS main database is OK."
      WriteLog "Repair  - Verify main database - PASS (Size: ${SizeStart}MB/${SizeFinish}MB)."
    else
      Output "Verification complete.  PMS main database import failed."
      WriteLog "Repair  - Verify main database - FAIL ($SQLerror)"
      Fail=1
    fi

    # Check blobs DB
    if CheckDB "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp" ; then
      SizeStart=$(GetSize "$CPPL.blobs.db")
      SizeFinish=$(GetSize "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp")
      Output "Verification complete.  PMS blobs database is OK."
      WriteLog "Repair  - Verify blobs database - PASS (Size: ${SizeStart}MB/${SizeFinish}MB)."
    else
      Output "Verification complete.  PMS blobs database import failed."
      WriteLog "Repair  - Verify main database - FAIL ($SQLerror)"
      Fail=1
    fi

    # If not failed,  move files normally
    if [ $Fail -eq 0 ]; then

      Output "Saving current databases with '-BACKUP-$TimeStamp'"
      [ -e $CPPL.db ]       && mv $CPPL.db       "$TMPDIR/$CPPL.db-BACKUP-$TimeStamp"
      [ -e $CPPL.blobs.db ] && mv $CPPL.blobs.db "$TMPDIR/$CPPL.blobs.db-BACKUP-$TimeStamp"

      Output "Making repaired databases active"
      WriteLog "Repair  - Making repaired databases active"
      mv "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"       $CPPL.db
      mv "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp" $CPPL.blobs.db

      Output "Repair complete. Please check your library settings and contents for completeness."
      Output "Recommend:  Scan Files and Refresh all metadata for each library section."

      # Ensure WAL and SHM are gone
      [ -e $CPPL.blobs.db-wal ] && rm -f $CPPL.blobs.db-wal
      [ -e $CPPL.blobs.db-shm ] && rm -f $CPPL.blobs.db-shm
      [ -e $CPPL.db-wal ]       && rm -f $CPPL.db-wal
      [ -e $CPPL.db-shm ]       && rm -f $CPPL.db-shm

      # Set ownership on new files
      chmod $Perms $CPPL.db $CPPL.blobs.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR:  Cannot set permissions on new databases. Error $Result"
        Output "        Please exit tool, keeping temp files, seek assistance."
        Output "        Use files: $TMPDIR/*-BACKUP-$TimeStamp"
        WriteLog "Repair  - Move files - FAIL"
        Fail=1
        return 1
      fi

      chown $Owner $CPPL.db $CPPL.blobs.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR:  Cannot set ownership on new databases. Error $Result"
        Output "        Please exit tool, keeping temp files, seek assistance."
        Output "        Use files: $TMPDIR/*-BACKUP-$TimeStamp"
        WriteLog "Repair  - Move files - FAIL"
        Fail=1
        return 1
      fi

      # We didn't fail, set CheckedDB status true (passed above checks)
      CheckedDB=1

      WriteLog "Repair  - Move files - PASS"
      WriteLog "Repair  - PASS"

      SetLast "Repair" "$TimeStamp"
      return 0
    else

      rm -f "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"
      rm -f "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp"

      Output "Repair has failed.  No files changed"
      WriteLog "Repair - $TimeStamp - FAIL"
      CheckedDB=0
      return 1
    fi
}

##### Replace current DB with a valid backup DB (if available)
DoReplace() {

  # If Databases already checked, confirm the user really wants to do this
  Confirmed=0
  Fail=0
  if CheckDatabases "Replace"; then
    if ConfirmYesNo "Are you sure you want to restore a previous database backup "; then
      Confirmed=1
    fi
  fi

  if [ $Damaged -eq 1 ] || [ $Confirmed -eq 1 ]; then
    # Get list of dates to use
    Dates="$(GetDates)"

    # If no backups, error and exit
    if [ "$Dates" = "" ]  && [ $Damaged -eq 1 ]; then
      Output "Database is damaged and no backups avaiable."
      Output "Only available option is Repair."
      WriteLog "Replace - Scan for usable candidates - FAIL"
      return 1
    fi

    Output "Checking for a usable backup."
    Candidate=""

    # Make certain there is ample free space
    if ! FreeSpaceAvailable ; then
      Output "ERROR:  Insufficient free space available on $AppSuppDir.  Cannot continue"
      WriteLog "REPLACE -  Insufficient free space available on $AppSuppDir.  Aborted."
      return 1
    fi

    Output "Database backups available are:  $Dates"
    Output " "
    Count=0
    Selection=0
    Candidate=""
    Valid=0

    # Print the list of dates
    for i in $Dates
    do
      Count=$((Count + 1))
      echo "  ${Count}) - $i"
    done

    # Get the selection
    Selection=""
    Output " "
    echo -n "Select backup date by number or date name  (blank = return to menu) "
    read Selection

    # If no selection - return
    [ "$Selection" = "" ] && return

    # Search for match
    Candidate=""
    Count=0
    for i in $Dates; do
      Count=$((Count + 1))
      if [ "$Selection" = "$Count" ] || [ "$Selection" = "$i" ]; then
        Candidate="$i"
      fi
    done

    # If no match, return
    if [ "$Candidate" = "" ]; then
      Output "Error.  No valid matching main and blobs database pairs.  Cannot replace."
      WriteLog "Replace - Select candidate - FAIL"
      return
    fi

    # Check candidate
    if [ -e $CPPL.db-$Candidate            ] && \
       [ -e $CPPL.blobs.db-$Candidate      ] ; then

      Fail=0
      Output "Checking backup candidate $Candidate"
      ! CheckDB $CPPL.db-$Candidate       && Fail=1
      ! CheckDB $CPPL.blobs.db-$Candidate && Fail=1

      [ $Fail -eq 1 ] && Output "Backup from $Candidate is not usable.  Try again" && return

      Output "Database backup $Candidate is valid."
      UseThis=0
      Output " "

      if ConfirmYesNo "Use backup dated: '$Candidate' ?"; then
        UseThis=1
      fi
    else
      # Did not pass checks
      Output "One of the backup files is missing.  Please make another selection"
      Fail=1
      return
    fi

    # OK, use this one
    if [ $UseThis -eq 1 ]; then

      # Move database, wal, and shm  (keep safe) with timestamp
      Output "Saving current databases with timestamp: '-BACKUP-$TimeStamp'"

      for j in "db" "db-wal" "db-shm" "blobs.db" "blobs.db-wal" "blobs.db-shm"
      do
        [ -e $CPPL.$j ] && mv -f $CPPL.$j  "$TMPDIR/$CPPL.$j-BACKUP-$TimeStamp"
      done
      WriteLog "Replace - Move Files - PASS"

      # Copy this backup into position as primary
      Output "Copying backup database from $Candidate to use as new database."

      cp -p $CPPL.db-$Candidate $CPPL.db-REPLACE-$TimeStamp
      Result=$?

      if [ $Result -ne 0 ]; then
        Output "Error $Result while copying $CPPL.db"
        Output "Database file is incomplete.   Please resolve manually."
        WriteLog "Replace - Copy $CPPL.db-$Candidate - FAIL"
        Fail=1
      else
        WriteLog "Replace - Copy $CPPL.db-$i - PASS"
      fi

      cp -p $CPPL.blobs.db-$Candidate $CPPL.blobs.db-REPLACE-$TimeStamp
      Result=$?

      if [ $Result -ne 0 ]; then
        Output "Error $Result while copying $CPPL.blobs.db"
        Output "Database file is incomplete.   Please resolve manually."
        WriteLog "Replace - Copy $CPPL.blobs.db-$Candidate - FAIL"
        Fail=1
      else
        WriteLog "Replace - Copy $CPPL.blobs.db-$Candidate - PASS"
      fi

      # If no failure copying,  check and make active
      if [ $Fail -eq 0 ]; then
        # Final checks
        Output "Copy complete. Performing final check"

        if CheckDB $CPPL.db-REPLACE-$TimeStamp         && \
           CheckDB $CPPL.blobs.db-REPLACE-$TimeStamp   ;  then

          # Move into position as active
          mv $CPPL.db-REPLACE-$TimeStamp       $CPPL.db
          mv $CPPL.blobs.db-REPLACE-$TimeStamp $CPPL.blobs.db

          # done
          Output " "
          Output "Database recovery and verification complete."
          WriteLog "Replace - Verify databases - PASS"

        else

          # DB did not verify after copy -- Something wrong

          rm -f $CPPL.db-$TimeStamp  $CPPL.blobs.db-$TimeStamp
          Output "Final check failed.  Keeping existing databases"
          WriteLog "Replace - Verify databases - FAIL"
          WriteLog "Replace - Failed Databses - REMOVED"
        fi
      else

        Output "Could not copy backup databases. Out of disk space?"
        Output "Restoring original databases"

        for k in "db" "db-wal" "db-shm" "blobs.db" "blobs.db-wal" "blobs.db-shm"
        do
          [ -e "$TMPDIR/$CPPL.$k-BACKUP-$TimeStamp" ] && mv -f "$TMPDIR/$CPPL.$k-BACKUP-$TimeStamp" $CPPL.$k
        done
        WriteLog "Replace - Verify databases - FAIL"
        Fail=1
      fi

      # If successful, save
      [ $Fail -eq 0 ] && SetLast "Replace" "$TimeStamp"
    fi
  fi
}

##### Deflate
DoDeflate() {

    Damaged=0
    Fail=0

    # Verify DBs are here
    if [ ! -e $CPPL.db ]; then
      Output "No main Plex database exists to deflate. Exiting."
      WriteLog "Deflate  - No main database - FAIL"
      Fail=1
      return 1
    fi

    # Check size
    Size=$(stat $STATFMT $STATBYTES $CPPL.db)

    # Exit if not valid
    if [ $Size -lt 300000 ]; then
      Output "Main database is too small/truncated, deflate is not possible.  Please try restoring a backup. "
      WriteLog "Deflate  - Main databse too small - FAIL"
      Fail=1
      return 1
    fi

    # Calculate DBsize in GB
    DBSize=$(( $Size / 1000000000 + 2 ))
    # Continue
    DoUpdateTimestamp
    #Output "Backing up databases using timestamp: $TimeStamp"

    # Make a backup
    if ! MakeBackups "Deflate"; then
      Output "Error making backups.  Cannot continue."
      WriteLog "Deflate - MakeBackups - FAIL"
      Fail=1
      return 1
    else
      WriteLog "Deflate - MakeBackups - PASS"
    fi

    # Inform user
    Output "Starting Deflate (Part 1 of 2 - Repair database table)"
    Output "Estimated completion is $((DBSize / 3)) minutes but is CPU & I/O speed dependent"
    Output ""
    WriteLog "Deflate - Start Deflate Pass 1"

    # Library and blobs successfully exported, create new
    "$PLEX_SQLITE" "$TMPDIR/$CPPL.db-BACKUP-$TimeStamp" << EOF
    -- Exclusive DB access
    BEGIN IMMEDIATE;

    -- Create new table
    CREATE TABLE temp_bandwidth (
      id INTEGER PRIMARY KEY,
      account_id INTEGER,
      device_id INTEGER,
      timespan INTEGER,
      at INTEGER,
      lan INTEGER,
      bytes INTEGER
    );

    -- Copy good data to new table
    INSERT INTO temp_bandwidth (
      account_id, device_id, timespan, at, lan, bytes
      )
      SELECT account_id, device_id, timespan, at, COALESCE(lan, 0), bytes
      FROM statistics_bandwidth WHERE account_id not null;

    -- Swap new for old
    DROP TABLE statistics_bandwidth;
    ALTER TABLE temp_bandwidth RENAME TO statistics_bandwidth;

    -- Create Indexes
    CREATE INDEX IF NOT EXISTS index_statistics_bandwidth_on_at
    ON statistics_bandwidth(at);

    CREATE INDEX IF NOT EXISTS index_statistics_bandwidth_on_account_id_and_timespan_and_at
    ON statistics_bandwidth(account_id, timespan, at);

    -- Make it so
    COMMIT;
EOF
    Result=$?
    if [ $Result -ne 0 ]; then
      Output "Error: Could not correct statistics_bandwidth table (error $Result)"
      Output "       Please seek additional help"
      WriteLog "Deflate: Error $Result during dodeflate."
      Fail=1
      return $Fail
    fi

    # Vacuum the DB to the new DB
    Output "PMS main database successfully repaired."
    Output "Starting Deflate (Part 2 of 2 - Reduce size)"
    WriteLog "Deflate - Start Deflate Pass 2"

    "$PLEX_SQLITE" "$TMPDIR/$CPPL.db-BACKUP-$TimeStamp" \
      "VACUUM main into '$TMPDIR/$CPPL.db-DEFLATE-$TimeStamp'"
    Result=$?

    # Good result?
    if [ $Result -eq 0 ]; then
      Output "PMS main database size reduced."
      WriteLog "Deflate - PMS main vacuum successful."
      Output "Verifying PMS main database."
      if CheckDB "$TMPDIR/$CPPL.db-DEFLATE-$TimeStamp" ; then
        SizeStart=$(GetSize "$CPPL.db")
        SizeFinish=$(GetSize "$TMPDIR/$CPPL.db-DEFLATE-$TimeStamp")
        Output "Verification complete.  PMS main database is OK."
        Output "PMS main database reduced from $SizeStart MB to $SizeFinish MB"
        WriteLog "Deflate - Verify main database - PASS (Size: ${SizeStart} MB / ${SizeFinish} MB."
      else
        Output "Verification complete.  PMS main database import failed."
        WriteLog "Deflate - Verify main database - FAIL ($SQLerror)"
        Fail=1
      fi
    else
      Output "Error: Error code $Result while vacuuming PMS main DB file."
      Output "       Please seek additional help."
      return $Fail
    fi

    # If not failed,  move files normally
    if [ $Fail -eq 0 ]; then

      Output "Saving current main database with '-BLOATED-$TimeStamp'"
      [ -e $CPPL.db ]        && mv $CPPL.db       "$TMPDIR/$CPPL.db-BLOATED-$TimeStamp"
      #[ -e $CPPL.blobs.db ] && mv $CPPL.blobs.db "$TMPDIR/$CPPL.blobs.db-BLOATED-$TimeStamp"

      Output "Making deflated database active"
      WriteLog "Deflate - Making deflated database active"
      mv "$TMPDIR/$CPPL.db-DEFLATE-$TimeStamp"       $CPPL.db

      # Ensure WAL and SHM are gone
      [ -e $CPPL.blobs.db-wal ] && rm -f $CPPL.blobs.db-wal
      [ -e $CPPL.blobs.db-shm ] && rm -f $CPPL.blobs.db-shm
      [ -e $CPPL.db-wal ]       && rm -f $CPPL.db-wal
      [ -e $CPPL.db-shm ]       && rm -f $CPPL.db-shm

      # Set ownership on new files
      chmod $Perms $CPPL.db $CPPL.blobs.db
      chown $Owner $CPPL.db $CPPL.blobs.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR:  Cannot set permissions on new databases. Error $Result"
        Output "        Please exit tool, keeping temp files, seek assistance."
        Output "        Use files: $TMPDIR/*-DEFLATE-$TimeStamp"
        WriteLog "Deflate - Move files - FAIL"
        Fail=1
        return 1
      fi

      # We didn't fail, set CheckedDB status true (passed above checks)
      CheckedDB=1

      WriteLog "Deflate - Move files - PASS"
      WriteLog "Deflate - PASS"


      Output "PMS main database deflate completed."


      SetLast "Deflate" "$TimeStamp"
      return 0
    else

      rm -f "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"
      rm -f "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp"

      Output "Deflate has failed.  No files changed"
      WriteLog "Deflate - $TimeStamp - FAIL"
      CheckedDB=0
      return 1
    fi
}

##### VACUUM
DoVacuum(){

  # Clear flags
  Fail=0
  Damaged=0

  # Check databases before Indexing if not previously checked
  if ! CheckDatabases "Vacuum " ; then
    Damaged=1
    Fail=1
  fi

  # If damaged, exit
  if [ $Damaged -eq 1 ]; then
    Output "Databases are damaged. Vacuum operation not available.  Please repair or replace first."
    WriteLog "Vacuum  - Databases damaged."
    return 1
  fi

  # Make a backup
  Output "Backing up databases"
  if ! MakeBackups "Vacuum "; then
    Output "Error making backups.  Cannot continue."
    WriteLog "Vacuum  - MakeBackups - FAIL"
    Fail=1
    return 1
  else
    WriteLog "Vacuum  - MakeBackups - PASS"
  fi

  # Start vacuuming
  Output "Vacuuming main database"
  SizeStart=$(GetSize $CPPL.db)

  # Vacuum it
  "$PLEX_SQLITE" $CPPL.db 'VACUUM;'
  Result=$?

  if SQLiteOK $Result; then
    SizeFinish=$(GetSize $CPPL.db)
    Output "Vacuuming main database successful (Size: ${SizeStart}MB/${SizeFinish}MB)."
    WriteLog "Vacuum  - Vacuum main database - PASS (Size: ${SizeStart}MB/${SizeFinish}MB)."
  else
    Output "Vaccuming main database failed. Error code $Result from Plex SQLite"
    WriteLog "Vacuum  - Vacuum main database - FAIL ($Result)"
    Fail=1
  fi

  Output "Vacuuming blobs database"
  SizeStart=$(GetSize $CPPL.blobs.db)

  # Vacuum it
  "$PLEX_SQLITE" $CPPL.blobs.db 'VACUUM;'
  Result=$?

  if SQLiteOK $Result; then
    SizeFinish=$(GetSize $CPPL.blobs.db)
    Output "Vacuuming blobs database successful (Size: ${SizeStart}MB/${SizeFinish}MB)."
    WriteLog "Vacuum  - Vacuum blobs database - PASS (Size: ${SizeStart}MB/${SizeFinish}MB)."
  else
    Output "Vaccuming blobs database failed. Error code $Result from Plex SQLite"
    WriteLog "Vacuum  - Vacuum blobs database - FAIL ($Result)"
    Fail=1
  fi

  if [ $Fail -eq 0 ]; then
    Output "Vacuum complete."
    WriteLog "Vacuum  - PASS"
    SetLast "Vacuum" "$TimeStamp"
  else
    Output "Vacuum failed."
    WriteLog "Vacuum  - FAIL"
    RestoreSaved "$TimeStamp"
  fi
}

##### (import) Viewstate/Watch history from another DB and import
DoImport(){

  if ! FreeSpaceAvailable; then
    Output "Unable to make backups before importing.  Insufficient free space available on $AppSuppDir."
    WriteLog "Import  - Insufficient free disk space for backups."
    return 1
  fi

  printf "Pathname of database containing watch history to import: "
  read Input

  # Did we get something?
  [ "$Input" = "" ] && return 0

  # Go see if it's a valid database
  if [ ! -f "$Input" ]; then
    Output "'$Input' does not exist."
    return 1
  fi

  Output ""
  WriteLog "Import  - Attempting to import watch history from '$Input' "

  # Confirm our databases are intact
  if ! CheckDatabases "Import "; then
    Output "Error:  PMS databases are damaged.  Repair needed. Refusing to import."
    WriteLog "Import   - Verify main database - FAIL"
    return 1
  fi

  # Check the given database
  Output "Checking database '$Input'"
  if ! CheckDB "$Input"; then
    Output "Error:  Given database '$Input' is damaged.  Repair needed. Database not trusted.  Refusing to import."
    WriteLog "Import  - Verify '$Input' - FAIL"
    return 1
  fi
  WriteLog "Import  - Verify '$Input' - PASS"
  Output "Check complete.  '$Input' is OK."


  # Make a backup
  Output "Backing up PMS databases"
  if ! MakeBackups "Import "; then
    Output "Error making backups.  Cannot continue."
    WriteLog "Import  - MakeBackups - FAIL"
    Fail=1
    return 1
  fi
  WriteLog "Import  - MakeBackups - PASS"


  # Export viewstate from DB
  Output "Exporting Viewstate & Watch history"
  echo ".dump metadata_item_settings metadata_item_views " | "$PLEX_SQLITE" "$Input" | grep -v TABLE | grep -v INDEX > "$TMPDIR/Viewstate.sql-$TimeStamp"

  # Make certain we got something usable
  if [ $(wc -l "$TMPDIR/Viewstate.sql-$TimeStamp" | awk '{print $1}') -lt 1 ]; then
    Output "No viewstates or history found to import."
    WriteLog "Import  - Nothing to import - FAIL"
    return 1
  fi

  # Make a working copy to import into
  Output "Preparing to import Viewstate and History data"
  cp -p $CPPL.db "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp"
  Result=$?

  if [ $Result -ne 0 ]; then
    Output "Error $Result while making a working copy of the PMS main database."
    Output "      File permissions?  Disk full?"
    WriteLog "Import  - Prepare: Make working copy - FAIL"
    return 1
  fi

  # Import viewstates into working copy (Ignore constraint errors during import)
  printf 'Importing Viewstate & History data...'
  DoSetPageSize "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp"
  "$PLEX_SQLITE" "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp" < "$TMPDIR/Viewstate.sql-$TimeStamp" 2> /dev/null

  # Remove duplicates (violations of unique constraint)
  if [ $RemoveDuplicates -eq 1 ]; then
   cat <<EOF | "$PLEX_SQLITE" "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp"
    DELETE FROM metadata_item_settings
    WHERE rowid NOT IN
    ( SELECT MIN(rowid) FROM metadata_item_settings GROUP BY guid, account_id );
EOF
  fi

  # Make certain the resultant DB is OK
  Output " done."
  Output "Checking database following import"

  if ! CheckDB "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp" ; then

    # Import failed discard
    Output "Error: Error code $Result during import.  Import corrupted database."
    Output "       Discarding import attempt."

    rm -f "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp"

    WriteLog "Import  - Import: $Input - FAIL"
    return 1
  fi

  # Import successful; switch to new DB
  Output "PMS main database is OK.  Making imported database active"
  WriteLog "Import  - Import: Making imported database active"

  # Move from tmp to active
  mv "$TMPDIR/$CPPL.db-IMPORT-$TimeStamp" $CPPL.db

  # We were successful
  Output "Viewstate import successful."
  WriteLog "Import  - Import: $Input - PASS"

  # Set owner and permissions
  chown $Owner $CPPL.db
  chmod $Perms $CPPL.db

  # We were successful
  SetLast "Import" "$TimeStamp"
  return 0
}

##### IsRunning  (True if PMS is running)
IsRunning(){
  [ "$($PIDOF 'Plex Media Server')" != "" ] && return 0
  return 1
}

##### DoStart (Start PMS if able)
DoStart(){

  if [ $HaveStartStop -eq 0 ]; then
    Output   "Start/Stop feature not available"
    WriteLog "Start/Stop feature not available"
    return 1
  else

    # Check if PMS running
    if IsRunning; then
      WriteLog "Start   - PASS - PMS already runnning"
      Output   "Start not needed.  PMS is running."
      return 0
    fi

    Output "Starting PMS."
    $StartCommand > /dev/null 2> /dev/null
    Result=$?

    if [ $Result -eq 0 ]; then
      WriteLog "Start   - PASS"
      Output   "Started PMS"
    else
      WriteLog "Start   - FAIL ($Result)"
      Output   "Could not start PMS. Error code: $Result"
    fi
  fi
  return $Result
}

##### DoStop (Stop PMS if able)
DoStop(){
  if [ $HaveStartStop -eq 0 ]; then
    Output   "Start/Stop feature not available"
    WriteLog "Start/Stop feature not available"
    return 1
  else

    if IsRunning; then
     Output "Stopping PMS. (60 second max delay)"
    else
     Output "PMS already stopped."
     return 0
    fi

    $StopCommand > /dev/null 2> /dev/null
    Result=$?
    if [ $Result -ne 0 ]; then
      Output   "Cannot send stop command to PMS, error $Result.  Please stop manually."
      WriteLog "Cannot send stop command to PMS, error $Result.  Please stop manually."
      return 1
    fi

    Count=10
    while IsRunning && [ $Count -gt 0 ]
    do
      sleep 6
      Count=$((Count - 1))
    done

    if  ! IsRunning; then
      WriteLog "Stop    - PASS"
      Output "Stopped PMS."
      return 0
    else
      WriteLog "Stop    - FAIL (Timeout)"
      Output   "Could not stop PMS. PMS did not shutdown within 60 second limit."
    fi
  fi
  return $Result
}

# Mac Helper Functions
startMacPMS() { TMPDIR=/tmp osascript -e 'tell app "Plex Media Server" to launch'; sleep 2; IsRunning && sayStarted; }
stopMacPMS() { osascript -e 'tell app "Plex Media Server" to quit'; sleep 2; IsRunning || sayStopped; }
sayStarted() { [ $HapticOkay -eq 1 ] && osascript -e 'say "started"'; }
sayStopped() { [ $HapticOkay -eq 1 ] && osascript -e 'say "Its stopped"'; }

# Do command line switches
#DoOptions() {


#}

# UpdateTimestamp
DoUpdateTimestamp() {
  TimeStamp="$(date "+%Y-%m-%d_%H.%M.%S")"
}

# Get latest version from Github
GetLatestRelease() {
  Response=$(curl -sL "https://api.github.com/repos/ChuckPa/DBRepair/tags")
  if [ $? -eq 0 ]; then
    LatestVersion="$(echo "$Response" | grep name | awk -F: '{print $2}' | sort -r | head -1 | tr -d \" | tr -d ' ' | tr -d ',')"
  else
    LatestVersion="$Version"
  fi

}

# Download and update script
DownloadAndUpdate() {
    Url="$1"
    Filename="$2"

    # Download the file and check if the download was successful
    if curl -sL "$Url" --output "${Filename}.tmp"; then
        # Check if the file was written to and at least 50000 bytes
        if [ -f "${Filename}.tmp" ]; then
          if [ $(stat $STATFMT $STATBYTES "${Filename}.tmp") -gt 50000 ]; then
            Output "Update downloaded successfully"
            mv "$Filename" "${Filename}.bak"
            mv "${Filename}.tmp" "$Filename"
            chmod +x "$Filename"
            return 0
          else
            Output "Error: Downloaded file incomplete."
            rm -f "${Filename}.tmp"
          fi
        else
            Output "Error: Unable to download update."
            rm -f "${Filename}.tmp"
        fi
    else
        Output "Error: Download failed."
        rm -f "${Filename}.tmp"
    fi
    return 1
}

# Prune old jpg files from the PhotoTranscoder directory (> 30 days -or- DBREPAIR_CACHEAGE days)
# and purge files from the TMP and Transcoder_Temp directories
DoPrunePhotoTranscoder() {

  PruneIt=0

  # Use default cache age of 30 days
  CacheAge=30

  # Does DBREPAIR_CACHEAGE exist and is it a valid positive integer ?
  if [ "$DBREPAIR_CACHEAGE" != "" ]; then
    if [ "$DBREPAIR_CACHEAGE" != "$(echo "$DBREPAIR_CACHEAGE" | sed 's/[^0-9]*//g')" ]; then
      WriteLog "PrunePhotoTranscoder  - ERROR: DBREPAIR_CACHEAGE is not a valid integer. Ignoring '$DBREPAIR_CACHEAGE'"
      Output "ERROR: DBREPAIR_CACHEAGE is not a valid integer. Ignoring '$DBREPAIR_CACHEAGE'"
      return
    else
      CacheAge=$DBREPAIR_CACHEAGE
    fi
  fi

  # If scripted / command line options, clean automatically
  if [ $Scripted -eq 1 ]; then
    PruneIt=1
  else
    Output "Counting how many files can be removed."
    FileCount=$(find "$CACHEDIR" \( -name \*.jpg -o -name \*.jpeg -o -name \*.png -o -name \*.ppm \) -mtime +${CacheAge} -print | wc -l)
    FileCount=$(( $FileCount + $(find "/tmp" -name pms-\* -mtime +1 -print | grep -v systemd | grep -v Easy | wc -l)))
    FileCount=$(( $FileCount + $(find "/tmp" \( -name \*.jpg -o -name \*.jpeg -o -name \*.png \) -mtime +1 | wc -l )))

    # If nothing found, continue back to the menu
    [ $FileCount -eq 0 ] && Output "No files found to prune." && return

    # Ask if we should remove it
    if ConfirmYesNo "OK to prune $FileCount files? "; then
        PruneIt=1
    fi
  fi

  # Prune old the jpgs/jpegs from Cache  and clean up /tmp
  if [ $PruneIt -eq 1 ]; then
    Output "Pruning started."
    WriteLog "Prune   - START"
    find "$CACHEDIR" \( -name \*.jpg -o -name \*.jpeg -o -name \*.png \) -mtime +${CacheAge} -delete

    PurgeFiles="/tmp/PurgeList.$$"
    find "$TMPDIR" /tmp -name pms-\* -mtime +1 -print | grep -v systemd | grep -v Easy -print > "$PurgeFiles"  2>> /dev/null
    find "$TMPDIR" /tmp \( -name \*.jpg -o -name \*.jpeg -o -name \*.png \) -mtime +1 -print >> "$PurgeFiles"   2>> /dev/null
    WriteLog "Prune   - Removing $FileCount files."
    while read Path
    do
      rm -rf "$Path"  >> /dev/null 2>> /dev/null
    done < "$PurgeFiles"

    rm -f "$PurgeFiles"

    Output "Pruning completed."
    WriteLog "Prune   - PASS."
  fi

}

#############################################################
#         Main utility begins here                          #
#############################################################

# Set Script Path
ScriptPath="$(readlink -f "$0")"
ScriptName="$(basename "$ScriptPath")"
ScriptWorkingDirectory="$(dirname "$ScriptPath")"

# Initialize LastName LastTimestamp
SetLast "" ""

# Process any given command line options in the ugliest manner possible :P~~
while [ "$(echo $1 | cut -c1)" = "-" ] && [ "$1" != "" ]
do
  Opt="$(echo $1 | awk '{print $1}' | tr [A-Z] [a-z])"
  [ "$Opt" = "-i" ] && shift
  [ "$Opt" = "-f" ] && shift
  [ "$Opt" = "-p" ] && shift

  # Manual configuration options (running outside of container or unusual hosts)
  if [ "$Opt" = "--sqlite" ]; then

    # Is this the directory where Plex SQLite exists?
    if   [ -d "$2" ] && [ -f "$2/Plex SQLite" ]; then
      PLEX_SQLITE="$2/Plex SQLite"
      ManualConfig=1

    # Or is it the direct path to Plex SQLite
    elif echo "$2" | grep "Plex SQLite" > /dev/null  && [ -f "$2" ] ; then
      PLEX_SQLITE="$2"

    else
      Output "Given 'Plex SQLite' directory/path ('$2') is invalid. Aborting."
      exit 2
    fi
    shift 2
  fi



  # Manual path to databases
  if [ "$Opt" = "--databases" ]; then

    # Manually specify path to where the databases reside and set all dependent dirs
    if [ -d "$2" ] && [ -f "$2"/com.plexapp.plugins.library.db ]; then
      DBDIR="$2"
      AppSuppDir="$(dirname "$(dirname "$(dirname "$DBDIR")")")"
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
      LOGFILE="$DBDIR/DBRepair.log"
      ManualConfig=1


    else
      Output "Given Plex databases directory ('$2') is invalid. Aborting."
      exit 2
    fi
    shift 2
  fi
done

# Confirm completed manual config
if [ $ManualConfig -eq 1 ]; then
  if [ "$DBDIR" = "" ] || [ "$PLEX_SQLITE" = "" ]; then
    Output "Error: Both 'Plex SQLite' and Databases directory paths must be specified with Manual configuration."
    WriteLog "Manual configuration incomplete.  One of the required arguments was missing."
    exit 2
  fi

  # Performing logging here
  [ $IgnoreErrors -eq 1     ] && WriteLog "Opt: Database error checking ignored."
  [ $RemoveDuplicates -eq 1 ] && WriteLog "Opt: Remove duplidate watch history viewstates."
  WriteLog "Plex SQLite = '$PLEX_SQLITE'"
  WriteLog "Databases   = '$DBDIR'"

  # Final configuration
  HostType="User Defined"
fi



# Are we scripted (command line args)
Scripted=0
[ "$1" != "" ] && Scripted=1

# Identify this host
if [ $ManualConfig -eq 0 ] && ! HostConfig; then
  Output 'Error: Unknown host. Current supported hosts are: QNAP, Syno, Netgear, Mac, ASUSTOR, WD (OS5), Linux wkstn/svr, SNAP, FreeBSD 14+'
  Output '                     Current supported container images:  Plexinc, LinuxServer, HotIO, & BINHEX'
  Output '                     Manual host configuration is available in most use cases.'
  Output ' '
  Output 'Are you trying to run the tool from outside the container environment?  Manual mode is available. Please see documentation.'
  exit 1
fi

# If root required, confirm this script is running as root
if [ $RootRequired -eq 1 ] && [ $(id -u) -ne 0 ]; then
  Output "ERROR:  Tool running as username '$(whoami)'.  '$HostType' requires 'root' user privilege."
  Output "        (e.g 'sudo -su root' or 'sudo bash')"
  Output "        Exiting."
  exit 2
fi

# We might not be root but minimally make sure we have write access
if [ ! -w "$DBDIR" ]; then
  echo ERROR: Cannot write to Databases directory.  Insufficient privilege.
  exit 2
fi

echo " "
# echo Detected Host:  $HostType
WriteLog "============================================================"
WriteLog "Session start: Host is $HostType"

# Make sure we have a logfile
touch "$LOGFILE"

# Basic checks;  PMS installed
if [ ! -f "$PLEX_SQLITE" ] ; then
  Output "PMS is not installed.  Cannot continue.  Exiting."
  WriteLog "PMS not installed."
  exit 1
fi

# Set tmp dir so we don't use RAM when in DBDIR
DBTMP="./dbtmp"
mkdir -p "$DBDIR/$DBTMP"

# Now set as DBTMP
export TMPDIR="$DBTMP"
export TMP="$DBTMP"

# If command line args then set flag
Scripted=0
[ "$1" != "" ] && Scripted=1

# Can I write to the Databases directory ?
if [ ! -w "$DBDIR" ]; then
  Output "ERROR: Cannot write to the Databases directory. Insufficient privilege or wrong UID. Exiting."
  exit 1
fi

# Databases exist or Backups exist to restore from
if [ ! -f "$DBDIR/$CPPL.db" ]       && \
   [ ! -f "$DBDIR/$CPPL.blobs.db" ] && \
   [ "$(echo com.plexapp.plugins.*-????-??-??)" = "com.plexapp.plugins.*-????-??-??" ]; then

  Output "Cannot locate databases. Cannot continue.  Exiting."
  WriteLog "Databases or backups not found."
  exit 1
fi

# Work in the Databases directory
cd "$DBDIR"

# Get the owning UID/GID before we proceed so we can restore
Owner="$(stat $STATFMT '%u:%g' $CPPL.db)"
Perms="$(stat $STATFMT $STATPERMS $CPPL.db)"

# Sanity check,  We are either owner of the DB or root
if [ ! -w $CPPL.db ]; then
   Output "Do not have write permission to the Databases. Exiting."
   WriteLog "No write permission to databases+.  Exit."
   exit 1
fi

# Run entire utility in a loop until all arguments used,  EOF on input, or commanded to exit
while true
do

  echo " "
  echo " "
  echo "      Database Repair Utility for Plex Media Server  ($HostType)"
  echo "                       Version $Version"
  echo " "

  # Print info if Manual
  if [ $ManualConfig -eq 1 ]; then
    WriteLog "SQLite path:   '$PLEX_SQLITE'"
    WriteLog "Database path: '$DBDIR'"
    Output "      PlexSQLite = '$PLEX_SQLITE'"
    Output "      Databases  = '$DBDIR'"
  fi

  Choice=0; Exit=0; NullCommands=0

  # Main menu loop
  while [ $Choice -eq 0 ]
  do
    if [ $ShowMenu -eq 1 ] && [ $Scripted -eq 0 ]; then

      echo ""
      echo "Select"
      echo ""
      [ $HaveStartStop -gt 0 ] && echo "  1 - 'stop'      - Stop PMS."
      [ $HaveStartStop -eq 0 ] && echo "  1 - 'stop'      - (Not available. Stop manually.)"
      echo "  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step."
      echo "  3 - 'check'     - Perform integrity check of database."
      echo "  4 - 'vacuum'    - Remove empty space from database without optimizing."
      echo "  5 - 'repair'    - Repair/Optimize databases."
      echo "  6 - 'reindex'   - Rebuild database indexes."

      [ $HaveStartStop -gt 0 ] && echo "  7 - 'start'     - Start PMS"
      [ $HaveStartStop -eq 0 ] && echo "  7 - 'start'     - (Not available. Start manually)"
      echo ""
      echo "  8 - 'import'    - Import watch history from another database independent of Plex. (risky)."
      echo "  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive)."
      echo " 10 - 'show'      - Show logfile."
      echo " 11 - 'status'    - Report status of PMS (run-state and databases)."
      echo " 12 - 'undo'      - Undo last successful command."
      echo ""
      echo " 21 - 'prune'     - Remove old image files from PhotoTranscoder cache & all temp files left by PMS."
      echo " 23 - 'deflate'   - Deflate a bloated PMS main database."
      [ $IgnoreErrors -eq 0 ] && echo " 42 - 'ignore'    - Ignore duplicate/constraint errors."
      [ $IgnoreErrors -eq 1 ] && echo " 42 - 'honor'     - Honor all database errors."
      echo ""
      echo " 88 - 'update'    - Check for updates."
      echo " 98 - 'quit'      - Quit immediately.  Keep all temporary files."
      echo " 99 - 'exit'      - Exit with cleanup options."

    fi

    if [ $Scripted -eq 0 ]; then
      echo ""
      printf "Enter command # -or- command name (4 char min) : "

      # Read next command from user
      read Input

      # Handle EOF/forced exit
      if [ "$Input" = "" ] ; then
        if [ $NullCommands -gt 4 ]; then
          Output "Unexpected EOF / End of command line options. Exiting. Keeping temp files. "
          Input="exit" && Exit=1
        else
          NullCommands=$(($NullCommands + 1))
          [ $NullCommands -eq 4 ] && echo "WARNING: Next empty command exits as EOF.  "
          continue
        fi
      else
        NullCommands=0
      fi
    else

      # Scripted
      Input="$1"

      # If end of line then force exit
      if [ "$Input" = "" ]; then
        Input="exit"
      else
        shift
      fi

    fi

    # Update timestamp
    DoUpdateTimestamp

    # Validate command input
    Command="$(echo $Input | tr '[A-Z]' '[a-z]' | awk '{print $1}')"
    echo " "

    case "$Command" in

      # Stop PMS (if available this host)
      1|stop)

        DoStop
        ;;


      # Automatic of all common operations
      2|auto*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Auto    - FAIL - PMS runnning"
          Output   "Unable to run automatic sequence.  PMS is running. Please stop PlexMediaServer."
          continue
        fi

        # Is there enough room to work
        if ! FreeSpaceAvailable; then
          WriteLog "Auto    - FAIL - Insufficient free space on $AppSuppDir"
          Output   "Error:   Unable to run automatic sequence.  Insufficient free space available on $AppSuppDir"
          Output   "         Space needed = $SpaceNeeded MB,  Space available = $SpaceAvailable MB"
          continue
        fi

        # Start auto
        Output "Automatic Check,Repair,Index started."
        WriteLog "Auto    - START"

        # Check the databases (forced)
        Output ""
        if CheckDatabases "Check  " force ; then
          WriteLog "Check   - PASS"
          CheckedDB=1
        else
          WriteLog "Check   - FAIL"
          CheckedDB=0
          continue
        fi

        # Now Repair
        Output ""
        if ! DoRepair; then

          WriteLog "Repair  - FAIL"
          WriteLog "Auto    - FAIL"
          CheckedDB=0

          Output "Repair failed. Automatic mode cannot continue. Please repair with individual commands"
          continue
        else
          WriteLog "Repair  - PASS"
          CheckedDB=1
        fi

        # Now Index
        DoUpdateTimestamp
        Output ""
        if ! DoIndex; then
          WriteLog "Index   - FAIL"
          WriteLog "Auto    - FAIL"
          CheckedDB=0

          Output "Index failed. Automatic mode cannot continue. Please repair with individual commands"
          continue
        else
          WriteLog "Reindex - PASS"
        fi

        # All good to here
        WriteLog "Auto    - COMPLETED"
        Output   "Automatic Check, Repair/optimize, & Index successful."
        ;;


      # Check databases
      3|chec*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Check   - FAIL - PMS runnning"
          Output   "Unable to check databases.  PMS is running."
          continue
        fi

        # CHECK DBs
        if CheckDatabases "Check  " force ; then
          WriteLog "Check   - PASS"
          CheckedDB=1
        else
          WriteLog "Check   - FAIL"
          CheckedDB=0
        fi
        ;;

      # Vacuum
      4|vacu*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Vacuum - FAIL - PMS runnning"
          Output   "Unable to vacuum databases.  PMS is running."
          continue
        fi

        DoVacuum
        continue
        ;;

      # Repair (Same as optimize but assumes damaged so doesn't check)
      5|repa*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Repair - FAIL - PMS runnning"
          Output   "Unable to repair databases.  PMS is running."
          continue
        fi

        # Is there enough room to work
        if ! FreeSpaceAvailable; then
          WriteLog "Import  - FAIL - Insufficient free space on $AppSuppDir"
          Output   "Error:   Unable to repair database.  Insufficient free space available on $AppSuppDir"
          continue
        fi


        DoRepair
        ;;


      # Index databases
      6|rein*|inde*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Index   - FAIL - PMS runnning"
          Output   "Unable to index databases.  PMS is running."
          continue
        fi

        # Is there enough room to work
        if ! FreeSpaceAvailable; then
          WriteLog "Index   - FAIL - Insufficient free space on $AppSuppDir"
          Output   "Error:   Unable to perform processing.  Insufficient free space available on $AppSuppDir"
          continue
        fi

        # First check the databases
        if CheckDatabases Check; then
          WriteLog "Check   - PASS"
          CheckedDB=1

          # Now index
          if DoIndex ; then
            WriteLog "Reindex - PASS"
          else
            WriteLog "Reindex - FAIL"
          fi
        else
          WriteLog "Check   - FAIL"
          CheckedDB=0
        fi
        ;;


      # Start PMS (if available this host)
      7|star*)

        DoStart
        ;;


      # Menu on/off control
      menu*)

        # Choices are ON,OFF,YES,NO
        Option="$(echo $Input | tr '[A-Z]' '[a-z]' | awk '{print $2}')"

        [ "$Option" = "on"  ] && ShowMenu=1
        [ "$Option" = "yes" ] && ShowMenu=1
        [ "$Option" = "off" ] && ShowMenu=0 && echo Menu off: Reenable with \'menu on\' command
        [ "$Option" = "no"  ] && ShowMenu=0 && echo menu off: Reenable with \'menu on\' command
        ;;


      # Import watch history
      8|impo*)

        DoImport
        ;;


      # Replace (from PMS backup)
      9|repl*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Replace - FAIL - PMS runnning"
          Output   "Unable to replace database from a backup copy.  PMS is running."
          continue
        fi

        # Is there enough room to work
        if ! FreeSpaceAvailable; then
          WriteLog "Replace - FAIL - Insufficient free space on $AppSuppDir"
          Output   "Error:   Unable to replace from backups.  Insufficient free space available on $AppSuppDir"
          continue
        fi

        DoReplace
        ;;


      # Show loggfile
      10|show*)

          echo ==================================================================================
          cat "$LOGFILE"
          echo ==================================================================================
          ;;


      # Current status of Plex and databases
      11|stat*)

        Output ""
        Output "Status report: $(date)"
        if IsRunning ; then
          Output "  PMS is running."
        else
          Output "  PMS is stopped."
        fi

        [ $CheckedDB -eq 0 ] && Output "  Databases are not checked,  Status unknown."
        [ $CheckedDB -eq 1 ] && [ $Damaged -eq 0 ] && Output "  Databases are OK."
        [ $CheckedDB -eq 1 ] && [ $Damaged -eq 1 ] && Output "  Databases were checked and are damaged."
        Output ""
        ;;


      # Undo
      12|undo*)

         DoUndo
         ;;


      # Remove (prune) unused image files from PhotoTranscoder Cache > 30 days old.
      # Also remove all PMS temp files left behind in TMP.  (combine both into one action)
      21|22|prun*|remo*|purg*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Prune   - FAIL - PMS runnning"
          Output   "Unable to prune PhotoTranscoder cache.  PMS is running."
          continue
        fi

        WriteLog "Prune   - START"
        DoPrunePhotoTranscoder
        WriteLog "Prune   - PASS"
        ;;


      # Deflate the DB because Plex isn't doing a good job during scheduled tasks.
      23|defl*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Deflate - FAIL - PMS runnning"
          Output   "Unable to deflate.  PMS is running. Please stop PlexMediaServer."
          continue
        fi

        # Is there enough room to work
        if ! FreeSpaceAvailable; then
          WriteLog "Deflate - FAIL - Insufficient free space on $AppSuppDir"
          Output   "Error:   Unable to deflate.  Insufficient free space available on $AppSuppDir"
          Output   "         Space needed = $SpaceNeeded MB,  Space available = $SpaceAvailable MB"
          continue
        fi

        # Start auto
        Output "Check and Deflate started."
        WriteLog "Deflate - START"

        # Check the databases (forced)
        Output ""
        if CheckDatabases "Check  " force ; then
          WriteLog "Check   - PASS"
          CheckedDB=1
        else
          WriteLog "Check   - FAIL"
          CheckedDB=0
        fi

        # Now Deflate
        Output ""
        if ! DoDeflate; then

          WriteLog "Deflate - FAIL"
          CheckedDB=0

          Output "Deflate failed. Please repair using Automatic mode."
          continue
        else
          WriteLog "Deflate - PASS"
          CheckedDB=1
        fi

        # All good to here
        WriteLog "Deflate - PASS"
        Output   "Deflate successful."
        Output   "Recommend running "Auto" next to complete optimization of new database."
        ;;


      # Records count
      30|coun*)

        Temp="$DBDIR/DBRepair.tab1"
        Temp2="$DBDIR/DBRepair.tab2"

        # Ensure clean
        rm -f "$Temp" "$Temp2"

        # Get list of tables
        Tables="$("$PLEX_SQLITE" "$DBDIR/com.plexapp.plugins.library.db" .tables | sed 's/ /\n/g')"

        # Separate and sort tables
        for i in $Tables
        do
          echo $i >> "$Temp"
        done
        sort < "$Temp" > "$Temp2"

        Tables="$(cat "$Temp2")"

        # Get counts
        for Table in $Tables
        do
          Records=$("$PLEX_SQLITE" "$DBDIR/com.plexapp.plugins.library.db" "select count(*) from $Table;")
          printf "%36s %-15d\n" $Table $Records
        done
      ;;

      # Ignore/Honor errors
      42|igno*|hono*)

        IgnoreErrors=$((IgnoreErrors ^ 1))
        [ $IgnoreErrors -eq 0 ] && Output "Honoring database errors." && WriteLog "Honoring database errors."
        [ $IgnoreErrors -eq 1 ] && Output "Ignoring database errors." && WriteLog "Ignoring database errors."
        ;;

      88|upda*)

        # Don't update again after restarting after updating
        if [ $DBRepairRestartedAfterUpdate -eq 1 ]; then
          Output "Already updated.  Continuing."
          WriteLog "Update - Ignore Update request after updating."
          continue
        fi

        DoUpdate=0
        Output "Checking for update"
        GetLatestRelease
        if [ $(VersionDigits $LatestVersion) -gt $(VersionDigits $Version) ]; then
          if [ $Scripted -eq 1 ]; then
            DoUpdate=1
          elif ConfirmYesNo "Download $LatestVersion and update?"; then
            DoUpdate=1
          fi
        else
          Output "No update available."
        fi

        # Check if script path is writable
        if [ $DoUpdate -eq 1 ]; then
          if [ -w "$ScriptWorkingDirectory" ]; then
            Output "Updating from $Version to $LatestVersion"
            DownloadAndUpdate "https://raw.githubusercontent.com/ChuckPa/DBRepair/master/DBRepair.sh" "$ScriptWorkingDirectory/$ScriptName"
            Result=$?
            if [ $Result -eq 0 ]; then
              chmod +x "$ScriptWorkingDirectory/$ScriptName"
              if [ $Scripted -eq 0 ] && ConfirmYesNo "Restart and use $LatestVersion ?" ; then
                WriteLog "Restarting after upgrade"
                Output   "Restarting"
                export DBRepairRestartedAfterUpdate=1
                exec "$ScriptWorkingDirectory/$ScriptName" "$*"
              else
                Output "Restart to launch updated DBRepair.sh ($LatestVersion)"
                WriteLog "Update   - Updated to version $LatestVersion."
              fi
              exit 0
            else
              Output "Unable to download and update.  Error $Result."
            fi
          else
            Output "Script path '${ScriptName}' is not writable."
          fi
        fi

        [ $Scripted -eq 1 ] && [ $DoUpdate -eq 1 ] && exit 0
      ;;

      # Quit
      98|quit)

        Output "Retaining all temporary work files."
        WriteLog "Exit    - Retain temp files."
        exit 0
        ;;

      # Orderly Exit
      99|exit)

        # If forced exit set,  exit and retain
        if [ $Exit -eq 1 ]; then
          Output "Unexpected exit command.  Keeping all temporary work files."
          WriteLog "EOFExit  - Retain temp files."
          exit 1
        fi

        # If cmd line mode, exit clean without asking
        if [ $Scripted -eq 1 ]; then
          rm -rf $TMPDIR
          WriteLog "Exit    - Delete temp files."

        else
          # Ask questions on interactive exit
          if ConfirmYesNo "Ok to remove temporary databases/workfiles for this session?" ; then
            # There it goes
            Output "Deleting all temporary work files."
            WriteLog "Exit    - Delete temp files."
            rm -rf "$TMPDIR"
          else
            Output "Retaining all temporary work files."
            WriteLog "Exit    - Retain temp files."
          fi
        fi

        WriteLog "Session end. $(date)"
        WriteLog "============================================================"
        exit 0
        ;;

      # Unknown command
      *)
        WriteLog "Unknown command:  '$Input'"
        Output   "ERROR: Unknown command: '$Input'"
        ;;

    esac
  done
done
exit 0