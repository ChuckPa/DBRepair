# DBRepair (for Plex Media Server)

[![GitHub issues](https://img.shields.io/github/issues/ChuckPa/DBRepair.svg?style=flat)](https://github.com/ChuckPa/DBRepair/issues)
[![Release](https://img.shields.io/github/release/ChuckPa/DBRepair.svg?style=flat)](https://github.com/ChuckPa/DBRepair/releases/latest)
[![Download latest release](https://img.shields.io/github/downloads/ChuckPa/DBRepair/latest/total.svg)](https://github.com/ChuckPa/DBRepair/releases/latest)
[![Download total](https://img.shields.io/github/downloads/ChuckPa/DBRepair/total.svg)](https://github.com/ChuckPa/DBRepair/releases)
[![master](https://img.shields.io/badge/master-stable-green.svg?maxAge=2592000)]('')
![Maintenance](https://img.shields.io/badge/Maintained-Yes-green.svg)


DBRepair is run from a command line (terminal or ssh/putty session) which has sufficient privilege to read/write the databases (minimum).
If sufficient privleges exist (root), and supported by the environment, the options to start and stop PMS are presented as well.
(Some envionments require DBRepair to run as the 'root' user.)

## Situations and errors commonly seen include:

        1. Searching is sluggish
        2. Database is malformed / damaged / corrupted
        3. Database has bloated from media addition or changes
        4. Damaged indexes damaged
        5. Importing data from other databases (watch history)
        6. Cleaning up operational temp files which PMS has forgotten to clean up


## Functions provided

 The utility accepts command names.
 Command names may be upper/lower case and may also be abbreviated (4 character minimum).

 The following commands (or their number), listed in alphabetical order,  are accepted as input.
```
   AUTO(matic)  - Automatically check, repair/optimize, reindex, and FTS rebuild in one step.
   CHEC(k)      - Check the main and blob databases integrity (includes FTS index check)
   DEFL(ate)    - Deflate a bloated PMS database (faulty statistics data)
   EXIT         - Exit the utility
   IGNOre/HONOr - Ignore/Honor constraint errors when IMPORTing additional data into DB.
   IMPO(rt)     - Import viewstate / watch history from another database
   PRUN(e)      - Prune (remove) old image files from transcoder cache diretory
   PURG(e)      - Purge (delete) all temporary files left behind by PMS & the transcoder from the temp directory
   REIN(dex)    - Rebuild the database indexes (includes FTS indexes)
   REPL(ace)    - Replace the existing databases with a PMS-generated backup
   SHOW         - Show the log file
   STAR(t)      - Start PMS (not available on all platforms)
   STOP         - Stop PMS  (not available on all platforms)
   UNDO         - UNDO the last operation
   VACU(um)     - Vacuum the databases
```

### The menu

  The menu gives you the option to enter either a 'command number' or the 'command name/abbreviation'.
  For clarity, each command's name is 'quoted'.

```
            Database Repair Utility for Plex Media Server (_host_configuration_name_)
                       Version v1.09.00

  Select

  1 - 'stop'      - Stop PMS.
  2 - 'automatic' - Check, Repair/Optimize, Reindex, and FTS rebuild in one step.
  3 - 'check'     - Perform integrity check of database and FTS indexes.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - Start PMS

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Prune (remove) old image files (jpeg,jpg,png) from PhotoTranscoder cache.
 22 - 'purge'     - Purge (delete) all temporary files left behind by PMS & the transcoder.
 23 - 'deflate'   - Deflate a bloated PMS main database.
 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99   'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) :



## Hosts currently supported

        1. Apple (MacOS)
        2. ASUSTOR
        3. Docker containers via 'docker exec' command (inside the running container environment)
           - Plex,inc.
           - Linuxserver.io
           - BINHEX
           - HOTIO
           - Podman (libgpod)
        4. FreeBSD (14+)
        5. Linux workstation & server
        6. MacOS
        7. Netgear (OS5 Linux-based systems)
        8. QNAP (QTS & QuTS)
        9. Synology (DSM 6 & DSM 7)
       10. Western Digital (OS5)
```
 # Installation

### Downloading
    Download DBRepair.sh (if you want just the script)
    # This overwrites any existing version.  Remove "-O DBRepair.sh" to not overwrite.
```
    wget -O DBRepair.sh https://github.com/ChuckPa/PlexDBRepair/releases/latest/download/DBRepair.sh
```
### Moving the downloaded DBRepair.sh

    Where to place the utility varies from host to host.
    Please use this table as a reference.

    Some hosts will not be listed here by name (e.g. Unraid, Proxmox).
    They will likely be supported by the container/VM PMS runs in.

```
    Vendor             | Shared folder name  |  Recommended directory
    -------------------+---------------------+------------------------------------------
    Apple              | Downloads           |  ~/Downloads
    Arch Linux         | N/A                 |  Anywhere
    ASUSTOR            | Plex                |  /volume1/Plex
    Binhex             | N/A                 |  Container root (adjacent /config)
    Docker (Plex,LSIO) | N/A                 |  Container root (adjacent /config)
    Hotio              | N/A                 |  Container root (adjacent /config)
    FreeBSD (14+)      | N/A                 |  Anywhere
    Kubernetes         | N/A                 |  Container root (adjacent /config)
    Linux (wkstn/svr)  | N/A                 |  Anywhere
    MacOS              | N/A                 |  Anywhere
    Netgear (ReadyNAS) | "your_choice"       |  "/data/your_choice"
    QNAP (QTS/QuTS)    | Public              |  /share/Public
    SNAP               | N/A                 |  Anywhere
    Synology (DSM 6)   | Plex                |  /volume1/Plex             (change volume as required)
    Synology (DSM 7)   | PlexMediaServer     |  /volume1/PlexMediaServer  (change volume as required)
    Western Digital    | Public              |  /mnt/HD/HD_a2/Public      (Does not support 'MyCloudHome' series)
```
    Plex,inc and LSIO docker images are included in "Docker" platform category independent of the actual host.

    Additional hosts and docker images can easily be supported in almost all cases with appropriate path
    information.   Please contact me as needed.

### Gettting a usable command line session
        1. Accessing a NAS
            Open a terminal/command line window on your computer.
            type: ssh admin-username@IP.addr.of.NAS

        2. Linux
            Open a terminal session and elevate to the root (sudo) user

        3. Windows  -- for Windows PMS hosts
            Open a Command window
            Follow the instructions for the Windows version of DBRepair


### General installation and usage instructions

        1. Open your browser to https://github.com/ChuckPa/DBRepair/releases/latest
        2. Download the source code (tar.gz or ZIP) file

        3. Knowing the file name will always be of the form 'DBRepair-X.Y.Z.tar.gz'
           --  where X.Y.Z is the release number.  Use the real values in place of X, Y, and Z.
        4. Place the tar.gz file in the appropriate directory on the system you'll use it.
        5. Open a command line session (usually Terminal or SSH)
        6. Elevate privilege level to root (sudo) if needed.
        7. Extract the utility from the tar or zip file
        8. 'cd' into the extraction directory
        9. Give DBRepair.sh 'execute' permission  (chmod +x)
       10. Invoke ./DBRepair.sh



###   (In the examples below,  substitute "x.y.z" with the actual version you download/use)

###   EXAMPLE:  To install & launch on Synology DSM 6 / DSM 7


        cd /volume1/Plex    # use /volume1/PlexMediaServer on DSM 7
        sudo bash
        tar xf DBRepair-x.y.z.tar.gz
        cd DBRepair-x.y.z
        chmod +x DBRepair.sh
        ./DBRepair.sh

###    EXAMPLE: Using DBRepair inside containers (manual start/stop included)

#### (Select containers allow stopping/starting PMS from the menu.  See menu for details)

        sudo docker exec -it plex /bin/bash

        # extract from downloaded version file name then cd into directory
        tar xf DBRepair-x.y.z.tar.gz
        cd DBRepair-x.y.z
        chmod +x DBRepair.sh
        ./DBRepair.sh
```
###    EXAMPLE:  Using DBRepair on regular Linux native host (Workstation/Server)
```
        sudo bash
        cd /path/to/DBRepair.tar
        tar xf DBRepair-x.y.z.tar.gz
        cd DBRepair-x.y.z
        chmod +x DBRepair.sh
        ./DBRepair.sh stop auto start exit
```

###    EXAMPLE: Using DBRepair from the command line on MacOS (on the administrator account)
```
        osascript -e 'quit app "Plex Media Server"'
        cd ~/Downloads
        tar xf DBRepair-x.y.z.tar.gz
        cd DBRepair-x.y.z

        chmod +x DBRepair.sh
        ./DBRepair.sh



## Typical usage

This utility can only operate on PMS when PMS is in the stopped state.
If PMS is running when you startup the utility,  it will tell you.

These examples

  A. The most common usage will be the "Automatic" function.

    Automatic mode is where DBRepair determines which steps are needed to make your database run optimally.
    For most users, Automatic is equivalent to 'Check, Repair, Reindex'.
    This repairs minor damage, vacuums out all the unused records, and rebuilds search indexes in one step.

  B. Database is malformed  (Backups of  com.plexapp.plugins.library.db and com.plexap.plugins.library.blobs.db available)
     Note: You may attempt "Repair" sequence

    1. (3)  Check   - Confirm either main or blobs database is damaged
    2. (9)  Replace - Use the most recent valid backup -- OR -- (5) Repair.  Check date/time stamps for best action.
                    -- If Replace fails, use Repair (5)
                    -- (Replace can fail if the database has been damaged for a long time.)
    3. (6)  Reindex - Generate new indexes so PMS doesn't need to at startup
    4. (99) Exit

  C. Database is malformed - No Backups
    1. (3)  Check   - Confirm either main or blobs database is damaged
    2. (5)  Repair  - Salvage as much as possible from the databases and rebuild them into a usable database.
    3. (6)  Reindex - Generate new indexes so PMS doesn't need to at startup
    4. (99) Exit

  D. Database sizes excessively large/bloated when compared to amount of media indexed (item count)
    1. (23) Deflate - Correct the known problem with a database table and recover the wasted space.
    2. (2)  Auto    - Perform automated check, repair, and reindex of the deflated database
    4. (99) Exit

  E. User interface has become 'sluggish' as more media was added
    1. (3)  Check   - Confirm there is no database damage
    2. (5)  Repair  - You are not really repairing.  You are rebuilding the DB in perfect sorted order.
    3. (6)  Reindex - Rebuild Indexes.
    4. (99) Exit

  F. Undo
    Undo is a special case where you need the utility to backup ONE step.
    This is rarely needed.  The only time you might want/need to backup one step is if Replace leaves you worse off
    than you were before. In this case, UNDO then Repair.  Undo can only undo the single most-recent action.
    (Note: In a future release, you will be able to 'undo' every action taken until the DBs are in their original state)

  G. HTTP 500 errors when adding to collections / FTS index corruption
    This occurs when standard integrity_check passes but FTS (Full-Text Search) indexes are corrupted.
    Symptoms: Adding items to collections fails, updating metadata fails, "database disk image is malformed"
    during UPDATE operations even though Check reports databases are OK.

    1. (3)  Check   - Will show "FTS index damaged" message
    2. (6)  Reindex - Rebuild indexes including FTS
    3. (99) Exit

    Alternatively, use (2) Automatic which will detect and repair FTS issues automatically.

Special considerations:

    1. As stated above, this utility requires PMS to be stopped in order to do what it does.
    2. - This utility CAN sit at the menu prompt with PMS running.
       - You did a few things and want to check BEFORE exiting the utility
       - If you don't like how it worked out,
        -- STOP PMS
        -- UNDO the last action and do something else
        -- OR do more things to the databases
    3. When satisfied,  Exit the utility.
       - There is no harm in keeping the database temp files (except for space used)
       - ALL database temps are named with date-time stamps in the name to avoid confusion.
    4. The Logfile ('show' command) shows all actions performed WITH timestamp so you can locate
       intermediate databases if desired for special / manual recovery cases.

  Community feedback has resulted in:

    "98" or "Quit" - Get out now without deleting the temp databases (Usually
                     used only during unexpected failures)
    "99" or "Exit" - Preferred way to exit and cleanup temp databases

   Notice:
     If command line EOF is encountered before Exit/Quit command received,
     DBRepair will quit and KEEP all temporary files.


  Also please be aware the script understands interactive versus scripted mode.


## Command line options

  To avoid confusion and making the menu complicated, a few command line options have been added.

  To use DBRepair when the container / host cannot be identified, --sqlite and --databases allow you
  to specify the pathnames from whichever context (namespace) DBRepair will be running in.

    --sqlite        Specify the path to "Plex SQLite" (diretory or full path)

    --databases     Specify the path to the directory which contains the PMS databases.

  Both must be used together.

  When operating with these options,  DBRepair will indicate it's in Manual configuration mode.
  You may still use other command line commands (batch mode) or use it normally in interactive mode.

## Scripting support

  Certain platforms don't provide for each command line access.
  To support those products,  this utility can be operated by adding command line arguments.

  Another use of this feature is to automate Plex Database maintenance44
  ( Stop Plex,  Run this sequence,  Start Plex ) at a time when the server isn't busy


  The command line arguments are the same as if typing at the menu.

  Example:   ./DBRepair.sh  stop auto start exit

  This executes:   Stop PMS,  Automatic (Check, Repair, Reindex), Start PMS, and Exit commands

  Beginning with v1.06.00, the 'exit' command is optional when scripted.


## Exiting

  When exiting,  you will be asked whether to keep the interim temp files created during this session.
  If you've encountered any difficulties or aren't sure what to do,  don't delete them.
  You'll be able to ask in the Plex forums about what to do.  Be prepared to present the log file to them.


## Sample interactive session

  This is a typical manual session if you aren't sure what to do and want the tool to decide.



```
bash-4.4# #=======================================================================================================
bash-4.4# ./DBRepair.sh



      Database Repair Utility for Plex Media Server (Ubuntu 20.04.6 LTS)
                       Version v1.03.01

Select

  1 - 'stop'      - Stop PMS.
  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step.
  3 - 'check'     - Perform integrity check of database.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - Start PMS

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Remove old image files (jpeg,jpg,png) from PhotoTranscoder cache & all temp files left by PMS.
 22 - 'purge'     - Remove unused temp files.
 23 - 'deflate'   - Deflate a bloated PMS main database.
 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99 - 'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) :  1

Stopping PMS.
Stopped PMS.

Select

  1 - 'stop'      - Stop PMS.
  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step.
  3 - 'check'     - Perform integrity check of database.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - Start PMS

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Remove old image files (jpeg,jpg,png) from PhotoTranscoder cache & all temp files left by PMS.
 22 - 'purge'     - Remove unused temp files.
 23 - 'deflate'   - Deflate a bloated PMS main database.
 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99 - 'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) : auto


Checking the PMS databases
Check complete.  PMS main database is OK.
Check complete.  PMS blobs database is OK.

Exporting current databases using timestamp: 2023-02-25_16.15.11
Exporting Main DB
Exporting Blobs DB
Successfully exported the main and blobs databases.  Proceeding to import into new databases.
Importing Main DB.
Importing Blobs DB.
Successfully imported data from SQL files.
Verifying databases integrity after importing.
Verification complete.  PMS main database is OK.
Verification complete.  PMS blobs database is OK.
Saving current databases with '-BKUP-2023-02-25_16.15.11'
Making imported databases active
Import complete. Please check your library settings and contents for completeness.
Recommend:  Scan Files and Refresh all metadata for each library section.

Backing up of databases
Backup current databases with '-BKUP-2023-02-25_16.20.41' timestamp.
Reindexing main database
Reindexing main database successful.
Reindexing blobs database
Reindexing blobs database successful.
Reindex complete.
Automatic Check,Repair/optimize,Index successful.

Select

  1 - 'stop'      - Stop PMS.
  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step.
  3 - 'check'     - Perform integrity check of database.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - Start PMS

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Remove old image files (jpeg,jpg,png) from PhotoTranscoder cache & all temp files left by PMS.
 22 - 'purge'     - Remove unused temp files.
 23 - 'deflate'   - Deflate a bloated PMS main database.
 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99 - 'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) : start

Starting PMS.
Started PMS

Select

  1 - 'stop'      - Stop PMS.
  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step.
  3 - 'check'     - Perform integrity check of database.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - Start PMS

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Remove old image files (jpeg,jpg,png) from PhotoTranscoder cache & all temp files left by PMS.
 22 - 'purge'     - Remove unused temp files.
 23 - 'deflate'   - Deflate a bloated PMS main database.
 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99 - 'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) : stat


Status report: Sat Feb 25 04:38:50 PM EST 2023
  PMS is running.
  Databases are OK.


Select

  1 - 'stop'      - Stop PMS.
  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step.
  3 - 'check'     - Perform integrity check of database.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - Start PMS

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Remove old image files (jpeg,jpg,png) from PhotoTranscoder cache & all temp files left by PMS.
 22 - 'purge'     - Remove unused temp files.
 23 - 'deflate'   - Deflate a bloated PMS main database.
 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99 - 'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) : exit

Ok to remove temporary databases/workfiles for this session? (Y/N) ? y
Are you sure (Y/N) ? y
Deleting all temporary work files.
bash-4.4#

```

## Sample (typical) scripted session (e.g.  via 'cron')

```
root@lizum:/sata/plex/Plex Media Server/Plug-in Support/Databases# ./DBRepair.sh stop check auto start exit



      Database Repair Utility for Plex Media Server (Ubuntu 20.04.5 LTS)
                       Version v1.03.01


[2023-03-05 18.53.49] Stopping PMS.
[2023-03-05 18.53.49] Stopped PMS.

[2023-03-05 18.53.49] Checking the PMS databases
[2023-03-05 18.54.22] Check complete.  PMS main database is OK.
[2023-03-05 18.54.22] Check complete.  PMS blobs database is OK.

[2023-03-05 18.54.22] Automatic Check,Repair,Index started.
[2023-03-05 18.54.22]
[2023-03-05 18.54.22] Checking the PMS databases
[2023-03-05 18.54.56] Check complete.  PMS main database is OK.
[2023-03-05 18.54.56] Check complete.  PMS blobs database is OK.
[2023-03-05 18.54.56]
[2023-03-05 18.54.56] Exporting current databases using timestamp: 2023-03-05_18.54.22
[2023-03-05 18.54.56] Exporting Main DB
[2023-03-05 18.55.30] Exporting Blobs DB
[2023-03-05 18.55.33] Successfully exported the main and blobs databases.  Proceeding to import into new databases.
[2023-03-05 18.55.33] Importing Main DB.
[2023-03-05 18.57.04] Importing Blobs DB.
[2023-03-05 18.57.05] Successfully imported SQL data.
[2023-03-05 18.57.05] Verifying databases integrity after importing.
[2023-03-05 18.57.40] Verification complete.  PMS main database is OK.
[2023-03-05 18.57.40] Verification complete.  PMS blobs database is OK.
[2023-03-05 18.57.40] Saving current databases with '-BACKUP-2023-03-05_18.54.22'
[2023-03-05 18.57.40] Making repaired databases active
[2023-03-05 18.57.40] Repair complete. Please check your library settings and contents for completeness.
[2023-03-05 18.57.40] Recommend:  Scan Files and Refresh all metadata for each library section.
[2023-03-05 18.57.40]
[2023-03-05 18.57.40] Backing up of databases
[2023-03-05 18.57.40] Backup current databases with '-BACKUP-2023-03-05_18.57.40' timestamp.
[2023-03-05 18.57.41] Reindexing main database
[2023-03-05 18.58.17] Reindexing main database successful.
[2023-03-05 18.58.17] Reindexing blobs database
[2023-03-05 18.58.17] Reindexing blobs database successful.
[2023-03-05 18.58.17] Reindex complete.
[2023-03-05 18.58.17] Automatic Check, Repair/optimize, & Index successful.

[2023-03-05 18.58.17] Starting PMS.
[2023-03-05 18.58.17] Started PMS

root@lizum:/sata/plex/Plex Media Server/Plug-in Support/Databases#

```

======================
```

```
## Logfile

  The logfile (DBRepair.log) keeps track of all commands issues and their status (PASS/FAIL) with timestamp.
  This can be useful when recovering from an interrupted session because temporary files are timestamped.


```
2023-02-25 16.14.39 - ============================================================
2023-02-25 16.14.39 - Session start: Host is Synology (DSM 7)
2023-02-25 16.14.56 - StopPMS  - PASS
2023-02-25 16.16.06 - Check   - Check com.plexapp.plugins.library.db - PASS
2023-02-25 16.16.06 - Check   - Check com.plexapp.plugins.library.blobs.db - PASS
2023-02-25 16.16.06 - Check   - PASS
2023-02-25 16.17.20 - Repair  - Export databases - PASS
2023-02-25 16.19.52 - Repair  - Import - PASS
2023-02-25 16.20.41 - Repair  - Verify main database - PASS (Size: 399MB/399MB).
2023-02-25 16.20.41 - Repair  - Verify blobs database - PASS (Size: 1MB/1MB).
2023-02-25 16.20.41 - Repair  - Move files - PASS
2023-02-25 16.20.41 - Repair  - PASS
2023-02-25 16.20.41 - Repair  - PASS
2023-02-25 16.20.46 - Reindex - MakeBackup com.plexapp.plugins.library.db - PASS
2023-02-25 16.20.46 - Reindex - MakeBackup com.plexapp.plugins.library.blobs.db - PASS
2023-02-25 16.20.46 - Reindex - MakeBackup - PASS
2023-02-25 16.21.34 - Reindex - Reindex: com.plexapp.plugins.library.db - PASS
2023-02-25 16.21.35 - Reindex - Reindex: com.plexapp.plugins.library.blobs.db - PASS
2023-02-25 16.21.35 - Reindex - PASS
2023-02-25 16.21.35 - Reindex - PASS
2023-02-25 16.21.35 - Auto    - PASS
2023-02-25 16.38.35 - StartPMS  - PASS
2023-02-25 16.38.57 - Exit    - Delete temp files.
2023-02-25 16.38.58 - Session end.
2023-02-25 16.38.58 - ============================================================
2023-02-25 16.40.10 - ============================================================
2023-02-25 16.40.10 - Session start: Host is Synology (DSM 7)
2023-02-25 16.40.27 - StopPMS  - PASS
2023-02-25 16.42.23 - Check   - Check com.plexapp.plugins.library.db - PASS
2023-02-25 16.42.24 - Check   - Check com.plexapp.plugins.library.blobs.db - PASS
2023-02-25 16.42.24 - Check   - PASS
2023-02-25 16.43.39 - Repair  - Export databases - PASS
2023-02-25 16.46.10 - Repair  - Import - PASS
2023-02-25 16.46.58 - Repair  - Verify main database - PASS (Size: 399MB/399MB).
2023-02-25 16.46.58 - Repair  - Verify blobs database - PASS (Size: 1MB/1MB).
2023-02-25 16.46.59 - Repair  - Move files - PASS
2023-02-25 16.46.59 - Repair  - PASS
2023-02-25 16.46.59 - Repair  - PASS
2023-02-25 16.47.03 - Reindex - MakeBackup com.plexapp.plugins.library.db - PASS
2023-02-25 16.47.03 - Reindex - MakeBackup com.plexapp.plugins.library.blobs.db - PASS
2023-02-25 16.47.03 - Reindex - MakeBackup - PASS
2023-02-25 16.47.52 - Reindex - Reindex: com.plexapp.plugins.library.db - PASS
2023-02-25 16.47.52 - Reindex - Reindex: com.plexapp.plugins.library.blobs.db - PASS
2023-02-25 16.47.52 - Reindex - PASS
2023-02-25 16.47.52 - Reindex - PASS
2023-02-25 16.47.52 - Auto    - PASS
2023-02-25 16.48.04 - StartPMS  - PASS
2023-02-25 16.48.05 - Exit    - Delete temp files.
2023-02-25 16.48.05 - Session end.

```

# Command Reference:

### Automatic

  Automatic provides automated processing of most checks and repairs.  (Check, Repair/Resequence, Index)
  In its current state,  it will not automatically replace a damaged database from a backup (future)

  It will not stop PMS as not all systems support stopping PMS from within this tool.

### Check

  Checks the integrity of the Plex main and blobs databases.

  Also performs FTS (Full-Text Search) index integrity checks. FTS indexes can become
  corrupted even when standard integrity checks pass, causing operations like adding
  items to collections to fail with "database disk image is malformed" errors.

  If FTS corruption is detected, use 'reindex' (option 6) or 'automatic' (option 2)
  to rebuild the FTS indexes.

### Deflate

  Repairs a known error in the PMS main database "statistics_bandwidth" table.
  After repairing it,  it purges all the errant data from the table (reducing DB size)

  This task can take a significant amount of time.  It's frequently used when the DB size is an order of magnitude above what it should be (e.g.  31 GB vs 206 MB).  Reductions from 134 GB to 210 MB have been realized.

### Exit

  Exits the utility and removes all temporary database files created during processing.
  To save all intermediate databases,  use the 'Quit' command.

### Ignore / Honor

  Toggle the state (ON/OFF) of the IGNORE flag. When ON, Duplicates and UNIQUE constraint errors will be ignored.
  Caution is advised as other errors will be ignored during initial processing.

  In ALL cases,  DBRepair will never allow a bad database to be created.

### Import

  Imports (raw) watch history from another PMS database without ability to check validity
  ( This can have side effects of "negative watch count" being displayed.   Caution is advised. )

### Prune (Remove)

  Checks the PhotoTransoder cache directory for JPG, JPEG, and PNG files older than 30 days and removes them.
  Under normal operation,  PMS manages this automatically.
  Under certain conditions, PMS will fail to prune them  (which is run during Scheduled Maintenance)
  This command allows you to manually remove what PMS would do normally during that Scheduled Maintenance.

#### Warning: Initial pruning might take longer than expected.
  Execution time, using a  Synology DS418 as benchmark, is approximately 100,000 image files per 2 minutes.



  For now, Both forms "Prune" and "Remove" are accepted.

### Reindex

  Rebuilds the database indexes after an import, repair, or replace operation.
  These indexes are used by PMS for searching (both internally and your typed searches)

  Also checks FTS (Full-Text Search) index integrity and rebuilds if corruption is detected.
  FTS indexes can become corrupted even when standard integrity checks pass, causing
  "database disk image is malformed" errors during UPDATE operations (e.g., adding items
  to collections, updating metadata).

### Repair

  Extracts/recovers all the usable data from the existing databases into text (SQL ascii) form.
  Repair then creates new SQLite-valid databases from the extracted/recovered data.

  The side effect of this process is a fully defragmented database (optimal for Plex use).

  100% validity/usability by Plex  is not guaranteed as the tool cannot validate each individual
  record contained in the database.  It can only validate at the SQLite level.

  In most cases, Repair is the preferred option as the records extracted are only those SQLite deemed valid.

### Replace

  Looks through the list of available PMS backups.

  Starting with the most recent PMS backup,
    1.  Check the both db files
    2.  If valid, offer as a replacement choice
    3.  If accepted (Y/N question) then use as the replacement
        else advance to the next available backup
    4.  Upon completion, validate one final time.

### Quit

   Exits the utility but leaves the temporary databases intact (useful for making exhaustive backups)

### Show

  Shows the activity log.  The activity log is date/time stamped of all activity.

### Start

  On platform environments which support it, and when invoked by the 'root' user, the tool can start PMS.
  If not the 'root' user or on a platform which doesn't support it, "Not available" will be indicated.

### Stop

  On platform environments which support it,  and when invoked by the 'root' user,  the tool can stop PMS.
  If not the 'root' user or on a platform which doesn't support it, "Not available" will be indicated.

  PMS must be in the stopped state in order to operate on the database files.

#### Stopping / Starting in Containers  (Special Considerations)

  Stopping/starting PMS in containers depends on the container execution control mechanism

  Some images are designed with an "Always Running" philosophy and do not allow the tool to stop/
  start PMS while under program control.

  In these image types,  the only mechanism,  subject to time constraints of any health check,
  is to type:  kill -15 $(pidof 'Plex Media Server')
  at the container command line prior to invoking DBRepair.sh and waiting for PMS to shutdown.

  After DB tasks are completed, and you've exited the container,  restart it normally through
  your normal 'docker start' mechanism.

  If your container (Image) supports start/stop ,  it will be shown in the menu for you to use.
  If not,  you'll need to disable health checks before safely running this tool.


### Undo

  Undo allows you to "Undo" the last Import, Repair, Replace, or Vacuum command.
  At present, it only allows the ONE most recent operation.
  (Future will support undoing more actions)

### Vacuum

  Instructs SQLite to remove the empty/deleted records and gaps from the databases.
  This is most beneficial after deleting whole library sections.

  For most users, the "automatic" command is the best method. It will regenerate the SQLite indexes
  as part of the process.

# Environment Variables

  DBRepair now supports the use of environment variables to allow customization of some operations.

####  WARNING:  Use of these variables may adverse impact PMS operation or performance.  USE WITH CAUTION.

## DBREPAIR_CACHEAGE - Specify the maximum age for PhotoTrancoder Cache images to be retained

  Default DBREPAIR_CACHEAGE is set at 30 days.

  You may override this by setting  DBREPAIR_CACHEAGE=N,  where N is the number of days worth of cache image
  you wish to retain.

  When using interactively,  DBRepair will prompt you to confirm OK to remove and show you the cache age

  Example:  export DBREPAIR_CACHEAGE=20
  ```
  Enter command # -or- command name (4 char min) : remove

  Counting how many files are more than 20 days old.
  OK to prune 4497 files?  (Y/N) ?
  ```

## DBREPAIR_PAGESIZE - Allows setting the Plex SQLite 'page_size'.

  Normal Linux (ext4, xfs) filesystems do not need this customization because the filesystem block size = 4096.
  ZFS users sometimes need to customize their datasets to improve I/O performance (HDDs vs SSDs).
  This capability allows them to compensate for some of those losses.

  If present, sets the Plex SQLite 'page_size' for both Main and Blobs databases.
  If not present, the default page size for the host OS is used (typically 4096 to match the OS page size).

  When in use, you will see the message:  "Setting Plex SQLite page size ($DbPageSize)"
  This will be shown on the console output and reported in the logfile.


### Constraints:

    1.  Must be a power of 2, with 1024 (2^10) as the Plex default.  (per SQLite 3.12.0 documentation).
        Any invalid value provided will be rounded up to the next integral value (1024, 2048, 4096 ... 65536)
        This may or may not be the value you intended.  Caution is advised.

    2.  May not exceed 65536  (per SQLite 3.12.0 documentation).
        Any value exceeding 65536 will be truncated to 65536.

### Validation

  If the value of DBREPAIR_PAGESIZE is not compliant with requirements, a new value will be selected.

  Typing errors will be rounded up (e.g 65535 vs 65536) to the next multiple of 1024 before validation
  is performed.

  If the value is invalid, an error will be printed and recorded in the logfile. The next higher power
  of two will be selected.

  If the value is too large, it will be reduced to the SQLite maximum of 65536.

### Management

  If you attempt to optimize your database but find the resultant performance is not to your liking,
  you may try another value and run "automatic" again.

  If you ultimately decide to run with the default values (4096),
  1.  Remove the environment variable.
  2.  Run DBRepair again using "automatic".  Your databases will revert to the host OS's default.

### Usage:  (QNAP example shown)

```
# export DBREPAIR_PAGESIZE=65534
# ./DBRepair.sh stop deflate auto start exit



      Database Repair Utility for Plex Media Server  (QNAP)
                       Version v1.12.00


[2025-10-21 16.54.00] PMS already stopped.

[2025-10-21 16.54.00] Check and Deflate started.
[2025-10-21 16.54.00]
[2025-10-21 16.54.00] Checking the PMS databases
[2025-10-21 16.54.19] Check complete.  PMS main database is OK.
[2025-10-21 16.54.21] Check complete.  PMS blobs database is OK.
[2025-10-21 16.54.21]
[2025-10-21 16.54.21] Backup current databases with '-BACKUP-2025-10-21_16.54.21' timestamp.
[2025-10-21 16.56.29] Starting Deflate (Part 1 of 2 - Repair database table)
[2025-10-21 16.56.29] Estimated completion is approx 6 minutes but is CPU & I/O speed dependent
[2025-10-21 16.56.29]
[2025-10-21 16.56.30] PMS main database successfully repaired.
[2025-10-21 16.56.30] Starting Deflate (Part 2 of 2 - Reduce size)
[2025-10-21 16.56.35] PMS main database size reduced.
[2025-10-21 16.56.35] Verifying PMS main database.
[2025-10-21 16.56.50] Verification complete.  PMS main database is OK.
[2025-10-21 16.56.50] PMS main database reduced from 31586 MB to 206 MB
[2025-10-21 16.56.51] Saving current main database with '-BLOATED-2025-10-21_16.54.21'
[2025-10-21 16.56.51] Making deflated database active
[2025-10-21 16.56.51] PMS main database deflate completed.
[2025-10-21 16.56.51] Deflate successful.
[2025-10-21 16.56.51] Recommend running Auto next to complete optimization of new database.

[2025-10-21 16.56.51] Automatic Check,Repair,Index started.
[2025-10-21 16.56.51]
[2025-10-21 16.56.51] Checking the PMS databases
[2025-10-21 16.57.04] Check complete.  PMS main database is OK.
[2025-10-21 16.57.05] Check complete.  PMS blobs database is OK.
[2025-10-21 16.57.05]
[2025-10-21 16.57.05] Exporting current databases using timestamp: 2025-10-21_16.56.51
[2025-10-21 16.57.05] Exporting Main DB
[2025-10-21 16.57.24] Exporting Blobs DB
[2025-10-21 16.59.18] Successfully exported the main and blobs databases.
[2025-10-21 16.59.18] Start importing into new databases.
[2025-10-21 16.59.18] Importing Main DB.
[2025-10-21 16.59.18] Setting Plex SQLite page size (65536)
[2025-10-21 17.00.19] Importing Blobs DB.
[2025-10-21 17.00.19] Setting Plex SQLite page size (65536)
[2025-10-21 17.00.32] Successfully imported databases.
[2025-10-21 17.00.32] Verifying databases integrity after importing.
[2025-10-21 17.01.59] Verification complete.  PMS main database is OK.
[2025-10-21 17.02.01] Verification complete.  PMS blobs database is OK.
[2025-10-21 17.02.01] Saving current databases with '-BACKUP-2025-10-21_16.56.51'
[2025-10-21 17.02.01] Making repaired databases active
[2025-10-21 17.02.01] Repair complete. Please check your library settings and contents for completeness.
[2025-10-21 17.02.01] Recommend:  Scan Files and Refresh all metadata for each library section.
[2025-10-21 17.02.01]
[2025-10-21 17.02.01] Backing up of databases
[2025-10-21 17.02.01] Backup current databases with '-BACKUP-2025-10-21_17.02.01' timestamp.
[2025-10-21 17.02.02] Reindexing main database
[2025-10-21 17.02.13] Reindexing main database successful.
[2025-10-21 17.02.13] Reindexing blobs database
[2025-10-21 17.02.14] Reindexing blobs database successful.
[2025-10-21 17.02.14] Reindex complete.
[2025-10-21 17.02.14] Automatic Check, Repair/optimize, & Index successful.

[2025-10-21 17.02.14] Starting PMS.
[2025-10-21 17.02.14] Started PMS

#
```

# Special considerations - MANUAL CONFIGURATION

  Manual configuration is enabled by supplying two command line arguments.
  These must precede all other options or commands on the command line.

  --sqlite "Directory containing Plex SQLite"   (OR)   --sqlite  "/path/to/Plex SQLite"

  Scripted Example:

  DBRepair.sh --sqlite /usr/lib/plexmediaserver --databases "/real/host/directory/...../Databases" auto prune
  -or-
  DBRepair.sh --sqlite "/tmp/plex/Plex SQLite" --databases "/real/host/directory/...../Databases" auto prune

  Interactive Example:

  DBRepair.sh --sqlite /usr/lib/plexmediaserver --databases /real/host/directory/...../Databases

## Manual Configuration --  Example of using with docker.

1.  I find the SQLite executable
```
root@Jasper:/mnt/disk1/appdata# find /var/lib/docker -name \*SQLite\*
/var/lib/docker/btrfs/subvolumes/4bb78fb70589d4d2ba56754f4d6bc0edd4cdaa8eab7986943767e09a66cefd19/usr/lib/plexmediaserver/Plex SQLite
/var/lib/docker/btrfs/subvolumes/eae4fef243ca71fbf190957256705fdc493863ee1f08222a7df0b5004cc8afb6-init/usr/lib/plexmediaserver/Plex SQLite
/var/lib/docker/btrfs/subvolumes/eae4fef243ca71fbf190957256705fdc493863ee1f08222a7df0b5004cc8afb6/usr/lib/plexmediaserver/Plex SQLite
root@Jasper:/mnt/disk1/appdata#
```

2.  I get to where my container is
```
root@Jasper:~# cd /mnt/user
root@Jasper:/mnt/user# ls
Media/  appdata/  domains/  isos/  plex/  system/
root@Jasper:/mnt/user# cd appdata
root@Jasper:/mnt/user/appdata# ls
PlexMediaServer/
root@Jasper:/mnt/user/appdata# cd PlexMediaServer/
```

3.  Invoke DBRepair.sh with both --sqlite and --databases command line options specified (both are required when either is used)
```
root@Jasper:/mnt/user/appdata/PlexMediaServer# /tmp/DBRepair.sh --databases /mnt/user/appdata/PlexMediaServer/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/ --sqlite /var/lib/docker/btrfs/subvolumes/4bb78fb70589d4d2ba56754f4d6bc0edd4cdaa8eab7986943767e09a66cefd19/usr/lib/plexmediaserver/



      Database Repair Utility for Plex Media Server (User Defined)
                       Version v1.09.00

      PlexSQLite = '/var/lib/docker/btrfs/subvolumes/4bb78fb70589d4d2ba56754f4d6bc0edd4cdaa8eab7986943767e09a66cefd19/usr/lib/plexmediaserver//Plex SQLite'
      Databases  = '/mnt/user/appdata/PlexMediaServer/Library/Application Support/Plex Media Server/Plug-in Support/Databases/'

Select

  1 - 'stop'      - (Not available. Stop manually.)
  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step.
  3 - 'check'     - Perform integrity check of database.
  4 - 'vacuum'    - Remove empty space from database without optimizing.
  5 - 'repair'    - Repair/Optimize databases.
  6 - 'reindex'   - Rebuild database indexes.
  7 - 'start'     - (Not available. Start manually)

  8 - 'import'    - Import watch history from another database independent of Plex. (risky).
  9 - 'replace'   - Replace current databases with newest usable backup copy (interactive).
 10 - 'show'      - Show logfile.
 11 - 'status'    - Report status of PMS (run-state and databases).
 12 - 'undo'      - Undo last successful command.

 21 - 'prune'     - Prune (remove) old image files (jpeg,jpg,png) from PhotoTranscoder cache older than specific age.
 22 - 'purge'     - Purge (remove) all temporary files left by PMS & Transcoder in Temp Dir.'
 23 - 'deflate'   - Deflate a bloated PMS main database.


 42 - 'ignore'    - Ignore duplicate/constraint errors.

 88 - 'update'    - Check for updates.
 98 - 'quit'      - Quit immediately.  Keep all temporary files.
 99 - 'exit'      - Exit with cleanup options.

Enter command # -or- command name (4 char min) :
```



# Special considerations - Synology DSM 7

  Using DBRepair on Synology DSM 7 systems with Task Scheduler requires special handling.
  DSM 7 has additional security (app-armor).   Care must be taken to not violate this.

  One exception must be implemented.  Care must be used to implement.

### DSM 7 - Step 1 - Designate a DSM username which will run DBRepair
    - Creating a to-task username with a complex password is best practice
    - Create a Scheduled task, user-script:
      -  Runs as root
      -  Emails you the result
      -  Is not scheduled
      -  Is disabled in the Task Scheduler task list

    Contents of the user-script are:
```
#!/bin/bash
#
# This script grants the given syno username (your username)
# the ability to elevate to 'root' privilege for use with DBRepair.sh
#
# Set your desired Syno username here (no spaces in the username)
MyUsername="chuck"

# Confirm username exists
if [ "$(id "$MyUsername")" = "" ]; then
  echo ERROR:  No such user \'$MyUsername\'
  exit 1
fi

# Remove old record
sed -i s/^${MyUsername}.\*$// /etc/sudoers

# Add myself to sudoers
echo "$MyUsername" 'ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
```
### DSM 7 - Step 2 - Run DBRepair as the designated username

  With the security now set,  DBRepair can be invoked from Task Scheduler.

  Download and place DBRepair.sh in the desired location (PlexMediaServer shared folder ok)
  Make certain it's executable.

  Create Scheduled Task - User-Script to run DBRepair
  -  Runs as the selected username
  -  Emails you the result
  -  Runs on the schedule you desire (Weekly after PMS scheduled tasks completed is optimal)
```
#!/bin/bash

# Go to the PlexMediaServer shared folder
cd /var/packages/PlexMediaServer/shares/PlexMediaServer

# Run classic  Stop PMS, Automatic optimization/repair, Start PMS, and exit  sequence
sudo ./DBRepair.sh stop auto start exit
```



# Special Considerations - Windows

Windows support is available via DBRepair-Windows.ps1 and DBRepair-Windows.bat. See [README-Windows](Windows/README-Windows.md) for details.
