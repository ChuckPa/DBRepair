# DBRepair (for Plex Media Server)

[![GitHub issues](https://img.shields.io/github/issues/ChuckPa/DBRepair.svg?style=flat)](https://github.com/ChuckPa/DBRepair/issues)
[![Release](https://img.shields.io/github/release/ChuckPa/DBRepair.svg?style=flat)](https://github.com/ChuckPa/DBRepair/releases/latest)
[![Download latest release](https://img.shields.io/github/downloads/ChuckPa/DBRepair/latest/total.svg)](https://github.com/ChuckPa/DBRepair/releases/latest)
[![Download total](https://img.shields.io/github/downloads/ChuckPa/DBRepair/total.svg)](https://github.com/ChuckPa/DBRepair/releases)
[![Main](https://img.shields.io/badge/Main-stable-green.svg?maxAge=2592000)](https://github.com/ChuckPa/DBRepair/tree/main)
![Maintenance](https://img.shields.io/badge/Maintained-Yes-green.svg)
[![Sponsor ChuckPa](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa.svg?style=flat&logo=github)](https://github.com/sponsors/ChuckPa)


## DBREPAIR IS BACK!


DBRepair has been completely rewritten from scratch for all supported platforms as a free-standing, no external dependencies, executable program.

`DBRepair.sh` is now fully obsolete and removed from use.   Please delete any copies/forks you may have and switch to the new version (does what the scripts could not)

> **🎉 FreeBSD Users:** Beginning with DBRepair 26.11.00, FreeBSD 14+ (x86_64) is supported
> via a native, standalone `DBRepair` executable.
> Just download, extract, and run as root.

> **🎉 Windows Users:** Beginning with DBRepair 26.10.00, Windows is fully supported
> via a native, standalone `DBRepair.exe` executable!
> Previous versions of DBRepair required separate `.bat` or `.ps1` scripts, have now been completely obsoleted.
> Just download, extract, and run.

DBRepair is run from a command line (terminal, Command
Prompt/PowerShell, or ssh/putty session) on the local host machine. It must have
sufficient privileges to read/write the databases. Because DBRepair is
distributed as a compiled executable, it requires no external runtime
dependencies.

If sufficient privileges exist (root/Administrator), and are supported by the environment, the options to start and stop PMS are presented as well.

## Documentation

Full documentation (installation, every menu command, typical usage, command-line options, environment variables, supported hosts) is on the [DBRepair Wiki](https://github.com/ChuckPa/DBRepair/wiki).

  * [Install](https://github.com/ChuckPa/DBRepair/wiki/Install)
  * [Typical Usage](https://github.com/ChuckPa/DBRepair/wiki/Typical-Usage)
  * [Command-Line Options](https://github.com/ChuckPa/DBRepair/wiki/Command-Line-Options)
  * [Supported Hosts](https://github.com/ChuckPa/DBRepair/wiki/Supported-Hosts)
  * [Support](https://github.com/ChuckPa/DBRepair/wiki/Support)

For a complete list of commands in the menu, see: [Menu](https://github.com/ChuckPa/DBRepair/wiki/Menu)

## Situations and errors commonly seen include:

  1. PMS has stopped making automatic backups of your databases.
  2. Searching is sluggish or broken
  3. Database is malformed / damaged / corrupted / bloated
  4. Damaged indexes / Rows out of order
  5. Tables, Indexes, or other items missing from databases (seen in logs)
  6. Importing data from other databases (watch history)
  7. Cleaning up operational temp files which PMS has forgotten
  8. Other maintenance and checks to keep your server running optimally

## Getting Started

### Downloading

#### Available Packages

DBRepair is packaged as a `.zip` archive for easy downloading. Each archive
contains the standalone executable for the target platform, along with the
`README.md`, `README.html`, `ReleaseNotes.txt`, and `LICENSE.txt` files.

The following architectures are supported:

* [MacOS - Arm64](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-MacOS-arm64.zip)
* [MacOS - X86_64](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-MacOS-x86_64.zip)
* [Linux - Arm32 (armv7)](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-Linux-arm32.zip)
* [Linux - Arm64 (armv8)](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-Linux-arm64.zip)
* [Linux - X86_64](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-Linux-x86_64.zip)
* [FreeBSD - X86_64](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-FreeBSD-x86_64.zip)
* [Windows - X86_64](https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair-26.11.00-Windows-x86_64.zip)

It is highly recommended to download the packaged `.zip` archive for your system.

Navigate to the latest release:
[DBRepair Latest Release](https://github.com/ChuckPa/DBRepair/releases/latest)
and download the appropriate `.zip` file for your platform from the
**Assets** section.

[Where to install DBRepair](https://github.com/ChuckPa/DBRepair/wiki/Install)

**DBRepair is free but one-time Donations or Sponsorships to defray development costs are always welcomed**

## License

See `LICENSE.txt` for terms of use.