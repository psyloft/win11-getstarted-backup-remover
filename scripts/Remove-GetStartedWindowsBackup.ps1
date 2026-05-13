#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$SkipBackup,
    [switch]$SkipManifest,
    [switch]$CleanStartAppsResidue,
    [switch]$InstallMySQLite,
    [switch]$NoRestartShell
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot "src\ClientCBS.Tools.psm1"
$backupRoot = Join-Path $projectRoot "backups"

Import-Module $modulePath -Force

if (-not $SkipBackup) {
    Backup-ClientCBS -BackupRoot $backupRoot -InstallMySQLite:$InstallMySQLite | Out-Host
}

if (-not $SkipManifest) {
    Remove-ClientCBSManifestApplications -NoRestartShell:$NoRestartShell | Out-Host
}

Show-ClientCBSState

if ($CleanStartAppsResidue) {
    Remove-ClientCBSStartAppsResidue -InstallMySQLite:$InstallMySQLite | Out-Host
} else {
    Write-Host ""
    Write-Host "If Get-StartApps still returns the target entries, rerun with:" -ForegroundColor Yellow
    Write-Host "  .\scripts\Remove-GetStartedWindowsBackup.ps1 -SkipBackup -SkipManifest -CleanStartAppsResidue -InstallMySQLite" -ForegroundColor Yellow
}
