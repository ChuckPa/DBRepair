# DBRepair v1.18.00 — change log against v1.17.01

Branch `pms143-fts` (https://github.com/pwsh/DBRepair) compared with ChuckPa/DBRepair master
at commit b55dc8e (v1.17.01 with the FTS emergency patch).

```
 DBRepair.sh                  | 734 ++++++++++++++++++++++++++-------
 README.md                    |  66 ++--
 ReleaseNotes                 |  66 +++
 Windows/DBRepair-Windows.ps1 |  66 ++-
 Windows/ReleaseNotes-Windows |  10 +
```

## Why anything changed at all

PMS 1.43 replaced the bundled `Plex SQLite` 3.39.4 with 3.53.3. Beginning with SQLite 3.44,
`PRAGMA integrity_check` also validates FTS3/FTS4 virtual tables and reports lines such as

```
malformed inverted index for FTS4 table main.fts4_metadata_titles_icu
```

The very same database file reports `ok` under 3.39.4. This was verified by desyncing one FTS
content row on a copy of a production 1.43.4 database and running both binaries against it.
Nothing about the tokenizer, ICU version (69 in both releases), dump/reload, `REINDEX`, triggers,
or `INSERT OR REPLACE` changed behaviour; all of those were tested across both binaries and pass.

v1.17.01 treated any non-`ok` line from `integrity_check` as structural damage, so a database
with nothing but FTS drift was declared damaged. Its Repair (dump and reload) could not fix it,
because `.dump` copies the FTS shadow tables verbatim and never re-tokenises anything. The
emergency patch then disabled the one operation that would have fixed it, the FTS rebuild.

Every change below follows from that.

---

## DBRepair.sh

### 1. Version and new globals (top of file)

| Change | Explanation |
|---|---|
| `Version="v1.18.00"` | New feature release. |
| `SQLiteVersion`, `SQLiteVersionNum`, `MinSQLiteVersionNum=34400` | Holds the detected Plex SQLite version and the 3.44.0 floor, encoded as `major*10000 + minor*100 + patch` so it can be compared with a plain integer test in POSIX sh. |
| `CheckDBStructural`, `CheckDBFTS`, `CheckDBFTSTables` | Per-call results of `CheckDB`, so callers can tell structural damage from FTS drift and see which tables were named. |
| `FTSDamagedMain`, `FTSDamagedBlobs` | Per-database FTS state, used to rebuild and back up only the database that needs it. |
| `FTS_TRIGGER_QUERY` | Counts how many of the eight PMS 1.43 FTS maintenance triggers exist, built line by line in the same style as `FTS_TABLE_QUERY`. |

### 2. `GetSQLiteVersion()` (new, called right after the "PMS is installed" check)

Runs `select sqlite_version()` through Plex SQLite, logs it on every session start, and exits with
code 3 if it is older than 3.44.0 with a message that PMS 1.42.x and earlier must keep using
v1.17.01. `DBREPAIR_ALLOW_OLD_SQLITE=1` overrides the refusal and the override is logged.

Why: ChuckPa's stated plan is to enforce PMS 1.43+ because the two SQLite generations behave
differently and one script cannot serve both. The floor is expressed as a SQLite version because
that is what actually changed and it is directly observable from the binary.

### 3. `CheckDB()` rewritten

| Before | After |
|---|---|
| `PRAGMA integrity_check(1)` | `PRAGMA integrity_check(20)` |
| any line other than `ok` = failure | every line is classified: lines containing `inverted index` are FTS drift, anything else is structural damage |
| returns 1 on any finding | returns 1 only for structural damage; FTS-only drift returns 0 and sets `CheckDBFTS`, `FTSDamaged`, and the table names |
| no log of the finding | FTS-only findings are logged with the table names |

Why: with a limit of 1 the first line might be an FTS line and mask real corruption, or vice
versa. With 20 lines and classification the tool can say precisely which of the two it found.
Under 3.39.4 no FTS lines can appear, so behaviour there is unchanged apart from the larger limit.

### 4. `CheckDatabases()`

`Damaged` now reflects structural damage only. Each database's `CheckDB` result also sets
`FTSDamagedMain` or `FTSDamagedBlobs`. When drift is seen it prints
"FTS indexes need rebuilding. This is not a damaged database." instead of "database is damaged".

Why: this is the line users saw and the reason the whole database was being reported as damaged.

### 5. `CheckFTS()` split into `CheckFTSDatabase()` plus a wrapper

The main and blobs loops were identical copies. `CheckFTSDatabase <file> <label> <caller>` now
holds one copy, produces byte-identical output and log lines (the "(blobs)" suffix is derived from
the label), and returns 0/1. `CheckFTS` calls it twice and records the per-database flags.
Per-table failures now print "NEEDS REBUILD" when the error text says malformed or corrupt, and
"ERROR (index could not be validated)" otherwise, followed by the raw detail.

Why: removes a duplicated block that had already drifted, and makes "needs rebuild" the message
users see rather than "DAMAGED".

### 6. `RestoreSaved()`

Previously removed the live copy of all six file names and then moved back whichever backups
existed. It now iterates the two databases, skips a database that has no backup, and restores
that database plus its `-wal` and `-shm`.

Why: with the selective FTS backup in item 8, the old code would have deleted the database that
was never backed up. Behaviour is unchanged when both databases were backed up.

### 7. `DoFTSRebuild()`: emergency patch removed, verification added

* The `return 0` that disabled the function is gone.
* Its pre-check still runs `CheckDatabases`; because that no longer fails on FTS drift, a rebuild
  is never blocked by the very condition it fixes. A true structural failure still prompts.
* After rebuilding it runs `CheckFTS` again (the v1.17.01 fix, kept) and then `DoTriggers`.
* Callers no longer append `&& CheckFTS` since the verification moved inside.

Why: the `rebuild` command is the documented remedy for exactly this condition and was verified
safe on the 1.43 tables under 3.53.3.

### 8. `DoFTSRebuild()`: selective backup and rebuild

If only one database is flagged (`FTSDamagedMain` / `FTSDamagedBlobs`), only that database is
backed up with `DoBackup` and rebuilt. If neither flag is set (manual invocation) both are
processed as before. The selected files are logged.

Why: the blobs database is typically 2 to 3 times the size of the main one and its FTS content is
empty; copying it to rebuild an index in the other file cost minutes and gigabytes for nothing.

### 9. `DoTriggers()` (new) and hidden command `31 | trig*`

Checks each database that has `fts4_metadata_titles_icu` for the eight triggers PMS 1.43 uses to
keep the ICU FTS tables in sync with `metadata_items` and `tags`. If fewer than eight exist it
recreates the missing ones with `CREATE TRIGGER IF NOT EXISTS` using the exact SQL PMS creates,
re-counts, and logs the outcome. Refuses to run while PMS is running. Available as hidden menu
command 31 for manual use; it also runs automatically after every FTS rebuild.

Why: if a trigger is missing the rebuilt index silently drifts again as soon as PMS writes. This is
what the upstream author refers to as the `DoTriggers` refactor needed for 1.43.

### 10. `DoRepair()`: FTS warning after verification

When the freshly imported database verifies structurally but still carries FTS drift, the tool now
says so and points at Automatic or Reindex.

Why: a dump/reload preserves drift; users should not assume Repair cleared it.

### 11. Startup banner

`Plex SQLite <version>` is printed under the version line of the banner. The version is also
written to the log at session start.

### 12. Automatic sequence reordered (`2 | auto*`)

| v1.17.01 | v1.18.00 |
|---|---|
| Check (forced) | Check (forced): structural, and under 3.44+ also reveals FTS drift |
| Repair | Rebuild FTS if `FTSDamaged` or `CheckFTS` fails (only the affected database) |
| Reindex | Repair |
| CheckFTS, rebuild if needed (rebuild was a no-op) | Reindex |
| | CheckFTS, rebuild once more if needed |

Why: FTS must be rebuilt before the dump/reload preserves the drift into the new file. Doing the
structural check first means DoFTSRebuild's own pre-check is memoised and the 40-second
integrity pass on both databases runs once, not twice. The final check catches anything the repair
or reindex reintroduced, so Automatic always ends with verified FTS.

### 13. `check` (3), `reindex` (6), `status` (11)

* `check` prints a two-line summary: "Database structure: OK|DAMAGED" and
  "FTS indexes: OK|NEED REBUILD".
* `reindex` keeps its check → rebuild → check tail; `DoIndex`'s pre-check no longer fails on
  drift so it can reach the rebuild.
* `status` reports the Plex SQLite version and derives FTS state from either kind of check.

### 14. Menu and help text

Item 2 now reads "Check, Rebuild FTS, Repair/Optimize, Reindex." and the success line matches.

---

## Windows/DBRepair-Windows.ps1 (v1.01.02 → v1.02.00)

| Change | Explanation |
|---|---|
| `IntegrityCheck()` uses `integrity_check(20)` and splits the output | Same classification as the bash tool: if every finding contains "inverted index" it logs a warning and continues; any other finding still aborts the run. |
| New `RebuildFTS($Database, $DbName)` | Lists FTS4 virtual tables in the newly built database, runs `rebuild` then `integrity-check` on each, and fails the run only if the check still fails. |
| Called for Main and Blobs after REINDEX and before the swap | The Windows port had no FTS handling at all; without this a dump/reload on 1.43 would carry drift into the new file and the new integrity check would flag it. |

---

## README.md

The "SPECIAL ANNOUNCEMENT" block is replaced by a "PMS 1.43+ support (v1.18.00)" section: the
requirement, the SQLite 3.44 explanation above, the override variable, and that 1.42.x users stay
on v1.17.01. Command tables gain `TRIG(gers)` / `31 - 'triggers'`, and item 2's description
matches the new order. The reference to the compiled program now defers to the maintainer's forum
notes rather than speaking for them.

## ReleaseNotes / Windows/ReleaseNotes-Windows

`v1.18.00` and `v1.02.00` entries in the existing style, covering items 2 through 13 above.

---

## Verification performed

* `bash -n`, `dash -n`, `busybox sh -n` pass; no arrays, `[[ ]]`, or other bashisms introduced.
* Stub-SQLite unit runs of `CheckDB`, `GetSQLiteVersion`, `CheckFTSDatabase`, Auto ordering,
  selective backup, and `RestoreSaved` with forced failures.
* Manual-mode runs against a copy of a 1.43.4 production database with two FTS tables desynced
  and one trigger dropped: the 1.42.2 binary is refused; `check` reports structure OK and FTS
  needing rebuild; `auto` rebuilds and verifies FTS, recreates the trigger, completes repair and
  reindex, and finishes with a clean integrity check. One integrity pass per Automatic run.
* Production run inside a plexinc Docker container on PMS 1.43.4: completed; post-run database
  identical in schema, triggers, row counts, and content checksums to the pre-run original, with
  only free pages reclaimed.

## Known limitations

* shellcheck was not available during development.
* The PowerShell changes were parse-checked only; they have not been run on a Windows host.
* Not tested on Synology, QNAP, macOS, or FreeBSD hosts; host detection is untouched.
