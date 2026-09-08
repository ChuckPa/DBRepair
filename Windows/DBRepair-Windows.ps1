#########################################################################
# Database check and repair utility script for Plex Media Server        #
#                                                                       #
#########################################################################

$DBRepairVersion = 'v1.02.00'

class DBRepair {
    [DBRepairOptions] $Options

    [string] $PlexDBDir # Path to Plex's Databases directory
    [string] $PlexCache # Path to the PhotoTranscoder directory
    [string] $PlexSQL   # Path to 'Plex SQLite.exe'
    [string] $Timestamp # Timestamp used for temporary database files
    [string] $LogFile   # Path of our log file
    [string] $Version   # Current script version
    [string] $Stage     # Current stage of the script (e.g. "Auto", "Prune", etc.)
    [bool]   $IsError   # Whether we're currently in an error state
    [string] $MainDB = "com.plexapp.plugins.library.db"
    [string] $BlobsDB = "com.plexapp.plugins.library.blobs.db"

    DBRepair($Arguments, $Version) {
        $this.Options = [DBRepairOptions]::new()
        $this.Version = $Version
        $this.IsError = $false
        $Commands = $this.PreprocessArgs($Arguments)
        if ($null -eq $Commands) {
            return
        }

        if (!$this.Init()) {
            Write-Host "Unable to initialize script, cannot continue."
            return
        }

        $this.PrintHeader($true)
        $this.MainLoop($Commands)
    }

    [void] PrintHeader([boolean] $WriteToLog) {
        $OS = [System.Environment]::OSVersion.Version
        if ($WriteToLog) {
            $this.WriteLog("============================================================")
            $this.WriteLog("Session start: Host is Windows $($OS.Major) (Build $($OS.Build))")
        }

        Write-Host "`n"
        Write-Host "       Database Repair Utility for Plex Media Server (Windows $($OS.Major), Build $($OS.Build))"
        Write-Host "                                 Version $($this.Version)                                "
        Write-Host
    }

    [void] PrintHelp() {
        # -Help doesn't write to the log, since our log file path isn't set.
        $this.PrintHeader($false)
        Write-Host "When run without arguments, starts an interactive session that displays available options"
        Write-Host "and lets you select the operations you want to perform. Or, to run tasks automatically,"
        Write-Host "provide them directly to the script, e.g. '.\DBRepair-Windows.ps1 Stop Prune Start Exit'"
        Write-Host
        $this.PrintOptions("Main Options")
        Write-Host
        Write-Host "Extra Options - These can only be specified once (last one wins)"
        Write-Host
        Write-Host " -CacheAge [int]  - The date cutoff for pruned images. Defaults to pruning images over 30"
        Write-Host "                    days old."
        Write-Host
    }

    [void] PrintMenu() {
        $this.PrintOptions("Select")
    }

    [void] PrintOptions([string]$Header) {
        # NOTE: While Windows only supports a subset of DBRepair.sh's features, keep the command
        # numbers the same as we attempt to reach feature parity
        Write-Host
        Write-Host $Header
        Write-Host
        Write-Host "  1 - 'stop'      - Stop PMS."
        Write-Host "  2 - 'automatic' - Check, Repair/Optimize, and Reindex Database in one step."
        Write-Host
        Write-Host "  7 - 'start'     - Start PMS"
        Write-Host
        Write-Host " 21 - 'prune'     - Prune (remove) old image files (jpeg,jpg,png) from PhotoTranscoder cache."
        if ($this.Options.IgnoreErrors) {
            Write-Host " 42 - 'honor'     - Honor all database errors."
        } else {
            Write-Host " 42 - 'ignore'    - Ignore duplicate/constraint errors."
        }
        Write-Host
        Write-Host " 98 - 'quit'      - Quit immediately.  Keep all temporary files."
        Write-Host " 99   'exit'      - Exit with cleanup options."
        Write-Host
        Write-Host "      'menu x'    - Show this menu in interactive mode, where x is on/off/yes/no"
    }

    # Do initial parsing of arguments that aren't part of the loop, returning
    # the list of arguments that _should_ be processed in the loop.
    #
    # E.g. given "Stop Prune CacheAge 20 Start", this function will set the CacheAge
    # to 20, and return "Stop Prune Start"
    [System.Collections.ArrayList] PreprocessArgs([string[]] $Arguments) {
        $FinalArgs = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $Arguments.Count; ++$i) {
            switch -Regex ($Arguments[$i]) {
                '^-?(H(elp)?|\?)$' {
                    if ($Arguments.Count -gt 1) {
                        Write-Warning "Found -Help, ignoring extra arguments"
                    }

                    $this.PrintHelp()
                    return $null
                }
                '^-?CacheAge$' {
                    if ($i -eq $Arguments.Count - 1) {
                        Write-Warning "Found -CacheAge argument, but no value. Using default of 30 days"
                        Break
                    }

                    ++$i
                    $Age = $Arguments[$i]
                    if (!($Age -match "^\d+$")) {
                        Write-Warning "Invalid -CacheAge value '$Age'. Using default of 30 days"
                        Break
                    }

                    $this.Options.CacheAge = [int]$Age
                }

                Default { $FinalArgs.Add($_) }
            }
        }

        return $FinalArgs
    }

    # Setup variables required for this utility to work.
    [bool] Init() {
        $this.Timestamp = Get-Date -Format HH-mm-ss

        $AppData = $this.GetAppDataDir()
        $Success = $this.GetPlexDBDir($AppData) -and $this.GetPlexSQL() -and $this.GetPhotoTranscoderDir($AppData)
        if ($Success) {
            $this.LogFile = Join-Path $this.PlexDBDir -ChildPath "DBRepair.log"
        }

        return $Success
    }

    # Core routine that loops over all provided commands and executes them in order.
    [void] MainLoop([System.Collections.ArrayList] $Arguments) {
        $this.Options.Scripted = $Arguments.Count -ne 0
        $i = 0
        $Argc = $Arguments.Count
        $NullInput = 0
        $EOFExit = $false
        while ($true) {
            $Choice = $null
            if ($this.Options.Scripted) {
                if ($i -eq $Argc) {
                    $Choice = "exit"
                } else {
                    $Choice = $Arguments[$i++]
                }
            } else {
                if ($this.Options.ShowMenu) {
                    $this.PrintMenu()
                }

                Write-Host
                $Choice = Read-Host "Enter command # -or- command name (4 char min)"
                if ($Choice -eq "") {
                    ++$NullInput
                    if ($NullInput -eq 5) {
                        $this.Output("Unexpected EOF / End of command line options. Exiting. Keeping temp files. ")
                        $Choice = "exit"
                        $EOFExit =  $true
                    } else {
                        if ($NullInput -eq 4) {
                            Write-Warning "Next empty command exits as EOF.  "
                        }

                        continue
                    }
                } else {
                    $NullInput = 0
                }
            }

            # Update timestamp
            $this.Timestamp = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'

            switch -Regex ($Choice) {
                "^(1|stop)$" { $this.DoStop() }
                "^(2|autom?a?t?i?c?)$" {
                    $this.SetStage("Auto")
                    $this.IsError = !$this.RunAutomaticDatabaseMaintenance()
                }
                "^(7|start?)$" { $this.StartPMS() }
                "^(21|(prune?|remov?e?))$" {
                    $this.SetStage("Prune")
                    $this.PrunePhotoTranscoderCache()
                }
                "^(42|ignor?e?|honor?)$" {
                    if (($this.Options.IgnoreErrors -and ($Choice[0] -eq 'i')) -or (!$this.Options.IgnoreErrors -and ($Choice[0] -eq 'h'))) {
                        Write-Host "Honor/Ignore setting unchanged."
                        Break
                    }

                    $this.Options.IgnoreErrors = !$this.Options.IgnoreErrors
                    $msg = if ($this.Options.IgnoreErrors) { "Ignoring database errors." } else { "Honoring database errors." }
                    $this.WriteOutputLog($msg)
                }
                "^(98|quit)$" {
                    $this.Output("Retaining all temporary work files.")
                    $this.WriteLog("Exit    - Retain temp files.")
                    $this.WriteEnd()
                    return
                }
                "^(99|exit)$" {
                    if ($EOFExit) {
                        $this.Output("Unexpected exit command. Keeping all temporary work files.")
                        $this.WriteLog("EOFExit  - Retain temp files.")
                        return
                    }

                    # If our last DB operation failed, we don't want to automatically delete
                    # temporary files when in scripted mode.
                    if ($this.IsError -and $this.Options.Scripted) {
                        $this.Output("Exiting with errors. Keeping all temporary work files.")
                        $this.WriteLog("Exit    - Retain temp files.")
                        return
                    }

                    $this.CleanDBTemp(!$this.Options.Scripted)
                    $this.WriteEnd()
                    return
                }
                "^menu\b" {
                    $Match = $Choice -match "^menu\s+(on|off|yes|no)"
                    if (!$Match) {
                        $this.OutputWarn("Invalid 'menu' format. Expected 'menu on/off/yes/no', got '$Choice'")
                        Break
                    }

                    $TurnOn = ($Matches.1 -eq 'on') -or ($Matches.1 -eq 'yes');
                    $this.Options.ShowMenu = $TurnOn
                    if (!$TurnOn) {
                        Write-Host "Menu off: Reenable with 'menu on' command"
                    }
                }
                Default {
                    $this.OutputWarn("Unknown Command: '$Choice'")
                    $this.WriteLog("Unknown command:   '$Choice'")
                }
            }
        }
    }

    # Attempt to stop Plex Media Server if it's running
    [void] DoStop() {
        $this.WriteLog("Stop    - START")
        $PMS = $this.GetPMS()
        if ($null -eq $PMS) {
            $this.Output("PMS already stopped.")
            return
        }

        $this.Output("Stopping PMS.")

        # Plex doesn't respond to CloseMainWindow because it doesn't have a window,
        # and Stop-Process does a forced exit of the process, so use taskkill to ask
        # PMS to close nicely, and bail if that doesn't work.
        $ErrorText = $null
        Invoke-Expression "taskkill /im ""Plex Media Server.exe""" 2>$null -ErrorVariable ErrorText
        if ($ErrorText) {
            $this.WriteOutputLogWarn("Failed to send terminate signal to PMS, please stop manually.")
            $this.WriteOutputLogWarn($ErrorText -join "`n")
            return
        }

        $PMS.WaitForExit(30000) *>$null # Wait at most 30 seconds for PMS to close. If it still hasn't by then, bail.
        if ($PMS.HasExited) {
            $this.WriteLog("Stop    - PASS")
            $this.Output("Stopped PMS.")
            return
        }

        $this.OutputWarn("Could not stop PMS. PMS did not shutdown within 30 second limit.")
        $this.WriteLog("Stop    - FAIL (Timeout)")
    }

    # Start Plex Media Server if it isn't already running
    [void] StartPMS() {
        $this.WriteLog("Start   - START")
        if ($this.PMSRunning()) {
            $this.Output("Start not needed. PMS is running.")
            $this.WriteLog("Start   - PASS - PMS is already running")
            return
        }

        $PMS = Join-Path (Split-Path -Parent $this.PlexSQL) -ChildPath "Plex Media Server.exe"
        try {
            Start-Process $PMS -EA Stop
            $this.Output("Started PMS")
            $this.WriteLog("Start   - PASS")
        } catch {
            $Err = $Error -join "`n"
            $this.OutputWarn("Could not start PMS: $Err")
            $Error.Clear()
        }
    }

    # All-in-one database utility - Repair/Check/Reindex
    [bool] RunAutomaticDatabaseMaintenance() {
        $this.Output("Automatic Check,Repair,Index started.")
        $this.WriteLog($this.StageLog("START"))

        if ($this.PMSRunning()) {
            $this.WriteLog($this.StageLog("FAIL - PMS running"))
            $this.OutputWarn("Unable to run automatic sequence.  PMS is running. Please stop PlexMediaServer.")
            return $false
        }

        # Create temporary backup directory
        $DBTemp = Join-Path $this.PlexDBDir -ChildPath "dbtmp"
        if (!$this.DirExists($DBTemp)) {
            $TempDirError = $null
            New-Item -Path $DBTemp -ItemType "directory" -ErrorVariable tempDirError *>$null
            if ($TempDirError) {
                $this.ExitDBMaintenance("Unable to create temporary database directory", $false)
                return $false
            }
        }

        $this.Output("Exporting Main DB")
        $MainDBPath = Join-Path $this.PlexDBDir -ChildPath $this.MainDB
        $MainDBSQL = Join-Path $DBTemp -ChildPath "library.sql_$($this.TimeStamp)"
        if (!$this.FileExists($MainDBPath)) {
            $this.ExitDBMaintenance("Could not find $($this.MainDB) in database directory", $false)
            return $false
        }

        if (!$this.ExportPlexDB($MainDBPath, $MainDBSQL)) { return $false }

        $this.Output("Exporting Blobs DB")
        $BlobsDBPath = Join-Path $this.PlexDBDir -ChildPath $this.BlobsDB
        $BlobsDBSQL = Join-Path $DBTemp -ChildPath "blobs.sql_$($this.Timestamp)"
        if (!$this.FileExists($BlobsDBPath)) {
            $this.ExitDBMaintenance("Could not find $($this.BlobsDB) in database directory", $false)
            return $false
        }

        if (!$this.ExportPlexDB($BlobsDBPath, $BlobsDBSQL)) { return $false }

        $this.Output("Successfully exported the main and blobs databases. Proceeding to import into new database.")
        $this.WriteLog("Repair  - Export databases - PASS")

        # Make sure Plex hasn't been started while we were exporting
        if (!$this.CheckPMS("export")) { return $false }

        $this.Output("Importing Main DB.")
        $MainDBImport = Join-Path $this.PlexDBDir -ChildPath "$($this.MainDB)_$($this.Timestamp)"
        if (!$this.ImportPlexDB($MainDBSQL, $MainDBImport)) { return $false }
        
        $this.Output("Importing Blobs DB.")
        $BlobsDBImport = Join-Path $this.PlexDBDir -ChildPath "$($this.BlobsDB)_$($this.Timestamp)"
        if (!$this.ImportPlexDB($BlobsDBSQL, $BlobsDBImport)) { return $false }

        $this.Output("Successfully imported databases.")
        $this.WriteLog("Repair  - Import - PASS")

        $this.Output("Verifying databases integrity after importing.")

        if (!$this.IntegrityCheck($MainDBImport, "Main")) { return $false }
        $this.Output("Verification complete. PMS main database is OK.")
        $this.WriteLog("Repair  - Verify main database - PASS")

        if (!$this.IntegrityCheck($BlobsDBImport, "Blobs")) { return $false }
        $this.Output("Verification complete. PMS blobs database is OK.")
        $this.WriteLog("Repair  - Verify blobs database - PASS")

        if (!$this.CheckPMS("import")) { return $false }

        # Import complete, now reindex
        $this.WriteOutputLog("Reindexing Main DB")
        if (!$this.RunSQLCommand("""$MainDBImport"" ""REINDEX;""", "Failed to reindex Main DB")) { return $false }
        $this.WriteOutputLog("Reindexing Blobs DB")
        if (!$this.RunSQLCommand("""$BlobsDBImport"" ""REINDEX;""", "Failed to reindex Blobs DB")) { return $false }
        $this.WriteOutputLog("Reindexing complete.")

        # Rebuild the FTS indexes.  The dump/reload copies the FTS shadow tables verbatim, so this
        # must be done on the newly built databases before they are made active.
        $this.WriteOutputLog("Rebuilding FTS indexes")
        if (!$this.RebuildFTS($MainDBImport, "Main")) { return $false }
        if (!$this.RebuildFTS($BlobsDBImport, "Blobs")) { return $false }
        $this.WriteOutputLog("FTS index rebuild complete.")

        $this.WriteOutputLog("Moving current DBs to DBTMP and making new databases active")
        if (!$this.CheckPMS("new database copy")) { return $false }

        try {
            $this.MoveDatabase($MainDBPath, (Join-Path $DBTemp -ChildPath "$($this.MainDB)_$($this.Timestamp)"), "move Main DB to DBTMP")
            $this.MoveDatabase($MainDBImport, $MainDBPath, "replace Main DB with rebuilt DB")
    
            $this.MoveDatabase($BlobsDBPath, (Join-Path $DBTemp -ChildPath "$($this.BlobsDB)_$($this.Timestamp)"), "move Blobs DB to DBTMP")
            $this.MoveDatabase($BlobsDBImport, $BlobsDBPath, "replace Blobs DB with rebuilt DB")
        } catch {
            $Error.Clear()
            return $false
        }

        $this.ExitDBMaintenance("Database repair/rebuild/reindex completed.", $true)
        return $true
    }

    # Return whether we can continue DB repair (i.e. whether PMS is running) at the given stage in the process.
    [bool] CheckPMS([string] $SubStage) {
        if ($this.PMSRunning()) {
            $SubMessage = if ($SubStage) { "during $SubStage" } else { "" }
            $this.WriteLog($this.StageLog("FAIL - PMS running $SubMessage"))
            $this.OutputWarn("Unable to run $($this.Stage.TrimEnd()).  PMS is running. Please stop PlexMediaServer.")
            return $false
        }

        return $true
    }

    # Try to move the source file to the destination. If it fails, attempt to find
    # open file handles (requires handle.exe on PATH) and throw.
    [void] MoveDatabase([string] $Source, [string] $Destination, [string] $FriendlyString) {
        $MoveError = $null
        Move-Item -Path $Source -Destination $Destination -ErrorVariable MoveError *>$null
        if ($MoveError) {
            $this.ExitDBMaintenance("Unable to $($FriendlyString): $MoveError", $false)
            throw "Unable to move database"
        }
    }

    # Attempts to prune PhotoTranscoder images that are older than the specified date cutoff (30 days by default)
    [void] PrunePhotoTranscoderCache() {
        $this.WriteLog($this.StageLog("START"))
        if ($this.PMSRunning()) {
            $this.OutputWarn("Unable to prune Phototranscoder cache. PMS is running.")
            $this.WriteLog($this.StageLog("FAIL - PMS running"))
            return
        }

        $Cutoff = $this.Options.CacheAge
        $ShouldPrune = $this.Options.Scripted
        if (!$ShouldPrune) {
            $this.Output("Counting how many files are more than $Cutoff days old")
            $CacheResult = $this.CheckPhotoTranscoderCache($true)
            $Prunable = $CacheResult.PrunableFiles
            $SpaceSaved = $CacheResult.SpaceSavings

            if ($Prunable -eq 0) {
                $this.Output("No files found to prune.")
                $this.WriteLog($this.StageLog("PASS (no files found to prune)"))
                return
            }

            $ShouldPrune = $this.GetYesNo("OK to prune $Prunable files ($SpaceSaved)")
        }

        if ($ShouldPrune) {
            $this.Output("Pruning started.")
            $PruneResult = $this.CheckPhotoTranscoderCache($false)
            $Pruned = $PruneResult.PrunableFiles
            $Total = $PruneResult.TotalFiles
            $Saved = $PruneResult.SpaceSavings
            $this.WriteOutputLog($this.StageLog("Removed $Pruned files over $Cutoff days old ($Saved), out of $Total total files"))
            $this.Output("Pruning completed.")
        } else {
            $this.WriteOutputLog($this.StageLog("Prune cancelled by user"))
        }

        $this.WriteLog($this.StageLog("PASS"))
    }

    # Traverses PhotoTranscoder cache to find and delete files older than the specified max age.
    # If $DryRun is $true, don't remove items, just gather statistics.
    [CleanCacheResult] CheckPhotoTranscoderCache([bool] $DryRun) {
        $Cutoff = (Get-Date).AddDays(-$this.Options.CacheAge);
        $AllFiles = 0;
        $OldFiles = 0;
        $FreedBytes = 0;
        Get-ChildItem -Path $this.PlexCache -Recurse -File |
        Where-Object { $_.extension -in '.jpg','.jpeg','.png','.ppm' } |
        ForEach-Object {
            $AllFiles++;
            if ($_.LastWriteTime -lt $Cutoff) {
                $OldFiles++;
                $FreedBytes += $_.Length;
                if (!$DryRun) {
                    Remove-Item $_.FullName;
                }
            }
        };

        return [CleanCacheResult]::new($AllFiles, $OldFiles, $FreedBytes)
    }

    ### Helpers ###

    ### Logging Helpers ###

    [string] Now() { return Get-Date -Format 'yyyy-MM-dd HH.mm.ss' }

    # Write the given text to the console
    [void] Output([string] $Text) {
        if ($this.Options.Scripted) {
            Write-Host "$($this.Now()) $Text"
        } else {
            Write-Host $Text
        }
    }

    # Write the given text as a warning in the console
    [void] OutputWarn([string] $Text) {
        if ($this.Options.Scripted) {
            Write-Warning "$($this.Now()) $Text"
        } else {
            Write-Warning $Text
        }
    }

    # Write the given text to the log file
    [void] WriteLog([string] $Text) {
        Add-Content -Path $this.LogFile -Value "$($this.Now()) -- $($Text)"
    }

    # Write the given text to the log file and console
    [void] WriteOutputLog([string] $Text) {
        $this.WriteLog($Text)
        $this.Output($Text)
    }

    # Write the given text to the log file and as warning text in the console
    [void] WriteOutputLogWarn([string] $Text) {
        $this.WriteLog($Text)
        $this.OutputWarn($Text)
    }

    # Write out the end of the session
    [void] WriteEnd() {
        $this.WriteLog("Session end. $(Get-Date)")
        $this.WriteLog("============================================================")
    }

    # Set the current stage (with the right amount of padding)
    [void] SetStage([string] $Stage) {
        $this.Stage = $Stage + (" " * [math]::Max(0, 8 - $Stage.Length))
    }

    # Prepend the current stage to the given text
    [string] StageLog([string] $text) {
        return "$($this.Stage) - $text"
    }

    ### File Helpers ###

    # Check whether the given directory exists (and is a directory)
    [bool] DirExists([string] $Dir) {
        if ($Dir) {
            return Test-Path $Dir -PathType Container
        }

        return $false
    }

    # Check whether the given file exists (and is a file)
    [bool] FileExists([string] $File) {
        if ($File) {
            return Test-Path $File -PathType Leaf
        }

        return $false
    }

    ### Setup Helpers ###

    # Retrieve Plex's data directory, exiting the script on failure
    [string] GetAppDataDir() {
        $PMSRegistry = $this.GetHKCU()
        $PlexAppData = $PMSRegistry.LocalAppDataPath
        if ($PlexAppData) {
            $PlexAppData = Join-Path -Path $PlexAppData -ChildPath "Plex Media Server"
        }

        if ($this.DirExists($PlexAppData)) {
            return $PlexAppData
        }

        $PlexAppData = "$env:LOCALAPPDATA\Plex Media Server"
        if ($this.DirExists($PlexAppData)) {
            return $PlexAppData
        }

        Write-Host "Could not determine Plex data directory, cannot continue"
        Write-Host "Normally $env:LOCALAPPDATA\Plex Media Server"
        exit
    }

    # Retrieve PMS settings under HKEY_CURRENT_USER, exiting the script on failure
    [PSCustomObject] GetHKCU() {
        try {
            return (Get-ItemProperty -path 'HKCU:\Software\Plex, Inc.\Plex Media Server' -EA Stop)
        } catch {
            Write-Warning "Could not find Plex registry settings (HKCU\Software\Plex, Inc.\Plex Media Server). Are you sure Plex is installed on this machine?"
            exit
        }
    }

    # Set the Plex database directory, returning whether we found the directory
    [bool] GetPlexDBDir([string] $AppData) {
        $DBDir = Join-Path -Path $AppData -ChildPath "Plug-in Support\Databases"
        if ($this.DirExists($DBDir)) {
            $this.PlexDBDir = $DBDir;
            return $true;
        }

        Write-Host "Could not find Databases folder, cannot continue."
        Write-Host "Normally $DBDir"
        return $false
    }

    # Set the path to Plex's PhotoTranscoder cache, returning whether we found the directory.
    [bool] GetPhotoTranscoderDir([string] $AppData) {
        $CacheDir = Join-Path -Path $AppData -ChildPath "Cache\PhotoTranscoder"
        if ($this.DirExists($CacheDir)) {
            $this.PlexCache = $CacheDir
            return $true
        }

        Write-Host "Could not find PhotoTranscoder path, cannot prune."
        Write-Host "Normally $CacheDir"
        return $false
    }

    # Find the path to Plex SQLite.exe, falling back to user input if necessary.
    [bool] GetPlexSQL() {
        $PMSRegistry = $this.GetHKCU()
        $InstallDir = $PMSRegistry.InstallFolder
        if (!$InstallDir) {
            # Install location might also be in HKLM
            $InstallDir = (Get-ItemProperty -path 'HKLM:\SOFTWARE\Plex, Inc.\Plex Media Server' -EA Ignore).InstallFolder
            if (!$InstallDir) {
                # Final registry attempt - WOW6432Node
                $InstallDir = (Get-ItemProperty -path 'HKLM:\SOFTWARE\WOW6432Node\Plex, Inc.\Plex Media Server' -EA Ignore).InstallFolder
            }
        }

        $SQL = if ($InstallDir) { Join-Path -Path $InstallDir -ChildPath "Plex SQLite.exe" } else { $null }
        if ($this.FileExists($SQL)) {
            $this.PlexSQL = $SQL
            return $true
        }

        # Still couldn't find install directory. Try standard PROGRAMFILES variables
        $SQL = "$env:PROGRAMFILES\Plex\Plex Media Server\Plex SQ Lite.exe"
        if ($this.FileExists($SQL)) {
            $this.PlexSQL = $SQL
            return $true
        }

        if (${env:PROGRAMFILES(X86)}) {
            $SQL = "${env:PROGRAMFILES(X86)}\Plex Plex Media Server\Plex SQLite.exe"
            if ($this.FileExists($SQL)) {
                Write-Host "Note: 32-bit version of PMS detected on a 64-bit version of Windows. Using the 64-bit release of PMS is recommended."
                $this.PlexSQL = $SQL
                return $true
            }
        }

        Write-Host "Could not determine Plex SQLite location. Please provide it below"
        Write-Host "Normally $env:PORGRAMFILES\Plex\Plex Media Server\Plex SQLite.exe"
        $First = $true
        while (!$this.FileExists($SQL)) {
            if (!$First) {
                Write-Host "ERROR: '$SQL' could not be found"
            }

            $First = $false
            $SQL = Read-Host -Prompt "Path to Plex SQLite.exe (Ctrl+C to cancel): "
        }

        $this.PlexSQL = $SQL
        return $true
    }

    ### Database Helpers ###

    # Writes to output/log when we're done with database maintenance (on success or failure)
    [void] ExitDBMaintenance([string] $Message, [boolean] $Success) {
        if ($Success) {
            $this.Output("Automatic Check,Repair,Index succeeded.")
            $this.WriteLog($this.StageLog("PASS"))
        } else {
            $this.OutputWarn("Database maintenance failed - $Message")
            $this.WriteLog($this.StageLog("$Message, cannot continue."))
            $this.WriteLog($this.StageLog("FAIL"))
        }
    }

    [bool] ExportPlexDB([string] $Source, [string] $Destination) {
        return $this.RunSQLCommand("""$Source"" "".output '$Destination'"" .dump", "Failed to export '$Source' to '$Destination'")
    }

    # Run an SQL command.
    # ErrorMessage is the message to output/write to the log on failure
    [bool] RunSQLCommand([string] $Command, [string] $ErrorMessage) {
        return $this.RunSQLCommandCore($Command, $ErrorMessage, $null)
    }

    # Run an SQL command and retrieve the output of said command
    # ErrorMessage is the message to output/write to the log on failure
    [bool] GetSQLCommandResult([string] $Command, [string] $ErrorMessage, [ref] $Output) {
        return $this.RunSQLCommandCore($Command, $ErrorMessage, $Output)
    }

    # Run a 'Plex SQLite' command
    [bool] RunSQLCommandCore([string] $Command, [string] $ErrorMessage, [ref] $Output) {
        $SqlError = $null
        $SqlResult = $null
        $ExitCode = 0
        try {
            Invoke-Expression "& ""$($this.PlexSQL)"" $Command" -ev sqlError -OutVariable sqlResult -EA Stop *>$null
            $ExitCode = $LASTEXITCODE
        } catch {
            $Err = $Error -join "`n"
            $this.ExitDBMaintenance("Failed to run command '$Command': '$Err'", $false)
            $Error.Clear()
            return $false
        }

        if ($SqlError -or $ExitCode) {
            $Err = $SqlError -join "`n"
            if (!$Err) { $Err = "Process exited with error code $ExitCode" }
            $Msg = $ErrorMessage
            if (!$Msg) {
                $Msg = "Plex SQLite operation failed"
            }

            if ($this.Options.IgnoreErrors -and $this.Options.CanIgnore) {
                $this.OutputWarn("Ignoring database errors - ${Msg}: $Err")
            } else {
                $this.ExitDBMaintenance("${Msg}: $Err", $false)
                return $false
            }
        }

        if ($null -ne $Output.Value) {
            $Output.Value = $SqlResult
        }

        return $true
    }

    # Import an exported .sql file into a new database
    [bool] ImportPlexDB($Source, $Destination) {
        # SQLite's .read can't handle files larger than 2GB on versions <3.45.0 (https://sqlite.org/forum/forumpost/9af57ba66fbb5349),
        # and Plex SQLite is currently on 3.39.4 (as of PMS 1.41.6).
        # If the source is smaller than 2GB we can .read it directly, otherwise do things in a more roundabout way.
        if ($this.FileExists($Source) -and (Get-Item $Source).Length -lt 2GB) {
            return $this.RunSQLCommand("""$Destination"" "".read '$Source'""", "Failed to import Plex database (importing '$Source' into '$Destination')")
        }

        $ImportError = $null
        $ExitCode = 0
        $Err = $null
        try {
            # Use Start-Process, since PowerShell doesn't have '<', and alternatives ("Get-Content X | SQLite.exe OutDB") are subpar at best when dealing with large files like these database exports.
            $process = Start-Process $this.PlexSQL -ArgumentList @("""$Destination""") -RedirectStandardInput $Source -NoNewWindow -Wait -PassThru -EA Stop -ErrorVariable ImportError
            $ExitCode = $process.ExitCode
        } catch {
            $Err = $Error -join "`n"
            $Error.Clear()
        }

        if ($ImportError) {
            $Err = $ImportError -join "`n"
        } elseif ($ExitCode) {
            if ($this.Options.IgnoreErrors) {
                $this.OutputWarn("Ignoring errors found during import")
            } else {
                $Err = "Process exited with error code $ExitCode (constraint error?)"
            }
        }

        if ($Err) {
            $this.ExitDBMaintenance("Failed to import Plex database (importing '$Source' into '$Destination'): $Err", $false)
            return $false
        }

        return $true
    }

    [bool] IntegrityCheck([string] $Database, [string] $DbName) {
        $this.Options.CanIgnore = $false
        $VerifyResult = ""
        $result = $this.GetSQLCommandResult("""$Database"" ""PRAGMA integrity_check(20)""", "Failed to verify $dbName DB", [ref]$VerifyResult)
        if ($result) {
            $Lines = @($VerifyResult) | Where-Object { $_ -and "$_".Trim() -ne "" }
            $Findings = @($Lines | Where-Object { "$_".Trim() -ne "ok" })
            $this.Output("$DbName DB verification check is: $($Lines -join '; ')")

            if ($Findings.Count -gt 0) {
                # Since SQLite 3.44 (PMS 1.43+), integrity_check also validates the content of FTS3/FTS4
                # virtual tables.  Those findings ('...inverted index...') are FTS index drift, not
                # database corruption, and are corrected by RebuildFTS - not by the dump/reload.
                $NonFTS = @($Findings | Where-Object { "$_" -notmatch 'inverted index' })
                if ($NonFTS.Count -eq 0) {
                    $this.OutputWarn("$DbName DB FTS indexes need rebuilding (this is not database corruption): $($Findings -join '; ')")
                    $this.WriteLog("Repair  - Verify $DbName database - FTS rebuild needed: $($Findings -join '; ')")
                } else {
                    $this.ExitDBMaintenance("$DbName DB verification failed: $($NonFTS -join '; ')", $false)
                    $result = $false
                }
            }
        }

        $this.Options.CanIgnore = $true
        return $result
    }

    # Rebuild the FTS4 indexes of the given database.
    # A dump/reload copies the FTS shadow tables verbatim, so any drift survives the repair and must
    # be rebuilt explicitly.  Only a failing 'integrity-check' after the rebuild fails the run.
    [bool] RebuildFTS([string] $Database, [string] $DbName) {
        $TableResult = ""
        $TableQuery = "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE 'CREATE VIRTUAL TABLE%fts4%'"
        if (!$this.GetSQLCommandResult("""$Database"" ""$TableQuery""", "Failed to list FTS tables in $DbName DB", [ref]$TableResult)) {
            return $false
        }

        $Tables = @($TableResult) | Where-Object { $_ -and "$_".Trim() -ne "" }
        if ($Tables.Count -eq 0) {
            $this.WriteOutputLog("No FTS4 tables found in $DbName DB.")
            return $true
        }

        foreach ($Table in $Tables) {
            $Table = "$Table".Trim()
            $this.WriteOutputLog("Rebuilding FTS index '$Table' in $DbName DB")
            if (!$this.RunSQLCommand("""$Database"" ""INSERT INTO $Table($Table) VALUES('rebuild');""", "Failed to rebuild FTS index '$Table' in $DbName DB")) {
                return $false
            }

            $this.Options.CanIgnore = $false
            $CheckResult = ""
            $Verified = $this.GetSQLCommandResult("""$Database"" ""INSERT INTO $Table($Table) VALUES('integrity-check');""", "FTS index '$Table' in $DbName DB is still damaged after rebuilding", [ref]$CheckResult)
            $this.Options.CanIgnore = $true

            if (!$Verified) { return $false }
        }

        $this.WriteLog("Repair  - Rebuild FTS indexes ($DbName) - PASS")
        return $true
    }

    # Clear out the temp database directory. If $Confirm is $true, asks the user before doing so.
    [void] CleanDBTemp([bool] $Confirm) {
        if ($Confirm -and !$this.GetYesNo("Ok to remove temporary databases/workfiles for this session")) {
            $this.Output("Retaining all temporary work files.")
            $this.WriteLog("Exit    - Retain temp files.")
            return
        }

        $DBTemp = Join-Path $this.PlexDBDir -ChildPath "dbtmp"
        if ($this.DirExists($DBTemp)) {
            try {
                Remove-Item $DBTemp -Recurse -Force -EA Stop
                $this.Output("Deleted all temporary work files.")
                $this.WriteLog("Exit    - Deleted temp files.")
            } catch {
                $Err = $Error -join "`n"
                $this.OutputWarn("Failed to remove temporary directory: $Err")
                $this.WriteLog("Exit    - Failed to remove temporary files: $Err")
                $Error.Clear()
            }
        }
    }

    ### Miscellaneous Helpers ###

    # Return whether PMS is running
    [bool] PMSRunning() {
        return $null -ne $this.GetPMS()
    }

    # Retrieve the PMS process, if running
    [System.Diagnostics.Process] GetPMS() {
        return Get-Process -EA Ignore -Name "Plex Media Server"
    }

    # Ask the user a yes or no question, continuing to prompt them until
    # their input starts with either a 'Y' or 'N'
    [bool] GetYesNo([string] $Prompt) {
        $Response = (Read-Host "$Prompt [Y/N]? ").ToLower()
        $Ch = $Response.Substring(0, [Math]::Min($Response.Length, 1))
        while (($Ch -ne "y") -and ($Ch -ne "n")) {
            Write-Host "Invalid input, please enter [Y]es or [N]o"
            $Response = (Read-Host "$Prompt [Y/N]? ").ToLower()
            $Ch = $Response.Substring(0, [Math]::Min($Response.Length, 1))
        }

        return $Ch -eq "y"
    }
}

# Contains miscellaneous options/state over the course of a session.
class DBRepairOptions {
    [bool] $Scripted # Whether we're running in scripted or interactive mode
    [bool] $ShowMenu # Whether to show the menu after each command executes
    [bool] $IgnoreErrors # Whether to honor or ignore constraint errors on import
    [bool] $CanIgnore # Some errors can't be ignored (e.g. integrity_check)
    [int32] $CacheAge # The date cutoff for pruning PhotoTranscoder cached images

    DBRepairOptions() {
        $this.CacheAge = 30
        $this.ShowMenu = $true
        $this.Scripted = $false
        $this.IgnoreErrors = $false
        $this.CanIgnore = $true
    }
}

# Contains relevant data about a PhotoTranscoder `prune` attempt
class CleanCacheResult {
    [int32] $TotalFiles    # Total number of PhotoTranscoder files
    [int32] $PrunableFiles # Total number of files that are older than the cutoff
    [string] $SpaceSavings # Friendly string of (potential) space savings

    CleanCacheResult([int32] $TotalFiles, [int32] $PrunableFiles, [int32] $PrunableBytes) {
        $this.TotalFiles = $TotalFiles
        $this.PrunableFiles = $PrunableFiles
        $this.SpaceSavings = "$($PrunableBytes) bytes"

        if ($PrunableBytes -gt 1GB) {
            $this.SpaceSavings = "$([math]::round($PrunableBytes / 1GB, 2)) GiB";
        } elseif ($PrunableBytes -gt 1MB) {
            $this.SpaceSavings = "$([math]::round($PrunableBytes / 1MB, 2)) MiB";
        } elseif ($PrunableBytes -gt 1KB) {
            $this.SpaceSavings = "$([math]::round($PrunableBytes / 1KB, 2)) KiB";
        }
    }
}

# Ensure the console can handle utf-8, as the export process pipes utf-8 data from the console to our temporary sql file.
$InputEncodingSave = [console]::InputEncoding
$OutputEncodingSave = [console]::OutputEncoding
[console]::InputEncoding = [console]::OutputEncoding = New-Object System.Text.UTF8Encoding

[void]([DBRepair]::new($args, $DBRepairVersion))

[console]::OutputEncoding = $OutputEncodingSave
[console]::InputEncoding = $InputEncodingSave
