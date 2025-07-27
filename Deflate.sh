#!/bin/bash
#########################################################################
# Database Deflate Utility for Plex Media Server.                       #
# Maintainer: ChuckPa                                                   #
# Version:    v1.00.00                                                  #
# Date:       26-Jul-2025                                               #
#########################################################################

# Version for display purposes
Version="v1.00.00"

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
[ "$DBDeflateRestartedAfterUpdate" = "" ] && DBDeflateRestartedAfterUpdate=0

# Universal output function
Output() {
  if [ $Scripted -gt 0 ]; then
    echo \[$(date "+%Y-%m-%d %H.%M.%S")\] "$@"
  else
    echo "$@"
  fi
  # $LOG_TOOL \[$(date "+%Y-%m-%d %H.%M.%S")\] "$@"
}

# Write to Deflate Tool log
WriteLog() {

  # Write given message into tool log file with TimeStamp
  echo "$(date "+%Y-%m-%d %H.%M.%S") - $*" >> "$LOGFILE"
  return 0
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
      LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"

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
      LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
      LOGFILE="$DBDIR/DBDeflate.log"
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
    LOGFILE="$DBDIR/DBDeflate.log"
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
      CACHEDIR="$AppSuppDir/Plex Media Server/Cache/PhotoTranscoder"
      LOGFILE="$DBDIR/DBDeflate.log"
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

      LOGFILE="$DBDIR/DBDeflate.log"
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
      LOGFILE="$DBDIR/DBDeflate.log"
      LOG_TOOL="logger"

      if grep rpcinterface /etc/supervisor.conf > /dev/null; then
        HaveStartStop=1
        StartCommand="supervisorctl start plexmediaserver"
        StopCommand="supervisorctl stop plexmediaserver"
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
      LOGFILE="$DBDIR/DBDeflate.log"
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

##### DoDeflate
DoDeflate() {

  Damaged=0
  Fail=0

  DoUpdateTimestamp

  # Verify DBs are here
  if [ ! -e $CPPL.db ]; then
    Output "No main Plex database exists to Deflate. Exiting."
    WriteLog "Deflate  - No main database - FAIL"
    Fail=1
    return 1
  fi

  # Check size
  Size=$(stat $STATFMT $STATBYTES $CPPL.db)

  # Exit if not valid
  if [ $Size -lt 300000 ]; then
    Output "Main database is too small/truncated, Deflate is not possible.  Please try restoring a backup. "
    WriteLog "Deflate  - Main databse too small - FAIL"
    Fail=1
    return 1
  fi

  # Continue
  Output "Starting Deflate."

  Output "Creating new table"
  "$PLEX_SQLITE" $CPPL.db 'CREATE TABLE temp_bandwidth as select * from statistics_bandwidth where account_id not null;'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite creating "
      Output "Could not create temporary working table"
      WriteLog "Deflate  - Cannot create temporary working table - FAIL ($Result)"
      Fail=1
      return 1
    fi

  Output "Deleting old bloated table.   (This might take time)"
  "$PLEX_SQLITE" $CPPL.db "DROP TABLE statistics_bandwidth;"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite while deleting bloated table."
      WriteLog "Deflate  - Cannot drop old table - FAIL ($Result)"
      Fail=1
      return 1
    fi

  Output "Renaming tables"
  "$PLEX_SQLITE" $CPPL.db 'ALTER TABLE temp_bandwidth RENAME to statistics_bandwidth;'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite while renaming temporary table"
      WriteLog "Deflate  - Cannot rename new table - FAIL ($Result)"
      Fail=1
      return 1
    fi

  Output "Creating indexes"
  "$PLEX_SQLITE" $CPPL.db "CREATE INDEX 'index_statistics_bandwidth_on_at' ON statistics_bandwidth ('at');"
      Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite creating first new INDEX."
      WriteLog "Deflate  - Cannot create first index - FAIL ($Result)"
      Fail=1
      return 1
    fi

  "$PLEX_SQLITE" $CPPL.db 'CREATE INDEX index_statistics_bandwidth_on_account_id_and_timespan_and_at ON statistics_bandwidth (account_id, timespan, at);'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot dump file
      Output "Error $Result from Plex SQLite while creating second new INDEX"
      WriteLog "Deflate  - Cannot create second index - FAIL ($Result)"
      Fail=1
      return 1
    fi

  Output "Vacuuming into new smaller DB using timestamp $TimeStamp (this will take time with no intermedia output)."
  "$PLEX_SQLITE" $CPPL.db "vacuum main into '$TMPDIR/$CPPL.db-Deflate-$TimeStamp';"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then

      # Cannot deflate
      Output "Error $Result from Plex SQLite creating new main DB."
      Output "Could not successfully export the main database to Deflate it.  Please try restoring a backup."
      WriteLog "Deflate  - Cannot reduce main database into '$TMPDIR/$CPPL.db-Deflate-$TimeStamp' - FAIL ($Result)"
      Fail=1
      return 1
    fi

    # Made it to here, now verify
    Output "Successfully deflated databases."
    WriteLog "Deflate  - PASS"

    # Verify databases are intact and pass testing
    Output "Verifying databases integrity after importing."

    # Check main DB
    if CheckDB "$TMPDIR/$CPPL.db-Deflate-$TimeStamp" ; then
      SizeStart=$(GetSize "$CPPL.db")
      SizeFinish=$(GetSize "$TMPDIR/$CPPL.db-Deflate-$TimeStamp")
      Output "Verification complete.  PMS main database is OK."
      Output " "
      Output "Original size = ${SizeStart} MB"
      Output "Deflated size = ${SizeFinish} MB"
      WriteLog "Deflate  - Verify main database - PASS (Size: ${SizeStart}MB / ${SizeFinish}MB)."
    else
      Output "Verification complete.  PMS main database deflate failed."
      WriteLog "Deflate  - Verify main database - FAIL ($SQLerror)"
      Fail=1
    fi

    # If not failed,  move files normally
    if [ $Fail -eq 0 ]; then

      Output "Saving current database with '-BACKUP-$TimeStamp'"
      [ -e $CPPL.db ] && mv $CPPL.db "$TMPDIR/$CPPL.db-BACKUP-$TimeStamp"

      Output " "
      Output "Making Deflated databases active"
      WriteLog "Deflate  - Making Deflateed databases active"
      mv "$TMPDIR/$CPPL.db-Deflate-$TimeStamp" $CPPL.db

      Output "Deflate complete."

      # Ensure WAL and SHM are gone
      [ -e $CPPL.blobs.db-wal ] && rm -f $CPPL.blobs.db-wal
      [ -e $CPPL.blobs.db-shm ] && rm -f $CPPL.blobs.db-shm
      [ -e $CPPL.db-wal ]       && rm -f $CPPL.db-wal
      [ -e $CPPL.db-shm ]       && rm -f $CPPL.db-shm

      # Set ownership on new files
      chmod $Perms $CPPL.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR:  Cannot set permissions on new database. Error $Result"
        Output "        Please exit tool, keeping temp files, seek assistance."
        Output "        Use files: $TMPDIR/*-BACKUP-$TimeStamp"
        WriteLog "Deflate  - Move files - FAIL"
        Fail=1
        return 1
      fi

      chown $Owner $CPPL.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR:  Cannot set ownership on new databases. Error $Result"
        Output "        Please exit tool, keeping temp files, seek assistance."
        Output "        Use files: $TMPDIR/*-BACKUP-$TimeStamp"
        WriteLog "Deflate  - Move files - FAIL"
        Fail=1
        return 1
      fi

      # We didn't fail, set CheckedDB status true (passed above checks)
      CheckedDB=1

      WriteLog "Deflate  - Move files - PASS"
      WriteLog "Deflate  - PASS"

      SetLast "Deflate" "$TimeStamp"
      return 0
    else

      rm -f "$TMPDIR/$CPPL.db-Deflate-$TimeStamp"

      Output "Deflate has failed.  No files changed"
      WriteLog "Deflate - $TimeStamp - FAIL"
      CheckedDB=0
      return 1
    fi
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
     Output "Stopping PMS."
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
      sleep 3
      Count=$((Count - 1))
    done

    if  ! IsRunning; then
      WriteLog "Stop    - PASS"
      Output "Stopped PMS."
      return 0
    else
      WriteLog "Stop    - FAIL (Timeout)"
      Output   "Could not stop PMS. PMS did not shutdown within 30 second limit."
    fi
  fi
  return $Result
}

# Mac Helper Functions
startMacPMS() { TMPDIR=/tmp osascript -e 'tell app "Plex Media Server" to launch'; sleep 2; IsRunning && sayStarted; }
stopMacPMS() { osascript -e 'tell app "Plex Media Server" to quit'; sleep 2; IsRunning || sayStopped; }
sayStarted() { [ $HapticOkay -eq 1 ] && osascript -e 'say "started"'; }
sayStopped() { [ $HapticOkay -eq 1 ] && osascript -e 'say "Its stopped"'; }


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

# UpdateTimestamp
DoUpdateTimestamp() {
  TimeStamp="$(date "+%Y-%m-%d_%H.%M.%S")"
}


#############################################################
#         Main utility begins here                          #
#############################################################


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
      LOGFILE="$DBDIR/DBDeflate.log"
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
  echo "      Database Deflate Utility for Plex Media Server  ($HostType)"
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
      echo "  2 - 'automatic' - Check and Deflate in one step."
      echo "  3 - 'check'     - Perform integrity check of database."
      echo "  4 - 'deflate'   - Remove bloated records from main database."

      [ $HaveStartStop -gt 0 ] && echo "  5 - 'start'     - Start PMS"
      [ $HaveStartStop -eq 0 ] && echo "  5 - 'start'     - (Not available. Start manually)"

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
        Output "Automatic Check and Deflate started."
        WriteLog "Auto    - START"

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

          WriteLog "Deflate  - FAIL"
          WriteLog "Auto    - FAIL"
          CheckedDB=0

          Output "Deflate failed. Automatic mode cannot continue. Please seek help in forums."
          continue
        else
          WriteLog "Deflate  - PASS"
          CheckedDB=1
        fi

        # All good to here
        WriteLog "Auto    - COMPLETED"
        Output   "Automatic Check and Deflate successful."
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
        if CheckDatabases "Check" force ; then
          WriteLog "Check   - PASS"
          CheckedDB=1
        else
          WriteLog "Check   - FAIL"
          CheckedDB=0
        fi
        ;;

      # Deflate (Same as optimize but assumes damaged so doesn't check)
      4|defl*)

        # Check if PMS running
        if IsRunning; then
          WriteLog "Deflate - FAIL - PMS runnning"
          Output   "Unable to Deflate databases.  PMS is running."
          continue
        fi

        # Is there enough room to work
        if ! FreeSpaceAvailable; then
          WriteLog "Import  - FAIL - Insufficient free space on $AppSuppDir"
          Output   "Error:   Unable to Deflate database.  Insufficient free space available on $AppSuppDir"
          continue
        fi

        DoDeflate
        ;;

      # Start PMS (if available this host)
      5|star*)

        DoStart
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

      # Records count
      30|coun*)

        Temp="$DBDIR/DBDeflate.tab1"
        Temp2="$DBDIR/DBDeflate.tab2"

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
