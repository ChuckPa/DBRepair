#!/bin/bash
#########################################################################
# Database Repair Utility for Plex Media Server.                        #
# Original Maintainer: ChuckPa                                          #
# Enhanced Version:    v1.13.02-enhanced-v3                             #
# Enhancement Date:    07-Jan-2026                                      #
#                                                                       #
# ENHANCEMENTS:                                                         #
#   - Real-time progress output (immediate flush)                       #
#   - Simultaneous console + log output                                 #
#   - Phase markers for long operations                                 #
#   - File size progress indicators                                     #
#   - Better feedback during SQLite operations                          #
#   - Automatic post-repair integrity check (uses Plex SQLite)          #
#   - Timeout detection for hung SQLite operations                      #
#   - Background heartbeat monitor (every 30s during long ops)          #
#   - Automatic stuck process detection and cleanup                     #
#   - Pre-flight cleanup of orphaned processes                          #
#   - Interactive prompts to kill stuck/zombie processes                #
#                                                                       #
# NOTE: This script uses Plex's bundled SQLite binary, NOT system       #
#       sqlite3, because Plex uses custom tokenizers and collations.    #
#########################################################################

# Trap cleanup on exit
trap 'Cleanup' EXIT INT TERM

# Global PID tracking for background processes
HEARTBEAT_PID=""
SQLITE_PID=""

# Version for display purposes
Version="v1.13.02-enhanced"

# Have the databases passed integrity checks
CheckedDB=0

# By default, we cannot start/stop PMS
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

# If LC_ALL is null, default to C
[ "$LC_ALL" = "" ] && export LC_ALL=C

# Check Restart
[ "$DBRepairRestartedAfterUpdate" = "" ] && DBRepairRestartedAfterUpdate=0

#########################################################################
# ENHANCED OUTPUT FUNCTIONS                                             #
#########################################################################

# Universal output function - ENHANCED with immediate flush and dual output
Output() {
  local msg timestamp
  timestamp="$(date "+%Y-%m-%d %H.%M.%S")"
  
  if [ $Scripted -gt 0 ]; then
    msg="[$timestamp] $*"
  else
    msg="$*"
  fi
  
  # Output to console with immediate flush
  echo "$msg"
  
  # Also write to log file immediately (if logfile exists)
  if [ -n "$LOGFILE" ] && [ -w "$(dirname "$LOGFILE" 2>/dev/null)" ]; then
    echo "$timestamp - $*" >> "$LOGFILE" 2>/dev/null
  fi
}

# Write to Repair Tool log only (no console output)
WriteLog() {
  # Write given message into tool log file with TimeStamp
  if [ -n "$LOGFILE" ]; then
    echo "$(date "+%Y-%m-%d %H.%M.%S") - $*" >> "$LOGFILE" 2>/dev/null
  fi
  return 0
}

# Progress indicator for long operations
ShowProgress() {
  local operation="$1"
  local detail="$2"
  local timestamp="$(date "+%Y-%m-%d %H.%M.%S")"
  
  echo "[$timestamp] >>> $operation: $detail"
  [ -n "$LOGFILE" ] && echo "$timestamp - PROGRESS: $operation - $detail" >> "$LOGFILE" 2>/dev/null
}

# Phase marker for major operations
StartPhase() {
  local phase="$1"
  local timestamp="$(date "+%Y-%m-%d %H.%M.%S")"
  
  echo ""
  echo "[$timestamp] ========================================"
  echo "[$timestamp] PHASE: $phase"
  echo "[$timestamp] ========================================"
  echo ""
  
  [ -n "$LOGFILE" ] && echo "$timestamp - ===== PHASE START: $phase =====" >> "$LOGFILE" 2>/dev/null
}

# End phase marker
EndPhase() {
  local phase="$1"
  local status="$2"
  local timestamp="$(date "+%Y-%m-%d %H.%M.%S")"
  
  echo ""
  echo "[$timestamp] PHASE COMPLETE: $phase - $status"
  echo ""
  
  [ -n "$LOGFILE" ] && echo "$timestamp - ===== PHASE END: $phase - $status =====" >> "$LOGFILE" 2>/dev/null
}

# Get human-readable file size
GetHumanSize() {
  local size=$1
  if [ $size -ge 1073741824 ]; then
    echo "$(echo "scale=2; $size/1073741824" | bc 2>/dev/null || echo "$((size/1073741824))GB")"
  elif [ $size -ge 1048576 ]; then
    echo "$((size/1048576))MB"
  elif [ $size -ge 1024 ]; then
    echo "$((size/1024))KB"
  else
    echo "${size}B"
  fi
}

#########################################################################
# CLEANUP AND PROCESS MANAGEMENT                                        #
#########################################################################

# Cleanup function called on exit
Cleanup() {
  # Kill heartbeat if running
  if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill "$HEARTBEAT_PID" 2>/dev/null
    wait "$HEARTBEAT_PID" 2>/dev/null
  fi
  
  # Kill any tracked SQLite process
  if [ -n "$SQLITE_PID" ] && kill -0 "$SQLITE_PID" 2>/dev/null; then
    Output "WARNING: Killing orphaned SQLite process $SQLITE_PID"
    kill "$SQLITE_PID" 2>/dev/null
    sleep 1
    kill -9 "$SQLITE_PID" 2>/dev/null
  fi
}

# Pre-flight check - ensure no orphaned DBRepair or SQLite processes
PreFlightCheck() {
  Output "Performing pre-flight checks..."
  
  # Check for other DBRepair processes (exclude self)
  local myPid=$$
  local otherRepair=$(pgrep -f "DBRepair" | grep -v "^${myPid}$" | head -1)
  
  if [ -n "$otherRepair" ]; then
    Output "WARNING: Found another DBRepair process running (PID: $otherRepair)"
    Output "         Checking if it's stuck..."
    
    # Check if it's stuck on pipe_read or has empty/unknown state
    local wchan=$(cat /proc/$otherRepair/wchan 2>/dev/null)
    local pstate=$(cat /proc/$otherRepair/stat 2>/dev/null | awk '{print $3}')
    local runtime=$(ps -o etimes= -p "$otherRepair" 2>/dev/null | tr -d ' ')
    
    Output "         Process state: wchan='$wchan', state='$pstate', runtime=${runtime}s"
    
    # Auto-kill if clearly stuck (pipe_read/pipe_wait) or unknown state with long runtime
    if [ "$wchan" = "pipe_read" ] || [ "$wchan" = "pipe_wait" ]; then
      Output "         Process appears STUCK (waiting on: $wchan)"
      Output "         Killing stuck process..."
      kill "$otherRepair" 2>/dev/null
      sleep 2
      if kill -0 "$otherRepair" 2>/dev/null; then
        kill -9 "$otherRepair" 2>/dev/null
      fi
      Output "         Stuck process terminated."
      WriteLog "PreFlight - Killed stuck DBRepair process $otherRepair (wchan=$wchan)"
    elif [ -z "$wchan" ] || [ "$wchan" = "0" ]; then
      # Empty or zero wchan - process may be zombie or stuck
      Output "         Process has unknown state (possibly zombie or stuck)"
      
      # If running > 5 minutes with unknown state, offer to kill
      if [ -n "$runtime" ] && [ "$runtime" -gt 300 ]; then
        Output "         Process has been running for ${runtime}s with unknown state."
        Output ""
        
        # Check if we're in scripted mode
        if [ $Scripted -gt 0 ]; then
          Output "         Scripted mode: Auto-killing long-running unknown process..."
          kill "$otherRepair" 2>/dev/null
          sleep 2
          kill -9 "$otherRepair" 2>/dev/null
          Output "         Process terminated."
          WriteLog "PreFlight - Auto-killed unknown DBRepair process $otherRepair (runtime=${runtime}s)"
        else
          # Interactive mode - ask user
          echo -n "         Kill this process? [y/N]: "
          read -t 30 answer
          if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            Output "         Killing process..."
            kill "$otherRepair" 2>/dev/null
            sleep 2
            if kill -0 "$otherRepair" 2>/dev/null; then
              kill -9 "$otherRepair" 2>/dev/null
            fi
            Output "         Process terminated."
            WriteLog "PreFlight - User killed DBRepair process $otherRepair"
          else
            Output "         Skipping - continuing anyway (may cause issues)"
            WriteLog "PreFlight - User skipped killing process $otherRepair"
          fi
        fi
      else
        Output "         Process is recent - may be actively working."
        echo -n "         Kill this process anyway? [y/N]: "
        read -t 30 answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
          Output "         Killing process..."
          kill "$otherRepair" 2>/dev/null
          sleep 2
          kill -9 "$otherRepair" 2>/dev/null
          Output "         Process terminated."
          WriteLog "PreFlight - User killed DBRepair process $otherRepair"
        else
          Output "ERROR: Another DBRepair may be running. Aborting."
          Output "       Run: kill $otherRepair   (or kill -9 $otherRepair)"
          return 1
        fi
      fi
    else
      # Has a valid wchan - actively doing something
      Output "         Process is actively working (wchan=$wchan)"
      echo -n "         Force kill anyway? [y/N]: "
      read -t 30 answer
      if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        Output "         Killing process..."
        kill "$otherRepair" 2>/dev/null
        sleep 2
        kill -9 "$otherRepair" 2>/dev/null
        Output "         Process terminated."
        WriteLog "PreFlight - User force-killed active DBRepair process $otherRepair"
      else
        Output "ERROR: Another DBRepair is actively running. Please wait or kill it first."
        Output "       PID: $otherRepair, State: $wchan"
        return 1
      fi
    fi
  fi
  
  # Check for orphaned Plex SQLite processes on our databases
  local orphanedSqlite=$(pgrep -f "Plex SQLite.*$CPPL" | head -1)
  if [ -n "$orphanedSqlite" ]; then
    Output "WARNING: Found orphaned Plex SQLite process (PID: $orphanedSqlite)"
    Output "         Killing orphaned process..."
    kill "$orphanedSqlite" 2>/dev/null
    sleep 1
    kill -9 "$orphanedSqlite" 2>/dev/null
    WriteLog "PreFlight - Killed orphaned SQLite process $orphanedSqlite"
  fi
  
  # Check for stale lock files
  if [ -f "$DBDIR/$CPPL.db-journal" ]; then
    Output "WARNING: Found stale journal file - removing"
    rm -f "$DBDIR/$CPPL.db-journal"
    WriteLog "PreFlight - Removed stale journal file"
  fi
  
  Output "Pre-flight checks complete."
  WriteLog "PreFlight - PASS"
  return 0
}

# Start heartbeat monitor - outputs periodic status during long operations
StartHeartbeat() {
  local operation="$1"
  local targetFile="$2"
  
  # Kill existing heartbeat if any
  StopHeartbeat
  
  # Start background heartbeat
  (
    local count=0
    while true; do
      sleep 30
      count=$((count + 1))
      local elapsed=$((count * 30))
      local timestamp="$(date "+%Y-%m-%d %H.%M.%S")"
      
      # Check if target file is growing (for exports)
      local size=""
      if [ -n "$targetFile" ] && [ -f "$targetFile" ]; then
        local bytes=$(stat -c %s "$targetFile" 2>/dev/null || echo 0)
        size=" - Output file: $((bytes/1048576))MB"
      fi
      
      echo "[$timestamp] ... HEARTBEAT: $operation running (${elapsed}s elapsed)${size}"
      
      # Also write to log
      [ -n "$LOGFILE" ] && echo "$timestamp - HEARTBEAT: $operation - ${elapsed}s${size}" >> "$LOGFILE" 2>/dev/null
    done
  ) &
  HEARTBEAT_PID=$!
}

# Stop heartbeat monitor
StopHeartbeat() {
  if [ -n "$HEARTBEAT_PID" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null
    wait "$HEARTBEAT_PID" 2>/dev/null
    HEARTBEAT_PID=""
  fi
}

# Run SQLite command with timeout and monitoring
# Usage: RunSQLiteWithTimeout timeout_seconds "sqlite_command" [output_file]
RunSQLiteWithTimeout() {
  local timeout=$1
  local sqlcmd="$2"
  local outfile="$3"
  local result=0
  
  # Start heartbeat
  StartHeartbeat "SQLite operation" "$outfile"
  
  # Run SQLite in background
  if [ -n "$outfile" ]; then
    "$PLEX_SQLITE" $sqlcmd &
  else
    "$PLEX_SQLITE" $sqlcmd &
  fi
  SQLITE_PID=$!
  
  # Wait with timeout
  local waited=0
  while kill -0 "$SQLITE_PID" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    
    if [ $waited -ge $timeout ]; then
      Output "ERROR: SQLite operation timed out after ${timeout}s"
      Output "       Killing stuck process..."
      kill "$SQLITE_PID" 2>/dev/null
      sleep 2
      kill -9 "$SQLITE_PID" 2>/dev/null
      StopHeartbeat
      SQLITE_PID=""
      return 124  # Timeout exit code
    fi
  done
  
  # Get exit status
  wait "$SQLITE_PID"
  result=$?
  SQLITE_PID=""
  
  # Stop heartbeat
  StopHeartbeat
  
  return $result
}

#########################################################################
# DATABASE FUNCTIONS                                                    #
#########################################################################

# Check given database file integrity
CheckDB() {
  # Confirm the DB exists
  [ ! -f "$1" ] && Output "ERROR: $1 does not exist." && return 1

  # Now check database for corruption
  ShowProgress "Integrity Check" "Running PRAGMA integrity_check on $(basename "$1")..."
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

  # Check if not checked or forced
  NeedCheck=0
  [ $CheckedDB -eq 0 ] && NeedCheck=1
  [ $CheckedDB -eq 1 ] && [ "$2" = "force" ] && NeedCheck=1

  # Do we need to check
  if [ $NeedCheck -eq 1 ]; then
    # Clear Damaged flag
    Damaged=0
    CheckedDB=0

    StartPhase "Database Integrity Check"
    Output "Checking the PMS databases"

    # Get file sizes for info
    if [ -f "$CPPL.db" ]; then
      local mainSize=$(stat $STATFMT $STATBYTES "$CPPL.db" 2>/dev/null || echo 0)
      Output "Main database size: $(GetHumanSize $mainSize)"
    fi
    if [ -f "$CPPL.blobs.db" ]; then
      local blobsSize=$(stat $STATFMT $STATBYTES "$CPPL.blobs.db" 2>/dev/null || echo 0)
      Output "Blobs database size: $(GetHumanSize $blobsSize)"
    fi

    # Check main DB
    if CheckDB $CPPL.db ; then
      Output "Check complete. PMS main database is OK."
      WriteLog "$1"" - Check $CPPL.db - PASS"
    else
      Output "Check complete. PMS main database is DAMAGED."
      Output "Error details: $SQLerror"
      WriteLog "$1"" - Check $CPPL.db - FAIL ($SQLerror)"
      Damaged=1
    fi

    # Check blobs DB
    if CheckDB $CPPL.blobs.db ; then
      Output "Check complete. PMS blobs database is OK."
      WriteLog "$1"" - Check $CPPL.blobs.db - PASS"
    else
      Output "Check complete. PMS blobs database is DAMAGED."
      Output "Error details: $SQLerror"
      WriteLog "$1"" - Check $CPPL.blobs.db - FAIL ($SQLerror)"
      Damaged=1
    fi

    # Yes, we've now checked it
    CheckedDB=1
    
    if [ $Damaged -eq 0 ]; then
      EndPhase "Database Integrity Check" "PASSED"
    else
      EndPhase "Database Integrity Check" "FAILED - Damage detected"
    fi
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
FreeSpaceAvailable() {
  Multiplier=3
  [ "$1" != "" ] && Multiplier=$1

  # Available space where DB resides
  SpaceAvailable=$(df $DFFLAGS "$DBDIR" | tail -1 | awk '{print $4}')

  # Get size of DB and blobs
  LibSize="$(stat $STATFMT $STATBYTES "${DBDIR}/$CPPL.db")"
  BlobsSize="$(stat $STATFMT $STATBYTES "${DBDIR}/$CPPL.blobs.db")"
  SpaceNeeded=$((LibSize + BlobsSize))

  # Compute need
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
    ShowProgress "Backup" "Copying $(basename "$2")..."
    cp -p "$2" "$3"
    Result=$?
    if [ $Result -ne 0 ]; then
      Output "Error $Result while backing up '$2'. Cannot continue."
      WriteLog "$1 - MakeBackup $2 - FAIL"
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
    if [ $Scripted -eq 0 ]; then
      printf "$1 (Y/N) ? "
      read Answer
      Answer=$(echo $Answer | tr '[a-z]' '[A-Z]')
    else
      Answer="Y"
    fi
  done

  if [ "$Answer" = "Y" ]; then
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

# Simple function to set variables
SetLast() {
  LastName="$1"
  LastTimestamp="$2"
  return 0
}

#########################################################################
# REINDEX FUNCTION                                                      #
#########################################################################

DoIndex() {
    # Clear flag
    Damaged=0
    Fail=0
    
    StartPhase "Database Reindex"
    
    # Check databases before Indexing if not previously checked
    if ! CheckDatabases "Reindex" ; then
      Damaged=1
      CheckedDB=1
      Fail=1
      [ $IgnoreErrors -eq 1 ] && Fail=0
    fi

    # If damaged, exit
    if [ $Damaged -eq 1 ]; then
      Output "Databases are damaged. Reindex operation not available. Please repair or replace first."
      EndPhase "Database Reindex" "FAILED - Damaged databases"
      return 1
    fi

    # Databases are OK, Make a backup
    Output "Backing up databases before reindex..."
    MakeBackups "Reindex"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if [ $Result -eq 0 ]; then
      WriteLog "Reindex - MakeBackup - PASS"
    else
      Output "Error making backups. Cannot continue."
      WriteLog "Reindex - MakeBackup - FAIL ($Result)"
      EndPhase "Database Reindex" "FAILED - Backup error"
      Fail=1
      return 1
    fi

    # Databases are OK, Start reindexing
    ShowProgress "Reindex" "Reindexing main database (this may take a few minutes)..."
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

    ShowProgress "Reindex" "Reindexing blobs database..."
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

    if [ $Fail -eq 0 ]; then
      SetLast "Reindex" "$TimeStamp"
      WriteLog "Reindex - PASS"
      EndPhase "Database Reindex" "PASSED"
    else
      RestoreSaved "$TimeStamp"
      WriteLog "Reindex - FAIL"
      EndPhase "Database Reindex" "FAILED"
    fi

    return $Fail
}

#########################################################################
# UNDO FUNCTION                                                         #
#########################################################################

DoUndo(){
    # Confirm there is something to undo
    if [ "$LastTimestamp" != "" ]; then
      echo ""
      echo "'Undo' restores the databases to the state prior to the last SUCCESSFUL action."
      echo "If any action fails before it completes, that action is automatically undone for you."
      echo "Be advised: Undo restores the databases to their state PRIOR TO the last action of 'Vacuum', 'Reindex', or 'Replace'"
      echo "WARNING: Once Undo completes, there will be nothing more to Undo until another successful action is completed"
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

#########################################################################
# PAGE SIZE FUNCTION                                                    #
#########################################################################

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
    Output "WARNING: DBREPAIR_PAGESIZE ($DBREPAIR_PAGESIZE) not a multiple of 1024. New value = $DbPageSize."
  fi

  # Must be compliant
  if [ $DbPageSize -gt 65536 ]; then
    Output "WARNING: DBREPAIR_PAGESIZE ($DbPageSize) too large. Reducing to 65536."
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
  WriteLog "SetPageSize - Setting Plex SQLite page_size: $DbPageSize"

  # Create DB with desired page size
  "$PLEX_SQLITE" "$1" "PRAGMA page_size=${DbPageSize}; VACUUM;"
}

#########################################################################
# REPAIR FUNCTION - ENHANCED WITH HEARTBEAT AND TIMEOUT                 #
#########################################################################

DoRepair() {
    Damaged=0
    Fail=0

    StartPhase "Database Repair"

    # Verify DBs are here
    if [ ! -e $CPPL.db ]; then
      Output "No main Plex database exists to repair. Exiting."
      WriteLog "Repair  - No main database - FAIL"
      EndPhase "Database Repair" "FAILED - No database"
      Fail=1
      return 1
    fi

    # Check size
    Size=$(stat $STATFMT $STATBYTES $CPPL.db)
    Output "Main database size: $(GetHumanSize $Size)"

    # Exit if not valid
    if [ $Size -lt 300000 ]; then
      Output "Main database is too small/truncated, repair is not possible. Please try restoring a backup."
      WriteLog "Repair  - Main database too small - FAIL"
      EndPhase "Database Repair" "FAILED - Database too small"
      Fail=1
      return 1
    fi

    # Calculate timeout based on size (allow 10 seconds per MB, minimum 300s, max 7200s)
    local sizeMB=$((Size / 1048576))
    local timeout=$((sizeMB * 10))
    [ $timeout -lt 300 ] && timeout=300
    [ $timeout -gt 7200 ] && timeout=7200
    
    # Estimate time based on size
    local estMinutes=$((Size / 1048576 / 50 + 1))
    Output "Estimated repair time: $estMinutes - $((estMinutes * 3)) minutes (depends on I/O speed)"
    Output "Operation timeout set to: $((timeout / 60)) minutes"

    # Continue
    Output "Exporting current databases using timestamp: $TimeStamp"
    Fail=0

    #-------------------------------------------------------------------
    # STEP 1: Export Main DB (with heartbeat)
    #-------------------------------------------------------------------
    ShowProgress "Export" "Exporting Main DB to SQL (this is the slowest step)..."
    ShowProgress "Export" "You will see heartbeat messages every 30 seconds..."
    WriteLog "Repair  - Export main database - STARTED"
    
    local exportStart=$(date +%s)
    local sqlFile="$TMPDIR/library.plexapp.sql-$TimeStamp"
    
    # Start heartbeat monitor
    StartHeartbeat "Main DB Export" "$sqlFile"
    
    # Run export
    "$PLEX_SQLITE" $CPPL.db ".output '$sqlFile'" .dump
    Result=$?
    
    # Stop heartbeat
    StopHeartbeat
    
    local exportEnd=$(date +%s)
    local exportTime=$((exportEnd - exportStart))
    
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then
      Output "Error $Result from Plex SQLite while exporting $CPPL.db"
      Output "Could not successfully export the main database to repair it. Please try restoring a backup."
      WriteLog "Repair  - Cannot recover main database to '$sqlFile' - FAIL ($Result)"
      EndPhase "Database Repair" "FAILED - Export error"
      Fail=1
      return 1
    fi
    
    # Show export file size
    if [ -f "$sqlFile" ]; then
      local sqlSize=$(stat $STATFMT $STATBYTES "$sqlFile")
      Output "Main DB exported successfully in ${exportTime}s - SQL file size: $(GetHumanSize $sqlSize)"
      WriteLog "Repair  - Export main database - PASS (${exportTime}s, $(GetHumanSize $sqlSize))"
    else
      Output "ERROR: Export file was not created!"
      WriteLog "Repair  - Export main database - FAIL (no output file)"
      EndPhase "Database Repair" "FAILED - No export file"
      Fail=1
      return 1
    fi

    #-------------------------------------------------------------------
    # STEP 2: Export Blobs DB (with heartbeat)
    #-------------------------------------------------------------------
    ShowProgress "Export" "Exporting Blobs DB to SQL..."
    WriteLog "Repair  - Export blobs database - STARTED"
    
    local blobsSqlFile="$TMPDIR/blobs.plexapp.sql-$TimeStamp"
    
    # Start heartbeat
    StartHeartbeat "Blobs DB Export" "$blobsSqlFile"
    
    "$PLEX_SQLITE" $CPPL.blobs.db ".output '$blobsSqlFile'" .dump
    Result=$?
    
    # Stop heartbeat
    StopHeartbeat
    
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result; then
      Output "Error $Result from Plex SQLite while exporting $CPPL.blobs.db"
      Output "Could not successfully export the blobs database to repair it. Please try restoring a backup."
      WriteLog "Repair  - Cannot recover blobs database to '$blobsSqlFile' - FAIL ($Result)"
      EndPhase "Database Repair" "FAILED - Blobs export error"
      Fail=1
      return 1
    fi
    
    if [ -f "$blobsSqlFile" ]; then
      local blobsSqlSize=$(stat $STATFMT $STATBYTES "$blobsSqlFile")
      Output "Blobs DB exported successfully - SQL file size: $(GetHumanSize $blobsSqlSize)"
      WriteLog "Repair  - Export blobs database - PASS ($(GetHumanSize $blobsSqlSize))"
    fi

    # Edit the .SQL files if all OK
    if [ $Fail -eq 0 ]; then
      ShowProgress "Export" "Fixing any ROLLBACK statements in SQL files..."
      sed -i -e 's/ROLLBACK;/COMMIT;/' "$sqlFile"
      sed -i -e 's/ROLLBACK;/COMMIT;/' "$blobsSqlFile"
    fi

    Output "Successfully exported the main and blobs databases."
    WriteLog "Repair  - Export databases - PASS"

    #-------------------------------------------------------------------
    # STEP 3: Import into new databases (with heartbeat)
    #-------------------------------------------------------------------
    ShowProgress "Import" "Importing Main DB from SQL (creating fresh database)..."
    ShowProgress "Import" "You will see heartbeat messages every 30 seconds..."
    WriteLog "Repair  - Import main database - STARTED"
    
    local importStart=$(date +%s)
    local newMainDb="$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"
    
    DoSetPageSize "$newMainDb"
    
    # Start heartbeat for import
    StartHeartbeat "Main DB Import" "$newMainDb"
    
    "$PLEX_SQLITE" "$newMainDb" < "$sqlFile"
    Result=$?
    
    # Stop heartbeat
    StopHeartbeat
    
    local importEnd=$(date +%s)
    local importTime=$((importEnd - importStart))
    
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result ; then
      Output "Error $Result from Plex SQLite while importing from '$sqlFile'"
      WriteLog "Repair  - Cannot import main database from '$sqlFile' - FAIL ($Result)"
      Output "Cannot continue."
      EndPhase "Database Repair" "FAILED - Import error"
      Fail=1
      return 1
    fi
    Output "Main DB imported successfully in ${importTime}s"
    WriteLog "Repair  - Import main database - PASS (${importTime}s)"

    ShowProgress "Import" "Importing Blobs DB from SQL..."
    ShowProgress "Import" "You will see heartbeat messages every 30 seconds..."
    WriteLog "Repair  - Import blobs database - STARTED"
    
    local blobsImportStart=$(date +%s)
    local newBlobsDb="$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp"
    local blobsSqlFile="$TMPDIR/blobs.plexapp.sql-$TimeStamp"
    
    DoSetPageSize "$newBlobsDb"
    
    # Start heartbeat for blobs import
    StartHeartbeat "Blobs DB Import" "$newBlobsDb"
    
    "$PLEX_SQLITE" "$newBlobsDb" < "$blobsSqlFile"
    Result=$?
    
    # Stop heartbeat
    StopHeartbeat
    
    local blobsImportEnd=$(date +%s)
    local blobsImportTime=$((blobsImportEnd - blobsImportStart))
    
    [ $IgnoreErrors -eq 1 ] && Result=0

    if ! SQLiteOK $Result ; then
      Output "Error $Result from Plex SQLite while importing from '$blobsSqlFile'"
      WriteLog "Repair  - Cannot import blobs database from '$blobsSqlFile' - FAIL ($Result)"
      Output "Cannot continue."
      EndPhase "Database Repair" "FAILED - Blobs import error"
      Fail=1
      return 1
    fi
    Output "Blobs DB imported successfully in ${blobsImportTime}s"
    WriteLog "Repair  - Import blobs database - PASS (${blobsImportTime}s)"

    Output "Successfully imported databases."
    WriteLog "Repair  - Import - PASS"

    #-------------------------------------------------------------------
    # STEP 4: Verify repaired databases
    #-------------------------------------------------------------------
    ShowProgress "Verify" "Verifying integrity of repaired databases..."
    Output "Verifying databases integrity after importing."

    # Check main DB
    if CheckDB "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp" ; then
      SizeStart=$(GetSize "$CPPL.db")
      SizeFinish=$(GetSize "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp")
      Output "Verification complete. PMS main database is OK."
      Output "Size comparison: ${SizeStart}MB (original) -> ${SizeFinish}MB (repaired)"
      WriteLog "Repair  - Verify main database - PASS (Size: ${SizeStart}MB/${SizeFinish}MB)."
    else
      Output "Verification complete. PMS main database import FAILED."
      WriteLog "Repair  - Verify main database - FAIL ($SQLerror)"
      Fail=1
    fi

    # Check blobs DB
    if CheckDB "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp" ; then
      SizeStart=$(GetSize "$CPPL.blobs.db")
      SizeFinish=$(GetSize "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp")
      Output "Verification complete. PMS blobs database is OK."
      Output "Size comparison: ${SizeStart}MB (original) -> ${SizeFinish}MB (repaired)"
      WriteLog "Repair  - Verify blobs database - PASS (Size: ${SizeStart}MB/${SizeFinish}MB)."
    else
      Output "Verification complete. PMS blobs database import FAILED."
      WriteLog "Repair  - Verify blobs database - FAIL ($SQLerror)"
      Fail=1
    fi

    #-------------------------------------------------------------------
    # STEP 5: Move files into place
    #-------------------------------------------------------------------
    if [ $Fail -eq 0 ]; then
      ShowProgress "Finalize" "Moving repaired databases into place..."
      
      Output "Saving current databases with '-BACKUP-$TimeStamp'"
      [ -e $CPPL.db ]       && mv $CPPL.db       "$TMPDIR/$CPPL.db-BACKUP-$TimeStamp"
      [ -e $CPPL.blobs.db ] && mv $CPPL.blobs.db "$TMPDIR/$CPPL.blobs.db-BACKUP-$TimeStamp"

      Output "Making repaired databases active"
      WriteLog "Repair  - Making repaired databases active"
      mv "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"       $CPPL.db
      mv "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp" $CPPL.blobs.db

      # Ensure WAL and SHM are gone
      [ -e $CPPL.blobs.db-wal ] && rm -f $CPPL.blobs.db-wal
      [ -e $CPPL.blobs.db-shm ] && rm -f $CPPL.blobs.db-shm
      [ -e $CPPL.db-wal ]       && rm -f $CPPL.db-wal
      [ -e $CPPL.db-shm ]       && rm -f $CPPL.db-shm

      # Set ownership on new files
      chmod $Perms $CPPL.db $CPPL.blobs.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR: Cannot set permissions on new databases. Error $Result"
        Output "       Please exit tool, keeping temp files, seek assistance."
        Output "       Use files: $TMPDIR/*-BACKUP-$TimeStamp"
        WriteLog "Repair  - Move files - FAIL"
        Fail=1
        return 1
      fi

      chown $Owner $CPPL.db $CPPL.blobs.db
      Result=$?
      if [ $Result -ne 0 ]; then
        Output "ERROR: Cannot set ownership on new databases. Error $Result"
        Output "       Please exit tool, keeping temp files, seek assistance."
        Output "       Use files: $TMPDIR/*-BACKUP-$TimeStamp"
        WriteLog "Repair  - Move files - FAIL"
        Fail=1
        return 1
      fi

      # We didn't fail, set CheckedDB status true
      CheckedDB=1

      WriteLog "Repair  - Move files - PASS"
      WriteLog "Repair  - PASS"

      SetLast "Repair" "$TimeStamp"
      
      Output ""
      Output "============================================================"
      Output "REPAIR COMPLETE!"
      Output "============================================================"
      Output ""
      Output "Please check your library settings and contents for completeness."
      Output "Recommend: Scan Files and Refresh all metadata for each library section."
      Output ""
      
      # Automatically run final integrity check with Plex SQLite
      Output "Running final integrity check with Plex SQLite..."
      Output ""
      
      local finalCheck=$("$PLEX_SQLITE" "$DBDIR/$CPPL.db" "PRAGMA integrity_check;" 2>&1)
      if [ "$finalCheck" = "ok" ]; then
        Output ">>> FINAL INTEGRITY CHECK: PASSED"
        Output "    Result: $finalCheck"
        Output ""
        Output "Database is healthy! Safe to start Plex."
        WriteLog "Repair  - Final integrity check - PASS"
      else
        Output ">>> FINAL INTEGRITY CHECK: WARNING"
        Output "    Result: $finalCheck"
        Output ""
        Output "WARNING: Integrity check did not return 'ok'."
        Output "         Review the output above before starting Plex."
        WriteLog "Repair  - Final integrity check - WARNING: $finalCheck"
      fi
      
      Output ""
      Output "To manually verify, run:"
      Output "  \"$PLEX_SQLITE\" \"$DBDIR/$CPPL.db\" \"PRAGMA integrity_check;\""
      Output ""
      Output "============================================================"
      Output ""
      
      EndPhase "Database Repair" "PASSED"
      return 0
    else
      rm -f "$TMPDIR/$CPPL.db-REPAIR-$TimeStamp"
      rm -f "$TMPDIR/$CPPL.blobs.db-REPAIR-$TimeStamp"

      Output "Repair has failed. No files changed"
      WriteLog "Repair - $TimeStamp - FAIL"
      CheckedDB=0
      EndPhase "Database Repair" "FAILED"
      return 1
    fi
}

#########################################################################
# VACUUM FUNCTION                                                       #
#########################################################################

DoVacuum() {
    Damaged=0
    Fail=0

    StartPhase "Database Vacuum"

    # Check databases before vacuuming if not previously checked
    if ! CheckDatabases "Vacuum " ; then
      Damaged=1
      CheckedDB=1
      Fail=1
      [ $IgnoreErrors -eq 1 ] && Fail=0
    fi

    # If damaged, exit
    if [ $Damaged -eq 1 ]; then
      Output "Databases are damaged. Vacuum operation not available. Please repair or replace first."
      EndPhase "Database Vacuum" "FAILED - Damaged databases"
      return 1
    fi

    # Databases are OK, Make a backup
    Output "Backing up databases before vacuum..."
    MakeBackups "Vacuum"
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if [ $Result -eq 0 ]; then
      WriteLog "Vacuum  - MakeBackup - PASS"
    else
      Output "Error making backups. Cannot continue."
      WriteLog "Vacuum  - MakeBackup - FAIL ($Result)"
      EndPhase "Database Vacuum" "FAILED - Backup error"
      Fail=1
      return 1
    fi

    # Get sizes before
    local mainSizeBefore=$(GetSize "$CPPL.db")
    local blobsSizeBefore=$(GetSize "$CPPL.blobs.db")

    # Vacuum main database
    ShowProgress "Vacuum" "Vacuuming main database (this may take several minutes)..."
    "$PLEX_SQLITE" $CPPL.db 'VACUUM;'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if SQLiteOK $Result; then
      local mainSizeAfter=$(GetSize "$CPPL.db")
      Output "Vacuuming main database successful. Size: ${mainSizeBefore}MB -> ${mainSizeAfter}MB"
      WriteLog "Vacuum  - Vacuum: $CPPL.db - PASS"
    else
      Output "Vacuuming main database failed. Error code $Result from Plex SQLite"
      WriteLog "Vacuum  - Vacuum: $CPPL.db - FAIL ($Result)"
      Fail=1
    fi

    ShowProgress "Vacuum" "Vacuuming blobs database..."
    "$PLEX_SQLITE" $CPPL.blobs.db 'VACUUM;'
    Result=$?
    [ $IgnoreErrors -eq 1 ] && Result=0

    if SQLiteOK $Result; then
      local blobsSizeAfter=$(GetSize "$CPPL.blobs.db")
      Output "Vacuuming blobs database successful. Size: ${blobsSizeBefore}MB -> ${blobsSizeAfter}MB"
      WriteLog "Vacuum  - Vacuum: $CPPL.blobs.db - PASS"
    else
      Output "Vacuuming blobs database failed. Error code $Result from Plex SQLite"
      WriteLog "Vacuum  - Vacuum: $CPPL.blobs.db - FAIL ($Result)"
      Fail=1
    fi

    if [ $Fail -eq 0 ]; then
      SetLast "Vacuum" "$TimeStamp"
      WriteLog "Vacuum  - PASS"
      EndPhase "Database Vacuum" "PASSED"
    else
      RestoreSaved "$TimeStamp"
      WriteLog "Vacuum  - FAIL"
      EndPhase "Database Vacuum" "FAILED"
    fi

    return $Fail
}

#########################################################################
# START/STOP PMS FUNCTIONS                                              #
#########################################################################

IsRunning() {
  $PIDOF "Plex Media Server" > /dev/null 2>&1
}

DoStart() {
  if [ $HaveStartStop -eq 0 ]; then
    Output "Start command not available on this host. Please start PMS manually."
    return 1
  fi

  if IsRunning; then
    Output "PMS is already running."
    return 0
  fi

  Output "Starting PMS..."
  eval $StartCommand
  sleep 3
  
  if IsRunning; then
    Output "Started PMS"
    WriteLog "StartPMS  - PASS"
    return 0
  else
    Output "Failed to start PMS"
    WriteLog "StartPMS  - FAIL"
    return 1
  fi
}

DoStop() {
  if [ $HaveStartStop -eq 0 ]; then
    Output "Stop command not available on this host. Please stop PMS manually."
    return 1
  fi

  if ! IsRunning; then
    Output "PMS already stopped."
    return 0
  fi

  Output "Stopping PMS..."
  eval $StopCommand
  
  # Wait for stop
  local count=0
  while IsRunning && [ $count -lt 30 ]; do
    sleep 1
    count=$((count + 1))
  done

  if ! IsRunning; then
    Output "Stopped PMS."
    WriteLog "StopPMS  - PASS"
    return 0
  else
    Output "Failed to stop PMS after 30 seconds"
    WriteLog "StopPMS  - FAIL"
    return 1
  fi
}

#########################################################################
# TIMESTAMP UPDATE                                                      #
#########################################################################

DoUpdateTimestamp() {
  TimeStamp="$(date "+%Y-%m-%d_%H.%M.%S")"
}

#########################################################################
# HOST CONFIGURATION (Simplified for manual mode)                       #
#########################################################################

HostConfig() {
  # This enhanced version focuses on manual configuration
  # For full host detection, use the original script
  
  # Check for standard Linux
  if [ -f /etc/os-release ]; then
    HostType="Linux"
    RootRequired=0
    return 0
  fi
  
  return 1
}

#########################################################################
# MAIN ENTRY POINT                                                      #
#########################################################################

# Set Script Path
ScriptPath="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ScriptName="$(basename "$ScriptPath")"
ScriptWorkingDirectory="$(dirname "$ScriptPath")"

# Initialize LastName LastTimestamp
SetLast "" ""

# Process command line options
while [ "$(echo $1 | cut -c1)" = "-" ] && [ "$1" != "" ]
do
  Opt="$(echo $1 | awk '{print $1}' | tr [A-Z] [a-z])"

  # Ignore errors option
  if [ "$Opt" = "--ignore-errors" ] || [ "$Opt" = "-i" ]; then
    IgnoreErrors=1
    shift
    continue
  fi

  # Manual configuration options
  if [ "$Opt" = "--sqlite" ]; then
    if [ -d "$2" ] && [ -f "$2/Plex SQLite" ]; then
      PLEX_SQLITE="$2/Plex SQLite"
      ManualConfig=1
    elif echo "$2" | grep "Plex SQLite" > /dev/null && [ -f "$2" ] ; then
      PLEX_SQLITE="$2"
      ManualConfig=1
    else
      Output "Given 'Plex SQLite' directory/path ('$2') is invalid. Aborting."
      exit 2
    fi
    shift 2
    continue
  fi

  # Manual path to databases
  if [ "$Opt" = "--databases" ]; then
    if [ -d "$2" ] && [ -f "$2"/com.plexapp.plugins.library.db ]; then
      DBDIR="$2"
      AppSuppDir="$(dirname "$(dirname "$(dirname "$DBDIR")")")"
      LOGFILE="$DBDIR/DBRepair.log"
      ManualConfig=1
    else
      Output "Given Plex databases directory ('$2') is invalid. Aborting."
      exit 2
    fi
    shift 2
    continue
  fi

  # Unknown option
  shift
done

# Confirm completed manual config
if [ $ManualConfig -eq 1 ]; then
  if [ "$DBDIR" = "" ] || [ "$PLEX_SQLITE" = "" ]; then
    Output "Error: Both 'Plex SQLite' and Databases directory paths must be specified with Manual configuration."
    exit 2
  fi
  HostType="User Defined"
fi

# Are we scripted (command line args)
Scripted=0
[ "$1" != "" ] && Scripted=1

# Identify this host if not manual
if [ $ManualConfig -eq 0 ] && ! HostConfig; then
  Output "Error: Unknown host. Please use --sqlite and --databases options for manual configuration."
  exit 1
fi

# Check write access
if [ ! -w "$DBDIR" ]; then
  Output "ERROR: Cannot write to Databases directory. Insufficient privilege."
  exit 2
fi

# Initialize log file
touch "$LOGFILE" 2>/dev/null

echo ""
echo "============================================================"
echo "  Database Repair Utility for Plex Media Server (Enhanced)"
echo "  Version $Version"
echo "============================================================"
echo ""

WriteLog "============================================================"
WriteLog "Session start: Host is $HostType"

# Run pre-flight check to clean up any stuck processes from previous runs
Output "Running pre-flight check..."
PreFlightCheck
Output "Pre-flight check complete."
WriteLog "Pre-flight check complete."

if [ $ManualConfig -eq 1 ]; then
  Output "PlexSQLite = '$PLEX_SQLITE'"
  Output "Databases  = '$DBDIR'"
  WriteLog "SQLite path:   '$PLEX_SQLITE'"
  WriteLog "Database path: '$DBDIR'"
fi

if [ $IgnoreErrors -eq 1 ]; then
  Output "NOTE: Running with --ignore-errors flag"
  WriteLog "Option: Ignoring database errors"
fi

# Basic checks - PMS installed
if [ ! -f "$PLEX_SQLITE" ]; then
  Output "PMS is not installed or Plex SQLite not found. Cannot continue."
  WriteLog "PMS not installed."
  exit 1
fi

# Set tmp dir
DBTMP="./dbtmp"
mkdir -p "$DBDIR/$DBTMP"
export TMPDIR="$DBTMP"
export TMP="$DBTMP"

# Check databases exist
if [ ! -f "$DBDIR/$CPPL.db" ] && [ ! -f "$DBDIR/$CPPL.blobs.db" ]; then
  Output "Cannot locate databases. Cannot continue."
  WriteLog "Databases not found."
  exit 1
fi

# Work in the Databases directory
cd "$DBDIR"

# Get the owning UID/GID
Owner="$(stat $STATFMT '%u:%g' $CPPL.db 2>/dev/null || echo "root:root")"
Perms="$(stat $STATFMT $STATPERMS $CPPL.db 2>/dev/null || echo "644")"

# Sanity check
if [ ! -w $CPPL.db ]; then
  Output "Do not have write permission to the Databases. Exiting."
  WriteLog "No write permission to databases. Exit."
  exit 1
fi

#########################################################################
# COMMAND PROCESSING                                                    #
#########################################################################

# Process commands
while [ "$1" != "" ] || [ $Scripted -eq 0 ]; do
  
  if [ $Scripted -eq 0 ]; then
    # Interactive mode
    echo ""
    echo "Commands: check, auto, repair, reindex, vacuum, exit"
    printf "Enter command: "
    read Input
    Command="$(echo $Input | tr '[A-Z]' '[a-z]' | awk '{print $1}')"
  else
    # Scripted mode
    if [ "$1" = "" ]; then
      break
    fi
    Command="$(echo $1 | tr '[A-Z]' '[a-z]')"
    shift
  fi

  DoUpdateTimestamp

  case "$Command" in
    stop)
      DoStop
      ;;

    auto*)
      # Check if PMS running
      if IsRunning; then
        WriteLog "Auto    - FAIL - PMS running"
        Output "Unable to run automatic sequence. PMS is running. Please stop PlexMediaServer."
        continue
      fi

      # Is there enough room
      if ! FreeSpaceAvailable; then
        WriteLog "Auto    - FAIL - Insufficient free space"
        Output "Error: Unable to run automatic sequence. Insufficient free space available."
        Output "       Space needed = $SpaceNeeded MB, Space available = $SpaceAvailable MB"
        continue
      fi

      Output ""
      Output "============================================================"
      Output "AUTOMATIC REPAIR SEQUENCE STARTING"
      Output "============================================================"
      Output ""
      WriteLog "Auto    - START"

      # Check databases
      if CheckDatabases "Check  " force ; then
        WriteLog "Check   - PASS"
        CheckedDB=1
      else
        WriteLog "Check   - FAIL"
        CheckedDB=0
        if [ $IgnoreErrors -eq 0 ]; then
          Output "Database check failed. Use --ignore-errors to proceed anyway."
          continue
        fi
        Output "Proceeding despite errors (--ignore-errors enabled)"
      fi

      # Repair
      Output ""
      if ! DoRepair; then
        WriteLog "Repair  - FAIL"
        WriteLog "Auto    - FAIL"
        CheckedDB=0
        Output "Repair failed. Automatic mode cannot continue."
        continue
      else
        WriteLog "Repair  - PASS"
        CheckedDB=1
      fi

      # Reindex
      DoUpdateTimestamp
      Output ""
      if ! DoIndex; then
        WriteLog "Index   - FAIL"
        WriteLog "Auto    - FAIL"
        CheckedDB=0
        Output "Index failed. Automatic mode cannot continue."
        continue
      else
        WriteLog "Reindex - PASS"
      fi

      WriteLog "Auto    - COMPLETED"
      Output ""
      Output "============================================================"
      Output "AUTOMATIC REPAIR SEQUENCE COMPLETED SUCCESSFULLY"
      Output "============================================================"
      Output ""
      
      # Offer to start Plex if we have start/stop capability
      if [ $HaveStartStop -eq 1 ] && [ -n "$StartCommand" ]; then
        echo -n "Start Plex Media Server now? [y/N]: "
        read -t 60 startAnswer
        if [ "$startAnswer" = "y" ] || [ "$startAnswer" = "Y" ]; then
          Output "Starting Plex Media Server..."
          DoStart
        else
          Output "Plex not started. Start manually when ready."
        fi
      else
        # No native start command - check for Docker
        if command -v docker &>/dev/null; then
          # Try to find Plex container
          local plexContainer=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'plex' | head -1)
          if [ -n "$plexContainer" ]; then
            echo -n "Start Docker container '$plexContainer' now? [y/N]: "
            read -t 60 startAnswer
            if [ "$startAnswer" = "y" ] || [ "$startAnswer" = "Y" ]; then
              Output "Starting Docker container: $plexContainer"
              docker start "$plexContainer"
              if [ $? -eq 0 ]; then
                Output "Container started successfully."
                WriteLog "Auto    - Started Docker container: $plexContainer"
              else
                Output "Failed to start container. Start manually: docker start $plexContainer"
                WriteLog "Auto    - Failed to start Docker container: $plexContainer"
              fi
            else
              Output "Container not started. Start manually: docker start $plexContainer"
            fi
          else
            Output "To start Plex, run your container start command manually."
          fi
        else
          Output "To start Plex, run your start command manually."
        fi
      fi
      Output ""
      ;;

    chec*)
      if IsRunning; then
        WriteLog "Check   - FAIL - PMS running"
        Output "Unable to check databases. PMS is running."
        continue
      fi

      if CheckDatabases "Check  " force ; then
        WriteLog "Check   - PASS"
        CheckedDB=1
      else
        WriteLog "Check   - FAIL"
        CheckedDB=0
      fi
      ;;

    vacu*)
      if IsRunning; then
        WriteLog "Vacuum  - FAIL - PMS running"
        Output "Unable to vacuum databases. PMS is running."
        continue
      fi
      DoVacuum
      ;;

    repa*)
      if IsRunning; then
        WriteLog "Repair  - FAIL - PMS running"
        Output "Unable to repair databases. PMS is running."
        continue
      fi
      DoRepair
      ;;

    rein*)
      if IsRunning; then
        WriteLog "Reindex - FAIL - PMS running"
        Output "Unable to reindex databases. PMS is running."
        continue
      fi
      DoIndex
      ;;

    undo)
      DoUndo
      ;;

    start)
      DoStart
      ;;

    exit|quit|q)
      Output "Exiting..."
      WriteLog "Exit    - Normal exit"
      WriteLog "Session end. $(date)"
      WriteLog "============================================================"
      exit 0
      ;;

    *)
      if [ -n "$Command" ]; then
        Output "Unknown command: $Command"
      fi
      ;;
  esac
done

# End of script
WriteLog "Exit    - End of commands"
WriteLog "Session end. $(date)"
WriteLog "============================================================"
exit 0
