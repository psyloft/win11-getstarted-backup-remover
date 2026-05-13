# Win11 Get Started / Windows Backup Remover

Remove the **Get Started** and **Windows Backup** entries from **All apps** in the Windows 11 Start Menu.

On some Windows 11 versions, these entries are not standalone Appx packages. Instead, they are registered inside the system package `MicrosoftWindows.Client.CBS`, so the normal `Remove-AppxPackage` method usually does not work. This project provides scripts for backup, removal, cache reset, and restoration.

## Risks

This is not an official Microsoft removal method. The scripts may modify:

```text
C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\AppxManifest.xml
C:\ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd
```

This may affect Windows cumulative updates, the Start Menu, Search, or Appx registration. Please create a backup first, and only use this on devices where you accept the risk.

## File Structure

```text
.
├── README.md
├── scripts/
│   ├── Backup-ClientCBS.ps1
│   ├── Remove-GetStartedWindowsBackup.ps1
│   ├── Reset-StartAppsCache.ps1
│   ├── Restore-ClientCBS.ps1
│   └── Verify-ClientCBS.ps1
├── src/
│   └── ClientCBS.Tools.psm1
├── .gitignore
└── .gitattributes
```

## Usage

Open PowerShell as Administrator and enter the project directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

Check the current state first:

```powershell
.\scripts\Verify-ClientCBS.ps1
```

Create a backup:

```powershell
.\scripts\Backup-ClientCBS.ps1
```

Remove Get Started / Windows Backup:

```powershell
.\scripts\Remove-GetStartedWindowsBackup.ps1
```

If the script indicates that `Get-StartApps` residue needs to be cleaned, try the lower-risk cache reset first:

```powershell
.\scripts\Reset-StartAppsCache.ps1
shutdown /r /t 0
```

If the entries still remain after reboot, run AppRepository cleanup:

```powershell
.\scripts\Remove-GetStartedWindowsBackup.ps1 -SkipBackup -SkipManifest -CleanStartAppsResidue -InstallMySQLite
shutdown /r /t 0
```

`-InstallMySQLite` installs the `MySQLite` PowerShell module for the current user. It is used to safely process a copy of the AppRepository SQLite database.

## Restore

Backups are saved by default in:

```text
backups\ClientCBS-backup-yyyyMMdd-HHmmss\
```

Restore the manifest:

```powershell
.\scripts\Restore-ClientCBS.ps1 -BackupPath .\backups\ClientCBS-backup-yyyyMMdd-HHmmss
shutdown /r /t 0
```

Only restore the AppRepository database when Windows Update, the Start Menu, Search, or Appx registration behaves abnormally:

```powershell
.\scripts\Restore-ClientCBS.ps1 -BackupPath .\backups\ClientCBS-backup-yyyyMMdd-HHmmss -RestoreStateRepository -InstallMySQLite
shutdown /r /t 0
```

If the system has already installed new cumulative updates, restoring an old `.srd` database is not recommended.

## Verification

Run:

```powershell
.\scripts\Verify-ClientCBS.ps1
```

When the removal is successful, the target manifest entries and target `Get-StartApps` entries should no longer be visible:

```text
WebExperienceHost
WindowsBackup
Get Started
Windows Backup
```

## Disclaimer

This project is intended for personal research and system customization. Users are responsible for any Windows update failure, system component issue, or repair cost caused by using this project.
