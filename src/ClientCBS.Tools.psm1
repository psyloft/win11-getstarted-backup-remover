$script:ClientCBSPackageName = "MicrosoftWindows.Client.CBS"
$script:ClientCBSPackageFamilyName = "MicrosoftWindows.Client.CBS_cw5n1h2txyewy"
$script:ClientCBSTargetApplicationIds = @("WebExperienceHost", "WindowsBackup")
$script:ClientCBSTargetAumids = @(
    "MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost",
    "MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup"
)
$script:ClientCBSTargetNamePattern = "Get Started|入门|Windows Backup|Backup|备份"
$script:StateRepositoryPath = "C:\ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"

function Write-ClientCBSStep {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n[+] $Message" -ForegroundColor Cyan
}

function Write-ClientCBSOk {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-ClientCBSWarn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Test-ClientCBSAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-ClientCBSAdministrator {
    if (-not (Test-ClientCBSAdministrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Get-ClientCBSProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-ClientCBSPackage {
    $pkg = Get-AppxPackage -Name $script:ClientCBSPackageName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) {
        throw "Package not found: $($script:ClientCBSPackageName)"
    }
    return $pkg
}

function Get-ClientCBSManifestPath {
    $pkg = Get-ClientCBSPackage
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }
    return $manifestPath
}

function Get-ClientCBSTargetStartApps {
    Get-StartApps -ErrorAction Stop | Where-Object {
        $_.AppID -in $script:ClientCBSTargetAumids -or
        $_.AppID -match "WebExperienceHost|WindowsBackup" -or
        $_.Name -match $script:ClientCBSTargetNamePattern
    }
}

function Get-ClientCBSRegisteredManifestApplications {
    $pkg = Get-ClientCBSPackage

    try {
        [xml]$registeredManifest = Get-AppxPackageManifest -Package $pkg.PackageFullName -ErrorAction Stop
    } catch {
        Write-ClientCBSWarn "Could not read registered package manifest: $($_.Exception.Message)"
        return @()
    }

    @($registeredManifest.Package.Applications.Application) |
        Where-Object { $_.Id -in $script:ClientCBSTargetApplicationIds } |
        Select-Object Id, Executable, EntryPoint, AppListEntry
}

function Show-ClientCBSState {
    [CmdletBinding()]
    param()

    Write-ClientCBSStep "MicrosoftWindows.Client.CBS package"
    $pkg = Get-ClientCBSPackage
    $pkg | Format-List Name, PackageFullName, Version, Status, InstallLocation, NonRemovable

    Write-ClientCBSStep "Target applications in registered manifest"
    $manifestApps = @(Get-ClientCBSRegisteredManifestApplications)
    if ($manifestApps.Count -gt 0) {
        $manifestApps | Format-Table -AutoSize
    } else {
        Write-Host "No target manifest applications found."
    }

    Write-ClientCBSStep "Target entries returned by Get-StartApps"
    $startApps = @(Get-ClientCBSTargetStartApps)
    if ($startApps.Count -gt 0) {
        $startApps | Format-Table Name, AppID -AutoSize
    } else {
        Write-Host "No target Start menu entries found."
    }
}

function Grant-ClientCBSAdminAccess {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }

    & takeown.exe /F $Path /A | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-ClientCBSWarn "takeown returned non-zero for: $Path"
    }

    & icacls.exe $Path /grant "*S-1-5-32-544:F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-ClientCBSWarn "icacls grant returned non-zero for: $Path"
    }
}

function Restore-ClientCBSTrustedInstallerOwner {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        & icacls.exe $Path /setowner "NT SERVICE\TrustedInstaller" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-ClientCBSWarn "Could not restore TrustedInstaller owner: $Path"
        }
    }
}

function Add-ClientCBSMoveFileExType {
    if (-not ("ClientCBS.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace ClientCBS {
    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    }
}
"@
    }
}

function Schedule-ClientCBSRebootReplace {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-ClientCBSMoveFileExType

    $flags = 0x1 -bor 0x4
    $ok = [ClientCBS.NativeMethods]::MoveFileEx($Source, $Destination, $flags)
    if (-not $ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "MoveFileEx scheduled replace failed. Win32Error=$err Source=$Source Destination=$Destination"
    }
}

function Schedule-ClientCBSRebootDelete {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-ClientCBSMoveFileExType

    $ok = [ClientCBS.NativeMethods]::MoveFileEx($Path, $null, 0x4)
    if (-not $ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-ClientCBSWarn "MoveFileEx scheduled delete failed. Win32Error=$err Path=$Path"
    }
}

function Stop-ClientCBSShell {
    Write-ClientCBSStep "Stopping shell processes"
    foreach ($processName in @("StartMenuExperienceHost", "ShellExperienceHost", "SearchHost", "RuntimeBroker", "explorer")) {
        Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
    }
}

function Restart-ClientCBSShell {
    [CmdletBinding()]
    param()

    Stop-ClientCBSShell
    Write-ClientCBSStep "Starting explorer"
    Start-Process explorer.exe
}

function Clear-ClientCBSStartCaches {
    [CmdletBinding()]
    param()

    Write-ClientCBSStep "Clearing Start menu and icon caches"

    $patterns = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start*.bin",
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Caches\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache*"
    )

    foreach ($pattern in $patterns) {
        Remove-Item $pattern -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Reset-ClientCBSStartAppsCache {
    [CmdletBinding()]
    param([switch]$NoRestartExplorer)

    Assert-ClientCBSAdministrator

    Write-ClientCBSStep "Current Get-StartApps result"
    $before = @(Get-ClientCBSTargetStartApps)
    if ($before.Count -gt 0) {
        $before | Format-Table Name, AppID -AutoSize
    } else {
        Write-Host "No target Start menu entries found."
    }

    Write-ClientCBSStep "Confirming Client.CBS registered manifest"
    $manifestApps = @(Get-ClientCBSRegisteredManifestApplications)
    if ($manifestApps.Count -gt 0) {
        Write-ClientCBSWarn "Registered manifest still contains target Application entries. Remove manifest entries first."
        $manifestApps | Format-Table -AutoSize
    } else {
        Write-ClientCBSOk "Registered manifest does not contain WebExperienceHost / WindowsBackup Application entries."
    }

    Stop-ClientCBSShell
    Start-Sleep -Seconds 2

    Write-ClientCBSStep "Resetting StartMenuExperienceHost and ShellExperienceHost packages"
    $resetCommand = Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue
    if ($resetCommand) {
        foreach ($packageName in @("Microsoft.Windows.StartMenuExperienceHost", "Microsoft.Windows.ShellExperienceHost")) {
            try {
                $package = Get-AppxPackage $packageName -ErrorAction SilentlyContinue
                if ($package) {
                    Write-Host "Reset-AppxPackage: $packageName"
                    $package | Reset-AppxPackage
                } else {
                    Write-ClientCBSWarn "Package not found: $packageName"
                }
            } catch {
                Write-ClientCBSWarn "Reset failed for $packageName : $($_.Exception.Message)"
            }
        }
    } else {
        Write-ClientCBSWarn "Reset-AppxPackage is not available on this system. Skipping package reset."
    }

    Write-ClientCBSStep "Renaming Start and Shell cache folders"
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $cachePaths = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState",
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState",
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\AC",
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy\LocalState",
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy\TempState",
        "$env:LOCALAPPDATA\Packages\Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy\AC",
        "$env:LOCALAPPDATA\Microsoft\Windows\Caches"
    )

    foreach ($path in $cachePaths) {
        if (Test-Path -LiteralPath $path) {
            $newLeaf = (Split-Path -Leaf $path) + ".old_$stamp"
            $newPath = Join-Path (Split-Path -Parent $path) $newLeaf
            try {
                Rename-Item -LiteralPath $path -NewName $newLeaf -Force
                Write-Host "Renamed: $path -> $newPath"
            } catch {
                Write-ClientCBSWarn "Could not rename $path : $($_.Exception.Message)"
            }
        } else {
            Write-Host "Not found: $path"
        }
    }

    Write-ClientCBSStep "Clearing Explorer icon and thumbnail caches"
    foreach ($pattern in @(
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache*"
    )) {
        try {
            Remove-Item $pattern -Force -ErrorAction SilentlyContinue
            Write-Host "Removed pattern: $pattern"
        } catch {
            Write-ClientCBSWarn "Could not remove pattern $pattern : $($_.Exception.Message)"
        }
    }

    Write-ClientCBSStep "Re-registering StartMenuExperienceHost and ShellExperienceHost manifests"
    foreach ($packageName in @("Microsoft.Windows.StartMenuExperienceHost", "Microsoft.Windows.ShellExperienceHost")) {
        try {
            $package = Get-AppxPackage $packageName -ErrorAction SilentlyContinue
            if ($package) {
                $manifestPath = Join-Path $package.InstallLocation "AppxManifest.xml"
                if (Test-Path -LiteralPath $manifestPath) {
                    Write-Host "Register: $manifestPath"
                    Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ForceApplicationShutdown -ErrorAction Continue
                }
            }
        } catch {
            Write-ClientCBSWarn "Register failed for $packageName : $($_.Exception.Message)"
        }
    }

    if (-not $NoRestartExplorer) {
        Write-ClientCBSStep "Starting explorer"
        Start-Process explorer.exe
        Start-Sleep -Seconds 5
    }

    Write-ClientCBSStep "Checking Get-StartApps again"
    $after = @(Get-ClientCBSTargetStartApps)
    if ($after.Count -gt 0) {
        $after | Format-Table Name, AppID -AutoSize
        Write-ClientCBSWarn "Entries are still visible in this session. Run a full reboot: shutdown /r /t 0"
    } else {
        Write-ClientCBSOk "Get Started / Windows Backup are no longer listed by Get-StartApps."
    }

    [pscustomobject]@{
        BeforeCount = $before.Count
        AfterCount = $after.Count
        RebootRecommended = $after.Count -gt 0
    }
}

function Import-ClientCBSSqliteModule {
    [CmdletBinding()]
    param([switch]$InstallMySQLite)

    if (Get-Module -Name MySQLite) {
        return
    }

    if (Get-Module -ListAvailable -Name MySQLite) {
        Import-Module MySQLite -ErrorAction Stop
        return
    }

    if (-not $InstallMySQLite) {
        throw "PowerShell module MySQLite is required for StateRepository operations. Install it manually with: Install-Module MySQLite -Scope CurrentUser, or rerun this script with -InstallMySQLite."
    }

    Write-ClientCBSWarn "Installing MySQLite from PSGallery for the current user."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null

    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    $restoreUntrusted = $false
    if ($repo -and $repo.InstallationPolicy -ne "Trusted") {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        $restoreUntrusted = $true
    }

    try {
        Install-Module MySQLite -Scope CurrentUser -Force -AllowClobber
    } finally {
        if ($restoreUntrusted) {
            Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted
        }
    }

    Import-Module MySQLite -ErrorAction Stop
}

function Invoke-ClientCBSSqliteQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Query
    )

    Invoke-MySQLiteQuery -Path $Path -Query $Query -ErrorAction Stop
}

function Test-ClientCBSTableExists {
    param([string]$Path, [string]$Table)

    $escaped = $Table.Replace("'", "''")
    $result = Invoke-ClientCBSSqliteQuery -Path $Path -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='$escaped';"
    return [bool]$result
}

function Test-ClientCBSColumnExists {
    param([string]$Path, [string]$Table, [string]$Column)

    if (-not (Test-ClientCBSTableExists -Path $Path -Table $Table)) {
        return $false
    }

    $columns = Invoke-ClientCBSSqliteQuery -Path $Path -Query "PRAGMA table_info([$Table]);"
    return @($columns | Where-Object { $_.name -eq $Column }).Count -gt 0
}

function ConvertTo-ClientCBSNumberList {
    param($Items)

    $numbers = @(
        $Items |
            Where-Object { $_ -ne $null -and "$_" -ne "" } |
            ForEach-Object { [int]$_ } |
            Select-Object -Unique
    )

    if ($numbers.Count -eq 0) {
        return ""
    }

    return ($numbers -join ",")
}

function Quote-ClientCBSSqlName {
    param([string]$Name)
    return "[" + ($Name -replace "\]", "]]") + "]"
}

function Escape-ClientCBSSqlString {
    param([string]$Text)
    return $Text.Replace("'", "''")
}

function Remove-ClientCBSSqlRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Table,
        [Parameter(Mandatory = $true)][string]$Where
    )

    if (-not (Test-ClientCBSTableExists -Path $Path -Table $Table)) {
        Write-Host "Skip missing table: $Table"
        return 0
    }

    $before = @(Invoke-ClientCBSSqliteQuery -Path $Path -Query "SELECT COUNT(*) AS C FROM [$Table] WHERE $Where;")
    $beforeCount = 0
    if ($before.Count -gt 0) {
        $beforeCount = [int]$before[0].C
    }

    Invoke-ClientCBSSqliteQuery -Path $Path -Query "DELETE FROM [$Table] WHERE $Where;" | Out-Null

    $after = @(Invoke-ClientCBSSqliteQuery -Path $Path -Query "SELECT COUNT(*) AS C FROM [$Table] WHERE $Where;")
    $afterCount = 0
    if ($after.Count -gt 0) {
        $afterCount = [int]$after[0].C
    }

    $deleted = $beforeCount - $afterCount
    Write-Host ("Deleted from {0}: {1}" -f $Table, $deleted)
    return $deleted
}

function Select-ClientCBSSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Query
    )

    try {
        return @(Invoke-ClientCBSSqliteQuery -Path $Path -Query $Query)
    } catch {
        Write-ClientCBSWarn "Query failed: $($_.Exception.Message)"
        return @()
    }
}

function New-ClientCBSStateRepositoryBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [switch]$InstallMySQLite
    )

    $method = "DirectCopy"

    try {
        Import-ClientCBSSqliteModule -InstallMySQLite:$InstallMySQLite
        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force
        }

        $escaped = Escape-ClientCBSSqlString $DestinationPath
        Invoke-ClientCBSSqliteQuery -Path $SourcePath -Query "VACUUM INTO '$escaped';" | Out-Null
        $method = "VacuumInto"
    } catch {
        Write-ClientCBSWarn "Could not create SQLite-consistent StateRepository backup: $($_.Exception.Message)"
        Write-ClientCBSWarn "Falling back to direct file copy. This may not include WAL-visible changes."
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force

        foreach ($sidecar in @("$SourcePath-wal", "$SourcePath-shm", "$SourcePath-journal")) {
            if (Test-Path -LiteralPath $sidecar) {
                Copy-Item -LiteralPath $sidecar -Destination (Join-Path (Split-Path -Parent $DestinationPath) (Split-Path -Leaf $sidecar)) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    [pscustomobject]@{
        Path = $DestinationPath
        Method = $method
    }
}

function Backup-ClientCBS {
    [CmdletBinding()]
    param(
        [string]$BackupRoot = (Join-Path (Get-ClientCBSProjectRoot) "backups"),
        [switch]$InstallMySQLite
    )

    Assert-ClientCBSAdministrator

    Write-ClientCBSStep "Creating backup directory"
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupDir = Join-Path $BackupRoot ("ClientCBS-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $pkg = Get-ClientCBSPackage
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    $manifestBackup = Join-Path $backupDir "AppxManifest.Client.CBS.backup.xml"
    $stateRepoBackup = Join-Path $backupDir "StateRepository-Machine.srd.backup"

    Write-ClientCBSStep "Backing up AppxManifest.xml"
    Copy-Item -LiteralPath $manifestPath -Destination $manifestBackup -Force

    Write-ClientCBSStep "Backing up StateRepository-Machine.srd"
    if (-not (Test-Path -LiteralPath $script:StateRepositoryPath)) {
        throw "StateRepository database not found: $($script:StateRepositoryPath)"
    }
    $stateBackup = New-ClientCBSStateRepositoryBackup -SourcePath $script:StateRepositoryPath -DestinationPath $stateRepoBackup -InstallMySQLite:$InstallMySQLite

    $metadata = [ordered]@{
        CreatedAt = (Get-Date).ToString("o")
        PackageName = $pkg.Name
        PackageFullName = $pkg.PackageFullName
        Version = [string]$pkg.Version
        Architecture = [string]$pkg.Architecture
        InstallLocation = $pkg.InstallLocation
        ManifestBackup = "AppxManifest.Client.CBS.backup.xml"
        StateRepositoryBackup = "StateRepository-Machine.srd.backup"
        StateRepositoryBackupMethod = $stateBackup.Method
    }

    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupDir "metadata.json") -Encoding UTF8

    Write-ClientCBSOk "Backup created: $backupDir"
    return Get-Item -LiteralPath $backupDir
}

function Remove-ClientCBSManifestApplications {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string[]]$ApplicationIds = $script:ClientCBSTargetApplicationIds,
        [switch]$NoRestartShell
    )

    Assert-ClientCBSAdministrator

    $pkg = Get-ClientCBSPackage
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"

    Write-ClientCBSStep "Reading AppxManifest.xml"
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($manifestPath)

    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($applicationId in $ApplicationIds) {
        $nodes = @($xml.SelectNodes("//*[local-name()='Applications']/*[local-name()='Application'][@Id='$applicationId']"))
        foreach ($node in $nodes) {
            [void]$node.ParentNode.RemoveChild($node)
            [void]$removed.Add($applicationId)
        }
    }

    if ($removed.Count -eq 0) {
        Write-ClientCBSWarn "No target Application nodes were found in the manifest."
        return [pscustomobject]@{
            ManifestPath = $manifestPath
            RemovedApplications = @()
            Changed = $false
        }
    }

    $tempManifest = Join-Path $env:TEMP ("ClientCBS-AppxManifest-" + [guid]::NewGuid().ToString("N") + ".xml")
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $false
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::None

    $writer = [System.Xml.XmlWriter]::Create($tempManifest, $settings)
    try {
        $xml.Save($writer)
    } finally {
        $writer.Close()
    }

    if ($PSCmdlet.ShouldProcess($manifestPath, "remove Application nodes: $($removed -join ', ')")) {
        Write-ClientCBSStep "Replacing AppxManifest.xml"
        Grant-ClientCBSAdminAccess -Path $manifestPath
        Copy-Item -LiteralPath $tempManifest -Destination $manifestPath -Force

        Write-ClientCBSStep "Re-registering MicrosoftWindows.Client.CBS"
        Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ForceApplicationShutdown -Verbose
        Write-ClientCBSOk "Client.CBS re-registered"

        try {
            Restore-ClientCBSTrustedInstallerOwner -Path $manifestPath
            Restore-ClientCBSTrustedInstallerOwner -Path $pkg.InstallLocation
        } catch {
            Write-ClientCBSWarn "Owner restore warning: $($_.Exception.Message)"
        }

        Clear-ClientCBSStartCaches
        if (-not $NoRestartShell) {
            Restart-ClientCBSShell
        }
    }

    Remove-Item -LiteralPath $tempManifest -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        ManifestPath = $manifestPath
        RemovedApplications = @($removed | Select-Object -Unique)
        Changed = $true
    }
}

function Remove-ClientCBSStartAppsResidue {
    [CmdletBinding()]
    param(
        [string]$StateRepositoryPath = $script:StateRepositoryPath,
        [string]$WorkRoot = $env:TEMP,
        [switch]$InstallMySQLite
    )

    Assert-ClientCBSAdministrator
    Import-ClientCBSSqliteModule -InstallMySQLite:$InstallMySQLite

    if (-not (Test-Path -LiteralPath $StateRepositoryPath)) {
        throw "Database not found: $StateRepositoryPath"
    }

    $appRepoDir = Split-Path $StateRepositoryPath -Parent

    Write-ClientCBSStep "Current Get-StartApps result"
    $current = @(Get-ClientCBSTargetStartApps)
    if ($current.Count -gt 0) {
        $current | Format-Table Name, AppID -AutoSize
    } else {
        Write-Host "No target Start menu entries found before database cleanup."
    }

    Write-ClientCBSStep "Creating consistent database copy"
    $tempDir = Join-Path $WorkRoot ("ClientCBS-StartApps-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $workDb = Join-Path $tempDir "StateRepository-Machine.cleaned.srd"

    try {
        if (Test-Path -LiteralPath $workDb) {
            Remove-Item -LiteralPath $workDb -Force
        }
        $escapedWorkDb = Escape-ClientCBSSqlString $workDb
        Invoke-ClientCBSSqliteQuery -Path $StateRepositoryPath -Query "VACUUM INTO '$escapedWorkDb';" | Out-Null
        Write-Host "Created clean copy via VACUUM INTO: $workDb"
    } catch {
        Write-ClientCBSWarn "VACUUM INTO failed: $($_.Exception.Message)"
        Write-ClientCBSWarn "Falling back to direct copy of .srd and sidecar files."
        Copy-Item -LiteralPath $StateRepositoryPath -Destination $workDb -Force
        foreach ($sidecar in @("$StateRepositoryPath-wal", "$StateRepositoryPath-shm")) {
            if (Test-Path -LiteralPath $sidecar) {
                Copy-Item -LiteralPath $sidecar -Destination (Join-Path $tempDir (Split-Path -Leaf $sidecar)) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-ClientCBSStep "Reading target rows in copied database"

    $appRows = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _ApplicationID, Package, PackageRelativeApplicationId, ApplicationUserModelId,
       DisplayName, Executable, Entrypoint, Activation, AppListEntry
FROM Application
WHERE ApplicationUserModelId IN (
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost',
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup'
)
OR PackageRelativeApplicationId IN ('WebExperienceHost','WindowsBackup')
OR Executable IN ('WebExperienceHostApp.exe','WindowsBackupClient.exe');
"@

    $identityRows = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _ApplicationIdentityID, ApplicationUserModelId
FROM ApplicationIdentity
WHERE ApplicationUserModelId IN (
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost',
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup'
);
"@

    $tileRows = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _PrimaryTileID, Application, Package, TileId
FROM PrimaryTile
WHERE TileId IN ('WebExperienceHost','WindowsBackup');
"@

    $mrtRows = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _MrtApplicationID, Application, DisplayNameReference, DescriptionReference
FROM MrtApplication
WHERE DisplayNameReference LIKE '%WebExperienceHost%'
   OR DisplayNameReference LIKE '%WindowsBackup%'
   OR DisplayNameReference LIKE '%GetStarted%'
   OR DisplayNameReference LIKE '%GetStartedAppName%'
   OR DisplayNameReference LIKE '%WindowsBackupHostName%'
   OR DescriptionReference LIKE '%WebExperienceHost%'
   OR DescriptionReference LIKE '%WindowsBackup%';
"@

    Write-Host "`n--- Application rows ---"
    $appRows | Format-List
    Write-Host "`n--- ApplicationIdentity rows ---"
    $identityRows | Format-List
    Write-Host "`n--- PrimaryTile rows ---"
    $tileRows | Format-List
    Write-Host "`n--- MrtApplication rows ---"
    $mrtRows | Format-List

    $totalFound = @($appRows).Count + @($identityRows).Count + @($tileRows).Count + @($mrtRows).Count
    if ($totalFound -eq 0) {
        Write-ClientCBSWarn "The copied database has no target residue. Replacement will still be scheduled to flush possible live WAL residue."
    }

    $appIds = @($appRows | ForEach-Object { $_._ApplicationID })
    $appIds += @($tileRows | ForEach-Object { $_.Application })
    $appIds += @($mrtRows | ForEach-Object { $_.Application })
    $appIds = @($appIds | Where-Object { $_ -ne $null -and "$_" -ne "" } | Select-Object -Unique)

    $identityIds = @($identityRows | ForEach-Object { $_._ApplicationIdentityID } | Where-Object { $_ -ne $null -and "$_" -ne "" } | Select-Object -Unique)
    $primaryTileIds = @($tileRows | ForEach-Object { $_._PrimaryTileID } | Where-Object { $_ -ne $null -and "$_" -ne "" } | Select-Object -Unique)

    $appIdList = ConvertTo-ClientCBSNumberList $appIds
    $identityIdList = ConvertTo-ClientCBSNumberList $identityIds
    $primaryTileIdList = ConvertTo-ClientCBSNumberList $primaryTileIds

    $activationIds = @()
    $activationIds += @($appRows | ForEach-Object { $_.Activation })
    if ($appIdList) {
        $extensionActivations = Select-ClientCBSSafe -Path $workDb -Query "
SELECT Activation
FROM ApplicationExtension
WHERE Application IN ($appIdList)
  AND Activation IS NOT NULL;
"
        $activationIds += @($extensionActivations | ForEach-Object { $_.Activation })
    }
    $activationIds = @($activationIds | Where-Object { $_ -ne $null -and "$_" -ne "" } | Select-Object -Unique)
    $activationIdList = ConvertTo-ClientCBSNumberList $activationIds

    Write-ClientCBSStep "Resolved IDs"
    Write-Host "Application IDs:       $appIdList"
    Write-Host "ApplicationIdentity:   $identityIdList"
    Write-Host "PrimaryTile IDs:       $primaryTileIdList"
    Write-Host "Activation IDs:        $activationIdList"

    Write-ClientCBSStep "Temporarily dropping triggers in copied database"
    $triggers = @(Invoke-ClientCBSSqliteQuery -Path $workDb -Query "SELECT name, sql FROM sqlite_master WHERE type='trigger' ORDER BY name;")
    Write-Host "Triggers found: $($triggers.Count)"

    foreach ($trigger in $triggers) {
        if ([string]::IsNullOrWhiteSpace($trigger.name)) {
            continue
        }
        $quotedName = Quote-ClientCBSSqlName $trigger.name
        Invoke-ClientCBSSqliteQuery -Path $workDb -Query "DROP TRIGGER IF EXISTS $quotedName;" | Out-Null
    }

    Write-ClientCBSStep "Deleting target residue in copied database"
    Invoke-ClientCBSSqliteQuery -Path $workDb -Query "PRAGMA foreign_keys=OFF;" | Out-Null

    if ($identityIdList) {
        if (Test-ClientCBSColumnExists -Path $workDb -Table "ApplicationUser" -Column "ApplicationIdentity") {
            Remove-ClientCBSSqlRows -Path $workDb -Table "ApplicationUser" -Where "ApplicationIdentity IN ($identityIdList)" | Out-Null
        }
        if (Test-ClientCBSColumnExists -Path $workDb -Table "PrimaryTileUser" -Column "ApplicationIdentity") {
            Remove-ClientCBSSqlRows -Path $workDb -Table "PrimaryTileUser" -Where "ApplicationIdentity IN ($identityIdList)" | Out-Null
        }
        if (Test-ClientCBSColumnExists -Path $workDb -Table "SecondaryTileUser" -Column "ApplicationIdentity") {
            Remove-ClientCBSSqlRows -Path $workDb -Table "SecondaryTileUser" -Where "ApplicationIdentity IN ($identityIdList)" | Out-Null
        }
    }

    if ($primaryTileIdList) {
        foreach ($tableName in @("PrimaryTileUser", "PrimaryTileUserChangelog")) {
            foreach ($columnName in @("PrimaryTile", "_PrimaryTileID")) {
                if (Test-ClientCBSColumnExists -Path $workDb -Table $tableName -Column $columnName) {
                    Remove-ClientCBSSqlRows -Path $workDb -Table $tableName -Where "$columnName IN ($primaryTileIdList)" | Out-Null
                }
            }
        }
    }

    if ($appIdList) {
        foreach ($tableName in @(
            "ApplicationContentUriRule",
            "ApplicationProperty",
            "ApplicationExtension",
            "ApplicationUser",
            "MrtApplication",
            "DefaultTile",
            "PrimaryTile"
        )) {
            if (Test-ClientCBSColumnExists -Path $workDb -Table $tableName -Column "Application") {
                Remove-ClientCBSSqlRows -Path $workDb -Table $tableName -Where "Application IN ($appIdList)" | Out-Null
            }
        }

        Remove-ClientCBSSqlRows -Path $workDb -Table "Application" -Where "_ApplicationID IN ($appIdList)" | Out-Null
    }

    if (Test-ClientCBSTableExists -Path $workDb -Table "PrimaryTile") {
        Remove-ClientCBSSqlRows -Path $workDb -Table "PrimaryTile" -Where "TileId IN ('WebExperienceHost','WindowsBackup')" | Out-Null
    }

    if (Test-ClientCBSTableExists -Path $workDb -Table "MrtApplication") {
        Remove-ClientCBSSqlRows -Path $workDb -Table "MrtApplication" -Where "
            DisplayNameReference LIKE '%WebExperienceHost%'
            OR DisplayNameReference LIKE '%WindowsBackup%'
            OR DisplayNameReference LIKE '%GetStarted%'
            OR DisplayNameReference LIKE '%GetStartedAppName%'
            OR DisplayNameReference LIKE '%WindowsBackupHostName%'
            OR DescriptionReference LIKE '%WebExperienceHost%'
            OR DescriptionReference LIKE '%WindowsBackup%'
        " | Out-Null
    }

    if ($identityIdList) {
        Remove-ClientCBSSqlRows -Path $workDb -Table "ApplicationIdentity" -Where "_ApplicationIdentityID IN ($identityIdList)" | Out-Null
    } elseif (Test-ClientCBSTableExists -Path $workDb -Table "ApplicationIdentity") {
        Remove-ClientCBSSqlRows -Path $workDb -Table "ApplicationIdentity" -Where "
            ApplicationUserModelId IN (
                'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost',
                'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup'
            )
        " | Out-Null
    }

    if ($activationIdList) {
        if (Test-ClientCBSColumnExists -Path $workDb -Table "ApplicationExtension" -Column "Activation") {
            Remove-ClientCBSSqlRows -Path $workDb -Table "ApplicationExtension" -Where "Activation IN ($activationIdList)" | Out-Null
        }
        Remove-ClientCBSSqlRows -Path $workDb -Table "Activation" -Where "_ActivationID IN ($activationIdList)" | Out-Null
    }

    Write-ClientCBSStep "Restoring triggers in copied database"
    foreach ($trigger in $triggers) {
        if ([string]::IsNullOrWhiteSpace($trigger.sql)) {
            continue
        }
        Invoke-ClientCBSSqliteQuery -Path $workDb -Query $trigger.sql | Out-Null
    }

    $triggerCountAfter = @(Invoke-ClientCBSSqliteQuery -Path $workDb -Query "SELECT name FROM sqlite_master WHERE type='trigger';").Count
    Write-Host "Triggers restored: $triggerCountAfter"
    if ($triggerCountAfter -ne $triggers.Count) {
        throw "Trigger count mismatch. Expected $($triggers.Count), got $triggerCountAfter."
    }

    Write-ClientCBSStep "Verifying target residue in cleaned database"
    $remainApp = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _ApplicationID, PackageRelativeApplicationId, ApplicationUserModelId, Executable, Entrypoint, AppListEntry
FROM Application
WHERE ApplicationUserModelId IN (
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost',
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup'
)
OR PackageRelativeApplicationId IN ('WebExperienceHost','WindowsBackup')
OR Executable IN ('WebExperienceHostApp.exe','WindowsBackupClient.exe');
"@

    $remainIdentity = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _ApplicationIdentityID, ApplicationUserModelId
FROM ApplicationIdentity
WHERE ApplicationUserModelId IN (
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost',
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup'
);
"@

    $remainTile = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _PrimaryTileID, Application, Package, TileId
FROM PrimaryTile
WHERE TileId IN ('WebExperienceHost','WindowsBackup');
"@

    $remainMrt = Select-ClientCBSSafe -Path $workDb -Query @"
SELECT _MrtApplicationID, Application, DisplayNameReference
FROM MrtApplication
WHERE DisplayNameReference LIKE '%WebExperienceHost%'
   OR DisplayNameReference LIKE '%WindowsBackup%'
   OR DisplayNameReference LIKE '%GetStarted%'
   OR DisplayNameReference LIKE '%WindowsBackupHostName%';
"@

    if (@($remainApp).Count -gt 0 -or @($remainIdentity).Count -gt 0 -or @($remainTile).Count -gt 0 -or @($remainMrt).Count -gt 0) {
        Write-ClientCBSWarn "Remaining Application rows:"
        $remainApp | Format-List
        Write-ClientCBSWarn "Remaining ApplicationIdentity rows:"
        $remainIdentity | Format-List
        Write-ClientCBSWarn "Remaining PrimaryTile rows:"
        $remainTile | Format-List
        Write-ClientCBSWarn "Remaining MrtApplication rows:"
        $remainMrt | Format-List
        throw "Target residue still exists in cleaned database. Aborting."
    }

    Write-ClientCBSOk "Target residue removed from cleaned database."

    Write-ClientCBSStep "Checking cleaned database integrity"
    $integrity = Invoke-ClientCBSSqliteQuery -Path $workDb -Query "PRAGMA integrity_check;"
    $integrity | Format-Table -AutoSize
    if (($integrity | Out-String) -notmatch "ok") {
        throw "integrity_check did not return ok. Aborting."
    }

    Write-ClientCBSStep "Preparing cleaned database next to live database"
    $newDb = Join-Path $appRepoDir "StateRepository-Machine.srd.new"
    Grant-ClientCBSAdminAccess -Path $appRepoDir
    Copy-Item -LiteralPath $workDb -Destination $newDb -Force
    & icacls.exe $newDb /grant "*S-1-5-32-544:F" | Out-Null

    Write-ClientCBSStep "Scheduling boot-time replacement and sidecar deletion"
    Schedule-ClientCBSRebootReplace -Source $newDb -Destination $StateRepositoryPath

    foreach ($sidecar in @("$StateRepositoryPath-wal", "$StateRepositoryPath-shm", "$StateRepositoryPath-journal")) {
        if (Test-Path -LiteralPath $sidecar) {
            Schedule-ClientCBSRebootDelete -Path $sidecar
            Write-Host "Scheduled delete on reboot: $sidecar"
        } else {
            Write-Host "Sidecar not present: $sidecar"
        }
    }

    Write-ClientCBSOk "Cleaned database is scheduled to replace the live database on next reboot."
    Write-Host "Run this to apply it:" -ForegroundColor Yellow
    Write-Host "  shutdown /r /t 0" -ForegroundColor Yellow

    [pscustomobject]@{
        WorkDatabase = $workDb
        ScheduledReplacement = $true
        NewDatabase = $newDb
    }
}

function Get-ClientCBSLatestBackupDirectory {
    param([string]$BackupRoot = (Join-Path (Get-ClientCBSProjectRoot) "backups"))

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        return $null
    }

    Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "AppxManifest.Client.CBS.backup.xml") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Test-ClientCBSBackupStateRepositoryIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$InstallMySQLite
    )

    try {
        Import-ClientCBSSqliteModule -InstallMySQLite:$InstallMySQLite
        $integrity = Invoke-ClientCBSSqliteQuery -Path $Path -Query "PRAGMA integrity_check;"
        if (($integrity | Out-String) -notmatch "ok") {
            throw "PRAGMA integrity_check did not return ok."
        }
        Write-ClientCBSOk "Backup StateRepository integrity_check = ok"
        return $true
    } catch {
        Write-ClientCBSWarn "Could not verify backup StateRepository database: $($_.Exception.Message)"
        return $false
    }
}

function Restore-ClientCBS {
    [CmdletBinding()]
    param(
        [string]$BackupPath,
        [switch]$RestoreStateRepository,
        [switch]$InstallMySQLite,
        [switch]$Force,
        [switch]$NoRestartShell
    )

    Assert-ClientCBSAdministrator

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $latestBackup = Get-ClientCBSLatestBackupDirectory
        if (-not $latestBackup) {
            throw "No backup path was provided and no backup directory was found under backups."
        }
        $BackupPath = $latestBackup.FullName
        Write-ClientCBSWarn "No -BackupPath was provided. Using latest backup: $BackupPath"
    }

    $resolvedBackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
    $backupManifest = Join-Path $resolvedBackupPath "AppxManifest.Client.CBS.backup.xml"
    $backupStateRepo = Join-Path $resolvedBackupPath "StateRepository-Machine.srd.backup"

    if (-not (Test-Path -LiteralPath $backupManifest)) {
        throw "Backup manifest not found: $backupManifest"
    }

    Write-ClientCBSStep "Reading current MicrosoftWindows.Client.CBS package"
    $pkg = Get-ClientCBSPackage
    $targetManifest = Join-Path $pkg.InstallLocation "AppxManifest.xml"

    Write-Host "Current package: $($pkg.PackageFullName)"
    Write-Host "InstallLocation: $($pkg.InstallLocation)"

    Write-ClientCBSStep "Checking backup manifest identity"
    [xml]$backupXml = Get-Content -LiteralPath $backupManifest -Encoding UTF8
    $identity = $backupXml.Package.Identity

    $backupName = [string]$identity.Name
    $backupVersion = [string]$identity.Version
    $backupArch = [string]$identity.ProcessorArchitecture

    Write-Host "Backup Manifest: Name=$backupName Version=$backupVersion Arch=$backupArch"
    Write-Host "Current Package: Version=$($pkg.Version) Arch=$($pkg.Architecture)"

    if ($backupName -ne $script:ClientCBSPackageName) {
        throw "The backup manifest is not $($script:ClientCBSPackageName)."
    }

    if (([string]$pkg.Version -ne $backupVersion) -and (-not $Force)) {
        throw "Version mismatch. Current=$($pkg.Version), Backup=$backupVersion. Use -Force only if you intentionally want to restore this old manifest."
    }

    Stop-ClientCBSShell

    Write-ClientCBSStep "Restoring AppxManifest.xml"
    Grant-ClientCBSAdminAccess -Path $targetManifest
    Copy-Item -LiteralPath $backupManifest -Destination $targetManifest -Force
    Write-ClientCBSOk "Restored manifest: $targetManifest"

    Write-ClientCBSStep "Re-registering MicrosoftWindows.Client.CBS"
    Add-AppxPackage -DisableDevelopmentMode -Register $targetManifest -ForceApplicationShutdown -Verbose
    Write-ClientCBSOk "Client.CBS re-registered"

    try {
        Restore-ClientCBSTrustedInstallerOwner -Path $targetManifest
        Restore-ClientCBSTrustedInstallerOwner -Path $pkg.InstallLocation
    } catch {
        Write-ClientCBSWarn "Owner restore warning: $($_.Exception.Message)"
    }

    if ($RestoreStateRepository) {
        if (-not (Test-Path -LiteralPath $backupStateRepo)) {
            throw "StateRepository backup not found: $backupStateRepo"
        }

        Write-ClientCBSWarn "StateRepository restore is high-risk. Use it only if Windows Update, Appx registration, or StartApps is abnormal."
        [void](Test-ClientCBSBackupStateRepositoryIntegrity -Path $backupStateRepo -InstallMySQLite:$InstallMySQLite)

        $stateRepoDir = Split-Path $script:StateRepositoryPath -Parent
        $restoreCandidate = Join-Path $stateRepoDir "StateRepository-Machine.srd.restore"

        Write-ClientCBSStep "Preparing StateRepository restore file"
        Grant-ClientCBSAdminAccess -Path $stateRepoDir
        if (Test-Path -LiteralPath $script:StateRepositoryPath) {
            Grant-ClientCBSAdminAccess -Path $script:StateRepositoryPath
        }

        Copy-Item -LiteralPath $backupStateRepo -Destination $restoreCandidate -Force
        & icacls.exe $restoreCandidate /grant "*S-1-5-32-544:F" | Out-Null

        Write-ClientCBSStep "Scheduling StateRepository restore on next reboot"
        Schedule-ClientCBSRebootReplace -Source $restoreCandidate -Destination $script:StateRepositoryPath

        foreach ($sidecar in @("$($script:StateRepositoryPath)-wal", "$($script:StateRepositoryPath)-shm", "$($script:StateRepositoryPath)-journal")) {
            if (Test-Path -LiteralPath $sidecar) {
                Schedule-ClientCBSRebootDelete -Path $sidecar
                Write-Host "Scheduled delete on reboot: $sidecar"
            } else {
                Write-Host "Sidecar not present: $sidecar"
            }
        }

        Write-ClientCBSOk "StateRepository restore scheduled for next reboot"
    }

    Clear-ClientCBSStartCaches
    if (-not $NoRestartShell) {
        Write-ClientCBSStep "Starting explorer"
        Start-Process explorer.exe
    }

    Show-ClientCBSState

    if ($RestoreStateRepository) {
        Write-Host "Run this to apply the scheduled StateRepository restore:" -ForegroundColor Yellow
        Write-Host "  shutdown /r /t 0" -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function @(
    "Backup-ClientCBS",
    "Clear-ClientCBSStartCaches",
    "Get-ClientCBSTargetStartApps",
    "Remove-ClientCBSManifestApplications",
    "Remove-ClientCBSStartAppsResidue",
    "Reset-ClientCBSStartAppsCache",
    "Restart-ClientCBSShell",
    "Restore-ClientCBS",
    "Show-ClientCBSState"
)
